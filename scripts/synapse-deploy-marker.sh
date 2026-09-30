#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Marcador de deploy → centinela (ops-worker), Fase 2.6.
# Lo invoca el workflow reutilizable de deploy (paso SSH, en el manager) cuando un servicio convergió
# sin rollback. Con esto el centinela sabe qué commit corre en cada servicio y entorno: release en las
# tarjetas de error, responsable sugerido y detección de regresiones.
# Credenciales: service token `ops-ci` en /etc/synapse/ops-ci.env (root:root 0600). Nada en GitHub.
# Nunca rompe un deploy: ante cualquier problema avisa y sale con 0.
#
# Uso: synapse-deploy-marker.sh <servicio> <production|staging> <sha> <autor> [run_url]
# ==============================================================================
set -uo pipefail

SERVICE="${1:-}"
ENVIRONMENT="${2:-}"
SHA="${3:-}"
AUTHOR="${4:-}"
RUN_URL="${5:-}"

warn() { echo "⚠️  marcador de deploy omitido: $*"; exit 0; }

[ -n "$SERVICE" ] && [ -n "$SHA" ] || warn "faltan servicio o sha"
case "$ENVIRONMENT" in
  production|prod) ENV_NAME="prod" ;;
  staging)         ENV_NAME="staging" ;;
  *) warn "entorno desconocido '${ENVIRONMENT}'" ;;
esac

CREDS="${OPS_CI_ENV_FILE:-/etc/synapse/ops-ci.env}"
# shellcheck disable=SC1090
[ -r "$CREDS" ] && . "$CREDS"
[ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ] || warn "sin service token en ${CREDS}"
command -v jq >/dev/null 2>&1 || warn "jq no está instalado"

# JSON armado con jq: ningún valor se interpola como texto en el payload.
PAYLOAD=$(jq -cn \
  --arg service "$SERVICE" --arg env "$ENV_NAME" --arg sha "$SHA" \
  --arg author "$AUTHOR" --arg runUrl "$RUN_URL" \
  '{service: $service, env: $env, sha: $sha, author: (if $author == "" then null else $author end), runUrl: (if $runUrl == "" then null else $runUrl end), source: "ci"}')

for attempt in 1 2 3; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --connect-timeout 5 \
    -X POST "${OPS_WORKER_URL:-https://ops.synapse-tec.com}/api/v1/ops/deployments" \
    -H "Content-Type: application/json" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    -d "$PAYLOAD" 2>/dev/null) || code="000"
  if [ "$code" = "201" ]; then
    echo "📍 marcador de deploy enviado al centinela: ${SERVICE} · ${ENV_NAME} · ${SHA:0:7}"
    exit 0
  fi
  [ "$attempt" -lt 3 ] && sleep $((attempt * 2))
done
warn "el centinela respondió HTTP ${code} tras 3 intentos"
