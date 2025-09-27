#!/bin/sh
set -euo pipefail

# Initialise context
REGISTRY="observability-registry"

# Retrieve registry port on local machine
REGISTRY_PORT=$(docker port "$REGISTRY" "5000" | cut -d: -f2)

# Deployment example from k3d documentation
cat <<EOF | kubectl apply -f >/dev/null 2>&1 - 
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-test-registry
  labels:
    app: web-test-registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-test-registry
  template:
    metadata:
      labels:
        app: web-test-registry
    spec:
      containers:
      - name: web-test-registry
        image: observability-registry:$REGISTRY_PORT/static-web:latest
        ports:
        - containerPort: 80
EOF
echo "✅    Deployment \"$REGISTRY\" requested"

# Wait until ready - timeout of 30 seconds
MAX_RETRIES=60 # 60 * 0.5 = 30 seconds
RETRY_COUNT=0

# Wait until the registry container is ready
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Retrieve container status
    STATE=$(kubectl get pods -l app=web-test-registry -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}')

    # Continue to wait if container is not running
    if [[ "$STATE" != "True" ]]; then
        sleep 0.5
        continue
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    break
done
echo "✅    Deployment \"$REGISTRY\" running successfully"

kubectl delete deployment web-test-registry >/dev/null 2>&1
echo "✅    Deployment \"$REGISTRY\" deleted"