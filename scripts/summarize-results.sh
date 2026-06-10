#!/usr/bin/env bash
set -euo pipefail

input="${1:-reports/results.csv}"
expected_header='scenario,mode,run_id,npm_ci_ms,build_ms,nginx_tgz_hit,nginx_tgz_miss,nginx_tgz_bypass,upstream_tgz_requests,upstream_tgz_bytes,metadata_requests,exit_code,notes'

if [[ ! -f "$input" ]]; then
  echo "Results file not found: $input" >&2
  exit 1
fi

header="$(head -n 1 "$input" | tr -d '\r')"
if [[ "$header" != "$expected_header" ]]; then
  echo "Unexpected CSV header in $input" >&2
  echo "Expected: $expected_header" >&2
  exit 1
fi

echo "# Measured Run Summary"
echo
echo "Source: \`$input\`"
echo
echo "| Scenario | Mode | Runs | Successes | Avg npm ci ms | Avg build ms | HIT | MISS | BYPASS | Upstream tgz requests | Upstream tgz bytes | Metadata requests |"
echo "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"

awk -F, '
  NR == 1 { next }
  NF < 12 { invalid++; next }
  {
    key = $1 SUBSEP $2
    scenario[key] = $1
    mode[key] = $2
    runs[key]++
    if (($12 + 0) == 0) successes[key]++
    npm[key] += $4 + 0
    build[key] += $5 + 0
    hit[key] += $6 + 0
    miss[key] += $7 + 0
    bypass[key] += $8 + 0
    upstream_requests[key] += $9 + 0
    upstream_bytes[key] += $10 + 0
    metadata[key] += $11 + 0
  }
  END {
    for (key in runs) {
      printf "| %s | %s | %d | %d | %.1f | %.1f | %d | %d | %d | %d | %.0f | %d |\n",
        scenario[key], mode[key], runs[key], successes[key],
        npm[key] / runs[key], build[key] / runs[key],
        hit[key], miss[key], bypass[key], upstream_requests[key],
        upstream_bytes[key], metadata[key]
    }
    if (invalid > 0) {
      printf "\nWarning: skipped %d malformed row(s).\n", invalid > "/dev/stderr"
      exit 2
    }
  }
' "$input" | sort

echo
echo "All values above are aggregates of supplied rows. They are not independently validated against raw logs."
