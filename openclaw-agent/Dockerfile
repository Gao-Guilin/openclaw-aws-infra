FROM node:24-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV OPENCLAW_VERSION=2026.6.11

# Container-internal OpenClaw paths.
# These are NOT host paths.
ENV OPENCLAW_HOME=/home/node/.openclaw
ENV OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json

# Runtime data path. The ECS task definition mounts EFS here.
ENV OPENCLAW_RUNTIME_DIR=/app/runtime

ENV AWS_REGION=ap-northeast-1
ENV AWS_DEFAULT_REGION=ap-northeast-1
ENV PATH="/opt/venv/bin:${PATH}"

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       python3 \
       python3-pip \
       python3-venv \
       ca-certificates \
       curl \
       jq \
       git \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g openclaw@${OPENCLAW_VERSION}

WORKDIR /app

COPY requirements.txt /app/requirements.txt

RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r /app/requirements.txt

COPY config /app/config
COPY prompts /app/prompts
COPY skills /app/skills
COPY VERSION /app/VERSION
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh \
    && find /app/skills -name "run_with_ecs_credentials.sh" -exec chmod +x {} \; \
    && mkdir -p /home/node/.openclaw \
    && mkdir -p /app/runtime \
    && chown -R node:node /app \
    && chown -R node:node /home/node/.openclaw

USER node

RUN openclaw plugins install @openclaw/deepseek-provider

ENTRYPOINT ["/app/entrypoint.sh"]
