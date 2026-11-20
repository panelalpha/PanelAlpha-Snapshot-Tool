#!/bin/bash
# Builds pasnap.sh from src/*.sh.
# pasnap.sh stays one file: users download it with wget and installed copies
# update themselves from main/pasnap.sh, so do not edit pasnap.sh by hand.
# Usage: ./build.sh          write pasnap.sh
#        ./build.sh --check  exit 1 if pasnap.sh does not match src/
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat src/[0-9][0-9]-*.sh > "$tmp"
bash -n "$tmp"

if [[ "${1:-}" == "--check" ]]; then
    if ! cmp -s "$tmp" pasnap.sh; then
        echo "pasnap.sh is out of date. Run ./build.sh and commit the result." >&2
        exit 1
    fi
    echo "pasnap.sh is up to date"
    exit 0
fi

cp "$tmp" pasnap.sh
chmod +x pasnap.sh
echo "Built pasnap.sh ($(wc -l < pasnap.sh) lines)"
