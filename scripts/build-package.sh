#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$ROOT_DIR/registry/packages/hello-cache"
PKG_SRC="$PKG_ROOT/package"
SCOPED_PKG_SRC="$PKG_ROOT/scoped-package"
TARBALL="$PKG_ROOT/hello-cache-1.0.0.tgz"
SCOPED_TARBALL="$PKG_ROOT/scoped-hello-cache-1.0.0.tgz"

export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$ROOT_DIR/.npm-cache}"
mkdir -p "$PKG_SRC" "$SCOPED_PKG_SRC"

cat > "$PKG_SRC/package.json" <<'JSON'
{
  "name": "hello-cache",
  "version": "1.0.0",
  "description": "Small package for NGINX npm tarball cache experiments.",
  "main": "index.js",
  "files": [
    "index.js"
  ],
  "license": "UNLICENSED"
}
JSON

cat > "$PKG_SRC/index.js" <<'JS'
"use strict";

module.exports = function helloCache() {
  return "hello from the cache lab";
};
JS

cat > "$SCOPED_PKG_SRC/package.json" <<'JSON'
{
  "name": "@myscope/hello-cache",
  "version": "1.0.0",
  "description": "Scoped package for NGINX npm tarball cache experiments.",
  "main": "index.js",
  "files": [
    "index.js"
  ],
  "license": "UNLICENSED"
}
JSON

cat > "$SCOPED_PKG_SRC/index.js" <<'JS'
"use strict";

module.exports = function scopedHelloCache() {
  return "hello from the scoped cache lab";
};
JS

rm -f "$TARBALL" "$SCOPED_TARBALL" "$PKG_SRC"/hello-cache-1.0.0.tgz "$SCOPED_PKG_SRC"/myscope-hello-cache-1.0.0.tgz "$PKG_ROOT"/myscope-hello-cache-1.0.0.tgz

(
  cd "$PKG_SRC"
  npm pack --pack-destination "$PKG_ROOT"
)

(
  cd "$SCOPED_PKG_SRC"
  npm pack --pack-destination "$PKG_ROOT"
)
mv "$PKG_ROOT/myscope-hello-cache-1.0.0.tgz" "$SCOPED_TARBALL"

echo
echo "Built tarball: $TARBALL"
if command -v sha1sum >/dev/null 2>&1; then
  echo "sha1: $(sha1sum "$TARBALL" | awk '{print $1}')"
fi

node -e '
const fs = require("fs");
const crypto = require("crypto");
const file = process.argv[1];
const data = fs.readFileSync(file);
console.log("integrity: sha512-" + crypto.createHash("sha512").update(data).digest("base64"));
' "$TARBALL"

echo
echo "Built scoped tarball: $SCOPED_TARBALL"
if command -v sha1sum >/dev/null 2>&1; then
  echo "sha1: $(sha1sum "$SCOPED_TARBALL" | awk '{print $1}')"
fi

node -e '
const fs = require("fs");
const crypto = require("crypto");
const file = process.argv[1];
const data = fs.readFileSync(file);
console.log("integrity: sha512-" + crypto.createHash("sha512").update(data).digest("base64"));
' "$SCOPED_TARBALL"
