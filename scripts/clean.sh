#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rm -rf "$ROOT_DIR/client/node_modules" "$ROOT_DIR/client/package-lock.json"
rm -rf "$ROOT_DIR/.npm-cache"
rm -f "$ROOT_DIR/registry/packages/hello-cache/hello-cache-1.0.0.tgz"
rm -f "$ROOT_DIR/registry/packages/hello-cache/scoped-hello-cache-1.0.0.tgz"

docker compose -f "$ROOT_DIR/docker-compose.yml" down -v --remove-orphans

echo "Cleaned client installs, generated tarball, containers, and NGINX cache volume."
