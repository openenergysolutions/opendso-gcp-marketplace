# OpenDSO Helm Chart

An umbrella Helm chart for deploying the OpenDSO platform on Kubernetes with 38 subcharts.

## Chart Information

- **Version**: 0.1.0
- **Type**: Umbrella Chart
- **Components**: 38 subcharts (37 internal + 1 external)
- **External Dependencies**: Grafana (10.5.14)

## Prerequisites

- Kubernetes 1.24+
- Helm 3.8+
- kubectl configured to access your cluster
- LoadBalancer support (cloud provider or minikube tunnel)
- [mkcert](https://github.com/FiloSottile/mkcert) for local TLS certificates (optional)

## Quick Installation

```bash
# 1. Download chart dependencies
helm dependency update

# 2. Create namespace
kubectl create namespace <namespace>

# 3. Create required secrets (see Security section below)

# 4. Install
helm install <release-name> . -n <namespace>
```

## Chart Structure

```text
opendso/
├── Chart.yaml                    # Chart metadata and dependencies
├── Chart.lock                    # Dependency lock file
├── values.yaml                   # Default configuration
├── charts/                       # 38 subcharts
│   ├── nats/                    # Infrastructure services
│   ├── keycloak/
│   ├── mongodb/                 # Database services
│   ├── citus-db/
│   ├── historian-svc/          # Core services
│   ├── gms-api/
│   └── ...                      # 36 more charts
├── templates/
│   ├── _helpers.tpl            # Template helper functions
│   ├── grafana-secret.yaml     # Grafana credentials secret
│   ├── site-configmaps.yaml    # Site-specific configuration
│   └── ingress.yaml            # Ingress resources
└── configs/                     # Site-specific configurations
    └── ieee13/                  # IEEE 13-node test feeder
```

## Dependencies

### External Charts

External dependencies are defined in `Chart.yaml` and downloaded via `helm dependency update`:

```yaml
dependencies:
  - name: grafana
    version: "10.5.14"
    repository: "https://grafana.github.io/helm-charts"
    condition: global.grafana.enabled
```

### Internal Subcharts

37 internal subcharts + 1 external (grafana) in the `charts/` directory:

- **Infrastructure** (3): nats, keycloak, grafana
- **Databases** (4): mongodb, citus-db, keycloak-db, opendso-apps-db
- **Core Services** (3): historian-svc, gms-api, openfmb-event-service
- **Topology** (2): topology-genesis, topology-nodes
- **DER** (2): der-dispatch-app, der-dispatch-svc
- **Frontend Apps** (11): genesis-node-app, data-viewer-app, event-viewer-app, gis-app, historian-app, inspector-app, inventory-app, one-line-app, opendso-docs-app, openfmb-event-creator-app, schedule-dispatch-app
- **CVR** (3): cvr-svc, cvr-openfmb-services-svc, cvr-genetic-algorithm-svc
- **ESS** (5): ess-manager-svc, ess-tester-svc, ess-manager-app, ess-tester-app, ess-manager-redis
- **Asset Health** (2): asset-health-svc, asset-health-sim-svc
- **OpenDSS** (2): omegadss-svc, rpcdss-svc
- **Additional** (1): nats-auth-svc

## Configuration

### Global Values

All subcharts share global values defined in `values.yaml`:

```yaml
global:
  # Site configuration
  site: ieee13
  domain: your-domain.example.com          # Base domain for ingress

  # Kubernetes configuration
  namespace: ""                  # leave unset; Helm release namespace is used
  storageClass: standard
  imageRegistry: ""              # Global registry override
  imagePullSecrets:
    - name: regsecret

  # Component enablement (42 flags)
  grafana:
    enabled: true
  nats:
    enabled: true
  mongodb:
    enabled: true
  # ... 39 more service flags
```

### Image Configuration

Centralized image management with digest support:

```yaml
global:
  images:
    nats:
      repository: nats
      tag: "2.9.9"
      pullPolicy: IfNotPresent
      digest: ""                 # Optional: sha256 digest overrides tag

    mongodb:
      repository: mongo
      tag: "7.0"
      pullPolicy: IfNotPresent
      digest: "sha256:abc123..."  # Use specific digest
```

### Component Enablement

Enable/disable services individually:

```yaml
global:
  # Infrastructure
  nats:
    enabled: true
  keycloak:
    enabled: true
  grafana:
    enabled: true               # NEW: Monitoring

  # Databases
  mongodb:
    enabled: true
  citus-db:
    enabled: true
  keycloak-db:
    enabled: false              # Only for production
  opendso-apps-db:
    enabled: true               # NEW: Consolidated app database

  # Core Services
  historian-svc:
    enabled: true
  gms-api:
    enabled: true

  # Frontend Applications (12 total)
  genesis-node-app:
    enabled: true
  # ... enable as needed

  # Energy Services
  cvr-svc:
    enabled: false
  ess-manager-svc:
    enabled: false
  der-dispatch-svc:
    enabled: false
```

### Site-Specific Configuration

Site configurations are stored in `configs/{site}/`:

```text
configs/
  ieee13/                        # IEEE 13-node test feeder
    topology-genesis/
      cim.xml                    # 359KB - CIM model
    keycloak/realm/
      oes-realm.json            # 79KB - OpenDSO realm
      master-realm.json         # 78KB - Master realm
    mongodb/
      mongo-init.js             # Database initialization
    citus-db/
      schema/init.sql           # Database schema
    opendso-apps-db/schema/
      00_create_databases.sql   # Creates ess_tester and assets databases
      10_ess_tester.sql         # ESS testing tables
      20_asset_health.sql       # Asset health tables (TimescaleDB)
    cvr-genetic-algorithm-svc/
      IEEE13Nodeckt.dss         # Power flow model
      Load1.csv                 # 162KB - Load profiles
    # ... more service configs
```

**Select a site**:

```yaml
global:
  site: ieee13
```

**Add a new site**:

1. Create `configs/mysite/` directory
2. Copy required configs from `configs/ieee13/`
3. Modify for your site
4. Set `global.site: mysite`

## Security and Secrets

### Secret-Based Credentials (Required)

All sensitive data uses Kubernetes secrets. The chart no longer ships plaintext fallback passwords for production installs. Required credentials must be provided explicitly, or created by the deploy flow before install:

- `mongodb.auth.rootPassword`
- `mongodb.auth.username`
- `mongodb.auth.password`
- `keycloak.config.adminPassword`
- `grafana.adminPassword` or `grafana.admin.existingSecret`
- `citus-db.auth.password`
- `opendso-apps-db.auth.password`

**Grafana Credentials** (auto-generated):

```yaml
grafana:
  admin:
    existingSecret: "{{ .Release.Name }}-grafana-credentials"
    userKey: admin-user
    passwordKey: admin-password
```

**TLS Certificates**:

```yaml
{{ .Release.Name }}-tls-secret      # Main TLS certificate
root-ca                             # Root CA for services
server-cert                         # Legacy alias for internal mounts
server-key                          # Legacy alias for internal mounts
```

When `global.tls.createSecrets=true`, the chart can generate or reuse the release-scoped TLS secret and create the compatibility aliases required by older workloads. The intended source of truth is the release-scoped secret:

```yaml
global:
  tls:
    existingSecret: "{{ .Release.Name }}-tls-secret"
```

**Container Registry**:

```bash
kubectl create secret docker-registry regsecret \
  --docker-server=your-registry.io \
  --docker-username=user \
  --docker-password=pass \
  -n <namespace>
```

### Creating Secrets Manually

```bash
# Grafana credentials
kubectl create secret generic <release-name>-grafana-credentials \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='secure-password' \
  --from-literal=citus-password='cituspassword' \
  --from-literal=mongodb-password='mongopassword' \
  --from-literal=opendso-apps-db-password='esspassword' \
  -n <namespace>

# TLS certificate (using mkcert)
mkcert -install
mkcert "*.your-domain.example.com" your-domain.example.com
kubectl create secret tls <release-name>-tls-secret \
  --cert=_wildcard.your-domain.example.com.pem \
  --key=_wildcard.your-domain.example.com-key.pem \
  -n <namespace>
```

## Parameterized Release Names

The chart supports custom release names for multi-instance deployments:

**Service References** use `{{ .Release.Name }}`:

```yaml
# NATS connection (automatically adjusted)
NATS_URL: {{ printf "nats://%s-nats-service:4222" .Release.Name }}

# MongoDB connection
MONGODB_URI: {{ printf "mongodb://%s-mongodb:27017" .Release.Name }}
```

**Install with custom name**:

```bash
helm install production . \
  --namespace production \
  --set grafana.admin.existingSecret=production-grafana-credentials
```

**Required overrides for custom names**:

```bash
--set grafana.admin.existingSecret=<release-name>-grafana-credentials
--set grafana.envValueFrom.CITUS_PASSWORD.secretKeyRef.name=<release-name>-grafana-credentials
--set grafana.envValueFrom.OPENDSO_APPS_DB_PASSWORD.secretKeyRef.name=<release-name>-grafana-credentials
```

## Network Configuration

### LoadBalancer + Ingress (Default)

All external access uses LoadBalancer with Ingress:

```yaml
# Ingress configuration
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: grafana.your-domain.example.com
      paths:
        - path: /
          service: {{ .Release.Name }}-grafana
          port: 80
```

**Services use ClusterIP**:

```yaml
service:
  type: ClusterIP    # NOT NodePort
  port: 80
```

Production values are hardened for ingress-based exposure. Local NodePort-style access belongs in development overlays such as `values-dev.yaml`, not in the production path.

**External IP provided by**:

- Cloud LoadBalancer (GKE, EKS, AKS)
- Minikube tunnel (local development)

### TLS Configuration

TLS is handled at the ingress level:

```yaml
ingress:
  tls:
    - secretName: {{ .Release.Name }}-tls-secret
      hosts:
        - "*.your-domain.example.com"
```

For production wildcard TLS on GKE, prefer **cert-manager with DNS-01**. `HTTP-01` is not appropriate for issuing `*.your-domain.example.com`. If you only need a single hostname for temporary testing, `HTTP-01` can work, but that is not the intended OpenDSO production model.

The chart can also generate a self-signed fallback certificate in Marketplace-oriented paths when no TLS secret exists yet. That fallback is intended for non-production verification and install resilience, not as the long-term production TLS posture.

## Values Files

### values.yaml (Default)

Full configuration with all 38 subcharts available.

### values-ha.yaml (High Availability Overlay)

`values-ha.yaml` is an optional overlay for larger production-style deployments. Apply it on top of `values-gcp.yaml` when you want higher replica counts, larger database volumes, and more aggressive resource sizing.

What it changes:

- scales selected stateless services to 2-3 replicas
- increases MongoDB, Citus, and apps DB storage and resource requests
- switches major database PVCs to `pd-ssd`
- enables autoscaling for `gms-api`
- adds nginx ingress rate-limit annotations

Use it like this:

```bash
helm upgrade --install <release-name> . \
  -f values-gcp.yaml \
  -f values-ha.yaml \
  -n <namespace>
```

Notes:

- this is an overlay, not a standalone values file
- it is intended for GKE-style production capacity planning, not minimal local testing
- review every replica and storage change before using it in a constrained cluster

### Security Context Defaults

The chart now applies a mixed hardening model based on what each image can actually support:

- Backend services and init containers that are known to support numeric non-root execution are configured with explicit `runAsNonRoot`, `runAsUser`, and `runAsGroup` settings.
- Frontend images should be built to run as a non-root numeric UID. The recommended nginx-based pattern is an explicit image `USER` plus matching Kubernetes `runAsUser`.
- Stateful and infrastructure images such as PostgreSQL-derived services, Redis, and NATS may still need image-default startup permissions. For those workloads, the chart keeps a more conservative posture instead of forcing non-root and breaking initialization.

Baseline hardening that remains in place where compatible includes:

- `allowPrivilegeEscalation: false`
- dropped Linux capabilities
- `seccompProfile.type: RuntimeDefault`

Do not assume every subchart can safely be forced to the same numeric UID. Validate image behavior first, especially for database, cache, and broker images that modify mounted volumes during startup.

## Upgrading

```bash
# Download latest dependencies
helm dependency update

# Upgrade release
helm upgrade <release-name> . \
  -f values.yaml \
  -n <namespace>

# Or with custom values
helm upgrade <release-name> . \
  --set global.domain=opendso.yourdomain.com \
  -n <namespace>
```

## Uninstalling

```bash
# Uninstall release
helm uninstall <release-name> -n <namespace>

# Clean up PVCs (optional)
kubectl delete pvc -l app.kubernetes.io/instance=<release-name> -n <namespace>

# Clean up secrets
kubectl delete secret <release-name>-grafana-credentials <release-name>-tls-secret root-ca regsecret -n <namespace>

# Delete namespace
kubectl delete namespace <namespace>
```

## Development

### Linting

```bash
helm lint .
```

### Template Rendering

```bash
# Render all templates
helm template <release-name> .

# Render specific template
helm template <release-name> . \
  -s charts/grafana/templates/deployment.yaml \
  --show-only charts/grafana/templates/deployment.yaml

# Debug mode
helm template <release-name> . --debug
```

### Dependency Management

```bash
# Update dependencies (downloads Grafana chart)
helm dependency update

# Build dependencies
helm dependency build

# List dependencies
helm dependency list
```

### Validation

```bash
# Dry-run install
helm install <release-name> . --dry-run --debug -n <namespace>
```

## Troubleshooting

### Common Issues

**1. Grafana pod pending**

```bash
# Check for insufficient resources
kubectl describe pod -l app.kubernetes.io/name=grafana -n <namespace>

# Common: CPU/memory limits too high
# Solution: Adjust in values or delete old pods
```

**2. Secret not found errors**

```bash
# Check secrets exist
kubectl get secrets -n <namespace>

# Recreate secrets manually (see Security and Secrets section above)
```

**2a. TLS secret alias errors**

Some workloads still mount `server-cert`, `server-key`, or `root-ca`. Those secrets are created automatically only when the TLS configuration path is enabled correctly. Check:

```bash
kubectl get secret <release-name>-tls-secret root-ca server-cert server-key -n <namespace>
```

If the release secret exists but the alias secrets do not, verify the install values for:

```yaml
global:
  tls:
    existingSecret: "<release-name>-tls-secret"
    createSecrets: true
```

Then upgrade the release.

**3. Grafana redirect issues**

Ensure correct configuration:

```yaml
env:
  GF_SERVER_ROOT_URL: "%(protocol)s://%(domain)s/"
  GF_SERVER_SERVE_FROM_SUB_PATH: "false"
```

**4. Image pull errors**

```bash
# Check image pull secret
kubectl get secret regsecret -n <namespace> -o yaml

# Recreate if needed
kubectl delete secret regsecret -n <namespace>
kubectl create secret docker-registry regsecret \
  --docker-server=registry.io \
  --docker-username=user \
  --docker-password=pass \
  -n <namespace>
```

**5. Helm dependency issues**

```bash
# Clean and rebuild
rm -rf charts/*.tgz Chart.lock
helm dependency update
```

**6. `runAsNonRoot` failures**

If a pod fails with `container has runAsNonRoot and image will run as root`, the issue is usually one of these:

- the image Dockerfile does not set a non-root `USER`
- the chart enforces a numeric `runAsUser` that the image is not prepared for
- the container or init container still performs root-only filesystem setup at startup

Start by checking the rendered pod security context and the image’s runtime user assumptions before forcing stricter settings.

### Debugging Commands

```bash
# Get all resources
kubectl get all -n <namespace>

# Check pod status
kubectl get pods -n <namespace> -o wide

# View pod logs
kubectl logs -l app.kubernetes.io/name=grafana -n <namespace>

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Describe problematic pod
kubectl describe pod <pod-name> -n <namespace>

# Check ingress
kubectl get ingress -n <namespace>
kubectl describe ingress <release-name>-ingress -n <namespace>

# Test service connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -n <namespace> -- sh
# Inside pod:
# wget -O- http://<release-name>-grafana:80
```

## Chart Publishing

### Package Chart

```bash
# Package for distribution
helm package .

# Output: opendso-0.1.0.tgz
```

### Chart Repository

```bash
# Index for chart repository
helm repo index . --url https://charts.example.com

# Generates: index.yaml
```

## Advanced Configuration

### Grafana Datasources

The chart includes three pre-configured PostgreSQL datasources:

1. **Historian DB** (Citus) - OpenFMB historian data in `ofmb_db`
2. **OpenDSO Apps DB** - ESS testing data in `ess_tester` database
3. **Assets DB** - Asset health monitoring data in `assets` database (TimescaleDB)

Configure in `values.yaml`:

```yaml
grafana:
  datasources:
    datasources.yaml:
      datasources:
        # Historian DB (Citus)
        - name: Historian DB
          type: postgres
          url: <release-name>-citus-db:5432
          database: ofmb_db
          user: citususer
          secureJsonData:
            password: $CITUS_PASSWORD

        # OpenDSO Apps DB - ESS Tester
        - name: OpenDSO Apps DB
          type: postgres
          url: <release-name>-opendso-apps-db:5432
          database: ess_tester
          user: essuser
          secureJsonData:
            password: $OPENDSO_APPS_DB_PASSWORD

        # Assets DB - Asset Health (TimescaleDB)
        - name: Assets DB
          type: postgres
          url: <release-name>-opendso-apps-db:5432
          database: assets
          user: essuser
          secureJsonData:
            password: $OPENDSO_APPS_DB_PASSWORD
```

**Note**: The `opendso-apps-db` PostgreSQL instance hosts two databases:

- `ess_tester` - ESS testing tables
- `assets` - Asset health tables with TimescaleDB features

### Multi-Site Deployment

Deploy multiple sites in one cluster:

```bash
# Site 1
helm install site1 . \
  --namespace site1 \
  --set global.site=ieee13 \
  --create-namespace

# Site 2
helm install site2 . \
  --namespace site2 \
  --set global.site=mysite \
  --create-namespace
```

### Resource Overrides

Override resources per service:

```bash
helm install <release-name> . \
  --set grafana.resources.requests.memory=512Mi \
  --set grafana.resources.limits.memory=1Gi
```
