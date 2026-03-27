FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm:latest

# Install nk CLI for NATS NKey generation
ARG NK_VERSION=0.4.15
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip && \
    curl -fsSL "https://github.com/nats-io/nkeys/releases/download/v${NK_VERSION}/nkeys-v${NK_VERSION}-linux-amd64.zip" \
      -o /tmp/nkeys.zip && \
    unzip -p /tmp/nkeys.zip "nkeys-v${NK_VERSION}-linux-amd64/nk" > /usr/local/bin/nk && \
    chmod +x /usr/local/bin/nk && \
    rm /tmp/nkeys.zip

# Package chart in the format the deployer_helm runtime expects:
#   /data/chart/chart.tar.gz  — tarball with chart/ at the top level
# The runtime extracts chart.tar.gz to /data/extracted/chart/ and runs helm against
# /data/extracted/chart/chart (see create_manifests.sh: helm template "$NAME" "$chart/chart").
# Because our tarball has chart/ at the top level, the actual chart path is:
#   /data/extracted/chart/chart/{Chart.yaml,values.yaml,configs/,...}
COPY chart /tmp/build/chart
RUN mkdir -p /data/chart \
    && tar -czf /data/chart/chart.tar.gz -C /tmp/build chart \
    && rm -rf /tmp/build

COPY schema.yaml /data/schema.yaml

# Override default deploy script with custom NKey + Keycloak injection logic
COPY deployer/deploy.sh /bin/deploy.sh
RUN chmod +x /bin/deploy.sh

# Override deploy_with_tests.sh (used by mpdev verify) to use our deploy.sh
# instead of the standard create_manifests.sh + kubectl apply flow, which
# ignores values-gcp.yaml and cannot handle large ConfigMaps (>262KB annotations).
COPY deployer/deploy_with_tests.sh /bin/deploy_with_tests.sh
RUN chmod +x /bin/deploy_with_tests.sh