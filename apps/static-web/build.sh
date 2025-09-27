#!/bin/sh
set -euo pipefail

# Build container
docker build --quiet -f Dockerfile -t static-web . >/dev/null 2>&1