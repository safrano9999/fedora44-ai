#!/usr/bin/env bash
set -euo pipefail
[ -f /named_volumes/CODEX_AUTH/auth.json ] || exit 0
for model in 5.5 5.4 5.4-mini; do openclaw models aliases add "codex-$model" "openai/gpt-$model"; done
