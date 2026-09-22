# The Keycloak/RHEL base image has neither curl nor wget, so fetch the
# replacement jar in a separate stage that does, then COPY it in.
FROM curlimages/curl:8.11.1 AS fetch

ARG NETTY_HANDLER_VERSION=4.1.137.Final
ARG NETTY_HANDLER_SHA1=ac2cfd0501b38d1749cff5f40c6b7bc4ddf6d477
RUN curl -sSL -o /tmp/netty-handler.jar \
      "https://repo1.maven.org/maven2/io/netty/netty-handler/${NETTY_HANDLER_VERSION}/netty-handler-${NETTY_HANDLER_VERSION}.jar" \
    && echo "${NETTY_HANDLER_SHA1}  /tmp/netty-handler.jar" | sha1sum -c -

ARG BCPROV_VERSION=1.85
ARG BCPROV_SHA1=2320b854dffe134687f7266bb22021b779e576d3
RUN curl -sSL -o /tmp/bcprov.jar \
      "https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/${BCPROV_VERSION}/bcprov-jdk18on-${BCPROV_VERSION}.jar" \
    && echo "${BCPROV_SHA1}  /tmp/bcprov.jar" | sha1sum -c -

FROM quay.io/keycloak/keycloak:26.7.4

USER root

# 26.7.4 fixes CVE-2026-18963 (keycloak-services) natively, and bumps most
# netty jars to 4.1.136.Final, which resolves everything except
# CVE-2026-75595 (fixed only in 4.1.137.Final+).
#
# Replace vulnerable netty-handler 4.1.136.Final (CVE-2026-75595) with
# patched 4.1.137.Final, in place at the original filename/path.
#
# Quarkus's classpath is driven by a build-time dependency descriptor baked
# into the base image (quarkus-application.dat, deployment-class-path.dat,
# appmodel.dat), not a filesystem scan — it hardcodes this exact jar path.
# Renaming the jar leaves that descriptor pointing at a file that no longer
# exists, and even `kc.sh build` can't repair it, since that descriptor is
# what `build` itself consults. Overwriting the jar's *contents* at its
# original path sidesteps this entirely: 4.1.137.Final is a same-branch
# security-patch bump over 4.1.136.Final (API/ABI-compatible), so the JVM
# loads the patched classes without Quarkus ever noticing the classpath
# changed.
#
# Fetched at build time (not vendored) so this Dockerfile is reproducible
# from a fresh checkout without a binary blob in git — *.jar is globally
# gitignored in this repo.
COPY --from=fetch /tmp/netty-handler.jar \
     /opt/keycloak/lib/lib/main/io.netty.netty-handler-4.1.136.Final.jar

# Same in-place overwrite technique for bcprov-jdk18on 1.84 (CVE-2026-8763,
# CVE-2026-13506), patched to 1.85. It ships in two independent locations:
# the server classpath and the separate kcadm/kcreg admin-CLI bundle under
# bin/client/lib, which has its own copy with a different filename (no
# org.bouncycastle. group prefix) — both need patching.
COPY --from=fetch /tmp/bcprov.jar \
     /opt/keycloak/lib/lib/main/org.bouncycastle.bcprov-jdk18on-1.84.jar
COPY --from=fetch /tmp/bcprov.jar \
     /opt/keycloak/bin/client/lib/bcprov-jdk18on-1.84.jar

USER 1000
