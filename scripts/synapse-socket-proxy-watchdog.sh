#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Watchdog del socket del socket-proxy (stack synapse-obs).
# Alloy lee la API de Docker por el socket unix que el socket-proxy crea en el volumen
# `synapse-obs_socket_proxy`. Si Swarm recrea las tareas del nodo (reconexión con el manager,
# update, reinicio concurrente), la tarea vieja borra el socket al apagarse DESPUÉS de que la nueva
# lo creó: el proxy sigue "Running" pero el volumen queda vacío y el nodo deja de enviar logs
# (incidentes del 2026-09-29 y 2026-09-30). El healthcheck de la imagen solo prueba TCP y no lo ve.
#
# Corre cada minuto (timer). Si el proxy está corriendo y el socket falta en 2 chequeos seguidos,
# reinicia el contenedor del proxy (recrea el socket; Alloy lo retoma solo). Sin red ni credenciales.
# ==============================================================================
set -uo pipefail

TAG="synapse-socket-proxy-watchdog"
VOLUME="${SOCKET_PROXY_VOLUME:-synapse-obs_socket_proxy}"
SERVICE="${SOCKET_PROXY_SERVICE:-synapse-obs_socket-proxy}"
STATE="/run/${TAG}.misses"

log() { logger -t "$TAG" "$*"; }

container=$(docker ps -q --filter "label=com.docker.swarm.service.name=${SERVICE}" | head -n1)
# Sin proxy en este nodo (o arrancando): nada que vigilar.
[ -z "$container" ] && { rm -f "$STATE"; exit 0; }

mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' "$VOLUME" 2>/dev/null) || { rm -f "$STATE"; exit 0; }

if [ -S "${mountpoint}/docker.sock" ]; then
  rm -f "$STATE"
  exit 0
fi

misses=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$misses" > "$STATE"
if [ "$misses" -lt 2 ]; then
  log "socket ausente en ${VOLUME} (chequeo ${misses}/2)"
  exit 0
fi

log "socket ausente en ${VOLUME} ${misses} chequeos seguidos: reiniciando ${container:0:12} (${SERVICE})"
if docker restart "$container" >/dev/null; then
  rm -f "$STATE"
  log "socket-proxy reiniciado"
else
  log "ERROR: no se pudo reiniciar ${container:0:12}"
  exit 1
fi
