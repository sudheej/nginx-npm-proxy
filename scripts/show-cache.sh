#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL_URL="${1:-http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz}"
SCOPED_TARBALL_URL="http://localhost:8080/@myscope/hello-cache/-/hello-cache-1.0.0.tgz"

echo "== Docker volume cache size =="
if docker compose -f "$ROOT_DIR/docker-compose.yml" ps nginx >/dev/null 2>&1; then
  docker compose -f "$ROOT_DIR/docker-compose.yml" exec nginx sh -c 'du -sh /var/cache/nginx/npm-tgz 2>/dev/null || true; find /var/cache/nginx/npm-tgz -type f 2>/dev/null | wc -l'
else
  echo "NGINX container is not running."
fi

echo
echo "== Curl unscoped tarball twice =="
curl -I "$TARBALL_URL"
echo
curl -I "$TARBALL_URL"

echo
echo "== Curl scoped tarball twice =="
curl -I "$SCOPED_TARBALL_URL"
echo
curl -I "$SCOPED_TARBALL_URL"

echo
echo "Expected: first response has X-Cache-Status: MISS, second has X-Cache-Status: HIT."
