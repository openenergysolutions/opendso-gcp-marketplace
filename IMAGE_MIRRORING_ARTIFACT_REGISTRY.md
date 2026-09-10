# OpenDSO GCP Marketplace — Image Mirroring Guide

This guide describes how to mirror the OpenDSO image set into a customer's GCP Artifact Registry before deployment, including Marketplace annotation, release-tagging, and `chart/values.yaml` tag and digest refresh.

## 1. Why Mirroring Is Needed

The Marketplace package references both OES-built images and third-party images. For controlled customer deployments, those images should exist in a GCP Artifact Registry repo that the target GKE cluster can read from.

The chart supports a shared registry prefix through:

```yaml
global.imageRegistry
```

All image repositories in `values.yaml` and `schema.yaml` are relative to that prefix.

## 2. Create an Artifact Registry Repository

Example:

```bash
gcloud artifacts repositories create oesinc \
  --repository-format=docker \
  --location=us-central1 \
  --description="OpenDSO Marketplace images"
```

Resulting registry prefix example:

```text
us-central1-docker.pkg.dev/<project-id>/oesinc
```

## 3. Authenticate Docker

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
```

## 4. Mirror Images

There are two mirroring flows in this repo, both implemented as thin wrappers over the shared helper library `scripts/lib/mirror-common.sh`:

- `scripts/mirror-app-images.sh`
  Mirrors the pre-defined first-party OpenDSO app image set from Docker Hub into Artifact Registry. It can also annotate images for Marketplace, add release tags like `1.0.0` and `1.0`, and update `chart/values.yaml` tags and digests.
- `scripts/mirror-k8s-marketplace-images.sh`
  Mirrors the hardcoded Marketplace dependency/helper image set into Artifact Registry and updates the matching `chart/values.yaml` tag plus `digest` or `sha` fields.

### First-party OpenDSO images

List the configured image set:

```bash
./scripts/mirror-app-images.sh --list
```

Mirror a subset:

```bash
./scripts/mirror-app-images.sh \
  --project <project-id> \
  --location us-central1 \
  --source-org <dockerhub-org> \
  --only gms-api,one-line-app
```

Mirror the full set, annotate for Marketplace, add release tags, and refresh tags and digests in `chart/values.yaml`:

```bash
./scripts/mirror-app-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --source-org <dockerhub-org> \
  --annotate \
  --service-name services/opendso-platform-byol.endpoints.<project-id>.cloud.goog \
  --tag-marketplace \
  --version 1.0.0 \
  --track 1.0 \
  --update-values
```

Dry-run the whole workflow first:

```bash
./scripts/mirror-app-images.sh \
  --project <project-id> \
  --location us-central1 \
  --source-org <dockerhub-org> \
  --annotate \
  --service-name services/opendso-platform-byol.endpoints.<project-id>.cloud.goog \
  --tag-marketplace \
  --dry-run
```

The script performs operations in this order:

1. copy the source tag into Artifact Registry
2. annotate the mirrored tag if `--annotate` is set
3. add Marketplace release tags if `--tag-marketplace` is set
4. read the resulting digest and patch `chart/values.yaml` tag and digest if `--update-values` is set

This order matters because annotation changes the image manifest, and therefore changes the digest.

Temporary `tmp-marketplace-*` tags created during annotation are now deleted automatically after the real tag has been updated.

### Marketplace dependency/helper images

List the configured Marketplace dependency/helper image set:

```bash
./scripts/mirror-k8s-marketplace-images.sh --list
```

Mirror the dependency/helper set and refresh the matching tag and digest/sha fields in `chart/values.yaml`:

```bash
./scripts/mirror-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --update-values
```

Mirror just a subset:

```bash
./scripts/mirror-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --only nats,curlimages/curl,kiwigrid/k8s-sidecar \
  --update-values
```

Dry-run the dependency/helper flow first:

```bash
./scripts/mirror-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --only nats,curlimages/curl \
  --update-values \
  --dry-run
```

This script does not annotate images or add `1.0` / `1.0.0` release tags. Continue using the dedicated Marketplace scripts for that part of the flow:

```bash
./scripts/tag-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --version 1.0.0 \
  --track 1.0

./scripts/annotate-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --service-name services/opendso-platform-byol.endpoints.<project-id>.cloud.goog
```

## 5. Minimum Image Categories to Mirror

Mirror at least the chart-managed default Marketplace image set:

- infrastructure:
  - NATS
  - Keycloak
  - Postgres (client image used by gms-api's wait-for-postgres-data init container)
  - ESS Manager Redis
- core OpenDSO services:
  - GMS API
  - Topology Genesis
  - Topology Nodes
  - DER Dispatch service
  - ESS Manager service
  - ESS Tester service
  - OmegaDSS
  - RPCDSS
  - NATS Auth service
- frontend images:
  - Genesis Node
  - One-Line
  - GIS
  - Historian
  - Inspector
  - Inventory
  - Event Viewer
  - Data Viewer
  - OpenDSO Docs
  - OpenFMB Event Creator
  - DER Dispatch app
  - ESS Manager app
  - ESS Tester app
  - Schedule Dispatch

Also review dependency-chart images separately, especially sidecar/helper images (e.g. envoy).

## 6. Point the Deployment at Artifact Registry

Set the shared registry prefix in Marketplace or Helm values:

```yaml
global:
  imageRegistry: us-central1-docker.pkg.dev/<project-id>/oesinc
```

## 7. Grant GKE Pull Access

Grant the node service account or Workload Identity principal read access:

```bash
gcloud artifacts repositories add-iam-policy-binding oesinc \
  --location=us-central1 \
  --member="serviceAccount:<node-sa-email>" \
  --role="roles/artifactregistry.reader"
```

## 8. Verify the Mirror

Before deploying, confirm:

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/<project-id>/oesinc
```

For a specific image, inspect tags and digest:

```bash
gcloud artifacts docker tags list \
  us-central1-docker.pkg.dev/<project-id>/oesinc/gms-api
crane digest us-central1-docker.pkg.dev/<project-id>/oesinc/gms-api:1.0.0
```

Check Artifact Registry vulnerability findings:

```bash
./scripts/check-ar-vulnerabilities.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc
```

Generate a report without failing the command:

```bash
./scripts/check-ar-vulnerabilities.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --fail-on NONE \
  --output markdown
```

And confirm the cluster can pull the images by starting a simple pod that references one mirrored image.

## 9. Operational Notes

- keep tags and digests aligned with `schema.yaml` and `chart/values.yaml`
- when using `--update-values`, commit the resulting tag and digest updates along with the mirrored-image change so the chart stays reproducible
- `scripts/mirror-app-images.sh --update-values` patches `global.images.*.tag` and `.digest`
- `scripts/mirror-k8s-marketplace-images.sh --update-values` patches both `.tag` and the configured `digest` or `sha` field for each hardcoded dependency/helper image block
- if a Marketplace deployment uses a repo prefix that does not contain all required images, failures will appear as pod scheduling or image pull errors rather than chart-rendering errors
