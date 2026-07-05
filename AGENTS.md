# AGENTS.md — synapse-infra

Repositorio de **infraestructura** (no aplicación). Levanta servicios compartidos
(Kafka, Redis, Vault, Prometheus, Grafana) para los microservicios Spring del
ecosistema Synapse. No hay código aplicacional: **no existen comandos build/test/lint**.

## Dos stacks separados (no mezclar)

| | Dev | Prod |
|---|---|---|
| Archivo | `compose.dev.yaml` | `compose.yaml` |
| Stack name | `synapse-dev` | `synapse-infra` |
| Red (externa) | `synapse-net` (bridge) | `synapse-overlay-net` (overlay, Swarm) |
| Kafka advertised EXTERNAL | `localhost:9092` | `synapse-infra_kafka:9092` |
| Vault | dev mode, token `synapse-master-token`, kv-v2 en memoria | prod mode, config en host `/opt/synapse/vault`, token `root-token` |
| Prometheus config | bind-mount local `./prometheus/prometheus.yaml` | bind-mount host `/opt/synapse/prometheus` |

- **Las redes son `external: true`**: deben crearse antes del `up`.
  - dev: `docker network create synapse-net`
  - prod: `docker network create --driver overlay synapse-overlay-net` (requiere Swarm init en nodo manager)
- **Prod se despliega con Docker Swarm** (`docker stack deploy` / `docker service update`), no con compose plano. Todos los servicios tienen `placement.constraints: node.role == manager`.
- Editar `prometheus/prometheus.yaml` **solo afecta a dev**; en prod se lee desde el host.

## Comandos

```bash
# --- DEV ---
docker network create synapse-net                 # solo la primera vez
docker compose -f compose.dev.yaml up -d
bash setup_dev_secrets.sh                         # carga secretos en Vault (vault debe estar arriba)
bash kafka_topics_dev.sh                          # crea tópicos (auto-create OFF)

# --- PROD (en nodo manager del Swarm) ---
docker network create --driver overlay synapse-overlay-net
docker stack deploy -c compose.yaml synapse-infra
set -a; . .env.prod; set +a                       # exporta vars para setup_init.sh
VAULT_TOKEN=root-token bash setup_init.sh
```

## Vault y secretos (patrón Spring Cloud Config)

- Los microservicios Spring leen de Vault vía Spring Cloud Config.
  - `secret/application` = **global**, heredado por todos los servicios.
  - `secret/<service-name>` = específico.
- Servicios: `iam-service`, `discovery-service`, `gateway-service`, `subscription-service`, `labquality-service`, `notify-orchestrator`, `notify-gateway`, `billing-service`.
- **`setup_init.sh`, `setup_dev_secrets.sh` y `.env.prod` están en `.gitignore`** y contienen secretos reales. NUNCA commitearlos. Sin ellos el stack no levanta correctamente.
- Convención de claves: dev usa sufijo `_DEV` (`DB_URL_DEV`, `DB_USER_DEV`...); prod usa sin sufijo.

## Kafka

- `KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"` → los tópicos **deben crearse** con los scripts `kafka_topics_*.sh` tras levantar Kafka.
- 8 tópicos (3 particiones, RF 1): `usuario_events`, `organizacion_events`, `sede_events`, `feature_events`, `suscripcion_events`, `plan_events`, `notification_events`, `notifyrequest_events`.
- Listener interno: `kafka:29092`. Externo: `localhost:9092` (dev).
- `kafka_topics_dev.sh` → contenedor `synapse-kafka`, broker `kafka:29092`.
- `kafka_topics.sh` (prod) busca contenedor `synapse-base-kafka-1` y broker `kafka:9092`. **Gotcha:** el stack de `compose.yaml` se llama `synapse-infra` (no `synapse-base`) y el listener interno es `29092`; revisar/ajustar antes de ejecutarlo en prod.

## Puertos host (dev y prod)

Kafka `9092` · Kafka UI `8091` · Redis `6379` · Vault `8200` · Prometheus `9090` · Grafana `3001` (admin).

## CI / Deploy

- `.github/workflows/deploy.yaml` es un workflow **reusable** (`workflow_call`) invocado desde los repos de cada microservicio; **no se ejecuta desde este repo**.
- Flujo: Maven build (JDK 21, `mvn clean package -DskipTests`) → push a `ghcr.io/synapse-core/<image>:latest` (multi-arch amd64/arm64) → SSH → `docker service update --image ... <stack>_<service>`.
