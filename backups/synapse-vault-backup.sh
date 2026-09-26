#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — HashiCorp Vault Raft Snapshot Backup to Cloudflare R2
# Node Target: synapse (Vault Manager Node)
# Schedule: Daily at 02:30 UTC
# Encryption: AES-256-CBC
# Destination: Cloudflare R2 (s3:backups/vault/)
# ==============================================================================
set -euo pipefail

BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/tmp/synapse_vault_backups"
ENC_PASS="Synapse_2026_Enterprise_Secure_AES256_Backup_Key_Safe!"
RCLONE_CONF="/etc/rclone/rclone.conf"
RETENTION_DAYS=30

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    log "🧹 Limpiando archivos temporales locales..."
    rm -rf "${BACKUP_DIR}"
}
trap cleanup EXIT

log "🚀 Iniciando respaldo del clúster HashiCorp Vault (Raft Data)..."

VAULT_CONTAINER=$(docker ps -q -f name=synapse-base_vault || true)
if [ -z "${VAULT_CONTAINER}" ]; then
    log "❌ Contenedor de Vault no encontrado en este nodo. Abortando."
    exit 1
fi

RAW_TAR="${BACKUP_DIR}/synapse_vault_${BACKUP_DATE}.tar.gz"
ENC_TAR="${RAW_TAR}.enc"

log "📦 Empaquetando almacenamiento Raft de Vault..."
docker exec -u 0 "${VAULT_CONTAINER}" tar -czf - -C /vault file > "${RAW_TAR}"

log "🔐 Cifrando respaldo con AES-256-CBC..."
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:${ENC_PASS}" -in "${RAW_TAR}" -out "${ENC_TAR}"
sha256sum "${ENC_TAR}" > "${ENC_TAR}.sha256"
rm -f "${RAW_TAR}"

log "☁️ Subiendo snapshot de Vault a Cloudflare R2..."
rclone --config "${RCLONE_CONF}" --no-update-modtime copy "${ENC_TAR}" r2:backups/vault/
rclone --config "${RCLONE_CONF}" --no-update-modtime copy "${ENC_TAR}.sha256" r2:backups/vault/

log "🕒 Aplicando política de retención (${RETENTION_DAYS} días) en Cloudflare R2..."
rclone --config "${RCLONE_CONF}" delete --min-age "${RETENTION_DAYS}d" r2:backups/vault/ || true

log "✅ Respaldo de HashiCorp Vault completado exitosamente."
