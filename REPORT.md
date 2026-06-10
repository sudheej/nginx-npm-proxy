# npm Tarball Cache Evaluation Report

## Executive Summary

This lab can demonstrate a narrow but useful reduction in load on an upstream
npm repository such as Artifactory: repeated downloads of immutable package
tarballs can be served by NGINX after the first cache miss.

The expected value is primarily:

- fewer upstream `.tgz` requests;
- fewer compressed tarball bytes sent by Artifactory;
- less repeated remote-download latency during clean CI installs;
- reduced concurrency pressure on Artifactory during CI bursts.

It does **not** eliminate npm metadata traffic, package lifecycle work, native
compilation, or application builds. With the current configuration, requests
carrying `Authorization` bypass the shared cache, which can reduce the
production benefit to zero for typical authenticated npm clients.

No benchmark result is claimed in this report until it appears in the
**Measured Results** section from captured run data.

## Result Classes

Use these labels consistently:

- **Measured**: derived from captured command timings and proxy/upstream logs.
- **Modeled**: calculated from measured artifact counts or bytes and an explicit
  number of CI runs.
- **Illustrative**: hypothetical values used only to show scale and formulas.

Do not present modeled or illustrative values as benchmark results.

## Measurement Question

For `X` clean CI runs of an unchanged lockfile:

1. How many upstream tarball requests are avoided?
2. How many upstream tarball bytes are avoided?
3. How much `npm ci` elapsed time changes?
4. Does the cache preserve install, lifecycle-script, native-addon, and build
   correctness?

The unit under test is a clean workspace with an empty npm client cache. Keep
the NGINX cache state explicit:

- `disabled`: control path with no effective NGINX tarball reuse;
- `cold`: NGINX cache empty before the run;
- `warm`: NGINX cache retained from an equivalent completed run;
- `auth-bypass`: token-bearing requests intentionally bypass the cache.

## Required Experiment Design

For each scenario, pin the Node.js and npm versions and preserve one committed
lockfile. Run at least one cold-cache trial and multiple warm-cache trials.
Also run an equivalent disabled-cache control. Randomize or alternate control
and warm trials when practical to reduce time-of-day and host-load bias.

Before every trial:

1. Delete `node_modules` and application build output.
2. Use a new empty `NPM_CONFIG_CACHE` directory.
3. Preserve `package-lock.json`.
4. Record Node.js, npm, OS/architecture, CPU, memory, and proxy topology.
5. Record whether an npm token is configured and whether tarball requests carry
   `Authorization`.

Do not clear the NGINX cache for a `warm` run. Clear it before a `cold` run.
Use the same lockfile and upstream contents across compared runs.

Capture separately:

- `npm_ci_ms`: wall time for `npm ci` only;
- `build_ms`: wall time for the application build only;
- NGINX `.tgz` `HIT`, `MISS`, and `BYPASS` counts;
- upstream `.tgz` request count and response bytes;
- upstream non-tarball/metadata request count;
- command exit status.

Use at least 5 warm and 5 control trials for a directional result. Use 20 or
more of each when publishing latency percentiles. Report median and p95 rather
than only the mean.

## Truth Sources

The repository currently provides:

- NGINX access logs with `cache=HIT|MISS|BYPASS`;
- fake-registry logs showing every request that reached the upstream;
- npm command exit status and externally measured elapsed time.

The current log formats do **not** contain response byte counts. Upstream
request avoidance is measurable now; byte avoidance requires one of:

- adding response bytes to the NGINX and/or Artifactory access log;
- using Artifactory request-log byte fields;
- summing the exact compressed sizes of the requested unique tarballs.

The last method is valid only when each requested artifact is mapped to its
actual `.tgz` size. `node_modules` size and lockfile entry count are not valid
substitutes for compressed transfer bytes or tarball request count.

## Formulas

Let:

- `U` = unique cacheable tarballs required by the lockfile;
- `B` = sum of their compressed `.tgz` bytes;
- `X` = number of clean CI runs with one persistent NGINX cache;
- `A` = fraction of tarball traffic eligible for shared caching after auth,
  URL, eviction, and cache-key effects, from `0` to `1`;
- `R0`, `D0` = measured upstream tarball requests and bytes in the control;
- `Rc`, `Dc` = measured upstream tarball requests and bytes with caching.

For an ideal unchanged workload with one cold fill followed by warm runs:

