#!/usr/bin/env bash
# Laptop side: shell helpers (ask, askcode, chat, ollamals) for the devbox
# Ollama API at http://ollama.internal, behind Traefik basic auth.
#
# Usage (laptop on the same tailnet, ollama.internal resolving to the server):
#   DEVBOX_OLLAMA_AUTH="$(ssh -p 5522 dev@<server> cat docker/.secrets/ollama-auth.txt)" \
#     bash scripts/laptop/ollama-setup.sh
#
# Optional: DEVBOX_OLLAMA_URL (default http://ollama.internal),
#           DEVBOX_OLLAMA_MODEL (default llama3.2).
# The credential is stored in ~/.config/devbox/ollama.curlrc (mode 0600) and
# passed to curl with -K, so it never appears on a command line. Re-run after
# rotate-ollama-auth.sh. Re-running replaces the managed block in your rc file.
set -euo pipefail

[[ "${DEVBOX_OLLAMA_AUTH:-}" == ?*:?* ]] || { sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

URL="${DEVBOX_OLLAMA_URL:-http://ollama.internal}"
MODEL="${DEVBOX_OLLAMA_MODEL:-llama3.2}"
CURLRC="${HOME}/.config/devbox/ollama.curlrc"

umask 077
mkdir -p "$(dirname "${CURLRC}")"
printf 'user = "%s"\n' "${DEVBOX_OLLAMA_AUTH}" >"${CURLRC}"
code=$(curl -s -o /dev/null -w '%{http_code}' -K "${CURLRC}" "${URL}/api/version" || true)
[ "${code}" = 200 ] || echo "warning: ${URL}/api/version answered HTTP ${code:-none} (check DNS, tailnet, credential)" >&2

case "$(basename "${SHELL:-bash}")" in
    zsh)  RC="${HOME}/.zshrc" ;;
    bash) RC="${HOME}/.bashrc" ;;
    *)    RC="${HOME}/.profile" ;;
esac
BEGIN="# >>> devbox-ollama (managed by scripts/laptop/ollama-setup.sh) >>>"
END="# <<< devbox-ollama <<<"
touch "${RC}"
if grep -qxF "${BEGIN}" "${RC}" && ! grep -qxF "${END}" "${RC}"; then
    echo "${RC} has the devbox-ollama start marker but no end marker: fix it by hand first." >&2
    exit 1
fi
awk -v b="${BEGIN}" -v e="${END}" '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "${RC}" >"${RC}.devbox-tmp"
{
    cat "${RC}.devbox-tmp"
    echo "${BEGIN}"
    echo "export DEVBOX_OLLAMA_URL=\"${URL}\" DEVBOX_OLLAMA_MODEL=\"${MODEL}\""
    cat <<'FNS'
_devbox_ollama() {  # <stream:true|false> <prompt>
    jq -n --arg m "$DEVBOX_OLLAMA_MODEL" --arg p "$2" --argjson s "$1" '{model: $m, prompt: $p, stream: $s}' \
        | curl -sS -N -K "$HOME/.config/devbox/ollama.curlrc" "$DEVBOX_OLLAMA_URL/api/generate" -d @- \
        | jq --unbuffered -rj '.response // empty'
    echo
}
ask()      { [ $# -gt 0 ] || { echo 'usage: ask "question"'; return 1; }; _devbox_ollama false "$*"; }
askcode()  { [ $# -gt 0 ] || { echo 'usage: askcode "question"'; return 1; }; _devbox_ollama false "You are a coding assistant. Answer concisely, with code when useful. Question: $*"; }
chat()     { [ $# -gt 0 ] || { echo 'usage: chat "question"'; return 1; }; _devbox_ollama true "$*"; }
ollamals() { curl -sS -K "$HOME/.config/devbox/ollama.curlrc" "$DEVBOX_OLLAMA_URL/api/tags" | jq -r '.models[].name'; }
FNS
    echo "${END}"
} >"${RC}.devbox-new"
rm -f "${RC}.devbox-tmp"
cat "${RC}.devbox-new" >"${RC}"   # keeps symlinks and mode
rm -f "${RC}.devbox-new"
echo "Updated ${RC}. Reload: source ${RC}. Commands: ask, askcode, chat, ollamals"
