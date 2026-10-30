#!/usr/bin/env bash
# Counts the system calls of one read case with `strace -c -f`, by default reading the
# archive from a file, where each seek outside the reader's buffer costs a read.
set -euo pipefail

usage() {
	cat <<'USAGE'
usage: scripts/perf-syscalls.sh [--count N] [--size BYTES] [--data random|text]
                                [--method deflate|stored] [--source memory|file]
                                [--case CASE] [--buffer BYTES]
Defaults: 20000 x 132 B random deflate, file, stream-names, 1 run, 4 KiB file buffer.
Prints the probe's timing (slowed by strace) and the strace summary.
USAGE
}

. "$(dirname "$0")/perf/common.sh"
source=file
runs=1
buffer=4096
parse_common "$@"
set -- "${rest[@]+"${rest[@]}"}"
while (($#)); do
	case $1 in
	--buffer) buffer=$2; shift 2 ;;
	*) usage >&2; exit 2 ;;
	esac
done

command -v strace >/dev/null || { echo "strace not found" >&2; exit 1; }
build_probe probe
zip=$(archive)
$TASKSET strace -c -f -o "$OUT/strace.txt" \
	"$OUT/probe" read "$zip" --source "$source" --case "$case_" --runs "$runs" --buffer "$buffer"
cat "$OUT/strace.txt"
echo "entries: $count, syscalls per entry:" \
	"$(awk '/total/ { printf "%.2f", $4 / '"$count"' }' "$OUT/strace.txt")"
