#!/usr/bin/env bash
# Times reading one archive with this library and with other readers: unzip -t, unzip -p
# into /dev/null, Python's zipfile and Zig's std.zip. Each line is the median wall time of
# --runs runs of a whole process, so process start-up is included for every reader.
set -euo pipefail

usage() {
	cat <<'USAGE'
usage: scripts/perf-baseline.sh [--count N] [--size BYTES] [--data random|text]
                                [--method deflate|stored] [--runs N] [--extract]
Defaults: 20000 x 132 B random deflate, 5 runs. --extract adds extraction into a
temporary folder: ours (extractAll), unzip -d, Python extractall and std.zip.extract.
Readers that are not installed are skipped.
USAGE
}

. "$(dirname "$0")/perf/common.sh"
extract=0
parse_common "$@"
set -- "${rest[@]+"${rest[@]}"}"
while (($#)); do
	case $1 in
	--extract) extract=1; shift ;;
	*) usage >&2; exit 2 ;;
	esac
done

build_probe probe
build_probe std_zip_read
zip=$(archive)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Prints the median wall time in ms of running "$@" `runs` times; `prep` runs untimed
# before each run.
median() {
	local label=$1 prep=$2
	shift 2
	python3 - "$runs" "$label" "$prep" "$@" <<'PY'
import statistics, subprocess, sys, time
runs, label, prep, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
times = []
for _ in range(runs):
    if prep:
        subprocess.run(prep, shell=True, check=True)
    start = time.perf_counter()
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
    times.append((time.perf_counter() - start) * 1000)
print(f"{label:<34} {statistics.median(times):>10.1f} ms")
PY
}

py_read='import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for i in z.infolist(): z.read(i)'
py_extract='import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])'

echo "archive: $zip ($(stat -c %s "$zip") bytes), median of $runs runs"
echo "read, CRC checked unless noted:"
median "ours, memory (probe stream)" "" $TASKSET "$OUT/probe" read "$zip" --source memory --case stream --runs 1
median "ours, file (probe stream)" "" $TASKSET "$OUT/probe" read "$zip" --source file --case stream --runs 1
median "ours, file-alloc (probe stream)" "" $TASKSET "$OUT/probe" read "$zip" --source file-alloc --case stream --runs 1
median "std.zip, file (no CRC)" "" $TASKSET "$OUT/std_zip_read" "$zip"
command -v unzip >/dev/null && median "unzip -t" "" $TASKSET unzip -tqq "$zip"
command -v unzip >/dev/null && median "unzip -p >/dev/null" "" $TASKSET unzip -p "$zip"
command -v python3 >/dev/null && median "python3 zipfile read" "" $TASKSET python3 -c "$py_read" "$zip"

if ((extract)); then
	echo "extract into a fresh folder:"
	median "ours (extractAll)" "rm -rf $tmp/x" $TASKSET "$OUT/probe" extract "$zip" "$tmp/x"
	median "std.zip.extract" "rm -rf $tmp/x" $TASKSET "$OUT/std_zip_read" --extract "$zip" "$tmp/x"
	command -v unzip >/dev/null && median "unzip -qq -d" "rm -rf $tmp/x" $TASKSET unzip -qq "$zip" -d "$tmp/x"
	command -v python3 >/dev/null && median "python3 extractall" "rm -rf $tmp/x" $TASKSET python3 -c "$py_extract" "$zip" "$tmp/x"
fi
