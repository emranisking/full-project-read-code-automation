#!/usr/bin/env bash

# read-code.sh — read every source file in the project the same way Claude does
# (git-aware, .gitignore-respecting, text-only, `cat -n` line numbering) and
# store ALL of it in ONE single txt file.
#
# ./read-code.sh
#   -> ./project-code.txt
#
# ./read-code.sh -o /tmp/dump.txt
#   custom output file
#
# ./read-code.sh -x '*_test.go' -x 'docs/*'
#
# CODE_DUMP_FILE=/tmp/x.txt ./read-code.sh

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# GLOBAL VARIABLES
# ══════════════════════════════════════════════════════════════════════════════

# Root of the project being read.
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ►► THE GLOBAL ◄◄
# Every single line of code from the project lands here.
CODE_DUMP_FILE="${CODE_DUMP_FILE:-$PROJECT_ROOT/project-code.txt}"

# ►► THE GLOBAL BUFFER ◄◄
# Code is accumulated in memory in this one variable,
# then flushed to $CODE_DUMP_FILE.
# FLUSH_AT keeps memory bounded on big repos.
CODE_DUMP=""
CODE_DUMP_BYTES=0
FLUSH_AT=$((4 * 1024 * 1024)) # Flush to disk every ~4 MB

# Behaviour knobs
LINE_NUMBERS=1                  # 1 = prefix " 12\t" like Claude's reader
MAX_FILE_BYTES=$((512 * 1024))  # Skip any single file larger than this
MAX_FILE_LINES=0                # 0 = unlimited; else truncate long files
APPEND=0                        # 1 = append to the txt instead of truncating
TRACKED_ONLY=0                  # 1 = git-tracked files only (skip new files)
QUIET=0

# Paths never worth dumping (match against repo-relative path).
EXCLUDE_GLOBS=(
    'vendor/*'
    '*/vendor/*'
    'node_modules/*'
    '*/node_modules/*'
    '.git/*'
    'dist/*'
    'build/*'
    'bin/*'
    'tmp/*'
    'go.sum'
    '*.lock'
    '*-lock.json'
    '*-lock.yaml'
    '*.png'
    '*.jpg'
    '*.jpeg'
    '*.gif'
    '*.ico'
    '*.svg'
    '*.webp'
    '*.pdf'
    '*.zip'
    '*.gz'
    '*.tar'
    '*.woff'
    '*.woff2'
    '*.ttf'
    '*.exe'
    '*.so'
    '*.dylib'
    '*.min.js'
    '*.min.css'
    '*.map'
)

INCLUDE_GLOBS=() # If non-empty, ONLY these are dumped

# Counters / report state
FILES=()
SKIPPED=()
FILES_WRITTEN=0
LINES_TOTAL=0
BYTES_TOTAL=0


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

log() {
    (( QUIET )) || printf '%s\n' "$*" >&2
}

die() {
    printf 'read-code: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//'

    cat <<'USAGE'
Options:
  -o, --output FILE       the single txt file to write (default: project-code.txt)
  -r, --root DIR          project root to read (default: script directory)
  -a, --append            append instead of overwriting the txt
  -n, --no-line-numbers   dump raw content without " 12\t" prefixes
  -x, --exclude GLOB      skip paths matching GLOB (repeatable)
  -i, --include GLOB      dump ONLY paths matching GLOB (repeatable)
  -s, --max-size BYTES    skip files bigger than BYTES (default: 524288)
  -l, --max-lines N       truncate each file to N lines (default: 0 = no limit)
  -t, --tracked-only      git-tracked files only (ignore new/untracked files)
  -q, --quiet             no progress output
  -h, --help              this help
USAGE
}

