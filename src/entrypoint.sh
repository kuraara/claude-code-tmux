#!/usr/bin/env bash
# entrypoint.sh — starts Claude Code inside a detached tmux session, then runs
# the sign-in status page in the foreground (keeps the container alive).
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOME="${HOME:-/workspace/.home}"
WORKDIR="${WORKDIR:-/workspace}"
SESSION="${TMUX_SESSION:-claude}"

umask 002                       # new files group-writable (media group)
mkdir -p "$HOME/.claude"
chmod 700 "$HOME" 2>/dev/null || true   # credentials live in here

git config --global --add safe.directory '*' 2>/dev/null || true

# Skip the first-run theme/welcome screens so the sign-in prompt comes up
# directly. Only written if no config exists yet; never overwrites yours.
if [ "${SKIP_ONBOARDING:-1}" = "1" ] && [ ! -f "$HOME/.claude.json" ]; then
  printf '{\n  "hasCompletedOnboarding": true,\n  "theme": "dark"\n}\n' > "$HOME/.claude.json"
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux -f "$STACK_DIR/tmux.conf" new-session -d -s "$SESSION" \
    -x "${TMUX_COLS:-400}" -y "${TMUX_ROWS:-50}" -c "$WORKDIR" \
    "$STACK_DIR/claude-runner.sh"
fi
echo "Claude is running in tmux session '$SESSION'."
echo "Attach: docker exec -it ${CONTAINER_NAME:-claude-code} tmux attach -t $SESSION"

exec node "$STACK_DIR/auth-server.js"
