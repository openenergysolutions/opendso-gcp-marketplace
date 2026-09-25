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

ARG NETTY_CODEC_HTTP_VERSION=4.1.137.Final
ARG NETTY_CODEC_HTTP_SHA1=a0525968e918c2ca2f6e7f3b66c35de1542a09a5
RUN curl -sSL -o /tmp/netty-codec-http.jar \
      "https://repo1.maven.org/maven2/io/netty/netty-codec-http/${NETTY_CODEC_HTTP_VERSION}/netty-codec-http-${NETTY_CODEC_HTTP_VERSION}.jar" \
    && echo "${NETTY_CODEC_HTTP_SHA1}  /tmp/netty-codec-http.jar" | sha1sum -c -

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

# Same in-place overwrite for netty-codec-http (CVE-2026-59903), patched to
# 4.1.137.Final.
COPY --from=fetch /tmp/netty-codec-http.jar \
     /opt/keycloak/lib/lib/main/io.netty.netty-codec-http-4.1.136.Final.jar

# Same in-place overwrite technique for the server-side copy of
# bcprov-jdk18on 1.84 (CVE-2026-8763, CVE-2026-13506), patched to 1.85.
COPY --from=fetch /tmp/bcprov.jar \
     /opt/keycloak/lib/lib/main/org.bouncycastle.bcprov-jdk18on-1.84.jar

# The separate kcadm/kcreg admin-CLI bundle under bin/client/lib ships its
# own independent copy of bcprov-jdk18on. Unlike the server, this bundle has
# no Quarkus classpath descriptor pinning an exact filename — kcadm.sh loads
# every jar it finds under -Dkc.lib.dir via a plain directory scan (verified:
# no Class-Path manifest entry, and kcadm.sh still starts and initializes TLS
# correctly after the jar here is renamed). Google's Container Analysis
# scanner has no pom.properties to read for BouncyCastle (it doesn't ship
# one) and falls back to parsing the version out of the filename, so an
# in-place content-only overwrite here — unlike the other jars in this
# Dockerfile — would keep showing up as CVE-2026-8763/CVE-2026-13506 even
# though the bytes are fixed. Renaming instead of overwriting is required.
RUN rm /opt/keycloak/bin/client/lib/bcprov-jdk18on-1.84.jar
COPY --from=fetch /tmp/bcprov.jar \
     /opt/keycloak/bin/client/lib/bcprov-jdk18on-1.85.jar

USER 1000
