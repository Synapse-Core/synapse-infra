#!/bin/bash
# Encuentra el contenedor de Kafka en el stack synapse-staging-base
CONTAINER_ID=$(docker ps -q -f name=synapse-staging-base_kafka | head -n 1)

if [ -z "$CONTAINER_ID" ]; then
  echo "❌ Error: No se encontró un contenedor corriendo para synapse-staging-base_kafka"
  exit 1
fi

BROKER="kafka:29092"
KAFKA_BIN="/opt/kafka/bin/kafka-topics.sh"

echo "🚀 Inicializando tópicos de Kafka en Staging (Contenedor: $CONTAINER_ID)..."

TOPICS=(
  "usuario_events"
  "organizacion_events"
  "sede_events"
  "feature_events"
  "suscripcion_events"
  "plan_events"
  "notification_events"
  "notifyrequest_events"
  "factura_events"
)

for TOPIC in "${TOPICS[@]}"; do
  docker exec "$CONTAINER_ID" $KAFKA_BIN \
    --create \
    --if-not-exists \
    --bootstrap-server "$BROKER" \
    --topic "$TOPIC" \
    --partitions 3 \
    --replication-factor 1

  if [ $? -eq 0 ]; then
    echo "✓ Tópico '$TOPIC' creado o ya existente."
  else
    echo "✗ Error al intentar crear '$TOPIC'"
  fi
done

echo "✅ Proceso de inicialización de tópicos Staging terminado."
