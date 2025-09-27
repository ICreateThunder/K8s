#!/bin/sh
set -euo pipefail

# Initialise context
REGISTRY="observability-registry"
WORKING_DIRECTORY=$(pwd)

# Build static-web container
cd ../../apps/static-web
/bin/sh build.sh
echo "✅    Build static web image successfully"

# Reset working directory
cd "$WORKING_DIRECTORY"

# Registry container existance check
if ! docker ps -a --format '{{.Names}}' | grep -Fxq "$REGISTRY"; then
    echo "❌    Please provision the regsitry (or start the cluster). 
      - Registry container \"$REGISTRY\" does not appear to exist"
    exit 1
fi
echo "✅    Found \"$REGISTRY\""

# Timeout
MAX_RETRIES=120 # 120 * 0.5 = 60 seconds
RETRY_COUNT=0

# Wait until the registry container is ready
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    # Retrieve container status
    STATE=$(docker inspect --format='{{.State.Status}}' "$REGISTRY")

    # Continue to wait if container is not running
    if [[ "$STATE" != "running" ]]; then
        sleep 0.5
        continue
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    break
done
echo "✅    Container \"$REGISTRY\" is ready"

# Retrieve registry port on local machine
PORT=$(docker port "$REGISTRY" "5000" | cut -d: -f2)

# Tag & push static web to registry
docker tag static-web "observability-registry:$PORT/static-web:latest"
docker push -q "observability-registry:$PORT/static-web:latest" >/dev/null 2>&1
echo "✅    Static web image pushed to registry"