FROM quay.io/keycloak/keycloak:26.6.3

USER root

# Replace vulnerable netty-resolver-dns 4.1.133.Final (CVE-2026-45674, CVE-2026-47691)
# with patched 4.1.135.Final. The jar lives in Keycloak's Quarkus lib directory
# and must be named with the io.netty. prefix to match the existing convention.
RUN rm /opt/keycloak/lib/lib/main/io.netty.netty-resolver-dns-4.1.133.Final.jar

COPY netty-resolver-dns-4.1.135.Final.jar \
     /opt/keycloak/lib/lib/main/io.netty.netty-resolver-dns-4.1.135.Final.jar

USER 1000
