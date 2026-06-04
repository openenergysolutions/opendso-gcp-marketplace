# OpenDSO GCP Marketplace — Customer Pre-Deployment Checklist

**Purpose:** Step-by-step guide for preparing your GKE cluster before deploying OpenDSO from the GCP Marketplace. Complete every step and verify each checkpoint before clicking **Deploy** in the Marketplace UI.

**Time estimate:** 30–60 minutes for a fresh cluster (mostly waiting on DNS propagation).

---

## Before You Start

Request the following from Open Energy Solutions before proceeding:

- [ ] **OpenDSO License Key** (`license.key`) — required to activate the platform
- [ ] **OpenDSO Installation Key** (`installation.key`) — required to activate the platform
- [ ] Confirmation that the **Marketplace listing is active** and your GCP project is authorized to deploy it (Model A), or that OES has granted your cluster image pull access (Model B — see Step 5)
- [ ] Your **base domain** — e.g. `opendso.example.com`. All service endpoints derive from this (e.g. `api.opendso.example.com`, `keycloak.opendso.example.com`)

---

## Step 1 — GKE Cluster

- [ ] GKE cluster is running with **Kubernetes 1.24 or later**
- [ ] `kubectl` is configured and pointed at the target cluster

```bash
# Verify cluster access
kubectl cluster-info
kubectl version --short
```

- [ ] Cluster has sufficient capacity for the chosen resource profile:

| Profile | Approximate node requirement |
|---|---|
| `minimal` | 2× e2-standard-4 (8 vCPU / 32 GB total) |
| `default` | 3× e2-standard-4 |
| `production` | 4–6× e2-standard-8 (with autoscaling recommended) |

- [ ] Target **namespace** created:

```bash
kubectl create namespace <namespace>
```

---

## Step 2 — nginx Ingress Controller

OpenDSO requires an **nginx** ingress controller with an external LoadBalancer IP.

- [ ] nginx ingress controller is installed:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
```

- [ ] LoadBalancer IP is assigned (may take 1–2 minutes):

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Record this IP — you will need it for DNS in Step 3.

**LoadBalancer IP:** `_______________________`

---

## Step 3 — DNS Configuration

All OpenDSO endpoints use subdomains of your base domain. A single wildcard DNS record covers all of them.

- [ ] Create a **wildcard A record** in your DNS provider:

```
*.opendso.example.com  →  <LoadBalancer IP>
```

- [ ] Verify DNS propagation (allow 2–30 minutes depending on TTL):

```bash
# Replace with your actual domain
nslookup test.opendso.example.com
# or
dig +short test.opendso.example.com
```

Expected result: the LoadBalancer IP address.

> **Note:** DNS must be propagated before the TLS certificate can be issued in Step 4. For the recommended wildcard certificate path on GKE, use **DNS-01**, not `HTTP-01`.

### Adding the wildcard A record

In your DNS provider's management console, create an `A` record:

| Field | Value |
| --- | --- |
| Type | `A` |
| Name / Host | `*.opendso` (or `*` if your provider scopes records to the base domain automatically) |
| Value / Points to | `<LoadBalancer IP from Step 2>` |
| TTL | `600` seconds (10 minutes) — lower TTL speeds up initial propagation; raise it after confirming everything works |

> **Scope:** This wildcard record covers one level of subdomain only — e.g. `api.opendso.example.com` matches, but `foo.api.opendso.example.com` does not. OpenDSO only needs one level, so this is sufficient.
>
> **cert-manager DNS-01:** Many DNS providers do not have a built-in cert-manager solver. For automated wildcard TLS renewal via DNS-01, you have two options:
>
> - Use a community cert-manager webhook for your DNS provider (if one exists)
> - Delegate the subdomain zone to Cloud DNS (add `NS` records at your registrar pointing `opendso.example.com` to Google's nameservers) and use cert-manager's built-in `cloudDNS` solver as shown in Step 4
>
> Delegation is the more reliable long-term path if you already use GCP.

### Delegating a subdomain to Cloud DNS (optional — enables cert-manager DNS-01)

Use this path if you want cert-manager to manage DNS-01 challenges automatically via Cloud DNS, regardless of where your domain is registered.

#### 1. Create a managed zone in Cloud DNS for your subdomain

```bash
gcloud dns managed-zones create opendso-zone \
  --dns-name="opendso.example.com." \
  --description="OpenDSO subdomain zone" \
  --project=<gcp-project-id>
```

#### 2. Retrieve the nameservers Cloud DNS assigned to the zone

```bash
gcloud dns managed-zones describe opendso-zone \
  --project=<gcp-project-id> \
  --format="value(nameServers)"
