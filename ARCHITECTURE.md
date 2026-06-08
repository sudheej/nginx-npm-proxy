# Architecture

This lab models an enterprise npm registry path where NGINX sits in front of a package repository and caches only package tarballs. The fake registry replaces Artifactory so the proxy and npm URL behavior can be tested locally without a licensed server.

## Components

```text
npm client
  |
  | registry=http://localhost:8080/
  v
NGINX :8080
  |
  | proxy_pass http://registry:4873
  v
fake npm registry :4873
  |
  v
local package tarballs
```

### npm Client

The client lives in `client/`.

- `client/.npmrc` sets `registry=http://localhost:8080/`.
- `client/package.json` depends on `hello-cache@1.0.0` and `@myscope/hello-cache@1.0.0`.
- `scripts/test-install.sh` deletes install artifacts, clears the lab-local npm cache, and runs installs twice.

The important npm behavior is that the registry setting controls where npm asks for metadata. It does not guarantee where npm downloads tarballs. Tarball downloads follow the `dist.tarball` URL in metadata, or the `resolved` URL already saved in `package-lock.json`.

### NGINX

NGINX listens on host port `8080` and proxies to the fake registry service inside the Compose network.

The cache policy is intentionally narrow:

- cache only request paths ending in `.tgz`
- do not cache metadata or other npm endpoints
- bypass cache for requests with `Authorization`
- add `X-Cache-Status` to every response

The cache is defined in `nginx/nginx.conf`:

```nginx
proxy_cache_path /var/cache/nginx/npm-tgz
                 keys_zone=npm_tgz_cache:10m
                 max_size=200m
                 inactive=30d;
```

Tarball requests use the cache:

```nginx
location ~ \.tgz$ {
    proxy_cache npm_tgz_cache;
    proxy_cache_valid 200 30d;
    proxy_cache_lock on;
}
```

All other paths proxy without cache:

```nginx
location / {
    proxy_pass http://npm_registry;
    add_header X-Cache-Status BYPASS always;
}
```

NGINX does not rewrite paths. This matters for scoped packages because npm may send either encoded or decoded scoped paths, such as `@myscope%2fhello-cache` or `@myscope/hello-cache`.

### Fake Registry

The fake registry is an Express app in `registry/server.js`. It serves:

- package metadata for `hello-cache`
- package metadata for `@myscope/hello-cache`
- one unscoped tarball
- one scoped tarball
- a ping endpoint

It logs every request:

```text
[registry] 2026-06-05T17:01:37.744Z GET /hello-cache
[registry] 2026-06-05T17:01:37.764Z GET /hello-cache/-/hello-cache-1.0.0.tgz
```

Those logs are the upstream truth source. If NGINX serves a tarball from cache, the fake registry should not log that tarball request.

## Request Flow

### Metadata Flow

```text
npm install
  |
  | GET http://localhost:8080/hello-cache
  v
NGINX location /
  |
  | proxy, no cache
  v
fake registry GET /hello-cache
  |
  | JSON metadata with dist.tarball
  v
npm
```

Metadata responses contain npm packument-style data:

```json
{
  "name": "hello-cache",
  "dist-tags": {
    "latest": "1.0.0"
  },
  "versions": {
    "1.0.0": {
      "name": "hello-cache",
      "version": "1.0.0",
      "dist": {
        "tarball": "http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz",
        "shasum": "...",
        "integrity": "sha512-..."
      }
    }
  }
}
```

Metadata is not cached by NGINX in this lab. Each metadata request should reach the fake registry.

### Tarball Flow, Correct Mode

Correct mode means registry metadata points tarballs at NGINX:

```text
TARBALL_BASE_URL=http://localhost:8080
```

Flow:

```text
npm follows dist.tarball
  |
  | GET http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz
  v
NGINX location ~ \.tgz$
  |
  | MISS: fetch upstream and store
  | HIT: serve from /var/cache/nginx/npm-tgz
  v
fake registry only on MISS
```

Expected curl proof:

```text
X-Cache-Status: MISS
X-Cache-Status: HIT
```

Expected registry log proof:

- first tarball request appears in registry logs
- repeated cached tarball request does not appear in registry logs

### Tarball Flow, Wrong Mode

Wrong mode means registry metadata points tarballs directly at the fake registry:

```text
TARBALL_BASE_URL=http://localhost:4873
```

Flow:

```text
npm follows dist.tarball
  |
  | GET http://localhost:4873/hello-cache/-/hello-cache-1.0.0.tgz
  v
fake registry directly
```

NGINX is bypassed because the request never reaches port `8080`. There is no `X-Cache-Status` header on those direct registry tarball responses, and registry logs keep showing tarball requests on repeated installs.

