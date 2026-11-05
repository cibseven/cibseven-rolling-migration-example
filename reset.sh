#!/usr/bin/env bash
# Fresh start: empty PostgreSQL 17 with the Camunda 7.24.0 schema, both JBoss EAP nodes on Camunda 7.24.0,
# HAProxy in front, admin user demo/demo. Takes about 1 minute.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh

step "Remove old cluster and database ($COMPOSE_PROJECT_NAME)"
docker compose down -v --remove-orphans
write_env "$CAMUNDA_IMAGE" "$CAMUNDA_IMAGE"
export NODE1_IMAGE=$CAMUNDA_IMAGE NODE2_IMAGE=$CAMUNDA_IMAGE   # override values exported from the old .env

# schema = the Camunda 7.24.0 create scripts from the downloaded distribution; it stays as is during the whole upgrade
sql=dist/camunda/sql/create
[ -s "$sql/postgres_engine_$CAMUNDA_VERSION.sql" ] || { echo "missing $sql - run ./build.sh camunda first"; exit 1; }
rm -rf build/sql-init && mkdir -p build/sql-init
cp "$sql/postgres_engine_$CAMUNDA_VERSION.sql" build/sql-init/01_engine.sql
cp "$sql/postgres_identity_$CAMUNDA_VERSION.sql" build/sql-init/02_identity.sql

step "Start PostgreSQL 17 + 2x JBoss EAP 8.1 ($CAMUNDA_IMAGE) + HAProxy"
# node2 starts only after the engine on node1 is up: on an empty database both engines would otherwise create the
# installation id at the same moment, and one of them fails to start
for n in 1 2; do
  docker compose up -d "node$n" lb
  port=$(node_port $n)
  printf '   node%s on :%s ' "$n" "$port"
  until curl -fs --max-time 2 "localhost:$port/engine-rest/process-definition/count" >/dev/null; do printf '.'; sleep 2; done
  echo " up: $(curl -s "localhost:$port/engine-rest/version")"
done
sleep 3

step "Admin user demo/demo"
python3 -I init-users.py

step "Ready - start the load now: python3 load.py"
cat <<EOF
   Load balancer (REST):   http://localhost:$LB_PORT/engine-rest
   node1 / node2:          http://localhost:$NODE1_PORT   http://localhost:$NODE2_PORT   (Camunda: /camunda, CIB seven: /webapp)
   HAProxy live status:    http://localhost:$STATS_PORT
   Login: demo / demo
EOF
