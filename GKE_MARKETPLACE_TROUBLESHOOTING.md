# OpenDSO GCP Marketplace — Troubleshooting Guide

This guide covers the most common failure modes seen during `mpdev verify`, Marketplace deployment, and early post-install validation on GKE.

## 1. Start With Cluster State

Check the overall state of the release namespace:

```bash
kubectl get all -n <namespace>
kubectl get pods -n <namespace> -o wide
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

If a pod is not `Running` and `Ready`, inspect it directly:

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous
kubectl logs <pod-name> -n <namespace>
```

## 2. Image Pull Failures

Symptoms:

- `ImagePullBackOff`
- `ErrImagePull`
- `FailedToRetrieveImagePullSecret`

Checks:

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get sa default -n <namespace> -o yaml
```

What to verify:

- the GKE node service account has `roles/artifactregistry.reader`
- the expected Artifact Registry repo actually contains the mirrored images
- `global.imageRegistry` points at the correct registry prefix
- the Marketplace deployment model matches how pull access was granted

## 3. TLS Secret Problems

Symptoms:

- `MountVolume.SetUp failed`
- missing `server-cert`, `server-key`, or `root-ca`
- ingress comes up with self-signed or unexpected certificate

Checks:

```bash
kubectl get secret <release-name>-tls-secret root-ca server-cert server-key -n <namespace>
kubectl describe ingress <release-name>-ingress -n <namespace>
```

What to verify:

- `<release-name>-tls-secret` exists in the target namespace
- `global.tls.existingSecret` resolves to the same name
- cert-manager has actually issued the certificate if that path is being used
- if relying on chart-managed fallback, confirm the generated alias secrets exist

## 4. Keycloak Problems

Symptoms:

- services fail waiting for OIDC discovery
- `Connection refused` to Keycloak
- `*-keycloak-env` secrets missing

Checks:

```bash
kubectl get deploy <release-name>-keycloak -n <namespace>
kubectl logs deploy/<release-name>-keycloak -n <namespace> --tail=200
kubectl get secret -n <namespace> | grep keycloak-env
kubectl port-forward svc/<release-name>-keycloak-svc -n <namespace> 18080:8080
curl -s http://localhost:18080/realms/oes/.well-known/openid-configuration
```

What to verify:

- Keycloak pod is actually Ready before dependent services start
- the deployer created the per-client `*-keycloak-env` secrets
- realm import completed on a fresh install
- on upgrades, the deployer Keycloak Admin API sync completed successfully

## 5. NATS and NATS Auth Problems

Symptoms:

- services fail with NATS connection errors
- NATS WebSocket endpoint fails externally
- `nats-auth-svc` fails OIDC or startup checks

Checks:

```bash
kubectl get deploy <release-name>-nats <release-name>-nats-auth-svc -n <namespace>
kubectl logs deploy/<release-name>-nats -n <namespace> --tail=200
kubectl logs deploy/<release-name>-nats-auth-svc -n <namespace> --tail=200
kubectl get secret <release-name>-nats-auth-keys -n <namespace>
kubectl describe ingress <release-name>-ingress-nats-ws -n <namespace>
```

What to verify:

- `<release-name>-nats-auth-keys` exists
- NATS started with the expected TLS settings
- the WebSocket ingress backend protocol matches the chart TLS mode
- Keycloak client secret injection succeeded for `nats-auth-svc`

## 6. Database Startup Failures

Symptoms:

- `CrashLoopBackOff` on `opendso-apps-db` (in-cluster) or Redis
- permission errors such as `chmod ... Operation not permitted`
- Cloud SQL connection errors (timeout, authentication failure) when using external database

Checks:

```bash
kubectl logs <db-pod> -n <namespace> --previous
kubectl describe pod <db-pod> -n <namespace>
kubectl get pvc -n <namespace>
```

What to verify:

- PVCs are bound
- the storage class matches the cluster
- the image is not being forced into a security context it cannot satisfy
- mounted volumes are writable by the container startup path

## 7. Frontend App Failures

Symptoms:

- frontend app pods `CrashLoopBackOff`
- ingress exists but UI endpoint does not load

Checks:

```bash
kubectl get deploy -n <namespace>
kubectl logs deploy/<frontend-deployment> -n <namespace> --tail=200
kubectl get configmap <release-name>-frontend-environment -n <namespace> -o yaml
kubectl describe ingress <release-name>-ingress -n <namespace>
```

What to verify:

- the frontend image is actually built for non-root if `runAsNonRoot` is enforced
- the generated frontend environment config points to the expected API and NATS URLs
- DNS and ingress hostnames resolve to the cluster ingress IP

## 8. GMS API Problems

Symptoms:

- `/api/health` fails
- frontend UIs load but API calls fail

Checks:

```bash
kubectl logs deploy/<release-name>-gms-api -n <namespace> --tail=200
kubectl port-forward svc/<release-name>-gms-api -n <namespace> 18081:8000
curl -s http://localhost:18081/api/health
```

What to verify:

- gms-api starts even if Postgres is unreachable (it warns and falls back to `AUTH_*` env vars instead of crashing — see `opendso-gms-applications` PR #57); DB-backed routes will fail per-request until connectivity is restored
- GMS API is using the internal Keycloak URL, not an external hostname
- orchestration (pod list/delete) is scoped to the app's own namespace — cross-namespace orchestration calls are expected to fail by design (namespace-scoped RBAC, not cluster-wide)

## 9. Ingress and DNS Problems

Symptoms:

- TLS works for some hosts but not others
- `404` from ingress
- browser cannot resolve hostnames

Checks:

```bash
kubectl get ingress -n <namespace>
kubectl describe ingress <release-name>-ingress -n <namespace>
kubectl describe ingress <release-name>-ingress-api -n <namespace>
kubectl describe ingress <release-name>-ingress-nats-ws -n <namespace>
nslookup keycloak.<domain>
nslookup api.<domain>
nslookup nats.<domain>
```

What to verify:

- wildcard DNS points to the nginx ingress LoadBalancer IP
- ingress class is `nginx`
- the correct TLS secret is attached

## 10. When `mpdev verify` Fails

Check both the deployer logs and the namespace state:

```bash
kubectl get jobs -n <namespace>
kubectl logs job/<deployer-job-name> -n <namespace> --tail=300
kubectl get pods -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

Important implementation details:

- the deployer does not use `helm --wait`
- readiness is checked by `scripts/verify.sh`
- some failures reported during verify are transient probe or cache-sync warnings, while others are real container startup failures

The critical distinction is whether the pod is still making progress or is in a steady failed state such as `CrashLoopBackOff`, `ImagePullBackOff`, or repeated mount errors.
