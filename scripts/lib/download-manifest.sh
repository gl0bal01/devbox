#!/usr/bin/env bash
# shellcheck disable=SC2034  # All MANIFEST_* vars are set for use by sourcing scripts
# Sourcable manifest of pinned download URLs and SHA256 hashes.
# Managed by scripts/update-manifest.sh — do not edit hashes by hand.
#
# After sourcing, each entry is available as:
#   MANIFEST_<NAME>_URL   — download URL
#   MANIFEST_<NAME>_SHA   — expected SHA256 (or __PLACEHOLDER__ if unresolved)
#
# To refresh all hashes: ./scripts/update-manifest.sh --apply
# To check for drift:    ./scripts/update-manifest.sh --check

# Guard against double-sourcing
if [ -n "${_DOWNLOAD_MANIFEST_LOADED:-}" ]; then
    return 0
fi
_DOWNLOAD_MANIFEST_LOADED=1

# -----------------------------------------------------------------------
# Tailscale install script
# Version: pinned-by-snapshot (mutable installer; update regularly)
# -----------------------------------------------------------------------
MANIFEST_TAILSCALE_URL="https://tailscale.com/install.sh"
MANIFEST_TAILSCALE_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# mise (dev tool version manager) install script
# Version: pinned-by-snapshot
# -----------------------------------------------------------------------
MANIFEST_MISE_URL="https://mise.run"
MANIFEST_MISE_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# lazygit — linux x86_64 tar.gz
# Version: resolved by scripts/lib/sources/lazygit.sh
# -----------------------------------------------------------------------
MANIFEST_LAZYGIT_URL="__PLACEHOLDER__"
MANIFEST_LAZYGIT_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# lazydocker — linux x86_64 install script
# Version: resolved by scripts/lib/sources/lazydocker.sh
# -----------------------------------------------------------------------
MANIFEST_LAZYDOCKER_URL="__PLACEHOLDER__"
MANIFEST_LAZYDOCKER_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Neovim — linux x86_64 tar.gz
# Version: resolved by scripts/lib/sources/neovim.sh
# -----------------------------------------------------------------------
MANIFEST_NEOVIM_URL="__PLACEHOLDER__"
MANIFEST_NEOVIM_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Rust (rustup install script)
# Version: resolved by scripts/lib/sources/rustup.sh
# -----------------------------------------------------------------------
MANIFEST_RUSTUP_URL="__PLACEHOLDER__"
MANIFEST_RUSTUP_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Bun — linux-x64 zip
# Version: resolved by scripts/lib/sources/bun.sh
# -----------------------------------------------------------------------
MANIFEST_BUN_URL="__PLACEHOLDER__"
MANIFEST_BUN_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Oh-my-Zsh install script
# Version: pinned-by-snapshot (mutable installer)
# -----------------------------------------------------------------------
MANIFEST_OHMYZSH_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
MANIFEST_OHMYZSH_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Claude Code (Anthropic CLI) install script
# Version: pinned-by-snapshot
# Source:  scripts/lib/sources/claude.sh
# -----------------------------------------------------------------------
MANIFEST_CLAUDE_URL="https://claude.ai/install.sh"
MANIFEST_CLAUDE_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# opencode install script
# Version: pinned-by-snapshot
# Source:  scripts/lib/sources/opencode.sh
# -----------------------------------------------------------------------
MANIFEST_OPENCODE_URL="https://opencode.ai/install"
MANIFEST_OPENCODE_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Goose (Block AI dev assistant) install script
# Version: pinned-by-snapshot
# Source:  scripts/lib/sources/goose.sh
# -----------------------------------------------------------------------
MANIFEST_GOOSE_URL="https://block.github.io/goose/install.sh"
MANIFEST_GOOSE_SHA="__PLACEHOLDER__"

# -----------------------------------------------------------------------
# Fabric (Daniel Miessler's AI framework) install script
# Version: pinned-by-snapshot
# Source:  scripts/lib/sources/fabric.sh
# -----------------------------------------------------------------------
MANIFEST_FABRIC_URL="https://raw.githubusercontent.com/danielmiessler/fabric/main/install.sh"
MANIFEST_FABRIC_SHA="__PLACEHOLDER__"
