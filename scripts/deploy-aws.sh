#!/bin/bash
set -e

# ============================================================
# Hermes Agent - AWS Deployment Script
# Deploys hermes-agent to the production server with a
# restricted api_server toolset (safe for multi-user use).
#
# Usage: bash scripts/deploy-aws.sh
#
# Reads secrets from your LOCAL ~/.hermes/.env and
# ~/.hermes/config.yaml — never hardcoded here.
# ============================================================

PORT=22
SSH_URL=root@34.230.59.2
APP_DIR=/app/hermes-agent
HERMES_HOME=/root/.hermes

# --- Read secrets from local environment ---
LOCAL_ENV=~/.hermes/.env
LOCAL_CONFIG=~/.hermes/config.yaml

if [ ! -f "$LOCAL_ENV" ]; then
  echo "ERROR: $LOCAL_ENV not found"
  exit 1
fi

API_SERVER_KEY=$(grep '^API_SERVER_KEY=' "$LOCAL_ENV" | cut -d= -f2-)
BEDROCK_API_KEY=$(grep 'api_key:' "$LOCAL_CONFIG" | head -1 | awk '{print $2}')
BEDROCK_BASE_URL=$(grep 'base_url:' "$LOCAL_CONFIG" | head -1 | awk '{print $2}')
BEDROCK_MODEL=$(grep 'default:' "$LOCAL_CONFIG" | head -1 | awk '{print $2}')

if [ -z "$API_SERVER_KEY" ]; then
  echo "ERROR: API_SERVER_KEY not found in $LOCAL_ENV"
  exit 1
fi

echo "Deploying hermes-agent to $SSH_URL..."

ssh -p $PORT $SSH_URL bash << ENDSSH
set -e

# 1. Clone or pull latest code
if [ -d "$APP_DIR" ]; then
  echo "Pulling latest code..."
  cd $APP_DIR && git fetch origin && git checkout ai2alpha && git pull --ff-only origin ai2alpha
else
  echo "Cloning repo..."
  cd /app && git clone --branch ai2alpha https://github.com/simbajigege/hermes-agent
fi

cd $APP_DIR

# 2. Install / update dependencies
if ! command -v uv &>/dev/null; then
  pip install uv
fi

if [ ! -d ".venv" ]; then
  uv venv
fi

source .venv/bin/activate
uv pip install -e ".[all]" --quiet

# 3. Write ~/.hermes/.env (API server config)
# Only set specific keys — preserves any manually added keys (e.g. FIRECRAWL_API_KEY)
mkdir -p $HERMES_HOME
touch $HERMES_HOME/.env
_set_env() {
  local key=\$1 val=\$2
  if grep -q "^\${key}=" "$HERMES_HOME/.env" 2>/dev/null; then
    sed -i "s|^\${key}=.*|\${key}=\${val}|" "$HERMES_HOME/.env"
  else
    echo "\${key}=\${val}" >> "$HERMES_HOME/.env"
  fi
}
_set_env API_SERVER_ENABLED true
_set_env API_SERVER_HOST    127.0.0.1
_set_env API_SERVER_PORT    8642
_set_env API_SERVER_KEY     ${API_SERVER_KEY}

# 4. Write ~/.hermes/config.yaml
# - Uses same Bedrock credentials as local
# - Restricts api_server to safe read-only toolsets (no terminal/file/code execution)
cat > $HERMES_HOME/config.yaml << 'EOF'
model:
  provider: custom
  base_url: ${BEDROCK_BASE_URL}
  api_key: ${BEDROCK_API_KEY}
  default: ${BEDROCK_MODEL}

platform_toolsets:
  api_server:
    - web
    - vision
    - memory
    - todo

agent:
  max_turns: 30
  gateway_timeout: 600

skills:
  guard_agent_created: true

sessions:
  auto_prune: true
  retention_days: 90

security:
  tirith_enabled: true
  redact_secrets: true
EOF

# 5. Stop existing gateway if running
if [ -f "$APP_DIR/gateway.pid" ]; then
  OLD_PID=\$(cat "$APP_DIR/gateway.pid")
  if kill -0 "\$OLD_PID" 2>/dev/null; then
    echo "Stopping existing gateway (PID \$OLD_PID)..."
    kill "\$OLD_PID"
    sleep 2
  fi
  rm -f "$APP_DIR/gateway.pid"
fi

# 6. Start hermes gateway in background
cd $APP_DIR
source .venv/bin/activate
nohup hermes gateway > $APP_DIR/gateway.log 2>&1 &
echo \$! > $APP_DIR/gateway.pid
echo "Hermes gateway started (PID \$(cat $APP_DIR/gateway.pid))"

# 7. Wait and verify API server is up
sleep 15
if curl -sf http://127.0.0.1:8642/health > /dev/null; then
  echo "API server is up at http://127.0.0.1:8642"
else
  echo "WARNING: API server health check failed. Check $APP_DIR/gateway.log"
fi

ENDSSH

echo ""
echo "Deploy complete."
echo "Tail logs: ssh $SSH_URL 'tail -f $APP_DIR/gateway.log'"
