# Angular build workload

This is a minimal application on the full Angular CLI/build toolchain rather
than a synthetic dependency list. Its lockfile contains the Angular compiler,
CLI, esbuild platform package, Rollup, and their transitive dependencies,
creating a broad set of npm tarball requests.

Run two isolated-cache installs and production builds:

```bash
./scripts/test-workload-scenarios.sh angular
```

Point `NPM_REGISTRY_URL` at the cache proxy when testing cache behavior. The
registry must expose the public packages used by the checked-in lockfile.
The default is `http://localhost:8080`; alternate ports such as
`http://localhost:18080` are supported. The harness maps checked-in resolved
URLs to that registry with `replace-registry-host=always`. Set
`REGENERATE_LOCKFILES=1` when the lockfile itself must contain the selected
registry URL.
