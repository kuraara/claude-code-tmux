# Claude Code in tmux, with a sign-in status page on :8765
FROM node:22-bookworm

# Match host ownership: PUID = kuraara's uid, PGID = the "media" group gid.
ARG PUID=1000
ARG PGID=1500
# Pin a version (e.g. 2.1.205) or change this value to force a fresh install
# on the next build; "latest" alone is cached by Docker after the first build.
ARG CLAUDE_CODE_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends tmux ripgrep less procps jq \
 && rm -rf /var/lib/apt/lists/*

# Re-number the image's built-in "node" user to PUID:PGID.
RUN groupmod -o -g "${PGID}" node \
 && usermod -o -u "${PUID}" -g "${PGID}" node

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# Stack source lives in the image at /opt/claude-stack (readable from a shell).
COPY src/ /opt/claude-stack/
RUN chmod 755 /opt/claude-stack/*.sh

ENV HOME=/workspace/.home \
    WORKDIR=/workspace \
    TMUX_SESSION=claude \
    AUTH_PAGE_PORT=8765 \
    CLAUDE_CONTINUE=1 \
    DISABLE_AUTOUPDATER=1

USER node
WORKDIR /workspace
EXPOSE 8765

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:8765/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/opt/claude-stack/entrypoint.sh"]
