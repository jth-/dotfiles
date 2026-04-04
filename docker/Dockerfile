# S.P.Q.R. Agent Workspace — Base Image
# Node 22 + Python 3.12 + Claude Code + common dev tools

FROM node:22-bookworm

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ── System Dependencies ──────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    jq \
    curl \
    wget \
    postgresql-client \
    less \
    procps \
    htop \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI ──────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ── Agent User (non-root) ───────────────────────────────────────
RUN groupadd -g 1000 agent 2>/dev/null || true \
    && useradd -m -u 1000 -g 1000 -s /bin/bash agent 2>/dev/null || true \
    && mkdir -p /home/agent/.claude \
    && chown -R agent:agent /home/agent

# ── Workspace ────────────────────────────────────────────────────
RUN mkdir -p /workspace && chown agent:agent /workspace
WORKDIR /workspace

# ── Entrypoint ───────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER agent
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