# Append a chunk to the global CODE_DUMP buffer,
# flushing when it gets big.
buf() {
    CODE_DUMP+="$1"
    CODE_DUMP_BYTES=$(( CODE_DUMP_BYTES + ${#1} ))

    if (( CODE_DUMP_BYTES >= FLUSH_AT )); then
        flush_buffer
    fi
}

# Write the global buffer out to the one txt file and empty it.
flush_buffer() {
    [[ -n "$CODE_DUMP" ]] || return 0

    printf '%s' "$CODE_DUMP" >> "$CODE_DUMP_FILE"

    BYTES_TOTAL=$(( BYTES_TOTAL + CODE_DUMP_BYTES ))
    CODE_DUMP=""
    CODE_DUMP_BYTES=0
}

matches_any() {
    # matches_any <path> <glob...>
    local path=$1
    shift

    local g

    for g in "$@"; do
        # shellcheck disable=SC2053
        [[ $path == $g ]] && return 0
        [[ $(basename "$path") == $g ]] && return 0
    done

    return 1
}

is_text_file() {
    # Binary files are never dumped.
    local f=$1

    [[ -s $f ]] || return 0 # Empty file counts as text

    grep -Iq . "$f" 2>/dev/null
}

file_size() {
    stat -c %s "$1" 2>/dev/null ||
        stat -f %z "$1" 2>/dev/null ||
        echo 0
}


# ══════════════════════════════════════════════════════════════════════════════
# 1. COLLECT — exactly the file set Claude would see
#    (git + .gitignore aware)
# ══════════════════════════════════════════════════════════════════════════════

collect_files() {
    local -a raw=()
    local rel

    if git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then

        if (( TRACKED_ONLY )); then
            mapfile -d '' -t raw < <(
                git -C "$PROJECT_ROOT" ls-files -z --cached
            )
        else
            # Tracked + untracked-but-not-ignored
            # = what a human sees in the repo
            mapfile -d '' -t raw < <(
                git -C "$PROJECT_ROOT" ls-files -z --cached --others --exclude-standard
            )
        fi

    else
        log "· not a git repo — falling back to find(1)"

        mapfile -d '' -t raw < <(
            find "$PROJECT_ROOT" \
                -type f \
                -not -path '*/.git/*' \
                -printf '%P\0'
        )
    fi

    for rel in "${raw[@]}"; do
        [[ -n $rel ]] || continue

        local abs="$PROJECT_ROOT/$rel"

        [[ -f $abs ]] || continue # staged-deleted

        if (( ${#INCLUDE_GLOBS[@]} )) &&
            ! matches_any "$rel" "${INCLUDE_GLOBS[@]}"; then
            continue
        fi

        if matches_any "$rel" "${EXCLUDE_GLOBS[@]}"; then
            SKIPPED+=("$rel (excluded)")
            continue
        fi

        local size
        size=$(file_size "$abs")

        if (( size > MAX_FILE_BYTES )); then
            SKIPPED+=("$rel (too large: ${size}B)")
            continue
        fi

        if ! is_text_file "$abs"; then
            SKIPPED+=("$rel (binary)")
            continue
        fi

        FILES+=("$rel")
    done

    # Stable, predictable order
    if (( ${#FILES[@]} )); then
        mapfile -t FILES < <(
            printf '%s\n' "${FILES[@]}" | LC_ALL=C sort
        )
    fi
}


# ══════════════════════════════════════════════════════════════════════════════
# 2. HEADER + MANIFEST
# ══════════════════════════════════════════════════════════════════════════════

write_header() {
    local branch commit

    branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)
    commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a)

    buf "################################################################################
PROJECT CODE DUMP
# root : $PROJECT_ROOT
# branch : $branch @ $commit
# date : $(date '+%Y-%m-%d %H:%M:%S %Z')
# files : ${#FILES[@]} dumped, ${#SKIPPED[@]} skipped
################################################################################

=============================== FILE MANIFEST ================================"

    local i=1
    local f

    for f in "${FILES[@]}"; do
        buf "$(printf '%4d. %s' "$i" "$f")"
        i=$(( i + 1 ))
    done

    if (( ${#SKIPPED[@]} )); then
        buf "------------------------------- SKIPPED --------------------------------------"

        for f in "${SKIPPED[@]}"; do
            buf " $f"
        done
    fi

    buf ""
}


# ══════════════════════════════════════════════════════════════════════════════
# 3. READ EACH FILE INTO THE GLOBAL BUFFER
# ══════════════════════════════════════════════════════════════════════════════

dump_file() {
    local rel=$1
    local abs="$PROJECT_ROOT/$1"
    local lines
    local content
    local truncated=""

    lines=$(wc -l < "$abs" | tr -d ' ')

    if (( MAX_FILE_LINES > 0 && lines > MAX_FILE_LINES )); then
        content=$(head -n "$MAX_FILE_LINES" "$abs")
        truncated="... [truncated: $lines total lines, showing first $MAX_FILE_LINES]"
        lines=$MAX_FILE_LINES
    else
        content=$(cat "$abs")
    fi

    if (( LINE_NUMBERS )); then
        content=$(printf '%s\n' "$content" | awk '{ printf "%6d\t%s\n", NR, $0 }')
    fi

    buf "================================================================================
FILE: $rel
LINES: $lines
================================================================================
$content
$truncated"

    FILES_WRITTEN=$(( FILES_WRITTEN + 1 ))
    LINES_TOTAL=$(( LINES_TOTAL + lines ))
}


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    while (( $# )); do
        case $1 in
            -o|--output)
                CODE_DUMP_FILE=$2
                shift 2
                ;;
            -r|--root)
                PROJECT_ROOT=$(cd "$2" && pwd)
                shift 2
                ;;
            -a|--append)
                APPEND=1
                shift
                ;;
            -n|--no-line-numbers)
                LINE_NUMBERS=0
                shift
                ;;
            -x|--exclude)
                EXCLUDE_GLOBS+=("$2")
                shift 2
                ;;
            -i|--include)
                INCLUDE_GLOBS+=("$2")
                shift 2
                ;;
            -s|--max-size)
                MAX_FILE_BYTES=$2
                shift 2
                ;;
            -l|--max-lines)
                MAX_FILE_LINES=$2
                shift 2
                ;;
            -t|--tracked-only)
                TRACKED_ONLY=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option: $1 (try --help)"
                ;;
        esac
    done

    [[ -d $PROJECT_ROOT ]] || die "no such directory: $PROJECT_ROOT"

    mkdir -p "$(dirname "$CODE_DUMP_FILE")"

    (( APPEND )) || : > "$CODE_DUMP_FILE"

    log "· reading $PROJECT_ROOT"

    collect_files

    (( ${#FILES[@]} )) || die "no readable source files found"

    write_header

    local f

    for f in "${FILES[@]}"; do
        log " + $f"
        dump_file "$f"
    done

    buf "################################################################################
# END — $FILES_WRITTEN files, $LINES_TOTAL lines
################################################################################"

    flush_buffer

    log "· wrote $CODE_DUMP_FILE"
    log "· totals $FILES_WRITTEN files · $LINES_TOTAL lines · $(file_size "$CODE_DUMP_FILE") bytes"

    printf '%s\n' "$CODE_DUMP_FILE"
}

main "$@"
