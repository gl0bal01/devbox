#!/usr/bin/env bash
# Shared test helpers sourced by bats unit tests.
# Provides standalone copies of setup.sh functions for isolation.

# ---------------------------------------------------------------------------
# render_env — standalone copy extracted from setup.sh for testability.
# Renders a *.template file via whitelisted envsubst.
# Refuses to overwrite an existing destination.
# Sets mode 0600 on the rendered destination.
#
# Usage: render_env <template_path> <dest_path> '$VAR1 $VAR2'
# ---------------------------------------------------------------------------
render_env() {
  local tmpl="$1" dest="$2" whitelist="$3"
  if [ -e "$dest" ]; then
    # Destination exists — do not overwrite (idempotency contract)
    return 0
  fi
  envsubst "$whitelist" <"$tmpl" >"$dest"
  chmod 0600 "$dest"
}
