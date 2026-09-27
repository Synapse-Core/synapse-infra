#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Swarm Node Heartbeat Reporter
# Reporta estado del nodo al OpsAgent cada 60s vía backend proxy
# ==============================================================================
set -euo pipefail

OPS_BACKEND="${OPS_BACKEND_URL:-https://api-dev.synapse-tec.com}"
OPS_KEY="${OPS_INTERNAL_KEY:-synapse-ops-internal-key-secure-2026}"
NODE_NAME="${HOSTNAME:-$(hostname)}"
LOG_FILE="/var/log/synapse-heartbeat.log"

log() {
    local msg="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
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
  -X POST "${OPS_BACKEND}/api/v1/admin/resilience/heartbeat" \
  -H "Content-Type: application/json" \
  -H "X-Synapse-Internal-Key: $OPS_KEY" \
  -d "$PAYLOAD" 2>&1) || true

if echo "$RESPONSE" | grep -q '"success":true'; then
    log "Heartbeat OK: ${NODE_NAME}"
else
    log "Heartbeat FAILED: ${NODE_NAME} - ${RESPONSE}"
fi
