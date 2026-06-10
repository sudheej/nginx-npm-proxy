#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKFILE_SOURCE_DIR="$ROOT_DIR/scenarios/lockfile-ci"
LEGACY_SOURCE_DIR="$ROOT_DIR/scenarios/legacy-peers"
NPM_PROXY_URL="${NPM_PROXY_URL:-http://localhost:8080}"
CANONICAL_PROXY_URL="http://localhost:8080"
TMP_DIR="$(mktemp -d)"
LOCKFILE_DIR="$TMP_DIR/lockfile-ci"
LEGACY_DIR="$TMP_DIR/legacy-peers"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Missing required file: $1"
}

prepare_scenario() {
  local source_dir="$1"
  local working_dir="$2"

  cp -R "$source_dir" "$working_dir"
  rm -rf "$working_dir/node_modules" "$working_dir/.npm-cache"

  node - "$working_dir/package-lock.json" "$CANONICAL_PROXY_URL" "$NPM_PROXY_URL" <<'NODE'
const fs = require("fs");
const [lockPath, canonicalUrl, selectedUrl] = process.argv.slice(2);
const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
let rewritten = 0;

for (const entry of Object.values(lock.packages || {})) {
  if (typeof entry.resolved === "string" && entry.resolved.startsWith(`${canonicalUrl}/`)) {
    entry.resolved = `${selectedUrl}${entry.resolved.slice(canonicalUrl.length)}`;
    rewritten += 1;
  }
}

if (rewritten === 0) {
  throw new Error(`No canonical proxy URLs found in ${lockPath}`);
}

fs.writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
NODE
}

assert_proxy_cache_hit() {
  local tarball_path="$1"
  local headers_file="$TMP_DIR/headers-$(basename "$tarball_path")"

  curl -fsS -D "$headers_file" -o /dev/null "$NPM_PROXY_URL$tarball_path"
  grep -Eiq '^X-Cache-Status:[[:space:]]*HIT[[:space:]]*$' "$headers_file" ||
    fail "Expected an NGINX cache HIT for $tarball_path after npm ci"
}

run_clean_ci() {
  local scenario_dir="$1"
  local run_number="$2"
  shift 2

  rm -rf "$scenario_dir/node_modules" "$scenario_dir/.npm-cache"
  mkdir -p "$scenario_dir/.npm-cache"

  echo "== $(basename "$scenario_dir"): clean-client npm ci run $run_number =="
  (
    cd "$scenario_dir"
    npm ci \
      --cache "$scenario_dir/.npm-cache" \
      --registry "$NPM_PROXY_URL/" \
      --no-audit \
      --no-fund \
      "$@"
  )
}

NPM_PROXY_URL="${NPM_PROXY_URL%/}"
require_file "$LOCKFILE_SOURCE_DIR/package-lock.json"
require_file "$LEGACY_SOURCE_DIR/package-lock.json"
curl -fsS "$NPM_PROXY_URL/-/ping" >/dev/null ||
  fail "Cache lab is not reachable at $NPM_PROXY_URL"

LOCKFILE_SOURCE_HASH="$(sha256sum "$LOCKFILE_SOURCE_DIR/package-lock.json" | awk '{print $1}')"
LEGACY_SOURCE_HASH="$(sha256sum "$LEGACY_SOURCE_DIR/package-lock.json" | awk '{print $1}')"
prepare_scenario "$LOCKFILE_SOURCE_DIR" "$LOCKFILE_DIR"
prepare_scenario "$LEGACY_SOURCE_DIR" "$LEGACY_DIR"

LOCKFILE_HASH_BEFORE="$(sha256sum "$LOCKFILE_DIR/package-lock.json" | awk '{print $1}')"
run_clean_ci "$LOCKFILE_DIR" 1
node -e '
const hello = require(process.argv[1] + "/node_modules/hello-cache");
const scoped = require(process.argv[1] + "/node_modules/@myscope/hello-cache");
if (hello() !== "hello from the cache lab" || scoped() !== "hello from the scoped cache lab") {
  throw new Error("Installed lockfile scenario packages returned unexpected values");
}
' "$LOCKFILE_DIR"
assert_proxy_cache_hit "/hello-cache/-/hello-cache-1.0.0.tgz"
assert_proxy_cache_hit "/@myscope/hello-cache/-/hello-cache-1.0.0.tgz"

run_clean_ci "$LOCKFILE_DIR" 2
LOCKFILE_HASH_AFTER="$(sha256sum "$LOCKFILE_DIR/package-lock.json" | awk '{print $1}')"
[[ "$LOCKFILE_HASH_BEFORE" == "$LOCKFILE_HASH_AFTER" ]] ||
  fail "npm ci modified the committed lockfile"

echo "== legacy-peers: prove ordinary npm ci rejects the peer conflict =="
rm -rf "$LEGACY_DIR/node_modules" "$LEGACY_DIR/.npm-cache"
if (
  cd "$LEGACY_DIR"
  npm ci \
    --cache "$LEGACY_DIR/.npm-cache" \
    --registry "$NPM_PROXY_URL/" \
    --no-audit \
    --no-fund
) >"$TMP_DIR/legacy-default.log" 2>&1; then
  fail "Ordinary npm ci unexpectedly accepted the incompatible peer dependency"
fi
grep -Eq 'ERESOLVE|could not resolve|Conflicting peer dependency' "$TMP_DIR/legacy-default.log" ||
  fail "Ordinary npm ci failed, but not with the expected peer-resolution error"

LEGACY_LOCK_HASH_BEFORE="$(sha256sum "$LEGACY_DIR/package-lock.json" | awk '{print $1}')"
run_clean_ci "$LEGACY_DIR" 1 --legacy-peer-deps
node -e '
const plugin = require(process.argv[1] + "/node_modules/legacy-peer-plugin");
if (plugin !== "peer-host-v2") {
  throw new Error("Legacy peer fixture did not resolve the installed peer-host v2");
}
' "$LEGACY_DIR"
assert_proxy_cache_hit "/hello-cache/-/hello-cache-1.0.0.tgz"

run_clean_ci "$LEGACY_DIR" 2 --legacy-peer-deps
LEGACY_LOCK_HASH_AFTER="$(sha256sum "$LEGACY_DIR/package-lock.json" | awk '{print $1}')"
[[ "$LEGACY_LOCK_HASH_BEFORE" == "$LEGACY_LOCK_HASH_AFTER" ]] ||
  fail "npm ci --legacy-peer-deps modified the committed lockfile"
[[ "$LOCKFILE_SOURCE_HASH" == "$(sha256sum "$LOCKFILE_SOURCE_DIR/package-lock.json" | awk '{print $1}')" ]] ||
  fail "The canonical lockfile scenario was modified"
[[ "$LEGACY_SOURCE_HASH" == "$(sha256sum "$LEGACY_SOURCE_DIR/package-lock.json" | awk '{print $1}')" ]] ||
  fail "The canonical legacy-peer lockfile was modified"

echo
echo "PASS: committed lockfiles survived repeat clean-client-cache npm ci runs."
echo "PASS: the incompatible peer graph failed normally and succeeded with --legacy-peer-deps."
echo "PASS: package tarballs were available as NGINX cache HIT responses."
echo "PASS: canonical lockfiles remained unchanged while testing through $NPM_PROXY_URL."
