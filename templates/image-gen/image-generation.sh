#!/bin/bash
# Single dispatcher for every tool in this package. Usage:
#   image-generation.sh <subcommand> [--flag=value ...] [args...]
# Subcommands: generate_asset, clean_image, list_models, pick_model
#
# vite-node needs the real process cwd to actually be this package's own
# directory to resolve its dependencies correctly (confirmed empirically —
# without this, native deps like sharp fail to load at all; passing --root
# instead of actually `cd`-ing is not enough, and --root also has its own
# problem: vite-node's --script mode only strips the literal "--script"
# flag and the script path from argv when reconstructing it for the
# script's own process.argv, so any other vite-node flag like --root would
# leak straight through into the script's own arguments). Every path a
# subcommand takes (--assets-dir, --input, --output) must therefore be
# absolute — this script does no relative-path resolution against
# wherever the caller happened to be standing.
#
# generate_asset is the only subcommand that touches git: it resolves the
# OpenRouter API key from `git config openrouter.imagenapikey`, read in
# whichever repo the caller's directory is actually inside (git itself
# walks up from there to find the nearest .git), and passes it to
# generate-asset.ts as a plain --key=<value> flag. generate-asset.ts
# itself has no git/config knowledge at all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CALLER_CWD="$PWD"
SUBCOMMAND="${1:-}"
shift || true

usage() {
    echo "Usage: image-generation.sh <subcommand> [--flag=value ...] [args...]" >&2
    echo "Subcommands: generate_asset, clean_image, list_models, pick_model" >&2
    exit 1
}

cd "$SCRIPT_DIR"

case "$SUBCOMMAND" in
    generate_asset)
        API_KEY="$(git -C "$CALLER_CWD" config --get openrouter.imagenapikey 2>/dev/null || true)"
        if [ -z "$API_KEY" ]; then
            echo "git config openrouter.imagenapikey is not set in the git repo containing $CALLER_CWD." >&2
            echo "Run this from inside the repo that has it configured, or set it here:" >&2
            echo "  git config --local openrouter.imagenapikey 'YOUR_KEY_HERE'" >&2
            exit 1
        fi
        exec "$SCRIPT_DIR/node_modules/.bin/vite-node" --script "$SCRIPT_DIR/generate-asset.ts" --key="$API_KEY" "$@"
        ;;
    clean_image)
        exec "$SCRIPT_DIR/node_modules/.bin/vite-node" --script "$SCRIPT_DIR/clean-image.ts" "$@"
        ;;
    list_models)
        exec "$SCRIPT_DIR/node_modules/.bin/vite-node" --script "$SCRIPT_DIR/list-image-models.ts" "$@"
        ;;
    pick_model)
        exec "$SCRIPT_DIR/node_modules/.bin/vite-node" --script "$SCRIPT_DIR/pick-image-model.ts" "$@"
        ;;
    *)
        usage
        ;;
esac
