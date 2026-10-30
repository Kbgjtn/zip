# Sourced by scripts/perf-*.sh: builds the probes and makes the test archives.
#
# Environment:
#   TASKSET  CPU pinning prefix, default "taskset -c 0-3"; set it empty to run unpinned.
#   ZIG      zig binary, default `zig` on PATH, else /opt/zig-x86_64-linux-0.16.0/zig.
#   OUT      where probes and archives go, default .zig-cache/perf.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
TASKSET=${TASKSET-taskset -c 0-3}
ZIG=${ZIG:-$(command -v zig || echo /opt/zig-x86_64-linux-0.16.0/zig)}
OUT=${OUT:-$root/.zig-cache/perf}
mkdir -p "$OUT"

count=20000
size=132
data=random
method=deflate
source=memory
case_=stream-names
runs=5

# Parses the options every script shares; the rest are left in `rest`.
parse_common() {
	rest=()
	while (($#)); do
		case $1 in
		--count) count=$2; shift 2 ;;
		--size) size=$2; shift 2 ;;
		--data) data=$2; shift 2 ;;
		--method) method=$2; shift 2 ;;
		--source) source=$2; shift 2 ;;
		--case) case_=$2; shift 2 ;;
		--runs) runs=$2; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) rest+=("$1"); shift ;;
		esac
	done
}

# Builds scripts/perf/NAME.zig ReleaseFast with frame pointers, so perf -g can walk stacks.
build_probe() {
	local name=$1
	$TASKSET "$ZIG" build-exe -j4 -OReleaseFast -fno-omit-frame-pointer \
		--dep zip -Mroot="scripts/perf/$name.zig" -Mzip=src/root.zig \
		--cache-dir "$root/.zig-cache" -femit-bin="$OUT/$name" >&2
}

# Writes the archive for the current options once and prints its path.
archive() {
	local path="$OUT/$count-$size-$data-$method.zip"
	[[ -f $path ]] || $TASKSET "$OUT/probe" gen "$path" --count "$count" --size "$size" --data "$data" --method "$method"
	echo "$path"
}
