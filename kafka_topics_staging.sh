#!/bin/bash
set -e

BROKER="kafka:29092"
KAFKA_BIN="/opt/kafka/bin/kafka-topics.sh"

echo "🚀 Inicializando tópicos de Kafka en Staging..."

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

# 1. Si el contenedor corre en este nodo (synapse-1), usa docker exec
CONTAINER_ID=$(docker ps -q -f name=synapse-staging-base_kafka | head -n 1)

if [ -n "$CONTAINER_ID" ]; then
  echo "✓ Usando contenedor local de Kafka ($CONTAINER_ID)..."
  for TOPIC in "${TOPICS[@]}"; do
    docker exec "$CONTAINER_ID" $KAFKA_BIN \
      --create \
      --if-not-exists \
      --bootstrap-server "$BROKER" \
      --topic "$TOPIC" \
      --partitions 3 \
      --replication-factor 1
    echo "✓ Tópico '$TOPIC' verificado."
  done
else
  # 2. Si estás en el Manager y Kafka corre en el Worker, corre un cliente efímero en la red overlay
  echo "ℹ️ Kafka está en el worker synapse-1. Conectando a través de synapse-staging-overlay-net..."
  for TOPIC in "${TOPICS[@]}"; do
    docker run --rm --network synapse-staging-overlay-net apache/kafka:4.2.0 \
      $KAFKA_BIN \
      --create \
      --if-not-exists \
      --bootstrap-server "$BROKER" \
      --topic "$TOPIC" \
      --partitions 3 \
      --replication-factor 1
    echo "✓ Tópico '$TOPIC' verificado."
  done
fi

echo "✅ Todos los tópicos de Staging están listos."
