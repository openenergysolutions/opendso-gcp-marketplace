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
  Mirrors the pre-defined first-party OpenDSO app image set from Docker Hub into Artifact Registry. It can also annotate images for Marketplace, add release tags like `2.0.0` and `2.0`, and update `chart/values.yaml` tags and digests.
- `scripts/mirror-k8s-marketplace-images.sh`
  Mirrors the hardcoded Marketplace dependency/helper image set (nats, keycloak, envoy, postgres, redis, busybox) into Artifact Registry. Supports the same `--annotate`, `--tag-marketplace`, and `--update-values` flags as `mirror-app-images.sh`.

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
  --version 2.0.0 \
  --track 2.0 \
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

This order matters because annotation changes the image manifest, and therefore changes the digest. This order — and the four-step behavior — is identical in `mirror-k8s-marketplace-images.sh`.

Temporary `tmp-marketplace-*` tags created during annotation are now deleted automatically after the real tag has been updated.

**Important — step 1 always re-copies from the original upstream source**, unconditionally, on every run of either script. If you re-run one of these scripts later with only `--tag-marketplace` (forgot it the first time, say) but without `--annotate`, step 1 silently overwrites the already-annotated image in Artifact Registry with a fresh, unannotated copy pulled straight from upstream again — then tags *that* as the release version. The annotation is gone, and nothing errors.

If all you need is to add or fix release tags on images that are already correctly mirrored and annotated, don't re-run the mirror scripts — use `scripts/tag-k8s-marketplace-images.sh` instead. It reads each image's current tag directly from `chart/values.yaml` and adds the version/track tags as plain `gcloud artifacts docker tags add` aliases pointing at that same digest — no re-copy from upstream, so it can't clobber an existing annotation:

```bash
./scripts/tag-k8s-marketplace-images.sh \
  --version 2.0.0 \
  --track 2.0
```

It covers every image declared in `schema.yaml` (both first-party and third-party) in one pass, and is safe to re-run — adding a tag that already points at the same digest is a no-op.

### Marketplace dependency/helper images

List the configured Marketplace dependency/helper image set:

```bash
./scripts/mirror-k8s-marketplace-images.sh --list
```

Mirror the full set, annotate for Marketplace, add release tags, and refresh tags and digests in `chart/values.yaml` — this is the one-shot command for a release:

```bash
./scripts/mirror-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --annotate \
  --service-name services/opendso-platform-byol.endpoints.<project-id>.cloud.goog \
  --tag-marketplace \
  --version 2.0.0 \
  --track 2.0 \
  --update-values
```

Mirror just a subset (without annotating — e.g. picking up a newer upstream build for local testing):

```bash
./scripts/mirror-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --only nats,postgres \
  --update-values
```

Dry-run the dependency/helper flow first:

```bash
./scripts/mirror-k8s-marketplace-images.sh \
  --project <project-id> \
  --location us-central1 \
  --repo oesinc \
  --only nats,postgres \
  --update-values \
  --dry-run
```

One image the mirror scripts never touch: the **deployer** image itself (built separately via `scripts/build-deployer.sh`, or annotated on its own via `scripts/annotate-k8s-marketplace-images.sh` if it's already pushed). Neither `mirror-app-images.sh` nor `mirror-k8s-marketplace-images.sh` covers it.

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
crane digest us-central1-docker.pkg.dev/<project-id>/oesinc/gms-api:2.0.0
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
