#!/usr/bin/env bash
# Rolling upgrade of the active-active cluster, one node at a time, while load.py keeps starting instances.
#   ./rolling-upgrade.sh            # Camunda 7.24.0 -> CIB seven
#   ./rolling-upgrade.sh camunda    # and back again
#   PAUSE_BETWEEN_NODES=30 ./rolling-upgrade.sh   # keep both engines side by side for 30 s after the first node
# Per node: maintenance in HAProxy (no new requests) -> graceful stop (the other node takes over the jobs)
#           -> start the same node with the target image -> wait until it is fully started -> back into HAProxy.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
case ${1:-cibseven} in
  cibseven) TARGET=${TARGET:-$CIBSEVEN_IMAGE} ;;
  camunda)  TARGET=${TARGET:-$CAMUNDA_IMAGE} ;;
  *) echo "usage: ./rolling-upgrade.sh [cibseven|camunda]"; exit 1 ;;
esac
haproxy() { python3 -I -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1]))); s.sendall((sys.argv[2]+"\n").encode()); print(s.recv(4096).decode().strip())' "$ADMIN_PORT" "$1"; }
version() { curl -fs --max-time 2 "localhost:$1/engine-rest/version" | python3 -I -c 'import json,sys; v=json.load(sys.stdin)["version"]; print(("Camunda " if v.startswith("7.") else "CIB seven ")+v)' 2>/dev/null || echo down; }
show() { printf '   node1: %-28s node2: %s\n' "$(version "$NODE1_PORT")" "$(version "$NODE2_PORT")"; }

step "Cluster before the upgrade"; show

if [[ "$TARGET" == *cibseven* ]]; then
  step "0  Additive tables for the CIB seven web client (the engine tables ACT_* stay as they are; Camunda nodes keep running)"
  ext=$(ls dist/cibseven-"$EDITION"/sql/create/postgres_extensions_*.sql 2>/dev/null | head -1)
  if docker compose exec -T db psql -U engine -d engine -tAc "select 1 from information_schema.tables where table_name='mod_folders'" | grep -q 1; then
    echo "   already there"
  elif [ -n "$ext" ]; then
    docker compose exec -T db psql -q -U engine -d engine -v ON_ERROR_STOP=1 < "$ext"
    echo "   applied $(basename "$ext")"
  else
    echo "   no extension script in dist/cibseven-$EDITION - run ./build.sh cibseven first"; exit 1
  fi
fi

for n in 1 2; do
  port=$(node_port $n)
  step "node$n  1/4 maintenance in the load balancer - all new requests go to the other node"
  haproxy "set server eap_nodes/node$n state maint"
  step "node$n  2/4 graceful stop (running jobs finish, open jobs are picked up by the other node)"
  docker compose stop "node$n"
  step "node$n  3/4 start with $TARGET"
  sed -i "s#^NODE${n}_IMAGE=.*#NODE${n}_IMAGE=${TARGET}#" .env
  export "NODE${n}_IMAGE=$TARGET"
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  docker compose up -d --no-deps "node$n"
  printf '   waiting for the server and all deployments'
  # WFLYSRV0025 = server started with all deployments; WFLYSRV0026 = started with errors
  until docker compose logs --no-log-prefix --since "$since" "node$n" 2>/dev/null | grep -q -E 'WFLYSRV002[56]'; do printf '.'; sleep 2; done
  if docker compose logs --no-log-prefix --since "$since" "node$n" | grep -q WFLYSRV0026; then
    echo; echo "   node$n started WITH ERRORS - it stays out of the load balancer: docker compose logs node$n"; exit 1
  fi
  until curl -fs --max-time 2 "localhost:$port/engine-rest/process-definition/count" >/dev/null; do printf '.'; sleep 2; done; echo
  step "node$n  4/4 back into the load balancer"
  haproxy "set server eap_nodes/node$n state ready"
  show
  if [ "$n" = 1 ] && [ "${PAUSE_BETWEEN_NODES:-0}" -gt 0 ]; then
    echo "   both engines serve requests side by side on the same database - next node in ${PAUSE_BETWEEN_NODES}s"
    sleep "$PAUSE_BETWEEN_NODES"
  fi
done

step "Upgrade finished"; show
