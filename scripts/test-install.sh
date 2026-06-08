#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$ROOT_DIR/client"

export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$ROOT_DIR/.npm-cache}"

echo "== First install: clean node_modules, package-lock, and local npm cache =="
rm -rf "$CLIENT_DIR/node_modules" "$CLIENT_DIR/package-lock.json"
npm cache clean --force
(
  cd "$CLIENT_DIR"
  npm install --verbose
)

echo
echo "== Second install: delete node_modules, preserve package-lock.json, and clear npm cache =="
rm -rf "$CLIENT_DIR/node_modules"
npm cache clean --force
(
  cd "$CLIENT_DIR"
  npm install --verbose
)

echo
echo "Install test completed."
echo
echo "What to look for:"
echo "- Registry logs: metadata paths should appear on each install."
echo "- Registry logs: tarball paths should appear on first install, then disappear once NGINX serves HIT."
echo "- NGINX/curl: first tarball request should be MISS; repeated tarball request should be HIT."
echo "- If TARBALL_BASE_URL=http://localhost:4873, npm follows direct registry tarball URLs and bypasses NGINX."
