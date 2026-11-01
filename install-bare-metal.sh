#!/usr/bin/env bash
# install-bare-metal.sh: Claude Code in tmux, started at boot, with the sign-in page.
# No Docker. For a Raspberry Pi (64-bit OS) or any Debian/Ubuntu machine with systemd.
#
#   curl -fsSL https://raw.githubusercontent.com/kuraara/claude-code-tmux/main/install-bare-metal.sh | sudo bash
#
# Run it with sudo from the account Claude should run as (it uses $SUDO_USER).
# Safe to run again: it updates the files and restarts the services.
#
# Settings (put them after sudo, e.g. `sudo PORT=8080 bash install-bare-metal.sh`):
#   CLAUDE_USER   account Claude runs as                 (default: whoever ran sudo)
#   WORKDIR       folder Claude works in                 (default: ~/workspace)
#   PROJECT_REPO  repo cloned into WORKDIR, where Claude starts; "none" to skip
#                 (default: https://github.com/kuraara/shiny-trinkets.git)
#   PORT          sign-in page port                      (default: 8765)
#   SESSION       tmux session name                      (default: claude)
#   CLAUDE_ARGS   extra arguments for claude             (default: none)
#
# Afterwards:
#   Sign in:      http://<this machine>:8765
#   Attach:       tmux attach -t claude        (as CLAUDE_USER; detach with Ctrl-b then d)
#   Restart:      sudo systemctl restart claude-tmux claude-auth
#   Logs:         journalctl -u claude-tmux -u claude-auth
#   Remove:       sudo systemctl disable --now claude-tmux claude-auth
set -euo pipefail

STACK_REPO=${STACK_REPO:-https://github.com/kuraara/claude-code-tmux.git}
PROJECT_REPO=${PROJECT_REPO:-https://github.com/kuraara/shiny-trinkets.git}
CLAUDE_USER=${CLAUDE_USER:-${SUDO_USER:-}}
PORT=${PORT:-8765}
SESSION=${SESSION:-claude}
INSTALL_DIR=/opt/claude-tmux

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "install-bare-metal: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run it with sudo"
[ -n "$CLAUDE_USER" ] && [ "$CLAUDE_USER" != root ] \
  || die "run it with sudo from your own account (or set CLAUDE_USER=name); Claude shouldn't run as root"
id "$CLAUDE_USER" >/dev/null 2>&1 || die "no such user: $CLAUDE_USER"
command -v systemctl >/dev/null || die "needs systemd"
case $(uname -m) in
  aarch64|arm64|x86_64) ;;
  *) die "Claude Code needs a 64-bit OS (this is $(uname -m)). On a Pi, install Raspberry Pi OS 64-bit." ;;
esac

USER_HOME=$(getent passwd "$CLAUDE_USER" | cut -d: -f6)
USER_GROUP=$(id -gn "$CLAUDE_USER")
WORKDIR=${WORKDIR:-$USER_HOME/workspace}
as_user() { sudo -u "$CLAUDE_USER" -H "$@"; }

say "Packages: tmux, git, Node.js and friends"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq tmux git curl ca-certificates ripgrep jq less nodejs >/dev/null
NODE=$(command -v node) || die "Node.js didn't install"

say "Claude Code (native installer, as $CLAUDE_USER; it keeps itself up to date)"
if [ -x "$USER_HOME/.local/bin/claude" ]; then
  echo "already installed: $(as_user "$USER_HOME/.local/bin/claude" --version 2>/dev/null || echo '?')"
else
  as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
fi
[ -x "$USER_HOME/.local/bin/claude" ] || die "Claude Code didn't install to $USER_HOME/.local/bin/claude"
# so `claude` works in the user's own shells too
grep -qs '.local/bin' "$USER_HOME/.profile" \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' | as_user tee -a "$USER_HOME/.profile" >/dev/null

