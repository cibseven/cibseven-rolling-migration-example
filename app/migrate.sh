#!/usr/bin/env bash
# Migrates the number-porting process application from Camunda 7.24.0 to CIB seven with the public OpenRewrite
# recipe, and builds both WARs:
#   wars/camunda/number-porting.war   Camunda 7.24.0 (app/ in this repository, unchanged)
#   wars/cibseven/number-porting.war  recipe output, BOM re-pointed to $CIBSEVEN_TARGET (default 3.0.0-SNAPSHOT)
#   wars/cibseven-2.2.0/...           recipe output exactly as generated (CIB seven 2.2.0)
# The recipe runs in a git worktree (.migrated/ in the repository root) on the current commit; it is recreated on
# every run and kept afterwards for inspection:  git -C .migrated diff
#
#   app/migrate.sh                            (~1 min; needs network for the recipe URL and Maven Central)
#   CIBSEVEN_TARGET=2.2.0 app/migrate.sh      (no re-pointing, build the recipe output as is)
set -euo pipefail
APP=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$APP" rev-parse --show-toplevel)
WARS=$REPO/wars
WT=$REPO/.migrated
RECIPE_URL=${RECIPE_URL:-https://cibseven.github.io/cibseven-migration/replace-camunda-with-cibseven.yml}
RECIPE=org.cibseven.ReplaceCamundaWithCIBSeven
REWRITE_PLUGIN=org.openrewrite.maven:rewrite-maven-plugin:6.46.1
TARGET=${CIBSEVEN_TARGET:-3.0.0-SNAPSHOT}
SNAPSHOT_REPO=https://artifacts.cibseven.org/repository/snapshots
LOGS=$(mktemp -d)
KEEP_LOGS=

step() { printf '\n\033[1;31m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mFAILED: %s\033[0m  (full log: %s)\n' "$1" "$2"; tail -40 "$2"; exit 1; }

# build <dir> <log> [maven args...]: clean, test and package; prints engine and test summary
build() {
  local dir=$1 log=$2; shift 2
  (cd "$dir" && mvn -B "$@" clean package) > "$log" 2>&1 || return 1
  info "$(grep -h -m1 'Engine under test' "$log")"
  info "$(grep -E 'Tests run: [0-9]+, Failures' "$log" | tail -1 | sed 's/^\[[A-Z]*\] //')"
}

# superclass <war>: shows what the process application class extends inside the WAR
superclass() {
  local tmp; tmp=$(mktemp -d)
  unzip -q "$1" 'WEB-INF/classes/*' -d "$tmp"
  javap -cp "$tmp/WEB-INF/classes" com.example.telco.NumberPortingApplication | grep -o 'class .*' | sed 's/ {$//'
  rm -rf "$tmp"
}

mkdir -p "$WARS/camunda" "$WARS/cibseven" "$WARS/cibseven-2.2.0"
info "Commit: $(git -C "$REPO" log -1 --format='%h %s')"
git -C "$REPO" diff --quiet HEAD -- app || warn "Uncommitted changes in app/ are NOT migrated - the recipe runs on the commit above."

step "1/5  Today: Camunda 7.24.0 process application - run the tests, build the WAR"
build "$APP" "$LOGS/1-camunda.log" || die "Camunda build" "$LOGS/1-camunda.log"
cp "$APP/target/number-porting.war" "$WARS/camunda/"
info "WAR: wars/camunda/number-porting.war"

step "2/5  Run the public migration recipe (OpenRewrite): $RECIPE"
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
rm -rf "$WT"; git -C "$REPO" worktree prune
git -C "$REPO" worktree add -q --detach "$WT" HEAD
(cd "$WT/app" && mvn -B "$REWRITE_PLUGIN:run" \
    -Drewrite.configLocation="$RECIPE_URL" -Drewrite.activeRecipes="$RECIPE") \
  > "$LOGS/2-rewrite.log" 2>&1 || die "OpenRewrite recipe" "$LOGS/2-rewrite.log"
grep -E 'Changes have been made to' "$LOGS/2-rewrite.log" | sed 's/^\[WARNING\] Changes have been made to /    changed: /; s/ by:$//'

step "3/5  This is the complete code change"
git -C "$WT" --no-pager diff --color=always -- app
echo
git -C "$WT" --no-pager diff --stat -- app

step "4/5  Same tests, same BPMN, now on CIB seven 2.2.0 (recipe output as generated)"
build "$WT/app" "$LOGS/4-cibseven-2.2.0.log" || die "CIB seven 2.2.0 build" "$LOGS/4-cibseven-2.2.0.log"
cp "$WT/app/target/number-porting.war" "$WARS/cibseven-2.2.0/"
info "WAR: wars/cibseven-2.2.0/number-porting.war"

if [ "$TARGET" = "2.2.0" ]; then
  cp "$WARS/cibseven-2.2.0/number-porting.war" "$WARS/cibseven/"
  echo "$TARGET" > "$WARS/cibseven/VERSION"
else
  step "5/5  Target cluster runs CIB seven $TARGET: same recipe output, only the BOM version re-pointed"
  info "mvn package -Dcibseven.version=$TARGET   (no source change)"
  if [[ $TARGET == *-SNAPSHOT && $TARGET != *-ee-* ]]; then
    # unreleased CE version: resolve it from the public CIB seven snapshot repository
    python3 -I - "$WT/app/pom.xml" "$SNAPSHOT_REPO" <<'EOF'
import sys
pom, url = sys.argv[1], sys.argv[2]
s = open(pom).read()
if url not in s:
    s = s.replace("</properties>", "</properties>\n\n  <repositories>\n    <repository>\n      <id>cibseven-snapshots</id>\n"
                  f"      <url>{url}</url>\n      <snapshots><enabled>true</enabled></snapshots>\n"
                  "    </repository>\n  </repositories>", 1)
    open(pom, "w").write(s)
EOF
    info "pom.xml: + public CIB seven snapshot repository ($SNAPSHOT_REPO)"
  fi
  if build "$WT/app" "$LOGS/5-cibseven-$TARGET.log" -Dcibseven.version="$TARGET" \
     && grep -q "Engine under test: CIB seven $TARGET" "$LOGS/5-cibseven-$TARGET.log"; then
    cp "$WT/app/target/number-porting.war" "$WARS/cibseven/"
    echo "$TARGET" > "$WARS/cibseven/VERSION"
    info "WAR: wars/cibseven/number-porting.war   (built against CIB seven $TARGET)"
  else
    warn "Build against $TARGET failed (log: $LOGS/5-cibseven-$TARGET.log) - using the 2.2.0 WAR instead."
    KEEP_LOGS=1
    cp "$WARS/cibseven-2.2.0/number-porting.war" "$WARS/cibseven/"
    echo "2.2.0 (fallback for $TARGET)" > "$WARS/cibseven/VERSION"
  fi
fi

step "Result"
info "BPMN files changed by the migration: $(git -C "$WT" diff --name-only -- '*.bpmn' | wc -l)"
info "Camunda sources in app/: $( [ -z "$(git -C "$REPO" status --porcelain -- app)" ] && echo unchanged || echo 'local changes present')"
info "camunda  WAR: $(superclass "$WARS/camunda/number-porting.war")"
info "cibseven WAR: $(superclass "$WARS/cibseven/number-porting.war")"
info "WARs: wars/camunda/number-porting.war  wars/cibseven/number-porting.war"
info "Migrated sources: .migrated/app   (git -C .migrated diff)"
[ -n "${KEEP_LOGS:-}" ] || rm -rf "$LOGS"
