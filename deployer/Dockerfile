# Build nk (NATS NKey generation CLI) from source instead of using nats-io's
# prebuilt release binary. The prebuilt v0.4.15/v0.4.16 releases embed
# go1.24.12/go1.25.0 respectively — both vulnerable to CVE-2026-39821
# (fixed in go1.25.13 / go1.26.6). Building from source with a patched
# toolchain fixes it regardless of which nkeys release tag is used.
# go1.26.11 also fixes the later Go stdlib CVEs (CVE-2026-78667,
# CVE-2026-111943, CVE-2026-97033 through CVE-2026-97043) in nk.
#
# nkeys releases (through v0.4.17) still require golang.org/x/crypto v0.52.0,
# which is vulnerable to CVE-2026-56854 (fixed in 0.55.0). Build nk inside a
# throwaway module that also requires a fixed x/crypto, so Go's minimum
# version selection picks the newer one.
FROM golang:1.26.11 AS nk-builder
ARG NK_VERSION=0.4.17
ARG X_CRYPTO_VERSION=0.56.0
WORKDIR /nk
RUN go mod init nkbuild \
    && go get "github.com/nats-io/nkeys@v${NK_VERSION}" "golang.org/x/crypto@v${X_CRYPTO_VERSION}" \
    && go build -o /go/bin/nk github.com/nats-io/nkeys/nk

# Rebuild the base image's kubectl with a patched Go toolchain. deployer_helm
# 13.0.18 ships the upstream kubectl v1.37.2 release binary, built with
# go1.26.10, which Artifact Registry flags for the Go stdlib CVEs fixed in
# go1.26.11 (CVE-2026-97033 through CVE-2026-97043). Same source version,
# newer compiler. Drop this stage once the base ships a kubectl built with a
# fixed Go.
FROM golang:1.26.11 AS kubectl-builder
ARG KUBECTL_VERSION=v1.37.2
ENV GOTOOLCHAIN=local CGO_ENABLED=0
RUN git clone --depth 1 --branch "${KUBECTL_VERSION}" https://github.com/kubernetes/kubernetes.git /src
WORKDIR /src
RUN go build -trimpath -ldflags "-s -w \
      -X k8s.io/client-go/pkg/version.gitVersion=${KUBECTL_VERSION} \
      -X k8s.io/component-base/version.gitVersion=${KUBECTL_VERSION} \
      -X k8s.io/client-go/pkg/version.gitTreeState=clean \
      -X k8s.io/component-base/version.gitTreeState=clean" \
      -o /out/kubectl ./cmd/kubectl

FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm:latest

# The base image's Ubuntu 22.04 openssl 3.0.2-0ubuntu1.29 is vulnerable to
# CVE-2026-84782 (fixed in 0ubuntu1.30). Upgrade the OS openssl packages
# rather than waiting on a base image rebuild.
RUN apt-get update \
    && apt-get install -y --only-upgrade --no-install-recommends libssl3 openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=nk-builder /go/bin/nk /usr/local/bin/nk

# Replace the base kubectl only when it is the version we rebuilt, so a base
# image moving to another kubectl minor fails the build instead of silently
# keeping (or mismatching) a binary.
COPY --from=kubectl-builder /out/kubectl /tmp/kubectl
RUN test "$(readlink /opt/kubectl/default)" = /opt/kubectl/v1.37 \
    && install -m 0755 /tmp/kubectl /opt/kubectl/v1.37/kubectl \
    && rm /tmp/kubectl \
    && kubectl version --client | grep -q 'Client Version: v1.37.2'

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
