# Artifactory Lockfile and NGINX Cache Acceptance Report

## Executive Summary

On June 10, 2026, the lab successfully tested the workflow in which:

1. A developer generates a `package-lock.json` against the main upstream
   registry.
2. The lockfile is preserved for CI.
3. CI runs `npm ci` through NGINX with an empty npm client cache.
4. NGINX fills its tarball cache on the cold run.
5. A second clean CI run uses the same lockfile and a new empty npm client
   cache.
6. The warm run serves every npm tarball request from NGINX without fetching a
   tarball from the upstream registry.

All six acceptance checks passed in the lab:

| Check | Result | Primary evidence |
| --- | --- | --- |
| Direct-upstream lockfile generation | Pass | 569 `resolved` URLs use `localhost:24873` |
| Cold `npm ci` through NGINX | Pass | 471 npm tarball responses matched 471 NGINX requests |
| All cold tarballs traversed NGINX | Pass | Exact multiset path comparison; zero differences |
| Warm cache HIT behavior | Pass | 471 NGINX HITs, zero MISS/BYPASS |
| Integrity and lockfile stability | Pass | Zero `EINTEGRITY`; identical SHA-256 before/after |
| No warm upstream tarball traffic | Pass | Zero upstream `.tgz` requests and zero bytes |

The result supports the proposed development and CI model. A lockfile generated
against the main registry can be used safely through the NGINX cache, provided
CI deliberately replaces the lockfile registry host or the network design
routes that host through NGINX.

## Scope and Terminology

The lab does not contain a licensed Artifactory instance. It uses the local
registry/public npm fallback as the Artifactory substitute:

| Production role | Lab endpoint |
| --- | --- |
| Main Artifactory used by developers | `http://localhost:24873` |
| NGINX endpoint used by CI | `http://localhost:28080` |
| Public remote behind the registry | `https://registry.npmjs.org` |

The tested workload was Angular 20 with:

- Node.js `22.16.0`
- npm `10.9.2`
- lockfile version 3
- 569 lockfile package entries containing `resolved` and `integrity`
- 466 packages installed on Linux x86-64

Authentication was intentionally outside this test's scope.
The checked-in NGINX configuration bypasses shared caching when an
`Authorization` header is present. Production use therefore requires the
separate authentication-aware solution assumed by this evaluation.

## Test Design

An isolated Compose project named `npm-cache-acceptance` was used. It had:

- separate host ports;
- a newly created NGINX cache volume;
- no dependency on the previously running lab cache;
- a temporary Angular workspace;
- separate empty npm client caches for cold and warm runs.

The NGINX volume persisted between the cold and warm runs. `node_modules`,
Angular output, and the npm client cache did not persist.

## Acceptance Results

### 1. Generate the Lockfile Against the Main Registry

The registry initially advertised direct tarball URLs:

```text
metadata registry: http://localhost:24873
tarball base:      http://localhost:24873
```

The lockfile was generated with:

```bash
npm install \
  --package-lock-only \
  --ignore-scripts \
  --registry=http://localhost:24873 \
  --replace-registry-host=never \
  --no-audit \
  --no-fund
```

Result:

```text
lockfile resolved entries: 569
lockfile integrity entries: 569
resolved host:              localhost:24873
SHA-256: 9b3879eda2b5224d316dbe5efc52804c396e40a2f3b8183beb4a31913309b693
```

This proves the CI test started with a lockfile that pointed to the direct
upstream rather than one generated through NGINX.

The exact generated lockfile is retained at:

```text
reports/artifactory-lockfile-acceptance/direct-upstream-package-lock.json
```

### 2. Run Cold `npm ci` Through NGINX

The registry was restarted so metadata advertised the NGINX endpoint, while the
fresh NGINX cache volume was preserved:

```text
CI registry:   http://localhost:28080
tarball proxy: http://localhost:28080
```

CI used:

```bash
npm ci \
  --registry=http://localhost:28080 \
  --replace-registry-host=always \
  --cache=<new-empty-cache> \
  --prefer-online \
  --no-audit \
  --no-fund
```

