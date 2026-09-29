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
OPS_ENDPOINT="${OPS_WORKER}/api/v1/ops/emergency-alert"

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
# `|| CURL_STATUS=$?`: con set -e, un curl fallido abortaba el script antes de registrar el error.
CURL_STATUS=0
RESPONSE=$(curl -s -S --max-time 10 --connect-timeout 5 \
  -X POST "$OPS_ENDPOINT" \
  -H "Content-Type: application/json" \
  "${AUTH_HEADERS[@]}" \
  -d "$PAYLOAD" 2>&1) || CURL_STATUS=$?

if [ $CURL_STATUS -eq 0 ]; then
    log "Despacho exitoso a ops-worker: ${RESPONSE}"
    echo "${RESPONSE}"
    exit 0
else
    log "ERROR al despachar alerta a ops-worker (curl exit: ${CURL_STATUS}): ${RESPONSE}"
    echo "{\"success\": false, \"error\": \"Curl failed with exit code ${CURL_STATUS}: ${RESPONSE}\"}"
    exit 1
fi
