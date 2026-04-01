# Microservice Architecture Guide

This guide covers the end-to-end workflow for building, deploying, and operating a microservice on the Platform cluster.

The stack:

| Layer | Technology | Role |
|---|---|---|
| Container runtime | Docker (rootful) | Build & run images |
| Cluster | k3d / k3s | Kubernetes control plane |
| CNI | Cilium (eBPF) | L3/L4 networking, kube-proxy replacement |
| Service mesh | Istio Ambient | mTLS, L7 routing, AuthorizationPolicy |
| GitOps | ArgoCD | Continuous deployment from Git |
| Observability | Prometheus + Grafana | Metrics, dashboards, alerting |

---

## 1. Namespace & RBAC Design

Each team gets a dedicated namespace. This enforces resource isolation, RBAC scope, and network policy boundaries.

```
cluster
├── platform-system      (cluster infrastructure, not user-facing)
├── monitoring           (Prometheus, Grafana, AlertManager)
├── argocd               (GitOps controller)
└── team-<name>          (one per team — created with create-user.sh)
    ├── Deployments
    ├── Services
    ├── ServiceMonitors
    └── VirtualServices
```

### Creating a team namespace with a developer user

```bash
# Create the namespace
kubectl create namespace team-payments

# Label for Istio Ambient (enables ztunnel mTLS for all pods)
kubectl label namespace team-payments istio.io/dataplane-mode=ambient

# Provision a user with developer access scoped to this namespace
./create-user.sh alice developer --namespace team-payments
```

The developer user `alice` receives a kubeconfig at `kubeconfigs/alice.kubeconfig`. She can deploy workloads, manage Istio configs, and add ServiceMonitors — but only within `team-payments`.

### Resource quotas (recommended per namespace)

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: team-payments
spec:
  hard:
    requests.cpu:    "4"
    requests.memory: 8Gi
    limits.cpu:      "8"
    limits.memory:   16Gi
    pods:            "50"
    services:        "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: container-defaults
  namespace: team-payments
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu:    50m
        memory: 64Mi
      default:
        cpu:    500m
        memory: 512Mi
      max:
        cpu:    "2"
        memory: 4Gi
```

---

## 2. Service Repository Structure

```
my-service/
├── Dockerfile
├── .dockerignore
├── src/                        Application source
├── k8s/
│   ├── namespace.yaml          ResourceQuota + LimitRange
│   ├── serviceaccount.yaml     Dedicated SA (no default SA)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── networkpolicy.yaml      Default deny + selective allow
│   ├── servicemonitor.yaml     Prometheus scrape config
│   ├── istio/
│   │   ├── virtualservice.yaml  (optional: external routing)
│   │   ├── destinationrule.yaml (optional: circuit breaker, retries)
│   │   └── authpolicy.yaml      (optional: per-path access control)
│   └── argocd/
│       └── application.yaml    ArgoCD Application manifest
└── dashboards/
    └── my-service.json         Grafana dashboard JSON
```

---

## 3. Dockerfile Best Practices

```dockerfile
# ── Build stage ───────────────────────────────────────────────────────────────
FROM golang:1.23-alpine AS builder
WORKDIR /app

# Dependencies first for cache efficiency
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /bin/server ./cmd/server

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM gcr.io/distroless/static:nonroot
WORKDIR /app

COPY --from=builder /bin/server /bin/server

# Run as non-root (distroless nonroot uses uid 65532)
USER nonroot:nonroot

EXPOSE 8080    # application port
EXPOSE 9090    # metrics port (separate from app traffic)

ENTRYPOINT ["/bin/server"]
```

Key rules:
- Multi-stage build — never ship build tools in the runtime image
- Distroless or Alpine for runtime — no shell, no package manager
- Separate metrics port (9090) from application traffic (8080)
- `USER nonroot` — never run as root in a container

### Build and push to the local registry

```bash
# The k3d embedded registry is at registry.localhost:5000
docker build -t registry.localhost:5000/my-service:latest .
docker push registry.localhost:5000/my-service:latest

# Reference in manifests: registry.localhost:5000/my-service:latest
# k3d nodes can pull from this directly without imagePullSecrets
```

---

## 4. Kubernetes Manifests

### ServiceAccount

Every service gets its own ServiceAccount. Never rely on the `default` SA.

```yaml
# k8s/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-service
  namespace: team-payments
  labels:
    app: my-service
    team: payments
