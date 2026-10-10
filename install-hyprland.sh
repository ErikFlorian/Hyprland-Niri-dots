#!/usr/bin/env bash
# Entry point for hyprland + Noctalia; run only on the target Arch machine.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUNDLE_DIR="$SCRIPT_DIR"
[[ -f "$BUNDLE_DIR/manifest.json" ]] || BUNDLE_DIR="$SCRIPT_DIR/dotfiles-arch-niri"
[[ -f "$BUNDLE_DIR/install.sh" ]] || { printf '%s\n' 'Copy the complete dotfiles-arch-niri folder.' >&2; exit 1; }
export DOTFILES_COMPOSITOR=hyprland
exec bash "$BUNDLE_DIR/install.sh" "$@"
