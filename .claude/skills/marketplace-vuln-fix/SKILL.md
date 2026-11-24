---
name: marketplace-vuln-fix
description: Triage and fix vulnerabilities in the OpenDSO GCP Marketplace listing images, then cut a patch release. Use when Google Cloud Marketplace reports CVEs against listing images, when the scheduled listing scan or the deployer Trivy gate fails, or before preparing a new Marketplace release.
---

# Marketplace vulnerability fix and release

The listing ships the images declared in `schema.yaml`, pinned by digest in
`chart/values.yaml`, plus the deployer. Google reviews them with Artifact
Registry's scanner. This playbook takes a set of findings to a tested patch
release.

## Ground rules

- **Never merge or approve PRs.** Open them and stop; a person merges. This
  applies to this repo and every source repo.
- **Never change what a published version points at.** Google keeps its own
  copy of each published version, so a fix always ships as a new patch version
  (2.0.1 → 2.0.2). Don't re-push or re-tag `X.Y.Z` tags that were submitted.
- **Always pass `--annotate` when mirroring.** The mirror scripts re-copy from
  upstream first; without `--annotate` the tag ends up on an unannotated image
  and nothing errors.
- **This repo is public.** No license or installation keys, passwords, IPs or
  internal project names in commits, PR text or docs.
- **Work in a git worktree** in other repos; never switch the user's checkout.
  Run `git submodule update --init` in the worktree (some repos build from an
  `oss-compliance` submodule).
- Ask before anything that costs money or touches shared infrastructure
  (creating Cloud SQL instances, deleting namespaces).

## 1. Get the findings

```bash
./scripts/scan-listing-images.sh                 # table, fails on HIGH+
./scripts/scan-listing-images.sh --output json   # for parsing
```

A Google notice lists `gcr.io/cloud-marketplace/.../<image>@sha256:...`; match
the digest against `chart/values.yaml` (our Artifact Registry digests are the
same).

For package details and fixed versions, also run Trivy. Pull the image to the
host first: the Trivy container can't authenticate to Artifact Registry.

```bash
docker pull us-docker.pkg.dev/openenergysolutionsinc-public/oesinc/<image>@<digest>
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest image \
  -q --skip-version-check --severity CRITICAL,HIGH,MEDIUM,LOW \
  --format template --template '{{range .}}{{$t:=.Target}}{{range .Vulnerabilities}}{{$t}} | {{.VulnerabilityID}} {{.Severity}} | {{.PkgName}} {{.InstalledVersion}} -> {{.FixedVersion}}{{"\n"}}{{end}}{{end}}' \
  <image-ref>
```

Fix everything with an available fix in the affected images, not only the CVE
IDs Google named; the rest are usually the next notice.

## 2. Find the source

| Image(s) | Source | Build branch |
|---|---|---|
| `gms-api` and every `*-app` | `openenergysolutions/opendso-gms-applications` (one build; tag `v3-<sha>`) | `main` |
| `historian`, `topology-genesis`, `topology-nodes`, `der-dispatch`, `ess-manager`, `ess-tester`, `ahs`, `ahs-sim`, `opendso-data-service`, `openfmb-event-service` | `openenergysolutions/<same name>` (`ods-svc` is `opendso-data-service`) | `main` |
| `omegadss`, `rpcdss`, `nats-auth-service` | `openenergysolutions/<same name>` | `develop` |
| `nats`, `quay.io/keycloak/keycloak`, `envoyproxy/envoy`, `busybox` | Upstream, mirrored by `scripts/mirror-k8s-marketplace-images.sh` | — |
| `deployer` | This repo, `deployer/Dockerfile` on Google's `deployer_helm` base | `main` |

First-party images are built by each repo's CI when a PR merges and pushed to
Docker Hub as `oesinc/<image>:<short merge SHA>`. Before rebuilding, compare the
chart's commit with the build branch (`gh api repos/<org>/<repo>/compare/<sha>...<branch>`)
and call out any unreleased code a rebuild would pick up.

## 3. Classify and fix

| Finding | Fix |
|---|---|
| OS package (Alpine/Ubuntu) with a fixed version in the distro index | Rebuild. Check the runtime stage runs `apk upgrade --no-cache` / `apt-get upgrade`: the base image itself often still has the old package, so `apk add` alone keeps it. Add the upgrade if it's missing. |
| Go stdlib | Bump the builder image (`golang:X.Y.Z[-alpine]`) to the fixed patch. |
| Go module | `go get <module>@<fixed>` + `go mod tidy` (run in a `golang` container with `GOTOOLCHAIN=local`); the `go` directive may need to rise. |
| Third-party image (NATS, Envoy, Keycloak) | Newest patch on the same line. Scan the candidate first; prefer an upstream release that already contains the fix over patching jars. Test a Keycloak upgrade locally with the chart's rendered `keycloak.conf` and realm import before mirroring. |
| Google's `deployer_helm` base, or no fix published anywhere | Document it in `.trivyignore` with the component, why it's blocked and when to remove it. Note it for the review response. |

Verify every fix locally before opening a PR: build the image and confirm Trivy
no longer reports the finding. Open PRs whose body lists the CVEs, the fix and
the local verification. Then stop for merges.

## 4. Mirror into Artifact Registry

After the source PR merges and its CI pushes `oesinc/<image>:<sha>`:

```bash
# update the image's tag in IMAGE_SPECS first, then:
./scripts/mirror-app-images.sh --only <image> --annotate \
  --service-name opendso-platform-byol.endpoints.openenergysolutionsinc-public.cloud.goog \
  --update-values
# third-party images: scripts/mirror-k8s-marketplace-images.sh, same flags
```

Wait about two minutes, then confirm the new digest scans clean
(`./scripts/scan-listing-images.sh`). Commit the `values.yaml` and mirror-script
changes on a branch.

If a mirror run is interrupted, a `tmp-marketplace-*` tag can be left behind
and the version tag may point at an unannotated copy: delete the temporary tag
and re-run that image with `--annotate`.

## 5. Release

1. Bump `publishedVersion` and `publishedVersionMetadata.releaseNote` in
   `schema.yaml` and `appVersion` in `chart/Chart.yaml`. The deployer reads the
   version from the schema. Run `helm lint`.
2. Tag every listing image without re-copying:
   `./scripts/tag-k8s-marketplace-images.sh --dry-run`, then without
   `--dry-run`. Check that each image's `X.Y.Z` and `X.Y` tags resolve to the
   digest in `values.yaml`.
3. Build the deployer once from the committed release commit, then point the
   track tag at the same digest:
   ```bash
   ./scripts/build-deployer.sh --service-name <service> --tag X.Y.Z
   crane tag us-docker.pkg.dev/openenergysolutionsinc-public/oesinc/deployer:X.Y.Z X.Y
   ```
   Check the deployer's own scan, and that Trivy passes with `.trivyignore`.
4. Run an `mpdev install` of the new deployer on the test cluster (README,
   "Testing the Deployer Locally"). Confirm: Application version and
   `Success`, all pods Running with no restarts, pods use the new digests,
   license valid. Ask the user for a current installation key and for
   approval before creating or reusing billable test resources.
5. Push the branch, open the release PR, and stop. The user merges it and
   submits the version in Producer Portal.

## Report back

End with a table of each finding → fix → status (merged, mirrored, scanned
clean), anything still flagged and why, and the remaining human steps
(merges, Producer Portal submission, test resources to clean up).
