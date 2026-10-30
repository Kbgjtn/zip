#!/usr/bin/env bash
# Profiles one read case of the perf probe with `perf record -g` and prints the top of
# `perf report`. Writes a flame graph too when inferno or FlameGraph's scripts are on PATH.
set -euo pipefail

usage() {
	cat <<'USAGE'
usage: scripts/perf-profile.sh [--count N] [--size BYTES] [--data random|text]
                               [--method deflate|stored] [--source memory|file]
                               [--case CASE] [--runs N] [--percent P]
Cases: list names stream stream-names alloc inflate-std crc (see scripts/perf/probe.zig).
Defaults: 20000 x 132 B random deflate, memory, stream-names, 5 runs, 1 percent.
Output: $OUT/perf.data, the report on stdout, $OUT/flame.svg if a flame graph tool exists.
USAGE
}

. "$(dirname "$0")/perf/common.sh"
percent=1
parse_common "$@"
set -- "${rest[@]+"${rest[@]}"}"
while (($#)); do
	case $1 in
	--percent) percent=$2; shift 2 ;;
	*) usage >&2; exit 2 ;;
	esac
done

command -v perf >/dev/null || { echo "perf not found" >&2; exit 1; }
build_probe probe
zip=$(archive)
$TASKSET perf record -q -g -o "$OUT/perf.data" \
	"$OUT/probe" read "$zip" --source "$source" --case "$case_" --runs "$runs"
perf report -i "$OUT/perf.data" --stdio --no-children --percent-limit "$percent" \
	--sort symbol -g none 2>/dev/null | grep -v '^#' | grep -v '^$'

if command -v inferno-collapse-perf >/dev/null && command -v inferno-flamegraph >/dev/null; then
	perf script -i "$OUT/perf.data" | inferno-collapse-perf | inferno-flamegraph >"$OUT/flame.svg"
	echo "flame graph: $OUT/flame.svg"
elif command -v stackcollapse-perf.pl >/dev/null && command -v flamegraph.pl >/dev/null; then
	perf script -i "$OUT/perf.data" | stackcollapse-perf.pl | flamegraph.pl >"$OUT/flame.svg"
	echo "flame graph: $OUT/flame.svg"
fi
