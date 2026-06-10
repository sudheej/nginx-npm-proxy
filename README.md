# npm NGINX Cache Lab

This lab demonstrates npm tarball caching through NGINX without requiring Artifactory. It uses:

- a tiny Express fake npm registry on container port `4873`, exposed as `http://localhost:4873`
- NGINX on `http://localhost:8080`
- npm configured to use NGINX as its registry
- NGINX caching only `.tgz` tarballs
- uncached metadata so package metadata behavior stays visible
- a public npm fallback for realistic Angular/native dependency graphs

For the design-level explanation, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Project Layout

```text
npm-nginx-cache-lab/
  docker-compose.yml
  nginx/
    nginx.conf
  registry/
    Dockerfile
    server.js
    package.json
    packages/
      hello-cache/
        package/
          package.json
          index.js
        scoped-package/
          package.json
          index.js
  client/
    package.json
    .npmrc
  scripts/
    build-package.sh
    test-install.sh
    show-cache.sh
    clean.sh
  ARCHITECTURE.md
  README.md
```

## Quick Start

Build the test package tarball:

```bash
cd npm-nginx-cache-lab
./scripts/build-package.sh
```

The scripts use a project-local npm cache at `.npm-cache` so the lab does not depend on your home npm cache.

Start the registry and NGINX:

```bash
docker compose up --build
```

In another terminal, run the npm install experiment:

```bash
cd npm-nginx-cache-lab
./scripts/test-install.sh
```

## Run the CI and Workload Scenarios

The extended scenarios cover committed lockfiles, legacy peer resolution,
native lifecycle scripts, precompiled native packages, and an Angular
production build:

```bash
./scripts/test-ci-scenarios.sh
./scripts/test-workload-scenarios.sh native
./scripts/test-workload-scenarios.sh angular
```

When port `8080` is occupied, start Compose and run the scenarios on an
alternate port:

```bash
NGINX_PORT=18080 \
REGISTRY_PORT=14873 \
TARBALL_BASE_URL=http://localhost:18080 \
docker compose up -d --build

NPM_PROXY_URL=http://localhost:18080 ./scripts/test-ci-scenarios.sh
NPM_REGISTRY_URL=http://localhost:18080 ./scripts/test-workload-scenarios.sh all
```

Use a supported LTS Node release for Angular. The validated baseline is Node
`22.16.0`; Node `25.8.0` installed the dependencies but failed inside the
Angular build worker.

The native scenario deliberately separates three behaviors:

- npm-hosted `sharp` platform tarballs are cacheable;
- the root `node-gyp` addon compiles on every clean install;
- Node headers fetched from `nodejs.org` are outside this NGINX cache.

`node-sass` is not used because it is end-of-life and incompatible with the
current Node baseline.

See [REPORT.md](REPORT.md) for measured results, formulas, and scaling
projections.

## Public Registry Passthrough

The fake registry still serves the local `hello-cache` fixtures directly.
Unknown GET/HEAD requests fall back to `PUBLIC_REGISTRY_URL`, which defaults to
`https://registry.npmjs.org`. JSON metadata responses have their
`dist.tarball` URLs rewritten to `TARBALL_BASE_URL`, causing real package
tarballs to return through NGINX.

This makes the lab suitable for broad public lockfiles without turning metadata
caching on. The registry logs upstream response byte counts as
`[registry-upstream] ... bytes=N`.

## Test an Authenticated Upstream

Start the lab with bearer authentication enabled:

```bash
REGISTRY_AUTH_TOKEN=lab-secret-token docker compose up --build
```

Then run the authenticated install test in another terminal:

```bash
./scripts/test-auth.sh
```

Host ports are configurable when the defaults are occupied:

```bash
NGINX_PORT=18080 \
TARBALL_BASE_URL=http://localhost:18080 \
REGISTRY_AUTH_TOKEN=lab-secret-token \
docker compose up --build

NGINX_BASE_URL=http://localhost:18080 ./scripts/test-auth.sh
```

The checked-in `client/.npmrc.auth` uses npm's `${NPM_TOKEN}` environment
substitution, so no real token is stored in the repository. The script verifies
that missing and invalid tokens receive `401`, a valid token reaches the
upstream, and two complete npm installs succeed through NGINX.

NGINX forwards `Authorization` explicitly. Authenticated tarball requests still
bypass the shared cache by design:

```nginx
proxy_set_header Authorization $http_authorization;
proxy_no_cache $http_authorization;
proxy_cache_bypass $http_authorization;
```

This conservative policy avoids serving one user's private package response to
another user. It also means a token-bearing production npm client will not get
tarball cache hits with this configuration.

## Verify Cache HIT and MISS

Use curl against the NGINX URL:

```bash
./scripts/show-cache.sh
```

Expected pattern:

```text
X-Cache-Status: MISS
X-Cache-Status: HIT
```

You can also run the curl commands manually:

```bash
curl -I http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz
curl -I http://localhost:8080/hello-cache/-/hello-cache-1.0.0.tgz
curl -I http://localhost:8080/@myscope/hello-cache/-/hello-cache-1.0.0.tgz
curl -I http://localhost:8080/@myscope/hello-cache/-/hello-cache-1.0.0.tgz
```

