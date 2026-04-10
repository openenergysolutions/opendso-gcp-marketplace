# To use mpdev, do:
# gcloud auth login
# gcloud auth configure-docker gcr.io

BIN_FILE="$HOME/.local/bin/mpdev"
mkdir -p "$HOME/.local/bin"

cat > "$BIN_FILE" << 'EOF'
#!/bin/bash
DOCKER_SOCKET="${DOCKER_HOST:-unix:///var/run/docker.sock}"
DOCKER_SOCKET_PATH="${DOCKER_SOCKET#unix://}"

docker run \
  --net=host \
  --rm \
  -v "$DOCKER_SOCKET_PATH:/var/run/docker.sock" \
  -v "$HOME/.kube:/root/.kube" \
  -v "$HOME/.config/gcloud:/root/.config/gcloud" \
  gcr.io/cloud-marketplace-tools/k8s/dev:latest \
  "$@"
EOF

chmod +x "$BIN_FILE"