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

# In verification mode, overlay test-only defaults onto the main schema before
# invoking the custom deployer. Keep this file out of the canonical
# /data-test/schema.yaml path because Producer Portal schema extraction appears
# to inspect additional schema files in the image.
TEST_SCHEMA="/data-test/verification-defaults.yaml"
if [[ -f "${TEST_SCHEMA}" ]]; then
  overlay_test_schema.py \
    --test_schema "${TEST_SCHEMA}" \
    --original_schema "/data/schema.yaml" \
    --output "/data/schema.yaml"
fi

exec /bin/deploy.sh