automountServiceAccountToken: false   # opt in explicitly where needed
```

### Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
  namespace: team-payments
  labels:
    app: my-service
    version: v1
    team: payments
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-service
      version: v1
  template:
    metadata:
      labels:
        app: my-service
        version: v1
        team: payments
      annotations:
        # Prometheus scrape annotations (fallback if no ServiceMonitor)
        prometheus.io/scrape: "true"
        prometheus.io/port:   "9090"
        prometheus.io/path:   "/metrics"
    spec:
      serviceAccountName: my-service
      automountServiceAccountToken: false

      # Spread across nodes for HA
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: my-service

      containers:
        - name: my-service
          image: registry.localhost:5000/my-service:latest
          imagePullPolicy: Always

          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090

          # Explicit resource requests and limits (required by LimitRange)
          resources:
            requests:
              cpu:    50m
              memory: 64Mi
            limits:
              cpu:    500m
              memory: 512Mi

          # Readiness and liveness probes
          readinessProbe:
            httpGet:
              path: /healthz/ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /healthz/live
              port: http
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3

          # Security context — non-root, read-only filesystem
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]

          # Mount a writable tmp if the app needs it
          volumeMounts:
            - name: tmp
              mountPath: /tmp

          env:
            - name: PORT
              value: "8080"
            - name: METRICS_PORT
              value: "9090"
            - name: ENV
              value: "production"

      volumes:
        - name: tmp
          emptyDir: {}

      # Graceful shutdown
      terminationGracePeriodSeconds: 30
```

### Service

```yaml
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: team-payments
  labels:
    app: my-service
    team: payments
spec:
  selector:
    app: my-service
  ports:
    - name: http
      port: 80
      targetPort: http     # named port on the pod
    - name: metrics
      port: 9090
      targetPort: metrics
  type: ClusterIP
```

---

## 5. Network Policies

Default-deny all ingress and egress, then selectively open only what the service needs. This is the most important security control in Kubernetes.

```yaml
# k8s/networkpolicy.yaml
# ── Default deny all ──────────────────────────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-payments
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]

---
# ── Allow DNS resolution ──────────────────────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: team-payments
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP

---
# ── Allow inbound from Istio ingress gateway ──────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-gateway
  namespace: team-payments
spec:
  podSelector:
    matchLabels:
      app: my-service
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system

---
# ── Allow Prometheus to scrape metrics ───────────────────────────────────────
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: team-payments
spec:
  podSelector:
    matchLabels:
      app: my-service
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 9090

---
# ── Allow my-service to call downstream services ─────────────────────────────
# Repeat for each dependency
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-downstream
  namespace: team-payments
spec:
  podSelector:
    matchLabels:
      app: my-service
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: downstream-service
      ports:
        - port: 80
```

---

## 6. Istio Ambient: Service Mesh

All pods in a namespace labelled `istio.io/dataplane-mode=ambient` automatically get:
- **mTLS** at L4 via the ztunnel DaemonSet — no sidecars, zero config required
- **SPIFFE identity** tied to the pod's ServiceAccount

### L4 is automatic — no action needed

Once the namespace is labelled, ztunnel handles mTLS for all pod-to-pod traffic. You do not need to set `PeerAuthentication` unless you want to enforce strict mode explicitly.

```yaml
# Optional: explicitly enforce mTLS (ztunnel does this by default in ambient)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: team-payments
spec:
  mtls:
    mode: STRICT
```

### L7 features require a Waypoint proxy

For HTTP routing, retries, circuit breaking, or per-path AuthorizationPolicies, deploy a waypoint:

```bash
# Deploy waypoint for the namespace (one per namespace is typical)
istioctl waypoint apply --namespace team-payments --enroll-namespace

# Verify
kubectl get gateway -n team-payments
```

### VirtualService — external routing via platform-gateway

To expose a service externally, add a TLS cert to `istio-system` and a VirtualService:

