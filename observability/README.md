# Observability: Metrics, Logging & Tracing

This repository contains an simple cluster setup using [k3d](https://github.com/k3d-io/k3d) for testing collection, processing & general best practice surrounding observability in K8s.

Cluster consists of 3 server & 2 worker nodes - this is to test a cluster closer to real-world applications.

## Dependencies

- Docker
- k3d

## Setup

There is a start-up script for your convenience:

```bash
# Make script executable
chmod +x ./start.sh

# Spin up cluster
./start.sh
```

## Local Registries

As a side-effect of this small scratch project, I have been exploring usage of custom / local registries. Therefore, the k3d configuration will automatically provision one. Further, I have written some quick test scripts following the [documentation](https://k3d.io/v5.6.3/usage/registries/#pushing-to-your-local-registry-address) to test this registry when using locally. You can test this by looking at the `scripts/test-registry.sh` & `scripts/test-deployment.sh`.
