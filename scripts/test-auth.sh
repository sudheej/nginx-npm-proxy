#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_DIR="$ROOT_DIR/client"
AUTH_TOKEN="${REGISTRY_AUTH_TOKEN:-lab-secret-token}"
AUTH_NPMRC="$CLIENT_DIR/.npmrc.auth"
NGINX_BASE_URL="${NGINX_BASE_URL:-http://localhost:8080}"
TEST_NPMRC="$(mktemp)"

cleanup() {
  rm -f "$TEST_NPMRC"
}
trap cleanup EXIT

registry_authority="${NGINX_BASE_URL#*://}"
registry_authority="${registry_authority%/}"
sed \
  -e "s#http://localhost:8080/#${NGINX_BASE_URL%/}/#" \
  -e "s#//localhost:8080/#//${registry_authority}/#" \
  "$AUTH_NPMRC" > "$TEST_NPMRC"

export NPM_TOKEN="$AUTH_TOKEN"
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$ROOT_DIR/.npm-cache-auth}"

expect_status() {
  local expected="$1"
  shift
  local actual

  actual="$(curl --silent --output /dev/null --write-out '%{http_code}' "$@")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected HTTP $expected, received HTTP $actual: curl $*" >&2
    exit 1
  fi
}

echo "== Verify the upstream requires and validates bearer authentication =="
expect_status 401 "$NGINX_BASE_URL/-/ping"
expect_status 401 \
  --header "Authorization: Bearer invalid-token" \
  "$NGINX_BASE_URL/-/ping"
expect_status 200 \
  --header "Authorization: Bearer $AUTH_TOKEN" \
  "$NGINX_BASE_URL/-/ping"

echo "== Install through NGINX using an npm auth token =="
rm -rf "$CLIENT_DIR/node_modules" "$CLIENT_DIR/package-lock.json"
npm cache clean --force
(
  cd "$CLIENT_DIR"
  npm install \
    --userconfig "$TEST_NPMRC" \
    --registry "${NGINX_BASE_URL%/}/" \
    --verbose
)

echo "== Repeat from the lockfile with an empty npm client cache =="
rm -rf "$CLIENT_DIR/node_modules"
npm cache clean --force
(
  cd "$CLIENT_DIR"
  npm install \
    --userconfig "$TEST_NPMRC" \
    --registry "${NGINX_BASE_URL%/}/" \
    --verbose
)

echo
echo "Authenticated install test completed."
echo "NGINX should report cache=BYPASS for token-bearing tarball requests."
echo "The registry logs auth presence only; the token value is never logged."