```text
control upstream requests = X * U
cached upstream requests  = U
requests avoided          = (X - 1) * U

control upstream bytes    = X * B
cached upstream bytes     = B
bytes avoided             = (X - 1) * B
```

With partial eligibility:

```text
modeled requests avoided = (X - 1) * U * A
modeled bytes avoided    = (X - 1) * B * A
```

Prefer the direct measured comparison when available:

```text
measured requests avoided = R0 - Rc
measured bytes avoided    = D0 - Dc
request reduction %       = 100 * (R0 - Rc) / R0
byte reduction %          = 100 * (D0 - Dc) / D0
```

For timing, compare trial distributions:

```text
median npm ci saving = median(control npm_ci_ms) - median(warm npm_ci_ms)
relative saving %    = 100 * saving / median(control npm_ci_ms)
```

Do not multiply one local timing delta into an annual claim without stating
runner concurrency, network distance, cache placement, and confidence bounds.

## Illustrative Scale Projections

The following profiles are hypothetical, not measured characteristics of
Create React App, Angular, or any specific repository. Replace `U` and `B` with
values extracted from the exact lockfile and tarballs under test.

Assume `X = 100` clean runs, one cold fill, no eviction, and `A = 1`.

| Illustrative profile | `U` tarballs/run | `B` compressed/run | Requests avoided | Bytes avoided |
| --- | ---: | ---: | ---: | ---: |
| CRA-sized frontend | 900 | 180 MiB | 89,100 | 17.4 GiB |
| Angular-sized frontend | 1,300 | 300 MiB | 128,700 | 29.0 GiB |
| Heavier multi-tool stack | 2,500 | 750 MiB | 247,500 | 72.5 GiB |

These values show why a small per-install effect can matter during bursty CI:
the first runner fills the shared cache and subsequent runners avoid repeating
the same upstream transfers. They do not predict local install-time savings.

For an authenticated deployment using the current conservative policy,
`A` may be `0`, making all three avoided-load projections `0`. Measure this
before using the illustrative table in a business case.

## Scenario Acceptance Matrix

| Scenario | Required proof | What it answers | Important gap or confounder |
| --- | --- | --- | --- |
| Lockfile `npm ci` | committed lockfile; empty npm cache; cold then warm NGINX; identical integrity; second run has tarball hits | deterministic lockfile URLs use the proxy and cache | `npm install` is not a substitute for `npm ci`; verify every `resolved` URL points through NGINX |
| `--legacy-peer-deps` | lockfile created with compatible flags; `npm ci --legacy-peer-deps`; compare tarball set and success | peer resolution mode does not break cached delivery | the flag should not be expected to improve cache efficiency by itself |
| Native/prebuilt/postinstall | package with a real lifecycle script; capture npm-registry `.tgz` and any secondary binary-host requests separately | cached package delivery still allows scripts/native setup to complete | binaries fetched from GitHub/CDNs or compiled by `node-gyp` are outside this `.tgz` cache |
| Full Angular | `npm ci`, then a production Angular build; record install and build separately; verify output | realistic dependency graph and end-to-end correctness | NGINX should affect install transfer time, not TypeScript/bundling time |
| Authenticated control | valid npm token; show `BYPASS` and upstream requests on every run | production relevance of the current security policy | without a safe auth-aware design, shared-cache benefit may be absent |
| Concurrent cold start | multiple clean clients start together against empty NGINX cache | `proxy_cache_lock` prevents an upstream request stampede | sequential tests alone do not prove burst behavior |

### Native Scenario Guidance

Use `node-sass` only as a compatibility case if its pinned version supports the
selected Node.js runtime. A maintained native addon is better for measuring
current behavior. Record these as separate outcomes:

1. npm package tarball served by NGINX;
2. prebuilt binary fetched from another host;
3. fallback compilation performed by `node-gyp`;
4. lifecycle script success and duration.

Caching item 1 does not imply caching item 2 or reducing item 3.

## Measured Results

The following local measurements were captured on June 10, 2026. They are
directional single cold/warm pairs, not statistically robust benchmarks.

Environment:

- Node `22.16.0`, npm `10.9.2` for the valid Angular pair;
- Linux x86-64, 8 logical CPUs, 31 GiB RAM;
- NGINX and the fake/public-fallback registry in local Docker containers;
- empty npm client cache and deleted `node_modules` before each run;
- persistent NGINX cache between cold and warm runs;
- no bearer authentication.

