#!/usr/bin/env bash
# Fetch + extract what the image needs from the CIB seven WildFly distribution into dist/cibseven-<edition>/:
#   server modules, standalone.xml, engine REST + web apps, SQL scripts, the CIB seven web client (WildFly WAR)
#   and the PostgreSQL JDBC driver.
#
#   EDITION=ce (default): public artifacts from artifacts.cibseven.org - no account needed
#   EDITION=ee:           Enterprise artifacts via Maven (enterprise repository credentials in ~/.m2/settings.xml)
set -euo pipefail
cd "$(dirname "$0")"
. ./lib.sh
OUT=dist/cibseven-$EDITION
CACHE=dist/cache
PUBLIC=https://artifacts.cibseven.org/repository/public
SNAPSHOTS=https://artifacts.cibseven.org/repository/snapshots
M2=${M2_REPO:-$HOME/.m2/repository}
mkdir -p "$OUT" "$CACHE"

# fetch_public <groupId> <artifactId> <extension> [classifier] - prints the path of the downloaded file
fetch_public() {
  local g=$1 a=$2 ext=$3 cls=${4:-} repo=$PUBLIC file_version=$CIBSEVEN_VERSION
  local base="${g//.//}/$a/$CIBSEVEN_VERSION"
  if [[ $CIBSEVEN_VERSION == *-SNAPSHOT ]]; then
    repo=$SNAPSHOTS
    file_version=$(curl -fsSL "$repo/$base/maven-metadata.xml" | python3 -I -c '
import re, sys
xml, ext, cls = sys.stdin.read(), sys.argv[1], sys.argv[2]
for sv in re.findall(r"<snapshotVersion>(.*?)</snapshotVersion>", xml, re.S):
    c = re.search(r"<classifier>(.*?)</classifier>", sv)
    if re.search(rf"<extension>{re.escape(ext)}</extension>", sv) and (c.group(1) if c else "") == cls:
        print(re.search(r"<value>(.*?)</value>", sv).group(1)); break' "$ext" "$cls")
    [ -n "$file_version" ] || { echo "no $a $CIBSEVEN_VERSION $cls.$ext in $repo" >&2; exit 1; }
  fi
  local name="$a-$file_version${cls:+-$cls}.$ext"
  [ -s "$CACHE/$name" ] || { echo "   downloading $name" >&2; curl -fSL --progress-bar -o "$CACHE/$name.part" "$repo/$base/$name" && mv "$CACHE/$name.part" "$CACHE/$name"; }
  echo "$CACHE/$name"
}

# fetch_maven <groupId> <artifactId> <extension> [classifier] - EE: resolved by Maven with your settings.xml
fetch_maven() {
  local f="$M2/${1//.//}/$2/$CIBSEVEN_VERSION/$2-$CIBSEVEN_VERSION${4:+-$4}.$3"
  [ -s "$f" ] || mvn -B -q dependency:get -Dartifact="$1:$2:$CIBSEVEN_VERSION:$3${4:+:$4}" -Dtransitive=false >&2
  echo "$f"
}

if [ "$EDITION" = ee ]; then
  tgz=$(fetch_maven org.cibseven.bpm.wildfly cibseven-bpm-wildfly tar.gz)
  webclient=$(fetch_maven org.cibseven.webapp cibseven-webclient-web-ee war wildfly)
else
  tgz=$(fetch_public org.cibseven.bpm.wildfly cibseven-bpm-wildfly tar.gz)
  webclient=$(fetch_public org.cibseven.webapp cibseven-webclient-web war wildfly)
fi

rm -rf "$OUT" && mkdir -p "$OUT/webclient"
server=$(tar tzf "$tgz" | awk -F/ '$1=="server" && $2 ~ /^wildfly-/ {s=$1"/"$2} END {print s}')
tar xzf "$tgz" -C "$OUT" --wildcards "$server/modules/*" "$server/standalone/configuration/*" "$server/standalone/deployments/*.war" 'sql/*' --exclude='*/modules/system/*'
cp "$webclient" "$OUT/webclient/"
[ -s dist/postgresql-42.7.8.jar ] || curl -fsSL -o dist/postgresql-42.7.8.jar https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.8/postgresql-42.7.8.jar
echo "$OUT: $server, CIB seven $CIBSEVEN_VERSION ($EDITION), web client $(basename "$webclient")"
