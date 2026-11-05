# JBoss EAP 8.1 + process engine (Camunda 7.24.0 or CIB seven 3.0) as shared engine via the JBoss subsystem.
#   Red Hat ships no ready EAP server image: the runtime image only has JDK 21 + launch scripts.
#   The EAP server is provisioned with Galleon (eap/pom.xml -> eap/target/server) and copied in here.
#   build/<engine>/ is produced by prepare.py from the vendor's WildFly distribution:
#     modules/        engine modules (everything outside modules/system of the distro) + PostgreSQL driver
#     standalone.xml  EAP's own generated standalone.xml + engine extension, subsystem, datasource
#     deployments/    engine REST + web apps (+ CIB seven web client) + the process application (number-porting.war)
ARG RUNTIME=registry.redhat.io/jboss-eap-8/eap81-openjdk21-runtime-openshift-rhel9:latest
FROM ${RUNTIME}
ARG ENGINE
USER root
COPY --chown=jboss:root eap/target/server/ /opt/server/
COPY --chown=jboss:root build/${ENGINE}/modules/ /opt/server/modules/
COPY --chown=jboss:root build/${ENGINE}/configuration/ /opt/server/standalone/configuration/
COPY --chown=jboss:root build/${ENGINE}/deployments/ /opt/server/standalone/deployments/
RUN chmod -R ug+rwX /opt/server
USER jboss
ENV JBOSS_HOME=/opt/server LAUNCH_JBOSS_IN_BACKGROUND=true
EXPOSE 8080 9990
CMD ["sh", "-c", "exec /opt/server/bin/standalone.sh -b 0.0.0.0 -bmanagement 0.0.0.0 -Djboss.node.name=${NODE_NAME:-$(hostname)} -Djboss.tx.node.id=${NODE_NAME:-$(hostname)}"]
