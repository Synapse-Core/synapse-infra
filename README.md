# Synapse Infrastructure

Este repositorio contiene la infraestructura local necesaria para desarrollar los microservicios del ecosistema Synapse (IAM, Quality, Billing, etc.).

## Servicios Incluidos
- **Kafka:** `localhost:9092` (Mensajería de Eventos)
- **Zookeeper:** `localhost:2181` (Coordinador Kafka)
- **Redis:** `localhost:6379` (Caché distribuida)

## Cómo iniciar (Quick Start)

1. Clona este repositorio:
   ```bash
   git clone https://github.com/j0se25/synapse-infra.git
2. Levanta los servicios:
    ```bash
   docker-compose up -d