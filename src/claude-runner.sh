#!/usr/bin/env bash
# claude-runner.sh — runs inside the tmux window. Keeps Claude running:
# if it exits, it restarts after 5 s. Press Ctrl-C during the countdown
# to get a shell instead; type `exit` in that shell to restart Claude.
trap : INT
cd "${WORKDIR:-/workspace}"

while true; do
  # shellcheck disable=SC2086  # CLAUDE_ARGS is intentionally word-split
  claude ${CLAUDE_ARGS:-}
  rc=$?
  echo
  echo "[claude exited with code $rc] Restarting in 5 s. Ctrl-C for a shell."
  if ! sleep 5; then
    echo "Shell opened. Type 'exit' to restart Claude."
    bash -l
  fi
done
