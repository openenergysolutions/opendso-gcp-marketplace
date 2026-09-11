# OpenDSO GCP Marketplace — Live GKE Functional Testing

This guide covers how to validate a real `mpdev install`/`mpdev verify` run
against a live GKE cluster — the same mechanism Google's Producer Portal uses
for `TEST_K8S_APP_FUNCTIONALITY` — rather than relying on `helm template`
alone. Several real bugs in this chart have only ever surfaced this way:
Marketplace's own deployer tooling rewrites image references and resolves
schema-declared properties in ways a plain template render never exercises.

Use this whenever you want real confidence that a chart change works, not
just that it renders.

## 1. Why Not Just `helm template`?

`helm template` only proves the chart renders valid YAML with the values you
hand it. It does not exercise:

- Marketplace's `print_config.py`, which expands `x-google-marketplace`
  schema properties into `values.yaml`-shaped overrides — including forcing
  every schema-declared image to a specific tag (see [Section 6](#6-critical-gotcha-mpdev-forces-every-image-to-the-publishedversion-tag)).
- `deployer/deploy.sh`'s own logic (Keycloak client secret injection, NATS
  NKey generation, Application resource ownership adoption, the topology-genesis
  server-side ConfigMap pre-create).
- Real pod scheduling, image pulls, init container ordering, readiness
  probes, and inter-service network calls (Keycloak OIDC discovery, Postgres
  auth, NATS auth callout).

Bugs found only through a live run this way: an image helper missing a
registry-prefix guard, a hardcoded `externalDatabase.enabled` skipping the
in-cluster DB fallback that Marketplace's own automated test relies on, a
broken Keycloak CVE patch that invalidated the image's baked-in Quarkus
build cache, and two services reading Postgres credentials that silently
resolved to a placeholder string instead of the real generated password.
None of these show up in `helm template` output. A later round of testing
found a more fundamental issue with how images get resolved at all — see
[Section 7](#7-critical-gotcha-chartvaluesyaml-digests-win-over-tags-and-they-go-stale-silently)
and [Section 8](#8-other-bugs-found-in-this-round-2026-09-11).

## 2. Choose a Test Project

Use a **dedicated GCP project**, separate from `openenergysolutionsinc-public`
(which hosts the public Marketplace image registry for the real listing).
Mixing a disposable test cluster's IAM bindings, billing, and blast radius
into the production image-hosting project isn't necessary.

This repo's known-good test project is `opendso-491115` — it already has an
Artifact Registry repo (`oesinc`, `us-central1`) from prior test runs. Reuse
it rather than creating a new project unless you have a reason not to.

## 3. Mirror Images Into the Test Project

Mirror **both** image sets into the test project, and — critically — include
`--tag-marketplace` even though this is just a test, not a real release. See
[Section 6](#6-critical-gotcha-mpdev-forces-every-image-to-the-publishedversion-tag)
for why this is required.

```bash
PROJECT=opendso-491115
LOCATION=us-central1
REPO=oesinc
VERSION=2.0.0   # must match schema.yaml's x-google-marketplace.publishedVersion
TRACK=2.0

./scripts/mirror-app-images.sh \
  --project "$PROJECT" --location "$LOCATION" --repo "$REPO" \
  --tag-marketplace --version "$VERSION" --track "$TRACK"

./scripts/mirror-k8s-marketplace-images.sh \
  --project "$PROJECT" --location "$LOCATION" --repo "$REPO" \
  --tag-marketplace --version "$VERSION" --track "$TRACK"
```

Do **not** pass `--update-values` here — that patches the tracked
`chart/values.yaml`, which should keep pointing at the production registry
mirror, not this throwaway test project. Passing `--tag-marketplace` alone
just adds alias tags in Artifact Registry; it never touches files in the repo.

The `opendso-apps-db` fallback path (see [Section 9](#9-testing-the-in-cluster-database-fallback))
uses a plain `postgres` image that isn't part of the Marketplace-scanned
image set and isn't in either mirror script's `IMAGE_SPECS`. If you need it,
mirror it separately:

```bash
crane copy postgres:16-alpine \
  "${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}/postgres:16-alpine"
```

## 4. Build and Push the Deployer

```bash
./scripts/build-deployer.sh \
  --service-name "services/opendso-platform-byol.endpoints.${PROJECT}.cloud.goog" \
  --project "$PROJECT" --location "$LOCATION" --repo "$REPO" \
  --tag "$TRACK"
```

## 5. Provision the Cluster

```bash
./scripts/provision-test-env.sh \
  --project "$PROJECT" \
  --domain demo-gcp.oesinc.dev \
  --cluster opendso-test \
  --zone us-central1-a \
  --region "$LOCATION" \
  --ar-repo "$REPO" \
  --namespace opendso \
  --release opendso
```

This creates the GKE cluster, installs nginx ingress and cert-manager,
creates the namespace and a self-signed TLS secret, installs the
`app.k8s.io` Application CRD, and grants the node service account
`artifactregistry.reader` on the test project.

**DNS**: the script pauses partway through and prints the LoadBalancer IP,
waiting for you to point a wildcard DNS record at it before continuing. If
you're running this non-interactively (e.g. from an agent session with no
attached terminal), the script will exit at that prompt once stdin hits EOF —
this is expected, not a bug. Note the printed IP, update your DNS records
(Cloud DNS: `gcloud dns record-sets transaction ...` for both the apex and
`*.` wildcard), confirm propagation, then run the remaining steps from the
script by hand: cert-manager install, namespace creation, the TLS secret,
the Application CRD, and the IAM binding (read the script — each step is a
plain `helm install`/`kubectl apply`/`gcloud` call you can run directly).

## 6. Critical Gotcha: `mpdev` Forces Every Image to the `publishedVersion` Tag

This is the single biggest time-sink in testing this chart, and it's not
written down anywhere else.

`mpdev verify` and `mpdev install` both run Marketplace's own
`print_config.py --values_mode expanded`, which reads `schema.yaml`'s
`x-google-marketplace.images` declarations and **rewrites every declared
image's tag to match `schema.yaml`'s `publishedVersion`** — completely
independent of whatever tag is pinned in `chart/values.yaml`. This happens
for both first-party and third-party images (`gms-api`, `busybox`, `nats`,
everything under `x-google-marketplace.images`).

Symptom: every pod hits `ImagePullBackOff` looking for e.g.
`gms-api:2.0.0` even though `chart/values.yaml` says `tag: "v3-fc85c01d"`,
and editing `values.yaml`'s tag has **no effect** — mpdev overrides it
regardless.

Fix: make sure `2.0.0` and `2.0` (or whatever `schema.yaml`'s
`publishedVersion`/track currently is) actually exist as tags in the test
project's Artifact Registry, pointing at the digests you want to test. This
is exactly what `--tag-marketplace` in Step 3 does — it's not just a
release-submission nicety, it's required for `mpdev` to find the images at
all during a live test.

If you only need to swap one image's tag for a quick iteration (e.g. testing
a new Keycloak build), you can re-tag it directly without re-running the
whole mirror script:

```bash
crane tag "${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}/<image>:<new-tag>" "$VERSION"
crane tag "${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}/<image>:<new-tag>" "$TRACK"
```

## 7. Critical Gotcha: `chart/values.yaml` Digests Win Over Tags, and They Go Stale Silently

Every image in `chart/values.yaml` (first- and third-party alike) carries a
`digest:` field alongside `tag:`. The `opendso.image` helper — and all 33
near-identical per-subchart copies of it (`gms-api.image`, `keycloak.image`,
etc.) — apply this rule unconditionally:

```text
if digest is set: image = "<repo>@<digest>"
else:             image = "<repo>:<tag>"
```

Digest always wins when it's non-empty, **regardless of which registry
`global.imageRegistry` points at**. Section 3 correctly tells you not to run
the mirror scripts with `--update-values` against the test project, so the
digests in `chart/values.yaml` never change during a live test — they stay
pinned to whatever they were at the last real `--update-values` run against
production. If that pinned digest doesn't exist in the *test* project's
registry (it usually won't — a freshly mirrored image isn't guaranteed to
land on the same digest, and the pin itself can simply go stale over time),
every one of those pods fails with `ImagePullBackOff` / `ErrImagePull: ...
not found`, even though the tag mirrored successfully and mpdev's tag-rewrite
([Section 6](#6-critical-gotcha-mpdev-forces-every-image-to-the-publishedversion-tag))
worked exactly as documented.

This bit us in a 2026-09-11 round of testing: freshly re-mirroring every
image and rebuilding the deployer from a clean checkout still produced 1 of
29 pods healthy, because nearly every image in `chart/values.yaml` has a
`digest:` pinned from an earlier point in time. Confirmed concretely for
`busybox` — the digest pinned in `values.yaml` (`sha256:bcb6070e...`) matched
neither the current `docker.io/busybox:1.36` manifest-list digest nor its
`linux/amd64`-normalized digest; it didn't exist anywhere reachable.

**This also silently swallows source-image fixes.** If you patch a
Dockerfile (e.g. a Keycloak CVE patch), rebuild, and push a corrected image
under the same tag, `chart/values.yaml`'s pinned digest still points at the
*old* image — mpdev deploys the old, broken build every time, with no error
and no indication the fix didn't take effect. That's exactly what happened
re-validating the Keycloak `netty-resolver-dns` patch from
[Section 1](#1-why-not-just-helm-template): the pod pulled fine (a valid
digest, just the wrong one) and crash-looped with the *original* bug the
patch was supposed to fix.

**Confirmed fix / workaround**: [Section 11](#11-iterating-on-chart-fixes-without-a-full-mirror-cycle)'s
blank-every-digest scratch build isn't just for fast template iteration — it
is currently the *only* way to get a working live install against a freshly
mirrored test registry at all. Redeploying the same otherwise-unmodified
chart with every `digest:` field blanked took the install from 1 of 29 pods
healthy to 28 of 29 (the sole remaining failure was the expected
`topology-nodes` license-key limitation, see
[Section 12](#12-known-test-only-limitations)).

**Recommended long-term fix (not yet implemented)**: add a
`global.imageResolveBy: "digest" | "tag"` value, default `digest`, and have
all 33 `.image` helpers check it (`if digest is set AND resolveBy != "tag"`).
Leave it out of `schema.yaml` so it's never exposed to real Marketplace
customers — production always resolves by digest as required. Live testing
would then pass `global.imageResolveBy=tag` as a parameter instead of
maintaining a scratch chart copy.

## 8. Other Bugs Found in This Round (2026-09-11)

All three findings below were independently re-verified and the first two
are now **fixed** in production. The third remains an open design question.

- **FIXED — `gms-api`'s pinned tag didn't exist upstream.** `chart/values.yaml`
  pinned `global.images.gmsApi.tag` to `v3-fc85c01d`, but
  `docker.io/oesinc/gms-api:v3-fc85c01d` returned `MANIFEST_UNKNOWN` — that
  tag was never published (it was an interim image manually pushed straight
  to Artifact Registry earlier in development, bypassing Docker Hub
  entirely). `scripts/mirror-app-images.sh`'s `IMAGE_SPECS` still mirrored
  the older `v3-bad937d3`. By the time this was investigated, PR #57 in
  `opendso-gms-applications` (the fix this interim image existed for) had
  merged and CI had already published an official `v3-03d8fe65` build.
  Reconciled by mirroring `v3-03d8fe65` into the production registry with
  `--annotate --tag-marketplace --update-values`, and fixing
  `mirror-app-images.sh`'s `IMAGE_SPECS` to match — retiring the interim
  image entirely.

- **OPEN — `opendso-apps-db` renders on the Marketplace path, but its image
  doesn't exist there.** The in-cluster StatefulSet fallback (added earlier
  this session, see the top-level bug list) correctly renders whenever
  `externalDatabase.host` is blank — including for real Marketplace
  customers who don't supply Cloud SQL params, not just Marketplace's own
  automated test. But `postgres` is deliberately excluded from
  `schema.yaml`/the production-mirrored image set (an earlier decision to
  keep it off the Marketplace-scanned/CVE-tracked surface). Net effect: a
  real customer hitting this fallback today gets `opendso-apps-db-0` stuck
  in `ImagePullBackOff`, not a working database. This needs a decision:
  either mirror `postgres` into production and declare it in `schema.yaml`
  (re-adding it to the CVE-tracked surface), or gate the in-cluster fallback
  so it never renders under `values-gcp.yaml` specifically (restoring "always
  require external Cloud SQL" for real installs — which would also mean
  Marketplace's own automated functionality test fails again, since it never
  supplies Cloud SQL params either). Not yet resolved as of this writing.

- **FIXED — Production's patched Keycloak image was stale and broken.**
  `us-docker.pkg.dev/openenergysolutionsinc-public/oesinc/quay.io/keycloak/keycloak:26.6.3-patched`
  still contained the *old*, broken (rename-based) `netty-resolver-dns`
  patch — the Dockerfile fix in `patches/keycloak/Dockerfile` was committed
  but never rebuilt and republished there. Independently reproduced the
  exact crash (`netty-resolver-dns-4.1.133.Final.jar does not exist`)
  directly against the live production image to confirm before fixing.
  Rebuilt from the current Dockerfile, boot-tested locally, re-applied the
  required `com.googleapis.cloudmarketplace.product.service.name` annotation
  (present on the old image, lost on a plain rebuild) via the standard
  `crane tag` → `crane mutate --annotation` → `crane copy` pattern, boot-tested
  again, then pushed to production and updated `chart/values.yaml`'s digest.

## 9. Testing the In-Cluster Database Fallback

Marketplace's own automated functionality test (and `data-test/verification-defaults.yaml`)
never supplies Cloud SQL connection parameters. The chart's `opendso-apps-db`
external-database fallback (see `chart/values-gcp.yaml`) only activates the
in-cluster StatefulSet when `externalDatabase.host` is blank — so a live test
run without Cloud SQL params exercises that path, which the default `helm
template` smoke test never does. If you're testing this path specifically,
make sure the plain `postgres` image is mirrored per [Section 3](#3-mirror-images-into-the-test-project).
See also the render-condition discrepancy noted in
[Section 8](#8-other-bugs-found-in-this-round-2026-09-11).

## 10. Run `mpdev verify` / `mpdev install`

```bash
DEPLOYER="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}/deployer:${TRACK}"

mpdev verify \
  --deployer="$DEPLOYER" \
  --parameters='{
    "license.key": "test",
    "installation.key": "test",
    "global.imageRegistry": "'"${LOCATION}"'-docker.pkg.dev/'"${PROJECT}"'/'"${REPO}"'",
    "global.domain": "demo-gcp.oesinc.dev",
    "global.resourceProfile": "minimal",
    "keycloak.config.adminPassword": "changeme"
  }'
```

For a persistent, inspectable deployment instead of the ephemeral verify
namespace, use `mpdev install` (add `name`/`namespace` parameters):

```bash
mpdev install \
  --deployer="$DEPLOYER" \
  --parameters='{
    "name": "opendso",
    "namespace": "opendso",
    "license.key": "test",
    "installation.key": "test",
    "global.imageRegistry": "'"${LOCATION}"'-docker.pkg.dev/'"${PROJECT}"'/'"${REPO}"'",
    "global.domain": "demo-gcp.oesinc.dev",
    "global.resourceProfile": "minimal",
    "keycloak.config.adminPassword": "changeme"
  }'
```

### `mpdev verify`'s "PASSED" is not proof the app works

`mpdev verify` can report `VERIFICATION STATUS: PASSED` in its final output
even while multiple pods sit in a persistent `ImagePullBackOff` or
`CrashLoopBackOff`. Its check is shallower than "every pod is healthy." Don't
trust the verdict alone — always cross-check with:

```bash
kubectl get pods -n <namespace>
```

`mpdev install` is generally more useful for real validation since the
release stays up afterward and you can inspect it directly, rather than
relying on the ephemeral namespace `mpdev verify` tears down when it exits.

### Re-running against an existing release

`mpdev install` creates a Kubernetes `Job` (`<release>-deployer`) with an
immutable `spec.template`. Re-running `mpdev install` against the same
release without deleting the old job first fails with `field is immutable`:

```bash
kubectl delete job <release>-deployer -n <namespace> --ignore-not-found=true
```

## 11. Iterating on Chart Fixes Without a Full Mirror Cycle

Rebuilding a fix normally means: edit chart → re-mirror/re-tag images →
rebuild deployer → redeploy. For fast iteration on a chart-only fix (no new
image content), you can skip the mirror step entirely:

1. Copy the chart into a scratch directory and blank out every `digest:`
   field in `values.yaml` (the `opendso.image` helper falls back to
   tag-based resolution when digest is empty, and the already-mirrored
   images' tags haven't changed):

   ```bash
   rm -rf /tmp/scratch-build && mkdir -p /tmp/scratch-build
   cp -r chart deployer schema.yaml data-test /tmp/scratch-build/
   python3 -c "
   import re
   p = '/tmp/scratch-build/chart/values.yaml'
   s = open(p).read()
   open(p, 'w').write(re.sub(r'digest: \"sha256:[0-9a-f]+\"', 'digest: \"\"', s))
   "
   ```

2. Make your chart-template fix in `/tmp/scratch-build/chart/...` (mirror
   the same edit into the real repo once verified).

3. Build and push a throwaway deployer tag directly (skip `build-deployer.sh`'s
   defaults so you don't collide with the real `2.0`/`2.0.0` tags):

   ```bash
   cd /tmp/scratch-build
   docker build --pull --platform linux/amd64 -f deployer/Dockerfile \
     -t "${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}/deployer:scratch-test" .
   docker push "${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}/deployer:scratch-test"
   ```

4. Redeploy with `--deployer=...deployer:scratch-test`.

**Gotcha**: if you've ever manually run `helm dependency build`/`update`
inside the scratch chart (e.g. to render a single subchart's manifest for
debugging), it leaves packaged `charts/*.tgz` archives on disk. Helm prefers
those `.tgz` files over the live subchart source directories, so a later
edit to a subchart template can silently have no effect until you delete the
stale archives:

```bash
rm -f /tmp/scratch-build/chart/charts/*.tgz
```

The deployer image's own build (`RUN helm dependency build /tmp/build/chart`
in `deployer/Dockerfile`) regenerates these from the live directories, so
this only bites you if you ran `helm dependency build` yourself in the
scratch copy first.

## 12. Known Test-Only Limitations

- **`topology-nodes` license validation will fail** with the placeholder
  `"license.key": "test"` parameter — it needs a real license server over
  TLS. This is expected in any test environment without a real license and
  is not a chart bug.
- Manually deleting live resources out-of-band (e.g. `kubectl delete
  statefulset`) instead of doing everything through `mpdev install` leaves
  Helm's tracked release state out of sync with the cluster — Helm won't
  recreate a resource you deleted by hand unless its template content also
  changed. If you need to reset a resource's state, prefer deleting the
  whole namespace and doing a clean `mpdev install`, which is also the only
  way to be confident you're seeing what a real first-time customer install
  would look like (see [Section 10](#10-run-mpdev-verify--mpdev-install)).

## 13. Tearing Down

The test cluster is a real, billable 3-node `e2-standard-8` GKE cluster.
Tear it down when you're done testing:

```bash
gcloud container clusters delete opendso-test --project="$PROJECT" --zone=us-central1-a --quiet
```