| Scenario | Mode | npm ci | Build/verify | Result |
| --- | --- | ---: | ---: | --- |
| Angular 20 | cold proxy | 8,272 ms | 5,042 ms | pass |
| Angular 20 | warm proxy | 7,193 ms | 5,001 ms | pass |
| Native/node-gyp/sharp | warm proxy | 5,366 ms | 304 ms | pass |

The Angular pair installed 466 packages and produced a validated 185,370-byte
production output. Warm `npm ci` was 1,079 ms faster (13.0%) in this single
pair. Build time was effectively unchanged, as expected.

For the Angular pair, Docker logs measured:

- 427 upstream tarball requests during the cold fill;
- 56,188,909 upstream tarball bytes during the cold fill;
- 515 NGINX tarball HIT responses across the warm run;
- no second-run upstream tarball requests.

The HIT count exceeds the unique upstream request count because npm requested
some identical tarball URLs more than once. For `X` unchanged Angular CI runs
under these observed conditions, the modeled upstream savings are:

```text
requests avoided = (X - 1) * 427
bytes avoided    = (X - 1) * 56,188,909
```

Examples:

| Clean CI runs | Upstream requests avoided | Upstream bytes avoided |
| ---: | ---: | ---: |
| 10 | 3,843 | 482 MiB |
| 100 | 42,273 | 5.18 GiB |
| 1,000 | 426,573 | 52.28 GiB |

The native scenario passed real `node-gyp` compilation, a postinstall marker,
and Sharp/libvips verification. Its recorded cold timing of 79,589 ms is
excluded from comparison because NGINX was unavailable during npm's first two
retry windows. The subsequent warm run is functional evidence only, not a
defensible timing delta.

An attempted Angular build on Node `25.8.0` installed successfully but failed
inside Angular's JavaScript transformer worker. The same installed tree built
successfully with Node `22.16.0`; this is a runtime compatibility result, not a
cache failure.

Place run rows in `reports/results.csv`, following
`reports/results.csv.template`, then run:

```bash
./scripts/summarize-results.sh reports/results.csv
```

Use the generated summary only after validating that log
windows do not include health checks, manual curls, or another concurrent run.
The lightweight summarizer expects plain comma-separated fields; do not put an
unescaped comma in `notes`.

Recommended result table:

| Scenario | Mode | Trials | Successes | Median npm ci | p95 npm ci | Median build | Upstream tgz requests | Upstream tgz bytes | HIT/MISS/BYPASS |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| _pending_ | | | | | | | | | |

## Interpretation Rules

- Count an upstream request as avoided only relative to a matched control.
- A NGINX `HIT` is supporting evidence; absence from the upstream log is the
  direct evidence that Artifactory work was avoided.
- Metadata remains uncached and still reaches Artifactory.
- `npm audit`, search, dist-tags, and other non-`.tgz` endpoints remain uncached.
- A warm npm client cache would hide proxy behavior; each trial must use an
  empty npm client cache.
- Cache eviction, query-string variation, hostname variation, and stale direct
  lockfile URLs reduce eligibility.
- A successful build proves correctness but should not be counted as cache time
  saved unless build inputs or build execution are also cached separately.
- Report failures and timeouts, not only successful fast runs.

## Oversight Findings

The requested lockfile, legacy-peer, native/postinstall, and Angular scenarios
are necessary and collectively provide good functional breadth. They are not
sufficient for a defensible Artifactory benefit claim without:

- a disabled-cache matched control;
- repeated warm trials with an empty npm client cache;
- byte-level upstream instrumentation or exact tarball-size accounting;
- an authenticated `BYPASS` measurement;
- a concurrent cold-start test for `proxy_cache_lock`;
- separate install and build timings;
- pinned Node.js/npm/toolchain versions and preserved raw logs.

The implemented scenarios now contain pinned lockfiles, default to the local
proxy, separate install/build timings, and emit the report CSV schema. Remaining
gaps are:

- the lockfile/legacy harness does not delimit log counters per npm run;
- the workload runner does not automatically merge Docker counters into CSV;
- metadata request counts are not yet recorded in the consolidated results;
- the existing tests are sequential and do not exercise simultaneous cold
  clients;
- a matched cache-disabled control and repeated trials are still required for
  a publishable latency claim.

The largest deployment risk is authentication. This repository intentionally
bypasses shared caching whenever `Authorization` is present, while real private
registry clients commonly send a token for tarballs. Resolve or explicitly
accept that constraint before extrapolating local anonymous-cache results to
Artifactory.