say "Runner and sign-in page -> $INSTALL_DIR"
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
git clone -q --depth 1 "$STACK_REPO" "$SRC/stack"
install -d -m 755 "$INSTALL_DIR"
install -m 755 "$SRC/stack/src/claude-runner.sh" "$INSTALL_DIR/"
install -m 644 "$SRC/stack/src/auth-server.js" "$SRC/stack/src/tmux.conf" "$INSTALL_DIR/"
sed -i 's/ claude-code | / claude | /' "$INSTALL_DIR/tmux.conf"

say "Working folder: $WORKDIR"
as_user mkdir -p "$WORKDIR"
START_DIR=$WORKDIR
if [ "$PROJECT_REPO" != none ]; then
  NAME=$(basename "$PROJECT_REPO" .git)
  if [ -d "$WORKDIR/$NAME/.git" ]; then
    echo "$NAME is already there; leaving it as it is"
  else
    as_user git clone -q "$PROJECT_REPO" "$WORKDIR/$NAME"
  fi
  START_DIR=$WORKDIR/$NAME
fi

# Skip the first-run theme/welcome screens so the sign-in prompt comes up directly.
# Only when there's no config yet; never overwrites one.
if [ ! -f "$USER_HOME/.claude.json" ]; then
  printf '{\n  "hasCompletedOnboarding": true,\n  "theme": "dark"\n}\n' | as_user tee "$USER_HOME/.claude.json" >/dev/null
fi
as_user mkdir -p "$USER_HOME/.claude"

say "Services: claude-tmux (Claude in tmux) and claude-auth (the page on :$PORT)"
cat > /etc/default/claude-tmux <<EOF
# Read by claude-tmux.service and claude-auth.service. Run "sudo systemctl restart claude-tmux claude-auth" after changing it.
HOME=$USER_HOME
PATH=$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
WORKDIR=$START_DIR
TMUX_SESSION=$SESSION
AUTH_PAGE_PORT=$PORT
CLAUDE_CONTINUE=1
CLAUDE_ARGS=${CLAUDE_ARGS:-}
CONTAINER_NAME=$(hostname)
ATTACH_CMD=tmux attach -t $SESSION
RESTART_HINT='journalctl -u claude-tmux -u claude-auth -n 50\\nsudo systemctl restart claude-tmux claude-auth'
EOF

cat > /etc/systemd/system/claude-tmux.service <<EOF
[Unit]
Description=Claude Code in tmux session "$SESSION"
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=$CLAUDE_USER
Group=$USER_GROUP
EnvironmentFile=/etc/default/claude-tmux
WorkingDirectory=$START_DIR
UMask=0002
ExecStart=/usr/bin/tmux -f $INSTALL_DIR/tmux.conf new-session -d -s \${TMUX_SESSION} -x 400 -y 50 -c \${WORKDIR} $INSTALL_DIR/claude-runner.sh
ExecStop=/usr/bin/tmux kill-session -t \${TMUX_SESSION}
# If the tmux server is stopped (or the session is closed), bring it back.
Restart=always
RestartSec=5
# Claude and anything it starts are children of the tmux server; stop them with it.
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/claude-auth.service <<EOF
[Unit]
Description=Claude Code sign-in page on port $PORT
After=claude-tmux.service
Wants=claude-tmux.service

[Service]
User=$CLAUDE_USER
Group=$USER_GROUP
EnvironmentFile=/etc/default/claude-tmux
ExecStart=$NODE $INSTALL_DIR/auth-server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q claude-tmux claude-auth
systemctl restart claude-tmux claude-auth

sleep 3
ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if systemctl is-active -q claude-tmux && systemctl is-active -q claude-auth; then
  say "Done"
  echo "Sign in:  http://${ADDR:-$(hostname)}:$PORT"
  echo "Attach:   tmux attach -t $SESSION   (as $CLAUDE_USER; Ctrl-b then d to detach)"
  echo "Claude starts in $START_DIR and comes back by itself after a reboot."
else
  systemctl --no-pager status claude-tmux claude-auth | tail -20
  die "a service didn't start; see above"
fi