Result:

- `npm ci` succeeded.
- 466 packages were installed.
- npm received 471 tarball responses.
- NGINX received 471 matching tarball requests.
- The npm and NGINX tarball path multisets had zero differences.
- NGINX recorded zero `BYPASS` tarball requests.

This proves the direct-upstream URLs stored in the lockfile were replaced for
the CI execution and every npm tarball request traversed NGINX.

### 3. Confirm Cold Upstream Fetches

Cold-run NGINX results:

| Status | Requests |
| --- | ---: |
| MISS | 427 |
| HIT | 44 |
| BYPASS | 0 |
| Total | 471 |

The upstream registry recorded:

| Metric | Value |
| --- | ---: |
| Tarball requests | 427 |
| Tarball response bytes | 56,188,909 |

The 44 cold-run HITs are expected. npm requested some identical tarball URLs
more than once during the same run. The first request populated the cache and a
later request for the same cache key was a HIT.

The important reconciliation is:

```text
427 NGINX MISS == 427 upstream tarball requests
```

### 4. Run Warm `npm ci` With a New Client Cache

Before the warm run:

- `node_modules` was deleted;
- Angular `dist` output was deleted;
- a different empty npm client cache was used;
- the NGINX cache volume was retained;
- the lockfile was not regenerated or edited.

Warm result:

| Metric | Value |
| --- | ---: |
| Packages installed | 466 |
| npm tarball responses | 471 |
| NGINX tarball requests | 471 |
| NGINX HIT | 471 |
| NGINX MISS | 0 |
| NGINX BYPASS | 0 |

The npm and NGINX tarball path multisets again had zero differences.

The `cache miss` text in npm's HTTP log refers to npm's deliberately empty
local client cache. It does not describe NGINX. The NGINX access log is the
authoritative source for proxy-cache status and recorded all 471 requests as
HITs.

### 5. Verify Integrity, Lockfile Stability, and Build Correctness

Integrity result:

```text
EINTEGRITY errors: 0
integrity checksum failures: 0
```

The lockfile contained 569 integrity-bearing entries and 525 unique resolved
URLs. This Linux installation selected 427 unique tarball URLs. Successful
`npm ci` proves that the selected tarballs delivered through NGINX matched
their lockfile integrity values. Platform-specific packages that were not
selected were not downloaded or validated by this run.

Lockfile hashes:

```text
before: 9b3879eda2b5224d316dbe5efc52804c396e40a2f3b8183beb4a31913309b693
after:  9b3879eda2b5224d316dbe5efc52804c396e40a2f3b8183beb4a31913309b693
```

The warm installation was also followed by a production Angular build:

```text
Application bundle generation complete.
Angular production output: 2 files, 185370 bytes
```

This proves package installation and application build correctness for the
tested workload.

### 6. Confirm No Warm Tarball Traffic Reached Upstream

Warm upstream result:

```text
upstream tarball requests: 0
upstream tarball bytes:    0
```

Metadata still reached the registry because this implementation deliberately
does not cache npm metadata. The acceptance condition applies specifically to
package tarballs.

## Integrity Assessment

Changing the registry host does not alter the package identity or expected
content. The lockfile continues to define:

- exact package versions;
- exact tarball integrity hashes;
- dependency graph structure.

NGINX stores and returns the tarball response body without intentionally
modifying it. npm then validates downloaded content against the lockfile's
integrity hash. Based on npm's integrity mechanism, the expected behavior is:

- a correct cached tarball installs normally;
- a stale or incorrect tarball for the URL fails integrity validation;
- a truncated or corrupted cache object fails integrity validation;
- the lockfile does not need to be rewritten or regenerated in CI.

The proxy improves delivery efficiency but does not replace npm's content
integrity enforcement. This run proved successful integrity validation of the
selected artifacts. It did not deliberately corrupt a cached object to test the
negative failure path.

## Required CI Configuration

The critical configuration used by this test is:

```ini
registry=http://nginx-npm-proxy/
replace-registry-host=always
```

