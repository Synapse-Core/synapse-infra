#!/usr/bin/env bash
# ==============================================================================
# SYNAPSE-CORE — Automated Database Backup to Cloudflare R2
# Node Target: synapse-1 (Database Host)
# Schedule: Daily at 02:00 UTC
# Encryption: AES-256-CBC
# Destination: Cloudflare R2 (s3:backups/postgres/)
# ==============================================================================
set -euo pipefail

BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/tmp/synapse_db_backups"
ENC_PASS="Synapse_2026_Enterprise_Secure_AES256_Backup_Key_Safe!"
RCLONE_CONF="/etc/rclone/rclone.conf"
RETENTION_DAYS=14

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

log "🚀 Iniciando proceso de respaldo de bases de datos PostgreSQL..."

# 1. Base de Datos CORE (db_iam)
CORE_CONTAINER=$(docker ps -q -f name=synapse-dbs_postgres-core || true)
if [ -n "${CORE_CONTAINER}" ]; then
    log "📦 Respaldando postgres-core (db_iam)..."
    RAW_SQL="${BACKUP_DIR}/synapse_core_${BACKUP_DATE}.sql.gz"
    ENC_SQL="${RAW_SQL}.enc"
    
    docker exec "${CORE_CONTAINER}" pg_dump -U synapse_admin -d db_iam | gzip -9 > "${RAW_SQL}"
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:${ENC_PASS}" -in "${RAW_SQL}" -out "${ENC_SQL}"
    sha256sum "${ENC_SQL}" > "${ENC_SQL}.sha256"
    rm -f "${RAW_SQL}"
    
    log "☁️ Subiendo postgres-core a Cloudflare R2..."
    rclone --config "${RCLONE_CONF}" --no-update-modtime copy "${ENC_SQL}" r2:backups/postgres/
    rclone --config "${RCLONE_CONF}" --no-update-modtime copy "${ENC_SQL}.sha256" r2:backups/postgres/
    log "✅ postgres-core respaldado y cifrado exitosamente."
else
    log "⚠️ Contenedor postgres-core no encontrado. Saltando..."
fi

# 2. Base de Datos LABS (db_labquality)
LABS_CONTAINER=$(docker ps -q -f name=synapse-dbs_postgres-labs || true)
if [ -n "${LABS_CONTAINER}" ]; then
    log "📦 Respaldando postgres-labs (db_labquality)..."
    RAW_SQL="${BACKUP_DIR}/synapse_labs_${BACKUP_DATE}.sql.gz"
    ENC_SQL="${RAW_SQL}.enc"
    
    docker exec "${LABS_CONTAINER}" pg_dump -U synapse_admin -d db_labquality | gzip -9 > "${RAW_SQL}"
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 -pass "pass:${ENC_PASS}" -in "${RAW_SQL}" -out "${ENC_SQL}"
    sha256sum "${ENC_SQL}" > "${ENC_SQL}.sha256"
    rm -f "${RAW_SQL}"
    
    log "☁️ Subiendo postgres-labs a Cloudflare R2..."
    rclone --config "${RCLONE_CONF}" --no-update-modtime copy "${ENC_SQL}" r2:backups/postgres/
    rclone --config "${RCLONE_CONF}" --no-update-modtime copy "${ENC_SQL}.sha256" r2:backups/postgres/
    log "✅ postgres-labs respaldado y cifrado exitosamente."
else
    log "⚠️ Contenedor postgres-labs no encontrado. Saltando..."
fi

# 3. Purga de respaldos con antigüedad superior a RETENTION_DAYS
log "🕒 Aplicando política de retención (${RETENTION_DAYS} días) en Cloudflare R2..."
rclone --config "${RCLONE_CONF}" delete --min-age "${RETENTION_DAYS}d" r2:backups/postgres/ || true

log "🎉 Proceso de respaldo de bases de datos completado con éxito."