```

You will get four nameservers, e.g.:

```
ns-cloud-a1.googledomains.com.
ns-cloud-a2.googledomains.com.
ns-cloud-a3.googledomains.com.
ns-cloud-a4.googledomains.com.
```

#### 3. Add NS records at your registrar pointing to those nameservers

In your DNS provider's management console, add four `NS` records — one per nameserver:

| Field | Value |
| --- | --- |
| Type | `NS` |
| Name / Host | `opendso` (the subdomain prefix; your provider appends `.example.com`) |
| Value | one nameserver per record, e.g. `ns-cloud-a1.googledomains.com.` |
| TTL | `3600` |

Repeat for all four nameservers.

> Some DNS providers require the trailing dot on nameserver values; others do not. Check your provider's documentation if the field rejects the value.

#### 4. Verify delegation has propagated

```bash
# Should return the four Cloud DNS nameservers, not your registrar's
dig NS opendso.example.com +short
```

Allow up to 30 minutes for your registrar's TTL to expire.

#### 5. Move your wildcard A record into Cloud DNS

Once delegation is active, your registrar no longer serves DNS for `opendso.example.com`. Add the wildcard A record to Cloud DNS instead:

```bash
gcloud dns record-sets create "*.opendso.example.com." \
  --zone=opendso-zone \
  --type=A \
  --ttl=600 \
  --rrdatas=<LoadBalancer IP> \
  --project=<gcp-project-id>
```

#### 6. Grant cert-manager permission to modify the zone

cert-manager needs IAM access to create and delete TXT records for DNS-01 challenges.

```bash
# Create a dedicated service account
gcloud iam service-accounts create cert-manager-dns \
  --display-name="cert-manager DNS-01 solver" \
  --project=<gcp-project-id>

# Grant it DNS admin on the specific zone
gcloud projects add-iam-policy-binding <gcp-project-id> \
  --member="serviceAccount:cert-manager-dns@<gcp-project-id>.iam.gserviceaccount.com" \
  --role="roles/dns.admin"

# Create and download a key
gcloud iam service-accounts keys create cert-manager-dns-key.json \
  --iam-account=cert-manager-dns@<gcp-project-id>.iam.gserviceaccount.com

# Store the key as a Kubernetes secret
kubectl create secret generic clouddns-dns01-solver-svc-acct \
  --from-file=key.json=cert-manager-dns-key.json \
  -n cert-manager
```

> If your GKE cluster uses Workload Identity you can bind the cert-manager service account to the GCP service account instead of using a key file. See [cert-manager GKE Workload Identity docs](https://cert-manager.io/docs/configuration/acme/dns01/google/) for that path.

After completing these steps, continue to Step 4 and use the `cloudDNS` ClusterIssuer example with `hostedZoneName: opendso-zone`.

---

## Step 4 — TLS Certificate

OpenDSO requires a Kubernetes TLS secret named **`<release-name>-tls-secret`** in the target namespace. The release name is what you will enter as "Application instance name" in the Marketplace UI — decide on it now.

**Release name:** `_______________________` (e.g. `opendso`)

Production recommendation:

- use a real certificate before deployment
- do not rely on the chart's self-signed fallback for customer production installs
- treat the self-signed path as a test-only safety net for installer resilience

### Option A — cert-manager + Let's Encrypt with DNS-01 (recommended for production wildcard TLS)

Use **DNS-01** if you want a certificate for `*.opendso.example.com`. `HTTP-01` does not work for wildcard certificates.

- [ ] Install cert-manager:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true
```

- [ ] Verify cert-manager pods are running:

```bash
kubectl get pods -n cert-manager
```

- [ ] Create a ClusterIssuer for Let's Encrypt using a DNS solver

The exact `dns01` solver depends on your DNS provider. On GKE, the important point is the challenge type:

- use `dns01` for wildcard certificates
- request both the base domain and wildcard SANs
- verify your DNS provider credentials or webhook solver are configured before requesting the certificate

Example shape only:

```yaml
# letsencrypt-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <your-email>
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        # configure the solver for your DNS provider here
        # example: Cloud DNS, Route53, Cloudflare, or a cert-manager webhook
        <your-dns-solver>: {}
```

GKE / Google Cloud DNS example:

```yaml
# letsencrypt-issuer-gcp.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <your-email>
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudDNS:
          project: <gcp-project-id>
          hostedZoneName: <cloud-dns-zone-name>
```

If you use Cloud DNS, ensure cert-manager has IAM permission to modify DNS records for the target managed zone.

```bash
kubectl apply -f letsencrypt-issuer.yaml
```

- [ ] Request a certificate for your domain:

```yaml
# opendso-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: opendso-tls
  namespace: <namespace>
spec:
  secretName: <release-name>-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "opendso.example.com"
  - "*.opendso.example.com"
```

```bash
kubectl apply -f opendso-cert.yaml
```

- [ ] Wait for certificate to be issued (2–5 minutes):

```bash
kubectl get certificate -n <namespace> -w
# READY column should show: True
```

- [ ] Confirm the resulting secret name matches the Marketplace release name exactly:

```bash
kubectl get secret <release-name>-tls-secret -n <namespace>
```

### Option A1 — HTTP-01 (non-wildcard testing only)