Equivalent command-line configuration is:

```bash
npm ci \
  --registry=http://nginx-npm-proxy/ \
  --replace-registry-host=always
```

Setting only `registry` is not sufficient when a committed lockfile contains
absolute Artifactory URLs. Without host replacement, npm can follow those URLs
and bypass NGINX. This follows from npm's absolute `resolved` URL behavior and
was not exercised as a separate negative control in this acceptance run.

An alternative production design is to make the lockfile's existing
Artifactory hostname resolve or route through NGINX in CI. That avoids npm host
replacement but requires network and TLS ownership of that hostname.

## Operational Usefulness

For this Angular workload, one cold fill transferred approximately 53.6 MiB
across 427 upstream tarball requests. An equivalent warm clean install avoids
those requests and bytes when it uses the same artifact URLs and the cache
entries remain present.

At 400,000 equivalent clean CI builds per month, under ideal cache retention
and dependency reuse, the modeled impact remains:

- approximately 170.8 million upstream tarball requests avoided;
- approximately 20.4 TiB of upstream transfer avoided;
- reduced upstream connection and concurrency pressure during CI bursts.

The principal benefit is upstream scalability and traffic reduction. Build
compilation itself is unaffected by the tarball cache.

## Limitations

1. The upstream was a lab registry with public npm fallback, not a real
   Artifactory deployment.
2. The preserved lockfile represents the commit boundary by immutable copy and
   SHA-256 comparison; this test did not create a Git commit.
3. This was one cold/warm acceptance pair, not a latency benchmark.
4. Package paths, remote repository layouts, redirects, and TLS behavior must
   still be verified against the target Artifactory instance.
5. Lifecycle downloads from unrelated hosts are outside this npm tarball cache.
6. Metadata remains uncached and continues to reach the upstream registry.
7. Authentication was not exercised. The checked-in configuration bypasses
   shared caching for token-bearing requests and must be combined with the
   separate authentication-aware design assumed by this report.
8. The test commands were executed interactively rather than from a retained,
   single acceptance script. The raw request logs, generated lockfile, hashes,
   source state, and summarized counters are retained, but there is no complete
   shell transcript.
9. The tested source and evidence were in an uncommitted worktree. The
   `source-state.txt` and `evidence-sha256.txt` files record that provenance;
   durable organizational acceptance should commit or archive the exact source
   and evidence set.

These limitations do not weaken the tested integrity or routing result. They
define the additional environment-specific validation needed before rollout.

## Evidence Index

All raw evidence is under:

```text
reports/artifactory-lockfile-acceptance/
```

Key files:

| File | Purpose |
| --- | --- |
| `test-summary.txt` | Consolidated machine-readable counts |
| `direct-upstream-package-lock.json` | Exact generated direct-upstream lockfile |
| `cold-npm.log` | Cold npm HTTP and install output |
| `cold-nginx.log` | Cold NGINX cache statuses |
| `cold-registry.log` | Cold upstream requests and bytes |
| `warm-npm.log` | Warm npm HTTP and install output |
| `warm-nginx.log` | Warm NGINX cache statuses |
| `warm-registry.log` | Warm upstream evidence |
| `warm-build.log` | Angular build and output verification |
| `lockfile-before.txt` | Pre-run lockfile hash |
| `lockfile-after.txt` | Post-run lockfile hash |
| `source-state.txt` | Source HEAD and worktree state at evidence collection |
| `evidence-sha256.txt` | SHA-256 manifest for the retained evidence |

## Final Decision

Within the anonymous-cache scope tested here, the lab acceptance test supports
using this NGINX implementation for CI builds whose lockfiles were generated
directly against the main Artifactory. Production use assumes the separate
authentication-aware solution identified as outside this test.

The tested configuration preserved lockfile integrity, routed all npm tarballs
through NGINX, served the entire warm tarball workload from cache, generated no
warm upstream tarball traffic, and produced a valid Angular production build.

The deployment requirement is explicit registry-host routing in CI. With that
in place, no integrity issue was observed and npm's native integrity checks
remain active end to end.
