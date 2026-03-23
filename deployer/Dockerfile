FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm:latest

# Install nk CLI for NATS NKey generation
ARG NK_VERSION=0.4.15
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip && \
    curl -fsSL "https://github.com/nats-io/nkeys/releases/download/v${NK_VERSION}/nkeys-v${NK_VERSION}-linux-amd64.zip" \
      -o /tmp/nkeys.zip && \
    unzip -p /tmp/nkeys.zip "nkeys-v${NK_VERSION}-linux-amd64/nk" > /usr/local/bin/nk && \
    chmod +x /usr/local/bin/nk && \
    rm /tmp/nkeys.zip

# Copy Helm chart, schema, and custom deploy script
COPY chart /data/chart
COPY schema.yaml /data/schema.yaml
COPY deployer/deploy.sh /data/deploy.sh
RUN chmod +x /data/deploy.sh