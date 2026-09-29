#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Swarm Node Heartbeat Reporter
# Reporta estado del nodo al OpsAgent cada 60s vía worker directo
# El nombre del nodo se configura en el servicio systemd (Environment=SYNAPSE_NODE_NAME=xxx)
# ==============================================================================
set -euo pipefail

# Credenciales en /etc/synapse/ops-worker.env (root:root 0600), NUNCA en este script:
#   CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET  service token de Access de este nodo
#   OPS_INTERNAL_KEY                               llave interna (solo durante la transición)
# Con service token se entra por ops.synapse-tec.com (detrás de Cloudflare Access);
# sin él, por workers.dev como antes, para no cortar el reporte mientras se migra.
OPS_ENV_FILE="${OPS_ENV_FILE:-/etc/synapse/ops-worker.env}"
# shellcheck disable=SC1090
[ -r "$OPS_ENV_FILE" ] && . "$OPS_ENV_FILE"
AUTH_HEADERS=()
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  OPS_WORKER="${OPS_WORKER_URL:-https://ops.synapse-tec.com}"
  AUTH_HEADERS+=(-H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")
else
  OPS_WORKER="${OPS_WORKER_URL:-https://synapse-ops-worker.andresquinon25.workers.dev}"
fi
[ -n "${OPS_INTERNAL_KEY:-}" ] && AUTH_HEADERS+=(-H "X-Synapse-Internal-Key: ${OPS_INTERNAL_KEY}")

# SYNAPSE_NODE_NAME viene del Environment= en systemd. Si no está, usar hostname.
NODE_NAME="${SYNAPSE_NODE_NAME:-$(hostname)}"

log() {
    echo "$*"
}

DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "N/A")
DISK_FREE=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")
MEMORY=$(free -m 2>/dev/null | awk 'NR==2 {printf "%sMB/%sMB", $3, $2}' || echo "N/A")
UPTIME=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4,$5}' || echo "unknown")

PAYLOAD=$(jq -n \
  --arg nodeName "$NODE_NAME" \
  --arg status "HEALTHY" \
  --arg diskUsage "$DISK_USAGE" \
  --arg diskFree "$DISK_FREE" \
  --arg memory "$MEMORY" \
  --arg uptime "$UPTIME" \
  '{
    nodeName: $nodeName,
    status: $status,
    diskUsage: $diskUsage,
    diskFree: $diskFree,
    memory: $memory,
    uptime: $uptime
  }')

RESPONSE=$(curl -s -S --max-time 10 --connect-timeout 5 \
  -X POST "${OPS_WORKER}/api/v1/ops/heartbeat" \
  -H "Content-Type: application/json" \
  "${AUTH_HEADERS[@]}" \
  -d "$PAYLOAD" 2>&1) || true

if echo "$RESPONSE" | grep -qE '"success"[[:space:]]*:[[:space:]]*true'; then
    log "Heartbeat OK: ${NODE_NAME}"
else
    log "Heartbeat FAILED: ${NODE_NAME} - ${RESPONSE}"
fi
