#!/bin/bash

KAFKA_CONTAINER=$(docker ps -q -f name=synapse-base-kafka-1)
KAFKA_BROKER="kafka:9092"

echo "🚀 Inicializando tópicos de Kafka para Synapse Health..."

TOPICS=(
  "usuario_events"
  "organizacion_events"
  "sede_events"
  "feature_events"
  "suscripcion_events"
  "plan_events"
  "notification_events"
  "notifyrequest_events"
)

for TOPIC in "${TOPICS[@]}"; do
  docker exec $KAFKA_CONTAINER /opt/kafka/bin/kafka-topics.sh \
    --create \
    --if-not-exists \
    --bootstrap-server $KAFKA_BROKER \
    --topic $TOPIC \
    --partitions 3 \
    --replication-factor 1
  echo "✓ $TOPIC"
done

echo "✅ Tópicos creados exitosamente."