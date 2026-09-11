FROM quay.io/keycloak/keycloak:26.6.3

USER root

# Replace vulnerable netty-resolver-dns 4.1.133.Final (CVE-2026-45674, CVE-2026-47691)
# with patched 4.1.135.Final, in place at the original filename/path.
#
# Quarkus's classpath is driven by a build-time dependency descriptor baked
# into the base image (quarkus-application.dat, deployment-class-path.dat,
# appmodel.dat), not a filesystem scan — it hardcodes this exact jar path.
# Renaming the jar (as an earlier version of this patch did) leaves that
# descriptor pointing at a file that no longer exists, and even `kc.sh build`
# can't repair it, since that descriptor is what `build` itself consults.
# Overwriting the jar's *contents* at its original path sidesteps this
# entirely: 4.1.135.Final is a same-branch security-patch bump over
# 4.1.133.Final (API/ABI-compatible), so the JVM loads the patched classes
# without Quarkus ever noticing the classpath changed.
COPY netty-resolver-dns-4.1.135.Final.jar \
     /opt/keycloak/lib/lib/main/io.netty.netty-resolver-dns-4.1.133.Final.jar

USER 1000
