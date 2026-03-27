#!/bin/bash
#
# Custom deploy_with_tests.sh for OpenDSO GCP Marketplace.
#
# Overrides the standard deployer_helm deploy_with_tests.sh to use our custom
# deploy.sh (helm upgrade --install with values-gcp.yaml) instead of the
# standard create_manifests.sh + kubectl apply flow.
#
# The standard flow uses only user-provided schema values for helm template,
# ignoring values-gcp.yaml. Our deploy.sh applies values-gcp.yaml and all
# GCP-specific settings (TLS disabled, imagePullSecrets cleared, NATS NKeys,
# Keycloak injection, topology-genesis server-side apply, etc.).
#
# This script is invoked by mpdev verify via /bin/deploy_with_tests.sh.
# For mpdev install, the base image CMD (/bin/deploy.sh) is used directly.
#
set -euo pipefail

exec /bin/deploy.sh
