#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Emisor de eventos de contenedor al centinela (ops-worker), Fase 2.5.
# Escucha `docker events` (stream bloqueante: sin polling, sin CPU en reposo) y reenvía die / oom /
# health_status de contenedores de servicios Swarm a POST /api/v1/ops/node-events.
# El centinela decide: salida normal o dentro de un deploy → ignorar; staging → solo consola;
# prod → incidente. Solo viajan metadatos del evento, nunca contenido de logs.
# Credenciales en /etc/synapse/ops-worker.env (root:root 0600), igual que el heartbeat.
# ==============================================================================
set -uo pipefail

OPS_ENV_FILE="${OPS_ENV_FILE:-/etc/synapse/ops-worker.env}"
# shellcheck disable=SC1090
[ -r "$OPS_ENV_FILE" ] && . "$OPS_ENV_FILE"
OPS_WORKER="${OPS_WORKER_URL:-https://ops.synapse-tec.com}"
NODE_NAME="${SYNAPSE_NODE_NAME:-$(hostname)}"

if [ -z "${CF_ACCESS_CLIENT_ID:-}" ] || [ -z "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  echo "synapse-docker-events: falta el service token de Access en $OPS_ENV_FILE" >&2
  exit 1
fi

# Envío con 3 intentos y backoff (1s, 4s, 9s). Corre en segundo plano para no frenar el stream.
send() {
  local payload="$1" attempt code
  for attempt in 1 2 3; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --connect-timeout 5 \
      -X POST "${OPS_WORKER}/api/v1/ops/node-events" \
      -H "Content-Type: application/json" \
      -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
      -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
      -d "$payload" 2>/dev/null) || code="000"
    if [ "$code" = "200" ]; then return 0; fi
    sleep $((attempt * attempt))
  done
  echo "synapse-docker-events: no se pudo enviar el evento tras 3 intentos (último HTTP ${code})" >&2
}

echo "synapse-docker-events: escuchando eventos de contenedor en ${NODE_NAME}"
docker events \
  --filter type=container \
  --filter event=die \
  --filter event=oom \
  --filter event=health_status \
  --format '{{json .}}' |
while IFS= read -r line; do
  # Solo contenedores de servicios Swarm; los contenedores sueltos se ignoran.
  payload=$(printf '%s' "$line" | jq -c --arg node "$NODE_NAME" '
    (.Actor.Attributes // {}) as $a
    | select($a["com.docker.swarm.service.name"] != null)
    | (.Action // .status // "") as $action
    | {
        node: $node,
        service: $a["com.docker.swarm.service.name"],
        action: (if ($action | startswith("health_status")) then "health_status" else $action end),
        exitCode: ($a.exitCode // null),
        health: (if ($action | startswith("health_status: ")) then ($action | ltrimstr("health_status: ")) else null end),
        at: ((.time // now) | todate)
      }' 2>/dev/null) || continue
  [ -n "$payload" ] && send "$payload" &
done
