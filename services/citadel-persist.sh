#!/usr/bin/env bash
set -euo pipefail

root=/opt/safrano9999/CITADEL
state=${CITADEL_DATA_DIR:-/persistent/citadel}

persist_dir() {
    local relative=$1 source="$root/$1" target="$state/$1"
    mkdir -p "$target"
    if [ -d "$source" ] && [ ! -L "$source" ] && [ -z "$(find "$target" -mindepth 1 -print -quit)" ]; then
        cp -a "$source/." "$target/"
    fi
    rm -rf "$source"
    ln -s "$target" "$source"
}

persist_file() {
    local relative=$1 source="$root/$1" target="$state/$1"
    mkdir -p "$(dirname "$target")"
    if [ ! -e "$target" ] && [ -e "$source" ]; then
        cp -a "$source" "$target"
    fi
    if [ -e "$target" ]; then
        rm -f "$source"
        ln -s "$target" "$source"
    fi
}

mkdir -p "$state/extensions"
persist_dir cache
persist_dir icons
persist_dir CADDYFILES

for relative in \
    ports.filter.json \
    services.json \
    ss.json \
    tailscale.json \
    last_scan.txt \
    extensions/providers_state.json; do
    persist_file "$relative"
done

for provider_dir in "$root"/extensions/enabled/*; do
    [ -d "$provider_dir" ] || continue
    provider=$(basename "$provider_dir")
    persist_file "extensions/enabled/$provider/routes.json"
done
