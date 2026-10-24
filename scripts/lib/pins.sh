#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# Install-time trust anchors. Refresh with scripts/update-pins.sh.
#
# Packages come from vendor apt repositories whose signing keys are verified
# against these fingerprints before the keyring is written. apt then checks
# every package signature, and unattended-upgrades keeps them patched.

# https://pkgs.tailscale.com — key URL takes the Ubuntu codename.
TAILSCALE_APT_URL="https://pkgs.tailscale.com/stable/ubuntu"
TAILSCALE_APT_KEY_FPR="2596A99EAAB33821893C0A79458CA832957F5868"

# https://mise.jdx.dev/installing-mise.html#apt
MISE_APT_URL="https://mise.jdx.dev/deb"
MISE_APT_KEY_URL="https://mise.jdx.dev/gpg-key.pub"
MISE_APT_KEY_FPR="24853EC9F655CE80B48E6C3A8B81C9D17413A06D"

# Oh My Zsh is sourced by every dev login shell: pin the commit.
OHMYZSH_REPO="https://github.com/ohmyzsh/ohmyzsh.git"
OHMYZSH_COMMIT="2100c630ba4bd67bb48802c3e7da893a4fdaa1a0"

# LazyVim starter is a template; lazy.nvim fetches the plugins it lists on
# first launch, so pinning the starter alone would add nothing.
LAZYVIM_STARTER_REPO="https://github.com/LazyVim/starter.git"
