# Build nk (NATS NKey generation CLI) from source instead of using nats-io's
# prebuilt release binary. The prebuilt v0.4.15/v0.4.16 releases embed
# go1.24.12/go1.25.0 respectively — both vulnerable to CVE-2026-39821
# (fixed in go1.25.13 / go1.26.6). Building from source with a patched
# toolchain fixes it regardless of which nkeys release tag is used.
FROM golang:1.26.8 AS nk-builder
ARG NK_VERSION=0.4.15
RUN go install "github.com/nats-io/nkeys/nk@v${NK_VERSION}"

FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm:latest

COPY --from=nk-builder /go/bin/nk /usr/local/bin/nk

# Package chart in the format the deployer_helm runtime expects:
#   /data/chart/chart.tar.gz  — tarball with chart/ at the top level
# The runtime extracts chart.tar.gz to /data/extracted/chart/ and runs helm against
# /data/extracted/chart/chart (see create_manifests.sh: helm template "$NAME" "$chart/chart").
# Because our tarball has chart/ at the top level, the actual chart path is:
#   /data/extracted/chart/chart/{Chart.yaml,values.yaml,configs/,...}
COPY chart /tmp/build/chart
RUN mkdir -p /data/chart \
    && helm dependency build /tmp/build/chart \
    && for archive in /tmp/build/chart/charts/*.tgz; do \
         chart_name="$(basename "$archive" | sed -E 's/-[0-9][^-]*\.tgz$//')"; \
         if [ -d "/tmp/build/chart/charts/${chart_name}" ]; then \
           rm -f "$archive"; \
         fi; \
       done \
    && tar -czf /data/chart/chart.tar.gz -C /tmp/build chart \
    && rm -rf /tmp/build

COPY schema.yaml /data/schema.yaml
COPY data-test /data-test

# Override default deploy script with custom NKey + Keycloak injection logic
COPY deployer/deploy.sh /bin/deploy.sh
RUN chmod +x /bin/deploy.sh

# Override deploy_with_tests.sh (used by mpdev verify) to use our deploy.sh
# instead of the standard create_manifests.sh + kubectl apply flow, which
# ignores values-gcp.yaml and cannot handle large ConfigMaps (>262KB annotations).
COPY deployer/deploy_with_tests.sh /bin/deploy_with_tests.sh
RUN chmod +x /bin/deploy_with_tests.sh
