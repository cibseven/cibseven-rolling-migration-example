#!/usr/bin/env python3
"""Prepare build/<engine>/ for the Dockerfile from the vendor WildFly distribution + the Galleon-provisioned EAP.

  python3 prepare.py camunda   # dist/camunda           = Camunda 7.24.0 WildFly distribution (download-camunda.sh)
  python3 prepare.py cibseven  # dist/cibseven-<edition> = CIB seven WildFly distribution (download-cibseven.sh),
                               #                           EDITION=ce (default) or ee

Recipe (identical for both engines, only names differ):
  1. modules:      everything the distro adds outside modules/system + PostgreSQL JDBC driver module
  2. config:       EAP's OWN generated standalone.xml (not the distro's WildFly file) + engine extension,
                   engine subsystem block (copied from the distro), PostgreSQL datasource java:jboss/datasources/ProcessEngine
  3. deployments:  engine REST + web apps from the distro + our process application
"""
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
EAP_XML = ROOT / "eap/target/server/standalone/configuration/standalone.xml"
PG_JAR = ROOT / "dist/postgresql-42.7.8.jar"

# engine-specific settings added on top of the distro defaults
EXTRA_PROPERTIES = {
    "camunda": {},
    # migration flags: rewrite org.camunda -> org.cibseven in script imports and in class names of stored serialized objects
    "cibseven": {"useCibSevenNamespaceInScripting": "true", "useCibSevenNamespaceInReflection": "true",
                 # same cron semantics as Camunda 7.24 (cron-utils SPRING53) while both engines run side by side
                 "cronType": "SPRING53"},
}
EDITION = os.environ.get("EDITION", "ce")
DIST_DIR = {"camunda": "camunda", "cibseven": f"cibseven-{EDITION}"}  # dist/<dir> = extracted vendor WildFly distribution


def distro_server(engine: str) -> Path:
    servers = sorted((ROOT / "dist" / DIST_DIR[engine] / "server").glob("wildfly-*"))
    if not servers:
        sys.exit(f"no extracted distro in dist/{DIST_DIR[engine]}/server - run download-{engine}.sh first")
    return servers[-1]


