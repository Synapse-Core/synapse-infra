#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Automated Docker Cleanup & Storage Pruning
# Schedule: Daily at 03:30 UTC across all Swarm nodes
# ==============================================================================
set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "🧹 [Docker Cleanup] Iniciando barrida de contenedores e imágenes huérfanas..."

# 1. Eliminar contenedores muertos / detenidos
log "1. Purgando contenedores salidos/muertos..."
docker container prune -f || true

# 2. Eliminar imágenes 'dangling' (sin etiqueta)
log "2. Purgando imágenes huérfanas (dangling)..."
docker image prune -f || true

# 3. Eliminar imágenes con más de 7 días no asociadas a contenedores activos
log "3. Purgando imágenes no utilizadas antiguas (>168h)..."
docker image prune -a --filter "until=168h" -f || true

# 4. Eliminar redes no utilizadas
log "4. Purgando redes Docker huérfanas..."
docker network prune -f || true

# 5. Eliminar cache de construcción (buildx)
log "5. Purgando build cache antiguo (>168h)..."
docker builder prune -a --filter "until=168h" -f || true

log "📊 Espacio en disco actual tras limpieza:"
df -h / | awk 'NR==1 || NR==2'
log "✅ [Docker Cleanup] Barrida de mantenimiento finalizada."
