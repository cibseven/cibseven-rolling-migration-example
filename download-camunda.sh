#!/usr/bin/env bash
# Fetch + extract what the image needs from the Camunda 7.24.0 WildFly distribution into dist/camunda (+ PostgreSQL JDBC driver).
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${CAMUNDA_VERSION:-7.24.0}
mkdir -p dist/camunda
tgz=dist/camunda-bpm-wildfly-$VERSION.tar.gz
[ -s "$tgz" ] || curl -fsSL -o "$tgz" "https://downloads.camunda.cloud/release/camunda-bpm/wildfly/${VERSION%.*}/camunda-bpm-wildfly-$VERSION.tar.gz"
server=$(tar tzf "$tgz" | awk -F/ '$1=="server" && $2 ~ /^wildfly-/ {s=$1"/"$2} END {print s}')
tar xzf "$tgz" -C dist/camunda --wildcards "$server/modules/*" "$server/standalone/configuration/*" "$server/standalone/deployments/*.war" 'sql/*' --exclude='*/modules/system/*'
[ -s dist/postgresql-42.7.8.jar ] || curl -fsL -o dist/postgresql-42.7.8.jar https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.8/postgresql-42.7.8.jar
echo "dist/camunda: $server"