```yaml
# k8s/istio/virtualservice.yaml
# (First generate certs: see start-cluster.sh generate_cert function)
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-service
  namespace: team-payments
spec:
  hosts:
    - "my-service.internal"
  gateways:
    - istio-system/platform-gateway
  http:
    - match:
        - uri:
            prefix: /api/v1
      route:
        - destination:
            host: my-service.team-payments.svc.cluster.local
            port:
              number: 80
      timeout: 30s
      retries:
        attempts: 3
        perTryTimeout: 10s
        retryOn: gateway-error,connect-failure,retriable-4xx
```

### DestinationRule — circuit breaker and load balancing

```yaml
# k8s/istio/destinationrule.yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-service
  namespace: team-payments
spec:
  host: my-service.team-payments.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http2MaxRequests: 1000
        maxRequestsPerConnection: 10
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

### AuthorizationPolicy — access control per path/method

Requires waypoint proxy to be deployed (L7 enforcement).

```yaml
# k8s/istio/authpolicy.yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: my-service-authz
  namespace: team-payments
spec:
  selector:
    matchLabels:
      app: my-service
  action: ALLOW
  rules:
    # Allow internal services with mTLS identity
    - from:
        - source:
            principals:
              - "cluster.local/ns/team-payments/sa/order-service"
              - "cluster.local/ns/team-payments/sa/inventory-service"
      to:
        - operation:
            methods: [GET, POST]
            paths: ["/api/v1/*"]

    # Allow Prometheus to scrape /metrics
    - from:
        - source:
            namespaces: [monitoring]
      to:
        - operation:
            methods: [GET]
            paths: ["/metrics"]

    # Deny everything else (implicit — ALLOW policy denies non-matching traffic)
```

---

## 7. Prometheus Metrics

### Instrument your service

Expose a `/metrics` endpoint in Prometheus exposition format. Example (Go):

```go
import "github.com/prometheus/client_golang/prometheus/promhttp"

http.Handle("/metrics", promhttp.Handler())
```

Use the standard metric naming convention: `<namespace>_<subsystem>_<name>_<unit>`.

```go
var requestDuration = prometheus.NewHistogramVec(
    prometheus.HistogramOpts{
        Name:    "payments_request_duration_seconds",
        Help:    "HTTP request duration in seconds.",
        Buckets: prometheus.DefBuckets,
    },
    []string{"method", "status"},
)
```

### ServiceMonitor — tell Prometheus to scrape your service

```yaml
# k8s/servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service
  namespace: team-payments
  labels:
    # No label restriction needed (prometheus scrapes all ServiceMonitors)
    app: my-service
    team: payments
spec:
  selector:
    matchLabels:
      app: my-service
  endpoints:
    - port: metrics
      path: /metrics
      interval: 15s
      scheme: http
  namespaceSelector:
    matchNames:
      - team-payments
```

Verify Prometheus picked it up:
```bash
# Port-forward Prometheus UI
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090

# Check Targets: http://localhost:9090/targets
# Look for team-payments/my-service
```

### Grafana dashboard

Import dashboards via ConfigMap — they are automatically picked up by the Grafana sidecar:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-service-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"    # Grafana sidecar watches this label
data:
  my-service.json: |
    { ... paste exported dashboard JSON here ... }
```

---

## 8. GitOps with ArgoCD

### Application manifest

```yaml
# k8s/argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io   # enables cascading delete
spec:
  project: default

  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: k8s/                   # directory containing your manifests

  destination:
    server: https://kubernetes.default.svc
    namespace: team-payments

  syncPolicy:
    automated:
      prune: true           # delete resources removed from Git
      selfHeal: true        # revert manual kubectl changes
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        maxDuration: 3m
        factor: 2
```

Apply it:
```bash
kubectl apply -f k8s/argocd/application.yaml

# Watch sync status
kubectl -n argocd get app my-service -w
```

### App of Apps pattern (for multiple services)

Create a parent Application in ArgoCD that manages other Applications:

```
platform-apps/
├── argocd/
│   └── apps-of-apps.yaml       # parent Application
└── apps/
    ├── my-service.yaml
    ├── order-service.yaml
    └── inventory-service.yaml
```

```yaml
# argocd/apps-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-apps
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/your-org/platform.git
    targetRevision: main
    path: apps/
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 9. Deployment Workflow

### Local development cycle

```bash
# 1. Build image
docker build -t registry.localhost:5000/my-service:dev .
docker push registry.localhost:5000/my-service:dev

