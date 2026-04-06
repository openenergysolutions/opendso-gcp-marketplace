# OpenDSO GCP Marketplace — Image Mirroring Guide

This guide describes how to mirror the OpenDSO image set into a customer's GCP Artifact Registry before deployment.

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

The exact image inventory is defined by:

- `schema.yaml`
- `chart/values.yaml`
- `chart/values-gcp.yaml`

Practical mirroring workflow:

1. identify the source image
2. pull it locally
3. retag it into Artifact Registry
4. push it

Example:

```bash
docker pull nats:2.9.9
docker tag nats:2.9.9 us-central1-docker.pkg.dev/<project-id>/oesinc/nats:2.9.9
docker push us-central1-docker.pkg.dev/<project-id>/oesinc/nats:2.9.9
```

For OES images:

```bash
docker pull <source-registry>/gms-api:<tag>
docker tag <source-registry>/gms-api:<tag> us-central1-docker.pkg.dev/<project-id>/oesinc/gms-api:<tag>
docker push us-central1-docker.pkg.dev/<project-id>/oesinc/gms-api:<tag>
```

## 5. Minimum Image Categories to Mirror

Mirror at least the chart-managed default Marketplace image set:

- infrastructure:
  - NATS
  - Keycloak
  - MongoDB
  - Citus
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

Also review dependency-chart images separately, especially Grafana.

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

And confirm the cluster can pull the images by starting a simple pod that references one mirrored image.

## 9. Operational Notes

- keep tags and digests aligned with `schema.yaml`
- if you use digests in the chart, mirror by digest-aware tag discipline and verify the pushed image matches the expected digest
- if a Marketplace deployment uses a repo prefix that does not contain all required images, failures will appear as pod scheduling or image pull errors rather than chart-rendering errors