If you are only testing a single hostname and are not using the full wildcard model, `HTTP-01` can be used. That is not the recommended production configuration for OpenDSO because the platform expects multiple subdomains such as:

- `api.<domain>`
- `keycloak.<domain>`
- `grafana.<domain>`
- `nats.<domain>`
- UI app subdomains

### Option B — Self-signed certificate (testing only)

- [ ] Generate and install a self-signed cert using `mkcert`:

```bash
mkcert "*.opendso.example.com" "opendso.example.com"
kubectl create secret tls <release-name>-tls-secret \
  --cert=_wildcard.opendso.example.com.pem \
  --key=_wildcard.opendso.example.com-key.pem \
  -n <namespace>
```

### Option C — Chart-generated self-signed fallback (last resort, non-production)

If no TLS secret exists, the Marketplace chart can generate a self-signed fallback certificate in some install paths. This behavior is useful for controlled test deployments, but it should not be your target production configuration.

Use it only when:

- you are validating installer behavior
- you are testing in a non-production environment
- you understand browsers and strict TLS clients will not trust the certificate

### Verify TLS secret exists

- [ ] Confirm the secret is present before proceeding:

```bash
kubectl get secret <release-name>-tls-secret -n <namespace>
```

---

## Step 5 — Image Pull Access

All OpenDSO images are hosted by OES in their GCP Artifact Registry. Your GKE cluster needs read access to pull them. How access is granted depends on your deployment model.

### Model A — Deploying via GCP Marketplace listing (standard)

No action required on your side for image access. When you deploy through the Marketplace UI, GCP automatically grants your cluster pull access to the OES image registry. The Image Registry field in the Marketplace UI will be pre-populated.

- [ ] Confirm with OES that the Marketplace listing is active and your GCP project is authorized

### Model B — Direct / private install

OES must grant your GKE node service account pull access to their registry. Complete these steps and send the output to OES before proceeding.

- [ ] Find your GKE node service account email:

```bash
gcloud container clusters describe <cluster-name> \
  --zone=<zone> --project=<project-id> \
  --format='value(nodeConfig.serviceAccount)'
```

> If the output is `default`, your full service account email is:
> `<project-number>-compute@developer.gserviceaccount.com`
>
> Find your project number with:
>
> ```bash
> gcloud projects describe <project-id> --format='value(projectNumber)'
> ```

- [ ] Send the service account email to OES and wait for confirmation that access has been granted
- [ ] Once OES confirms, verify your node can pull a test image:

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev
docker pull us-central1-docker.pkg.dev/<PROJECT_ID>/oesinc/nats:<tag>
```

---

## Step 6 — Application CRD (no longer required)

The Terraform deployment does **not** use the `app.k8s.io/v1beta1` Application CRD.
No action is needed — this step is retained only so the checklist numbering is stable.

---

## Step 7 — Final Pre-Deployment Checklist

Run through this summary before clicking **Deploy** in the Marketplace UI:

| Item | Check |
|---|---|
| License Key and Installation Key obtained from OES | ☐ |
| GKE cluster running (Kubernetes 1.24+) | ☐ |
| Target namespace created | ☐ |
| nginx ingress controller installed, LoadBalancer IP assigned | ☐ |
| Wildcard DNS `*.<domain>` → LoadBalancer IP, propagated | ☐ |
| `<release-name>-tls-secret` exists in target namespace | ☐ |
| Image pull access confirmed with OES (Model B) **or** Marketplace listing active (Model A) | ☐ |
| Application CRD (`app.k8s.io/v1beta1`) installed | ☐ |

---

## Step 8 — Marketplace UI Parameters

When you click **Deploy**, you will be prompted for the following. Have these values ready:

| Parameter | Notes |
|---|---|
| Application instance name | Your chosen release name — must match the TLS secret prefix (e.g. `opendso`) |
| Namespace | Your target namespace |
| Domain Name | Your base domain (e.g. `opendso.example.com`) |
| OpenDSO License Key | Provided by OES |
| OpenDSO Installation Key | Provided by OES |
| Keycloak Admin Password | Choose a strong password |
| MongoDB Root Password | Choose a strong password |
| MongoDB App Password | Choose a strong password |
| Grafana Admin Password | Choose a strong password |
| Resource Profile | `minimal` / `default` / `production` |
| Image Registry | Model A: pre-populated by Marketplace. Model B: `us-central1-docker.pkg.dev/<PROJECT_ID>/oesinc` |

---

## Post-Deployment Verification

After the deployment completes, run the bundled verification script:

```bash
bash scripts/verify.sh <release-name> <namespace>
```

The script checks:

1. MongoDB StatefulSet readiness
2. Keycloak and NATS Deployment readiness
3. GMS API, Historian, and NATS Auth Service readiness
4. NATS auth keys secret existence
5. Keycloak OIDC discovery endpoint (via port-forward)
6. GMS API health endpoint (via port-forward)

On success, all services will be accessible at `https://*.<your-domain>`.