The first request for each tarball should be `MISS`. A repeat request should be `HIT`.

## Inspect Registry Logs

Keep `docker compose up --build` running in the foreground, or inspect logs with:

```bash
docker compose logs -f registry
```

The fake registry logs every request:

```text
[registry] 2026-06-05T12:00:00.000Z GET /hello-cache
[registry] 2026-06-05T12:00:00.000Z GET /hello-cache/-/hello-cache-1.0.0.tgz
```

When NGINX serves a tarball from cache, the tarball request should no longer appear in registry logs. Metadata requests should continue to appear because this lab does not cache metadata.

## Correct vs Wrong Tarball URLs

The registry writes tarball URLs into package metadata using `TARBALL_BASE_URL`.

Correct mode, through NGINX:

```yaml
TARBALL_BASE_URL: http://localhost:8080
```

Wrong-mode experiment, directly to the registry:

```bash
TARBALL_BASE_URL=http://localhost:4873 docker compose up --build
```

The Compose file defaults to `http://localhost:8080`, so normal startup is:

```bash
docker compose down -v
docker compose up --build
```

After switching modes, clear the client lockfile before testing:

```bash
rm -rf client/node_modules client/package-lock.json
npm cache clean --force
./scripts/test-install.sh
```

If metadata points to `http://localhost:4873`, npm downloads tarballs directly from the fake registry. NGINX cannot cache requests it never sees. You can prove this by watching registry logs: tarball requests keep hitting the registry, and `X-Cache-Status` does not appear on those direct registry responses.

## Why `npm --registry` Is Not Enough

`npm --registry=http://localhost:8080/` tells npm where to fetch metadata, but npm package metadata contains `dist.tarball` URLs. npm follows those tarball URLs. If the metadata says the tarball is at `http://localhost:4873/...`, the tarball request bypasses NGINX even though metadata came from NGINX.

This is also why real reverse proxies must ensure npm metadata contains externally correct tarball URLs.

## Why `package-lock.json` Matters

`package-lock.json` records `resolved` tarball URLs. Once a lockfile contains direct registry URLs, future installs may keep using those direct URLs even after you fix the registry setting.

For URL rewriting experiments, delete `client/package-lock.json` before retesting:

```bash
rm -f client/package-lock.json
```

Then run `npm install` again to regenerate the lockfile from fresh metadata.

## Why Metadata Is Not Cached Aggressively

npm metadata is mutable. Dist-tags can change, versions can be unpublished or republished depending on policy, and repository permissions can affect what metadata a user should see.

This lab deliberately proxies metadata without cache so you can see every metadata request in registry logs and avoid confusing stale packuments with tarball cache behavior.

## Why Tarballs Are Safer to Cache

Package tarballs are content-addressed in practice by version plus integrity. npm metadata includes `dist.shasum` and `dist.integrity`, and npm verifies downloads. Tarballs are much more stable than metadata, so they are a better first target for proxy caching.

The NGINX config caches only paths ending in `.tgz`:

```nginx
location ~ \.tgz$ {
    proxy_cache npm_tgz_cache;
    proxy_cache_valid 200 30d;
}
```

Authorization requests are forwarded upstream but not cached:

```nginx
proxy_no_cache $http_authorization;
proxy_cache_bypass $http_authorization;
```

## Scoped Packages

The fake registry supports:

- `GET /@myscope%2fhello-cache`
- `GET /@myscope/hello-cache`
- `GET /@myscope/hello-cache/-/hello-cache-1.0.0.tgz`
- `GET /@myscope%2fhello-cache/-/hello-cache-1.0.0.tgz`

The NGINX config does not rewrite paths. It proxies the original URI to avoid breaking encoded scoped package names.

## Replace the Fake Registry with Artifactory Later

To point NGINX at a real Artifactory npm repository, change the upstream in `nginx/nginx.conf`:

```nginx
upstream npm_registry {
    server artifactory.example.com:443;
}
```

Then adjust `proxy_pass` for HTTPS if needed:

```nginx
proxy_pass https://npm_registry;
```

Artifactory settings that matter:

- public base URL
- reverse proxy headers
- `X-JFrog-Override-Base-Url`
- npm virtual repository URL
- whether package metadata emits tarball URLs that point back through NGINX

The key test is the same: inspect package metadata and lockfiles. Tarball URLs must point at the NGINX-facing URL if you expect NGINX to cache them.

## What This Lab Does Not Cover

- private package permissions
- npm audit endpoints
- publish
- dist-tag changes
- postinstall binary downloads
- real Artifactory permission model

## Troubleshooting

Build the tarball before installing:

```bash
./scripts/build-package.sh
```

Check service health:

```bash
curl http://localhost:8080/-/ping
curl http://localhost:4873/-/ping
```

Inspect metadata:

```bash
curl -s http://localhost:8080/hello-cache | jq .
curl -s http://localhost:8080/@myscope%2fhello-cache | jq .
```

Check whether lockfile URLs are bypassing NGINX:

```bash
grep -n "resolved" client/package-lock.json
```

Clean everything:

```bash
./scripts/clean.sh
```

If `docker compose` is not available but `podman compose` is, use `podman compose` with the same arguments.
