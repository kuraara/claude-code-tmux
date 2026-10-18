#!/usr/bin/env bash
# claude-runner.sh — runs inside the tmux window. Keeps Claude running:
# if it exits, it restarts after 5 s. Press Ctrl-C during the countdown
# to get a shell instead; type `exit` in that shell to restart Claude.
#
# CLAUDE_CONTINUE=1 (default): resume the most recent conversation in this
# folder. If there's nothing to resume, it starts a new conversation.
# Use /clear inside Claude when you want a fresh conversation.
trap : INT
cd "${WORKDIR:-/workspace}"

start_claude() {
  # shellcheck disable=SC2086  # CLAUDE_ARGS is intentionally word-split
  if [ "${CLAUDE_CONTINUE:-1}" = "1" ]; then
    local started=$SECONDS
    claude --continue ${CLAUDE_ARGS:-}
    local rc=$?
    # A quick non-zero exit means there was no conversation to continue.
    if [ "$rc" -ne 0 ] && [ $((SECONDS - started)) -lt 10 ]; then
      echo "No previous conversation to continue. Starting a new one."
      claude ${CLAUDE_ARGS:-}
      return $?
    fi
    return $rc
  fi
  claude ${CLAUDE_ARGS:-}
}

while true; do
  start_claude
  rc=$?
  echo
  echo "[claude exited with code $rc] Restarting in 5 s. Ctrl-C for a shell."
  if ! sleep 5; then
    echo "Shell opened. Type 'exit' to restart Claude."
    bash -l
  fi
done
