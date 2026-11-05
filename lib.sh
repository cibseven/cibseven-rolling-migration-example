# shellcheck shell=bash
# Shared settings for build.sh, reset.sh and rolling-upgrade.sh (sourced, not executed).
# Precedence: environment variable > value in .env (written by reset.sh) > default below.
#
#   EDITION            ce (default, public artifacts) | ee (CIB seven Enterprise: Maven credentials + licence file)
#   CIBSEVEN_VERSION   3.0.0-SNAPSHOT (ce) / 3.0.0-ee-SNAPSHOT (ee), or a release such as 2.2.0
#   CAMUNDA_VERSION    7.24.0
#   IMAGE_PREFIX       prefix for the image names, e.g. "verify-" for a second build next to the first one
#   COMPOSE_PROJECT_NAME, LB_PORT, NODE1_PORT, NODE2_PORT, STATS_PORT, ADMIN_PORT, DB_PORT   cluster name and host ports

# .env holds the inputs of the last reset.sh (edition, versions, prefix, ports) and the node images; values derived
# from them (image names, compose files) are always recomputed. CIBSEVEN_VERSION is only reused for the same edition.
declare -A _dotenv=()
if [ -f .env ]; then
  while IFS='=' read -r k v; do [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] && _dotenv[$k]=$v; done < .env
fi
export EDITION=${EDITION:-${_dotenv[EDITION]:-ce}}
for k in "${!_dotenv[@]}"; do
  case $k in CAMUNDA_IMAGE|CIBSEVEN_IMAGE|COMPOSE_FILE) continue ;; esac
  [ "$k" = CIBSEVEN_VERSION ] && [ "${_dotenv[EDITION]:-}" != "$EDITION" ] && continue
  [ -z "${!k+x}" ] && export "$k=${_dotenv[$k]}"
done
unset _dotenv

case $EDITION in
  ce) export CIBSEVEN_VERSION=${CIBSEVEN_VERSION:-3.0.0-SNAPSHOT} ;;
  ee) export CIBSEVEN_VERSION=${CIBSEVEN_VERSION:-3.0.0-ee-SNAPSHOT} ;;
  *)  echo "EDITION must be ce or ee, not '$EDITION'" >&2; exit 1 ;;
esac
export CAMUNDA_VERSION=${CAMUNDA_VERSION:-7.24.0}
export IMAGE_PREFIX=${IMAGE_PREFIX:-}
export CAMUNDA_IMAGE=${CAMUNDA_IMAGE:-${IMAGE_PREFIX}eap81-camunda:${CAMUNDA_VERSION}}
export CIBSEVEN_IMAGE=${CIBSEVEN_IMAGE:-${IMAGE_PREFIX}eap81-cibseven:${CIBSEVEN_VERSION%-SNAPSHOT}}

export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-eap-rolling}
export LB_PORT=${LB_PORT:-8088} NODE1_PORT=${NODE1_PORT:-8081} NODE2_PORT=${NODE2_PORT:-8082}
export STATS_PORT=${STATS_PORT:-8404} ADMIN_PORT=${ADMIN_PORT:-9999} DB_PORT=${DB_PORT:-25432}
# EE: docker-compose.ee.yml mounts the licence file into both nodes
if [ "$EDITION" = ee ]; then export COMPOSE_FILE=docker-compose.yml:docker-compose.ee.yml; else export COMPOSE_FILE=docker-compose.yml; fi

step() { printf '\n\033[1;31m==> %s\033[0m\n' "$*"; }

# write_env <node1-image> <node2-image>: persist the current settings for docker compose and the Python scripts
write_env() {
  cat > .env <<EOF
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
COMPOSE_FILE=$COMPOSE_FILE
EDITION=$EDITION
CIBSEVEN_VERSION=$CIBSEVEN_VERSION
CAMUNDA_VERSION=$CAMUNDA_VERSION
IMAGE_PREFIX=$IMAGE_PREFIX
NODE1_IMAGE=$1
NODE2_IMAGE=$2
LB_PORT=$LB_PORT
NODE1_PORT=$NODE1_PORT
NODE2_PORT=$NODE2_PORT
STATS_PORT=$STATS_PORT
ADMIN_PORT=$ADMIN_PORT
DB_PORT=$DB_PORT
EOF
}

# node_port <1|2>
node_port() { if [ "$1" = 1 ]; then echo "$NODE1_PORT"; else echo "$NODE2_PORT"; fi; }