def copy_modules(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    for child in src.iterdir():
        if child.name == "system":
            continue
        shutil.copytree(child, dst / child.name)
    pg = dst / "org/postgresql/postgresql/main"
    pg.mkdir(parents=True)
    shutil.copy(PG_JAR, pg / PG_JAR.name)
    (pg / "module.xml").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<module xmlns="urn:jboss:module:1.9" name="org.postgresql.postgresql">
    <resources>
        <resource-root path="{PG_JAR.name}"/>
    </resources>
    <dependencies>
        <module name="javax.api"/>
        <module name="jakarta.transaction.api"/>
    </dependencies>
</module>
""")


DATASOURCE = """                <datasource jndi-name="java:jboss/datasources/ProcessEngine" pool-name="ProcessEngine" enabled="true" use-java-context="true" jta="true" use-ccm="true">
                    <connection-url>${env.DB_URL:jdbc:postgresql://db:5432/engine}</connection-url>
                    <driver>postgresql</driver>
                    <transaction-isolation>TRANSACTION_READ_COMMITTED</transaction-isolation>
                    <pool>
                        <min-pool-size>5</min-pool-size>
                        <max-pool-size>20</max-pool-size>
                    </pool>
                    <security user-name="${env.DB_USERNAME:engine}" password="${env.DB_PASSWORD:engine}"/>
                    <validation>
                        <valid-connection-checker class-name="org.jboss.jca.adapters.jdbc.extensions.postgres.PostgreSQLValidConnectionChecker"/>
                        <validate-on-match>true</validate-on-match>
                        <exception-sorter class-name="org.jboss.jca.adapters.jdbc.extensions.postgres.PostgreSQLExceptionSorter"/>
                    </validation>
                </datasource>
"""
DRIVER = """                    <driver name="postgresql" module="org.postgresql.postgresql">
                        <xa-datasource-class>org.postgresql.xa.PGXADataSource</xa-datasource-class>
                    </driver>
"""


def set_property(block: str, name: str, value: str) -> str:
    pat = re.compile(rf'(<property name="{re.escape(name)}">)[^<]*(</property>)')
    if pat.search(block):
        return pat.sub(rf"\g<1>{value}\g<2>", block, count=1)
    return block.replace("<properties>", f'<properties>\n                        <property name="{name}">{value}</property>', 1)


def build_config(engine: str, distro_xml: Path, out: Path) -> None:
    eap = EAP_XML.read_text()
    dist = distro_xml.read_text()

    ext = re.search(r'<extension module="org\.(camunda|cibseven)\.bpm\.wildfly\.[^"]+"/>', dist).group(0)
    sub = re.search(r'<subsystem xmlns="urn:org\.(camunda|cibseven)\.bpm\.jboss:[^"]+">.*?</subsystem>', dist, re.S).group(0)

    # one shared, pre-created schema (Camunda 7.24.0) for the whole rolling upgrade: no auto update on any node
    sub = set_property(sub, "isAutoSchemaUpdate", "false")
    for k, v in EXTRA_PROPERTIES[engine].items():
        sub = set_property(sub, k, v)
    # short job lock so that jobs held by a crashed node are picked up quickly by the other node
    sub = re.sub(r'(<property name="lockTimeInMillis">)\d+(</property>)', r"\g<1>30000\g<2>", sub)

    assert ext not in eap
    eap = eap.replace("<extensions>", f"<extensions>\n        {ext}", 1)
    eap = re.sub(r"(<subsystem xmlns=\"urn:jboss:domain:datasources:[^\"]+\">\s*<datasources>\n)", r"\g<1>" + DATASOURCE.replace("\\", "\\\\"), eap, count=1)
    eap = eap.replace("<drivers>\n", "<drivers>\n" + DRIVER, 1)
    # engine subsystem right before the datasources subsystem keeps the file readable
    eap = re.sub(r"(\n\s*)(<subsystem xmlns=\"urn:jboss:domain:datasources:)", lambda m: m.group(1) + sub + m.group(1) + m.group(2), eap, count=1)
    # http://node:8080/ -> engine UI instead of the EAP welcome page (Camunda: Cockpit, CIB seven: new web client)
    ui = {"camunda": "/camunda/", "cibseven": "/webapp/"}[engine]
    eap = eap.replace('<location name="/" handler="welcome-content"/>',
                      '<location name="/" handler="welcome-content"/>\n                    <filter-ref name="root-to-ui" predicate="path(\'/\')"/>', 1)
    eap = re.sub(r"(<subsystem xmlns=\"urn:jboss:domain:undertow:[^\"]+\".*?</handlers>)",
                 lambda m: m.group(1) + f'\n            <filters>\n                <rewrite name="root-to-ui" target="{ui}" redirect="true"/>\n            </filters>',
                 eap, count=1, flags=re.S)
    if engine == "cibseven":
        # CIB seven web client reads its settings from the global module org.cibseven.config
        eap = re.sub(r'(<subsystem xmlns="urn:jboss:domain:ee:[^"]+">)',
                     r'\g<1>\n            <global-modules>\n                <module name="org.cibseven.config" slot="main"/>\n            </global-modules>', eap, count=1)
    out.write_text(eap)


def copy_deployments(server: Path, engine: str, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    for war in sorted((server / "standalone/deployments").glob("*.war")):
        if any(x in war.name for x in ("example", "invoice", "welcome")):
            continue
        shutil.copy(war, dst / war.name)
    if engine == "cibseven":
        # CIB seven web client (CE or EE, WildFly build) - context root /webapp
        for war in (ROOT / "dist" / DIST_DIR[engine] / "webclient").glob("*.war"):
            shutil.copy(war, dst / war.name)
    # process applications: apps/<engine>/*.war (or wars/<engine>/ as written by app/migrate.sh)
    apps = next((d for d in (ROOT / "apps" / engine, ROOT / "wars" / engine) if d.is_dir()), None)
    wars = sorted(apps.glob("*.war")) if apps else []
    for war in wars:
        shutil.copy(war, dst / war.name)
    if not wars:
        print(f"WARNING: no process application in apps/{engine}/ - image contains only engine, REST and web apps")


def main() -> None:
    engine = sys.argv[1]
    server = distro_server(engine)
    out = ROOT / "build" / engine
    out.mkdir(parents=True, exist_ok=True)
    copy_modules(server / "modules", out / "modules")
    conf = out / "configuration"
    if conf.exists():
        shutil.rmtree(conf)
    conf.mkdir()
    build_config(engine, server / "standalone/configuration/standalone.xml", conf / "standalone.xml")
    templates = server / "standalone/configuration/element-templates"
    if templates.exists():
        shutil.copytree(templates, conf / "element-templates")
    if engine == "cibseven":
        # same JWT secret on both nodes, so a web client login stays valid when the load balancer switches nodes
        secret_file = ROOT / "build" / "jwt-secret.txt"
        if not secret_file.exists():
            import secrets, string
            secret_file.write_text("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(155)))
        (out / "modules/org/cibseven/config/main/cibseven-webclient.properties").write_text(
            f"cibseven.webclient.authentication.jwtSecret={secret_file.read_text().strip()}\n")
    copy_deployments(server, engine, out / "deployments")
    print(f"build/{engine}: modules={sum(1 for _ in (out / 'modules').rglob('module.xml'))} "
          f"deployments={[p.name for p in (out / 'deployments').iterdir()]}")


if __name__ == "__main__":
    main()
