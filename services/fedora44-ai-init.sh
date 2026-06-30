#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/optional_persistence.sh init
/usr/local/bin/named_volume_links.sh

find /usr/local/share/fedora44-ai/bin -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) -print \
    | sort \
    | while IFS= read -r script; do
        case "$script" in
            *.sh) /bin/bash "$script" ;;
            *.py) /usr/bin/python3 "$script" ;;
        esac
    done
