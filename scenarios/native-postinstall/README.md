# Native and lifecycle workload

This fixture deliberately covers two distinct native installation paths:

- `node-gyp` compiles `src/addon.cc` during the root package `install`
  lifecycle. The compiler output is local build output and is not an npm
  tarball, so the NGINX cache does not cache it. Node header downloads come
  from `nodejs.org` and also bypass this npm registry cache.
- `sharp` selects platform-specific optional packages such as
  `@img/sharp-linux-x64` and `@img/sharp-libvips-linux-x64`. Those packages are
  npm `.tgz` downloads and are cacheable by the lab proxy.
- `postinstall` writes `build/postinstall-ran.json`; verification fails if npm
  lifecycle scripts were skipped.

`node-sass` is intentionally excluded. It is end-of-life and does not support
the Node versions used by this fixture. `sharp` provides a maintained,
precompiled-native-binary case without pinning the test to an obsolete runtime.

Run through the workload harness:

```bash
./scripts/test-workload-scenarios.sh native
```

The host needs Python, `make`, and a C++ compiler. Use Node 22 LTS for the
reproducible baseline.

The default registry is `http://localhost:8080`. Override it for a different
proxy port, for example `NPM_REGISTRY_URL=http://localhost:18080`. The harness
uses npm's `replace-registry-host=always` setting so the checked-in lockfile's
public npm URLs are fetched through the selected proxy. Set
`REGENERATE_LOCKFILES=1` to rewrite resolved URLs in the lockfile itself.