# 2. Deploy directly (for rapid iteration)
kubectl -n team-payments set image deployment/my-service \
    my-service=registry.localhost:5000/my-service:dev

# 3. Watch rollout
kubectl -n team-payments rollout status deployment/my-service

# 4. Check logs
kubectl -n team-payments logs -l app=my-service --follow

# 5. Check ztunnel mTLS is working
istioctl -n team-payments proxy-status
```

### Production promotion via ArgoCD

```bash
# 1. Tag the image with a semantic version
docker tag registry.localhost:5000/my-service:dev \
           registry.localhost:5000/my-service:v1.2.3
docker push registry.localhost:5000/my-service:v1.2.3

# 2. Update the image tag in your Git repo (triggers ArgoCD sync)
# Edit deployment.yaml: image: registry.localhost:5000/my-service:v1.2.3
git add k8s/deployment.yaml
git commit -m "chore: bump my-service to v1.2.3"
git push

# 3. ArgoCD detects the change and syncs automatically
# Monitor at: https://argocd.internal:8443
```

---

## 10. Secret Management

Never put secrets in Git. Use sealed-secrets or an external secret manager.

### Option A: Kubernetes Secrets (for simple use cases)

```bash
# Create secret manually on the cluster
kubectl -n team-payments create secret generic db-credentials \
    --from-literal=host=postgres.team-payments.svc.cluster.local \
    --from-literal=password="$(openssl rand -base64 32)"

# Reference in Deployment via envFrom
```

```yaml
envFrom:
  - secretRef:
      name: db-credentials
```

### Option B: Sealed Secrets (GitOps safe)

```bash
# Install sealed-secrets controller (add to start-cluster.sh if desired)
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Seal a secret (output can be committed to Git)
kubectl -n team-payments create secret generic db-credentials \
    --from-literal=password=mysecret \
    --dry-run=client -o yaml \
  | kubeseal --format yaml > k8s/sealed-db-credentials.yaml

git add k8s/sealed-db-credentials.yaml   # safe to commit
```

---

## 11. Deployment Checklist

Before pushing a new service to the cluster:

- [ ] Dockerfile uses multi-stage build with distroless/Alpine runtime
- [ ] Image runs as non-root (`USER nonroot` or `runAsUser: 65532`)
- [ ] `readOnlyRootFilesystem: true` and `allowPrivilegeEscalation: false` set
- [ ] Dedicated `ServiceAccount` with `automountServiceAccountToken: false`
- [ ] Resource `requests` and `limits` set on all containers
- [ ] `readinessProbe` and `livenessProbe` configured
- [ ] `topologySpreadConstraints` set for HA (min 2 replicas across nodes)
- [ ] `NetworkPolicy` applied — default deny + explicit allow rules
- [ ] `ServiceMonitor` created and verified in Prometheus targets
- [ ] Istio namespace label `istio.io/dataplane-mode=ambient` applied
- [ ] Waypoint deployed if L7 features (AuthorizationPolicy, routing) are needed
- [ ] No secrets in Git — using Sealed Secrets or pre-created kubectl secrets
- [ ] ArgoCD `Application` manifest committed to Git repo
- [ ] `terminationGracePeriodSeconds` >= application shutdown timeout

---

## 12. Useful Commands

```bash
# Cluster health
kubectl get nodes
kubectl -n kube-system get pods          # Cilium agent, coredns
kubectl -n istio-system get pods         # istiod, ztunnel, ingressgateway

# Cilium
kubectl -n kube-system exec -it ds/cilium -- cilium status
kubectl -n kube-system exec -it ds/cilium -- cilium endpoint list

# Istio ambient
istioctl proxy-status                    # enrolled pods
istioctl waypoint list                   # deployed waypoints
istioctl analyze -n team-payments        # config validation

# ArgoCD CLI
argocd login argocd.internal:8443 --insecure
argocd app list
argocd app sync my-service
argocd app get  my-service

# Logs with labels
kubectl -n team-payments logs -l app=my-service --all-containers --follow

# Port-forward for local access (bypasses Istio)
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:3000
kubectl -n argocd    port-forward svc/argocd-server        8080:80

# Access via Istio gateway (full stack test)
curl -k https://grafana.internal:8443/api/health
```
