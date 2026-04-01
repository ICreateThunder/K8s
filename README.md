# K8s

Kubernetes platform configurations, Helm values, and tooling for building production-grade clusters.

## Platform

Self-contained Kubernetes platform built on k3d (k3s in Docker) with a modern cloud-native stack.

### Architecture

```
                  ┌──────────────────────────────────────────────┐
                  │              k3d Cluster (6 nodes)           │
                  │  ┌─────────────────┐  ┌──────────────────┐  │
  WireGuard VPN ──┤  │  Control Plane  │  │   Worker Nodes   │  │
                  │  │   (3 servers)   │  │   (3 workers)    │  │
                  │  └─────────────────┘  └──────────────────┘  │
                  │                                              │
                  │  ┌──────────────────────────────────────┐   │
                  │  │  Cilium CNI (eBPF, L3/L4)           │   │
                  │  │  └─ kube-proxy replacement           │   │
                  │  │  └─ socket-level load balancing      │   │
                  │  └──────────────────────────────────────┘   │
                  │                                              │
                  │  ┌──────────────────────────────────────┐   │
                  │  │  Istio Ambient (L7, zero-sidecar)   │   │
                  │  │  └─ automatic mTLS (SPIFFE identity) │   │
                  │  │  └─ VirtualService routing           │   │
                  │  │  └─ AuthorizationPolicy              │   │
                  │  └──────────────────────────────────────┘   │
                  │                                              │
                  │  ┌──────────────────────────────────────┐   │
                  │  │  Observability                       │   │
                  │  │  └─ Prometheus (15d retention)       │   │
                  │  │  └─ Grafana                          │   │
                  │  │  └─ AlertManager                     │   │
                  │  │  └─ Node Exporter + kube-state-metrics│  │
                  │  └──────────────────────────────────────┘   │
                  │                                              │
                  │  ┌──────────────────────────────────────┐   │
                  │  │  ArgoCD (GitOps CD)                  │   │
                  │  │  └─ auto-sync, prune, self-heal      │   │
                  │  │  └─ 3-tier RBAC                      │   │
                  │  └──────────────────────────────────────┘   │
                  └──────────────────────────────────────────────┘
```

### Stack

| Layer | Technology | Role |
|---|---|---|
| Container runtime | Docker (rootful) | Build & run images |
| Cluster | k3d / k3s | Kubernetes control plane |
| CNI | Cilium (eBPF) | L3/L4 networking, kube-proxy replacement |
| Service mesh | Istio Ambient | mTLS, L7 routing, zero-sidecar architecture |
| GitOps | ArgoCD | Continuous deployment from Git |
| Observability | Prometheus + Grafana | Metrics, dashboards, alerting |

### Networking

Cilium replaces kube-proxy entirely using eBPF for high-performance L3/L4 networking. L7 traffic management is delegated to Istio Ambient, which provides automatic mTLS between all pods via ztunnel DaemonSets without injecting sidecars.

### RBAC

Three-tier access model:

- **platform-admin** — Full cluster control (SRE / platform team)
- **developer** — Namespace-scoped workload management, Istio configs, ServiceMonitors, ArgoCD Applications
- **viewer** — Cluster-wide read-only (no secret access)

Users are provisioned via certificate-based authentication with the role encoded as the certificate Organisation.

### Bootstrap

The cluster is fully bootstrapped via a single script that:
1. Validates required tools (k3d, helm, kubectl, istioctl, docker)
2. Creates a custom Docker network and k3d cluster with registry
3. Installs Cilium, Istio Ambient, Prometheus stack, and ArgoCD
4. Generates TLS certificates for internal services
5. Configures RBAC, namespaces, and platform secrets

## Observability Demo

Simpler standalone cluster for experimenting with Prometheus and Grafana on k3d. Includes a Helm chart for deploying test applications with ServiceMonitor integration.

## Apps

Small applications used to test and validate cluster components:

- **picoservice-rs** — Minimal Rust HTTP service for testing deployments, HPA, and service mesh routing
- **static-web** — Static site served via nginx for testing ingress and routing
