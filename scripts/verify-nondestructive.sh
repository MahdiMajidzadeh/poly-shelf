#!/bin/bash
# Non-destructive invariant gate (§8 "Trust invariant").
#
# Usage:
#   scripts/verify-nondestructive.sh snapshot <corpus-dir>   # before exercising the app
#   scripts/verify-nondestructive.sh verify   <corpus-dir>   # after — fails on ANY change
#
# Checksums every file (content + name + mtime) in the corpus. Run `snapshot`,
# exercise Poly Shelf fully against the corpus (index, tag, rename, export…),
# then run `verify`. Any diff means a code path wrote to user files — a bug.

set -euo pipefail

MODE="${1:?usage: $0 snapshot|verify <corpus-dir>}"
CORPUS="${2:?usage: $0 snapshot|verify <corpus-dir>}"
SNAPSHOT_FILE="${TMPDIR:-/tmp}/polyshelf-corpus-snapshot.txt"

snapshot() {
    cd "$CORPUS"
    # content hash + relative path + mtime for every file
    find . -type f -print0 | sort -z | while IFS= read -r -d '' f; do
        printf '%s  %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f" "$(stat -f %m "$f")"
    done
}

case "$MODE" in
    snapshot)
        snapshot > "$SNAPSHOT_FILE"
        echo "Snapshot of $(wc -l < "$SNAPSHOT_FILE" | tr -d ' ') files written to $SNAPSHOT_FILE"
        ;;
    verify)
        if [[ ! -f "$SNAPSHOT_FILE" ]]; then
            echo "ERROR: no snapshot found at $SNAPSHOT_FILE — run snapshot first" >&2
            exit 2
        fi
        CURRENT="$(mktemp)"
        snapshot > "$CURRENT"
        if diff -u "$SNAPSHOT_FILE" "$CURRENT"; then
            echo "OK: corpus unchanged — non-destructive invariant holds."
        else
            echo "FAIL: corpus was modified — the app wrote to user files!" >&2
            exit 1
        fi
        ;;
    *)
        echo "usage: $0 snapshot|verify <corpus-dir>" >&2
        exit 2
        ;;
esac
