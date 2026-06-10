#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$ROOT_DIR/.workload-results}"
RESULTS_FILE="${RESULTS_FILE:-$RESULTS_DIR/results.csv}"
NPM_REGISTRY_URL="${NPM_REGISTRY_URL:-http://localhost:8080}"
RUNS="${RUNS:-2}"
REGENERATE_LOCKFILES="${REGENERATE_LOCKFILES:-0}"
SCENARIO="${1:-all}"

if [[ -z "${MODE_PREFIX:-}" ]]; then
  if [[ "$NPM_REGISTRY_URL" == "https://registry.npmjs.org" || \
        "$NPM_REGISTRY_URL" == "https://registry.npmjs.org/" ]]; then
    MODE_PREFIX="direct"
  else
    MODE_PREFIX="proxy"
  fi
fi

case "$SCENARIO" in
  native|angular|all) ;;
  *)
    echo "usage: $0 [native|angular|all]" >&2
    exit 2
    ;;
esac

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "RUNS must be a positive integer" >&2
  exit 2
fi

mkdir -p "$RESULTS_DIR"

now_ms() {
  node -e 'console.log(Date.now())'
}

csv_escape() {
  local value="${1//\"/\"\"}"
  printf '"%s"' "$value"
}

regenerate_lockfile() {
  local directory="$1"

  echo "== Regenerating $(basename "$directory") lockfile for $NPM_REGISTRY_URL =="
  (
    cd "$directory"
    npm install \
      --package-lock-only \
      --ignore-scripts \
      --registry="$NPM_REGISTRY_URL" \
      --replace-registry-host=always \
      --no-audit \
      --no-fund
  )
}

run_scenario() {
  local name="$1"
  local directory="$2"
  local run cache_dir log_file mode
  local install_start_ms install_end_ms install_ms
  local build_start_ms build_end_ms build_ms
  local tarballs install_status build_status exit_code notes

  if [[ ! -f "$directory/package-lock.json" ]]; then
    echo "missing lockfile: $directory/package-lock.json" >&2
    echo "generate it with npm install --package-lock-only in that directory" >&2
    return 1
  fi

  if [[ "$REGENERATE_LOCKFILES" == "1" ]]; then
    regenerate_lockfile "$directory"
  fi

  for ((run = 1; run <= RUNS; run++)); do
    cache_dir="$RESULTS_DIR/npm-cache-$name-$run"
    log_file="$RESULTS_DIR/$name-run-$run.log"
    mode="$MODE_PREFIX-warm"
    if [[ "$run" == "1" ]]; then
      mode="$MODE_PREFIX-cold"
    fi
    rm -rf "$directory/node_modules" "$directory/build" "$directory/dist" "$cache_dir"
    mkdir -p "$cache_dir"

    echo "== $name run $run/$RUNS: npm ci =="
    install_start_ms="$(now_ms)"
    set +e
    (
      cd "$directory"
      npm ci \
        --registry="$NPM_REGISTRY_URL" \
        --replace-registry-host=always \
        --cache="$cache_dir" \
        --prefer-online \
        --no-audit \
        --no-fund \
        --loglevel=http
    ) 2>&1 | tee "$log_file"
    install_status="${PIPESTATUS[0]}"
    set -e
    install_end_ms="$(now_ms)"
    install_ms=$((install_end_ms - install_start_ms))

    build_ms=""
    build_status=0
    if [[ "$install_status" == "0" ]]; then
      echo "== $name run $run/$RUNS: build/verify =="
      build_start_ms="$(now_ms)"
      set +e
      (
        cd "$directory"
        case "$name" in
          native)
            npm run verify
            ;;
          angular)
            npm run build
            npm run verify
            ;;
        esac
      ) 2>&1 | tee -a "$log_file"
      build_status="${PIPESTATUS[0]}"
      set -e
      build_end_ms="$(now_ms)"
      build_ms=$((build_end_ms - build_start_ms))
    fi

    exit_code="$install_status"
    if [[ "$exit_code" == "0" ]]; then
      exit_code="$build_status"
    fi
    tarballs="$(grep -Eic 'http (fetch|cache) GET 200 .*\.tgz([? ]|$)' "$log_file" || true)"
    notes="registry=$NPM_REGISTRY_URL; npm_log_tgz_responses=$tarballs"

    {
      printf '%s,%s,%s,%s,%s,,,,,,,%s,' \
        "$name" "$mode" "$run" "$install_ms" "$build_ms" "$exit_code"
      csv_escape "$notes"
      printf '\n'
    } >> "$RESULTS_FILE"

    if [[ "$exit_code" != "0" ]]; then
      echo "FAIL $name run $run: npm_ci=${install_ms}ms build_verify=${build_ms:-not-run}ms" >&2
      return "$exit_code"
    fi
    echo "PASS $name run $run: npm_ci=${install_ms}ms build_verify=${build_ms}ms"
  done
}

printf 'scenario,mode,run_id,npm_ci_ms,build_ms,nginx_tgz_hit,nginx_tgz_miss,nginx_tgz_bypass,upstream_tgz_requests,upstream_tgz_bytes,metadata_requests,exit_code,notes\n' \
  > "$RESULTS_FILE"

if [[ "$SCENARIO" == "native" || "$SCENARIO" == "all" ]]; then
  run_scenario native "$ROOT_DIR/scenarios/native-postinstall"
fi

if [[ "$SCENARIO" == "angular" || "$SCENARIO" == "all" ]]; then
  run_scenario angular "$ROOT_DIR/scenarios/angular-build"
fi

echo
echo "Results: $RESULTS_FILE"