## Why Package Lockfiles Matter

`package-lock.json` stores tarball URLs in `resolved` fields.

If a lockfile was generated in wrong mode, it may contain:

```text
"resolved": "http://localhost:4873/hello-cache/-/hello-cache-1.0.0.tgz"
```

After switching the registry back to correct mode, npm can still use that old direct URL. Delete `client/package-lock.json` when changing tarball URL experiments so npm regenerates it from fresh metadata.

Correct lockfile URLs should point to NGINX:

```text
"resolved": "http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz"
```

## Scoped Package Path Handling

Scoped npm packages introduce two path forms:

```text
/@myscope%2fhello-cache
/@myscope/hello-cache
```

The fake registry accepts both. It normalizes `%2f` to `/` internally for route matching.

NGINX does not rewrite paths. That is deliberate. Rewriting scoped paths too aggressively is a common source of proxy bugs because encoded slash handling can differ between clients, proxies, registries, and application frameworks.

The scoped tarball URL used by this lab is:

```text
http://localhost:8080/@myscope/hello-cache/-/hello-cache-1.0.0.tgz
```

The tarball served for that URL contains an internal package manifest named `@myscope/hello-cache`.

## Cache Key

The current cache key is:

```nginx
proxy_cache_key "$scheme$request_method$host$request_uri";
```

This means these are distinct cache entries:

```text
/hello-cache/-/hello-cache-1.0.0.tgz
/hello-cache/-/hello-cache-1.0.0.tgz?variant=1
```

That is conservative because query-specific tarball URLs will not collide. If a real registry adds irrelevant query parameters and you want those variants to share cache entries, change the key to use `$uri` instead of `$request_uri` after validating that query strings do not affect authorization, content selection, or integrity.

## Cache Safety Boundary

This lab treats tarballs as safe to cache and metadata as unsafe to cache aggressively.

Tarballs are safer because:

- npm validates tarballs using `dist.integrity` and `dist.shasum`
- package version tarballs should be immutable in normal registry operation
- tarballs are large enough for caching to matter

Metadata is riskier because:

- `dist-tags.latest` can move
- versions and permissions may change
- private registry metadata can be user-specific
- stale metadata can hide publishing or permission changes

That is why the cache policy starts with tarballs only.

## Authorization Boundary

The NGINX tarball cache bypasses requests with an `Authorization` header:

```nginx
proxy_no_cache $http_authorization;
proxy_cache_bypass $http_authorization;
```

This is important for enterprise registries because authenticated responses may be permission-dependent. This lab does not implement authentication, but the proxy config keeps that safety rule visible.

## Artifactory Replacement Point

To replace the fake registry with Artifactory, keep the client and NGINX-facing URL the same, then change the upstream:

```nginx
upstream npm_registry {
    server artifactory.example.com:443;
}
```

For HTTPS upstreams:

```nginx
proxy_pass https://npm_registry;
```

The Artifactory-specific requirements are:

- Artifactory public base URL must match the NGINX-facing URL clients use.
- Reverse proxy headers must preserve the external scheme, host, and port.
- `X-JFrog-Override-Base-Url` may be needed depending on Artifactory setup.
- npm virtual repository URLs should emit tarball links that point back through NGINX.
- Generated `package-lock.json` files should contain NGINX-facing `resolved` URLs, not internal Artifactory URLs.

The same proof applies: inspect metadata, inspect lockfiles, then watch whether repeated tarball requests hit NGINX cache or Artifactory.

## Verification Matrix

| Scenario | Metadata URL | Tarball URL in metadata | Expected NGINX cache | Expected registry logs |
| --- | --- | --- | --- | --- |
| Correct mode | `localhost:8080` | `localhost:8080` | `MISS`, then `HIT` | tarball only on first upstream miss |
| Wrong mode | `localhost:8080` | `localhost:4873` | bypassed | tarball on every npm fetch |
| Stale wrong lockfile | maybe `localhost:8080` | lockfile has `localhost:4873` | bypassed | tarball on every npm fetch |
| Metadata request | `localhost:8080` | not applicable | `BYPASS` | metadata request always visible |

## Operational Commands

Correct mode:

```bash
docker compose down -v
docker compose up --build
./scripts/test-install.sh
./scripts/show-cache.sh
```

Wrong mode:

```bash
docker compose down -v
TARBALL_BASE_URL=http://localhost:4873 docker compose up --build
./scripts/test-install.sh
```

Inspect resolved URLs:

```bash
grep -n "resolved" client/package-lock.json
```

Inspect upstream requests:

```bash
docker compose logs -f registry
```

Inspect NGINX status:

```bash
curl -I http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz
curl -I http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz
```
