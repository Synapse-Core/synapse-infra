#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Métricas de memoria por contenedor desde cgroup v2 (Fase 3 observabilidad v2).
# Lee memory.current, memory.max y memory.events de cada contenedor de Swarm y escribe un archivo
# en formato Prometheus (textfile) que Alloy expone con prometheus.exporter.unix.
# Reemplaza a cAdvisor: con el image store de containerd, cAdvisor necesitaría el socket de
# containerd (equivale a root en el host). Solo lectura de cgroups; sin red ni credenciales.
# ==============================================================================
set -uo pipefail

OUT_DIR="${SYNAPSE_METRICS_DIR:-/var/lib/synapse-metrics}"
OUT="${OUT_DIR}/containers.prom"
CG=/sys/fs/cgroup/system.slice
mkdir -p "$OUT_DIR"
tmp=$(mktemp "${OUT}.XXXXXX")

{
  echo "# HELP synapse_container_memory_current_bytes Memoria en uso del cgroup del contenedor."
  echo "# TYPE synapse_container_memory_current_bytes gauge"
  echo "# HELP synapse_container_memory_max_bytes Límite de memoria del cgroup (0 = sin límite)."
  echo "# TYPE synapse_container_memory_max_bytes gauge"
  echo "# HELP synapse_container_memory_events_total Eventos de memory.events (max, high, oom, oom_kill)."
  echo "# TYPE synapse_container_memory_events_total counter"
  docker ps --no-trunc --format '{{.ID}} {{.Label "com.docker.swarm.service.name"}} {{.Label "com.docker.stack.namespace"}}' |
  while read -r id svc stack; do
    [ -n "$svc" ] || continue
    d="$CG/docker-${id}.scope"
    [ -r "$d/memory.current" ] || continue
    l="swarm_service=\"${svc}\",stack=\"${stack}\""
    echo "synapse_container_memory_current_bytes{${l}} $(cat "$d/memory.current")"
    max=$(cat "$d/memory.max"); [ "$max" = "max" ] && max=0
    echo "synapse_container_memory_max_bytes{${l}} ${max}"
    while read -r ev n; do
      echo "synapse_container_memory_events_total{${l},event=\"${ev}\"} ${n}"
    done < "$d/memory.events"
  done
} > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$OUT"
