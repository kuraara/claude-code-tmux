# claude-code-tmux

Claude Code running in a persistent tmux session, plus a small web page that
handles sign-in.

- **Signed in:** the page shows a green "You're all set" banner.
- **Not signed in:** the page shows the Anthropic sign-in link and a box to
  paste the code back into Claude.

## Files

| Path | What it does |
| --- | --- |
| `Dockerfile` | `node:22-bookworm` + tmux, ripgrep, Claude Code. Re-numbers the `node` user to `PUID:PGID`. |
| `docker-compose.yml` | Portainer stack. Builds the image from this repo. |
| `src/entrypoint.sh` | Starts the tmux session, then runs the page in the foreground. |
| `src/claude-runner.sh` | Runs `claude` inside tmux and restarts it if it exits. |
| `src/auth-server.js` | The sign-in page (plain Node, no dependencies). |
| `src/tmux.conf` | tmux settings (50k scrollback, mouse on). |

Inside the container, the source is at `/opt/claude-stack`.

## Deploy (Portainer)

1. On the host, run `setup-media-access.sh` once. It creates the `media`
   group and `/media/disk1/claude`, and prints `PUID` and `PGID`.
2. Push this repo to your Git server.
3. In Portainer, go to Stacks → Add stack → Repository. Set the compose path
   to `docker-compose.yml`.
4. Add the environment variables `PUID`, `PGID` and `TZ=Australia/Perth`.
5. Deploy. The first build downloads Claude Code and takes a few minutes.

Portainer's web editor and upload options can't build images. The stack has to
come from a Git repository.

## Sign in

1. Open `http://<host>:8765`.
2. Click **Start sign-in**. If a login-method menu appears, click
   **Press Enter** to accept the default (your Claude account).
3. Click **Sign in with Anthropic**, approve access, copy the code, then
   paste it into the page.
4. The page switches to the green banner.

Your sign-in is saved in `/media/disk1/claude/.home`, so it survives
rebuilds.

If the page can't find a link, attach to the session and sign in by hand:

```
docker exec -it claude-code tmux attach -t claude
```

Detach with `Ctrl-b`, then `d`. If Claude exits, it restarts after 5 seconds.
Press `Ctrl-C` during the countdown to get a shell instead.

## Conversations

Claude resumes the most recent conversation every time it starts, including
after a container restart or reboot. If there's nothing to resume, it starts a
new conversation. To start fresh, run `/clear` inside Claude. To turn resuming
off, set `CLAUDE_CONTINUE=0`.

## Update Claude Code

The auto-updater is off because the CLI is baked into the image. To update,
set `CLAUDE_CODE_VERSION` to a specific version (or change its value), then
redeploy so the image rebuilds.

## Security

The page has no login of its own. It only accepts input while Claude is
signed out, and it only sends the login command, Enter, or a sign-in code to
tmux. Keep it on your LAN. Don't forward port 8765 through the router.

## Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `PUID` / `PGID` | 1000 / 1500 | Build-time uid and gid for file ownership. |
| `CLAUDE_CODE_VERSION` | latest | Build-time npm version. |
| `AUTH_PAGE_HOST_PORT` | 8765 | Host port for the page. |
| `CLAUDE_CONTINUE` | 1 | Resumes the last conversation on start. Set to `0` to always start fresh. |
| `CLAUDE_ARGS` | (none) | Extra flags for `claude`, for example `--model opus`. |
| `SKIP_ONBOARDING` | 1 | Skips the first-run theme screens. Only applies if `~/.claude.json` doesn't exist yet. |
| `ANTHROPIC_API_KEY` | (unset) | Uses API-key auth instead of a Claude account sign-in. |
