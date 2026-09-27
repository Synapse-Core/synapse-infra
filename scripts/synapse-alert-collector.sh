#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Out-of-Band Emergency Alert Collector & Dispatcher
# Recolecta logs de journald, telemetría y despacha alertas a Cloudflare OpsAgent
# ==============================================================================
set -euo pipefail

# Argumentos recibidos (compatibles con systemd OnFailure)
# $1: Nombre del servicio fallido (%i o %n)
# $2: Hostname del nodo (%H)
# $3: Código de salida
SERVICE="${1:-unknown-service}"
NODE="${2:-$(hostname)}"
EXIT_CODE="${3:-1}"

LOG_FILE="/var/log/synapse-alert-collector.log"
OPS_ENDPOINT="https://synapse-ops-worker.andresquinon25.workers.dev/api/v1/ops/emergency-alert"
OPS_KEY="synapse-ops-internal-key-secure-2026"

# Helper de logging dual (stdout/stderr + log file local)
log() {
    local msg="[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
    echo "$msg" >&2
    if [ -w "$LOG_FILE" ] 2>/dev/null || { [ ! -e "$LOG_FILE" ] && touch "$LOG_FILE" 2>/dev/null && chmod 666 "$LOG_FILE" 2>/dev/null; }; then
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log "Iniciando recolección de alerta para '${SERVICE}' en '${NODE}' (exitCode: ${EXIT_CODE})..."

# 1. Extracción de logs recientes (últimas 50 líneas de journalctl)
LOGS=$(journalctl -u "${SERVICE}" -n 50 --no-pager 2>&1 || true)
if [ -z "${LOGS}" ]; then
    LOGS="-- No entries --"
fi

# 2. Recolección de telemetría de sistema
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "N/A")
DISK_FREE=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")
MEMORY=$(free -m 2>/dev/null | awk 'NR==2 {printf "%sMB/%sMB", $3, $2}' || echo "N/A")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 3. Construcción del payload JSON seguro vía jq
PAYLOAD=$(jq -n \
  --arg service "$SERVICE" \
  --arg node "$NODE" \
  --arg timestamp "$TIMESTAMP" \
  --arg exitCode "$EXIT_CODE" \
  --arg severity "CRITICAL" \
  --arg logs "$LOGS" \
  --arg diskUsage "$DISK_USAGE" \
  --arg diskFree "$DISK_FREE" \
  --arg memory "$MEMORY" \
  '{
    service: $service,
    node: $node,
    timestamp: $timestamp,
    exitCode: ($exitCode | tonumber? // $exitCode),
    severity: $severity,
    logs: $logs,
    telemetry: {
      diskUsage: $diskUsage,
      diskFree: $diskFree,
      memory: $memory
    }
  }')

# 4. Despacho HTTP a Cloudflare OpsAgent (timeout 10s)
RESPONSE=$(curl -s -S --max-time 10 --connect-timeout 5 \
  -X POST "$OPS_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "X-Synapse-Internal-Key: $OPS_KEY" \
  -d "$PAYLOAD" 2>&1)
CURL_STATUS=$?

if [ $CURL_STATUS -eq 0 ]; then
    log "Despacho exitoso a ops-worker: ${RESPONSE}"
    echo "${RESPONSE}"
    exit 0
else
    log "ERROR al despachar alerta a ops-worker (curl exit: ${CURL_STATUS}): ${RESPONSE}"
    echo "{\"success\": false, \"error\": \"Curl failed with exit code ${CURL_STATUS}: ${RESPONSE}\"}"
    exit 1
fi
