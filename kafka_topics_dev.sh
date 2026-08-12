#!/bin/bash
CONTAINER_NAME="synapse-kafka"
BROKER="kafka:29092"
KAFKA_BIN="/opt/kafka/bin/kafka-topics.sh"

echo "🚀 Inicializando tópicos de Kafka..."

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
  docker exec "$CONTAINER_NAME" $KAFKA_BIN \
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

echo "✅ Proceso terminado."