#!/usr/bin/env bash
# Build the JBoss EAP 8.1 images:  ./build.sh [camunda|cibseven|all]   (default: all)
#   eap81-camunda:7.24.0             Camunda 7.24.0 as shared engine + number-porting.war (Camunda version)
#   eap81-cibseven:3.0.0[-ee]        CIB seven as shared engine + number-porting.war (migrated with app/migrate.sh)
# Needs: docker login registry.redhat.io, JDK 21 + Maven, Python 3, network. First run ~20 min (EAP provisioning).
# Settings (EDITION, CIBSEVEN_VERSION, IMAGE_PREFIX, ...): see lib.sh.
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
what=${1:-all}
case $what in camunda|cibseven|all) ;; *) echo "usage: ./build.sh [camunda|cibseven|all]"; exit 1 ;; esac

# 1. process application WARs: Camunda version as committed, CIB seven version produced by the OpenRewrite recipe
if [ ! -s wars/camunda/number-porting.war ] || [ ! -s wars/cibseven/number-porting.war ] \
   || [ "$(cat wars/cibseven/VERSION 2>/dev/null)" != "$CIBSEVEN_VERSION" ]; then
  step "Process application: build and migrate (app/migrate.sh)"
  CIBSEVEN_TARGET=$CIBSEVEN_VERSION app/migrate.sh
fi

# 2. JBoss EAP 8.1 server, provisioned once with Galleon from Red Hat's Maven repository
if [ ! -f eap/target/server/standalone/configuration/standalone.xml ]; then
  step "Provision JBoss EAP 8.1 with Galleon (first run ~15 min)"
  (cd eap && mvn -B -ntp package)
fi

# 3. one image per engine
build_image() {   # <engine> <tag>
  step "Image $2"
  "./download-$1.sh"
  EDITION=$EDITION python3 -I prepare.py "$1"
  docker build --build-arg ENGINE="$1" -t "$2" .
}
[ "$what" = cibseven ] || build_image camunda "$CAMUNDA_IMAGE"
[ "$what" = camunda ] || build_image cibseven "$CIBSEVEN_IMAGE"
step "Done"
docker images --format '   {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -F -e "$CAMUNDA_IMAGE" -e "$CIBSEVEN_IMAGE" || true
