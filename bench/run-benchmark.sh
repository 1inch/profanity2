#!/usr/bin/env bash
#
# Compares the speed of the two profanity2 revisions baked into this image.
#
# The two builds never run at the same time and never share a kernel cache.
# They take turns - A, B, A, B - so that clock drift or thermal throttling on
# the rented machine shows up as disagreement between repeats of the same
# build instead of masquerading as a difference between the two revisions.
#
# usage: bench [OPTIONS]
#
#   --mode leading|exact  what to measure [default = leading]
#   --seconds <n>         measured window per run, in seconds [default = 120]
#   --warmup <n>          seconds dropped before the window opens [default = 30]
#   --repeats <n>         how many times each revision runs [default = 2]
#   --extra-args "<...>"  options handed to both revisions
#                         [default = "-i 255 -I 16384 -w 64"]
#   --mask <hex>          mask used by --mode exact [default = deadbee]
#   --public-key <hex>    seed public key [default = the secp256k1 generator]
#   -h, --help            this text
#
# Every option can also be given as an environment variable (BENCH_MODE,
# BENCH_SECONDS, BENCH_WARMUP, BENCH_REPEATS, BENCH_EXTRA_ARGS,
# BENCH_EXACT_MASK, BENCH_PUBLIC_KEY), which is the only way to configure the
# run on platforms that replace the image entrypoint.
#
# An argument that does not start with a dash is executed instead of the
# benchmark, e.g. `clinfo` or `bash`.

set -euo pipefail

readonly ROOT=/opt/bench

# Generator point of secp256k1, x and y concatenated without the 04 prefix. It
# is a valid public key, so profanity2 accepts it, and its private key is the
# publicly known value 1 - fine for a benchmark, useless for anything else.
readonly GENERATOR_PUBLIC_KEY=79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8

# How long a revision may take to compile its kernel and initialize the device
# before the run is considered failed.
readonly STARTUP_TIMEOUT=900

MODE="${BENCH_MODE:-leading}"
WINDOW="${BENCH_SECONDS:-120}"
WARMUP="${BENCH_WARMUP:-30}"
REPEATS="${BENCH_REPEATS:-2}"
EXTRA_ARGS="${BENCH_EXTRA_ARGS:--i 255 -I 16384 -w 64}"
EXACT_MASK="${BENCH_EXACT_MASK:-deadbee}"

# PUBLIC_KEY is accepted for convenience but cannot be trusted: rental
# platforms hand out that name for their own SSH key and it may sit in an
# account-wide variable, so it is only taken when it looks like a seed public
# key. Which key won is printed in the header - a benchmark that picks up
# somebody else's value fails in a way that is hard to read otherwise.
SEED_KEY="$GENERATOR_PUBLIC_KEY"
KEY_SOURCE="the secp256k1 generator"

if [ -n "${BENCH_PUBLIC_KEY:-}" ]; then
	SEED_KEY="$BENCH_PUBLIC_KEY"
	KEY_SOURCE="BENCH_PUBLIC_KEY"
elif [ -n "${PUBLIC_KEY:-}" ]; then
	if printf '%s' "$PUBLIC_KEY" | grep -qE '^[0-9a-fA-F]{128}$'; then
		SEED_KEY="$PUBLIC_KEY"
		KEY_SOURCE="PUBLIC_KEY"
	else
		KEY_SOURCE="the secp256k1 generator (PUBLIC_KEY ignored, not 128 hex characters)"
	fi
fi

log() {
	printf 'bench: %s\n' "$*" >&2
}

die() {
	log "error: $*"
	exit 1
}

usage() {
	cat <<'EOF'
usage: bench [OPTIONS]

Runs the two profanity2 revisions baked into this image one after the other,
alternating A B A B, and reports how their speeds compare.

  --mode leading|exact  what to measure [default = leading]
  --seconds <n>         measured window per run, in seconds [default = 120]
  --warmup <n>          seconds dropped before the window opens [default = 30]
  --repeats <n>         how many times each revision runs [default = 2]
  --extra-args "<...>"  options handed to both revisions
                        [default = "-i 255 -I 16384 -w 64"]
  --mask <hex>          mask used by --mode exact [default = deadbee]
  --public-key <hex>    seed public key [default = the secp256k1 generator]
  -h, --help            this text

The same settings can be given as environment variables (BENCH_MODE,
BENCH_SECONDS, BENCH_WARMUP, BENCH_REPEATS, BENCH_EXTRA_ARGS,
BENCH_EXACT_MASK, BENCH_PUBLIC_KEY), which is the only way to configure the
run on platforms that replace the image entrypoint. A plain PUBLIC_KEY is used
too, but only when it holds 128 hexadecimal characters, because rental
platforms hand out that name for their own SSH key.

An argument that does not start with a dash is executed instead of the
benchmark, e.g. `clinfo` or `bash`.
EOF
}

cleanup() {
	local pids
	pids="$(jobs -p)"
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086
		kill $pids 2>/dev/null || true
	fi
}

label() {
	local slot="$1"
	printf '%s (%s)' "$(cat "$ROOT/$slot.ref")" "$(cat "$ROOT/$slot.sha")"
}

count_opencl_platforms() {
	local count=

	if command -v clinfo >/dev/null 2>&1; then
		count="$(clinfo -l 2>/dev/null | grep -c '^Platform #' || true)"

		case "$count" in
			''|0|*[!0-9]*)
				count="$(clinfo 2>/dev/null | awk '/^Number of platforms/ { print $NF; exit }' || true)"
				;;
		esac
	fi

	case "$count" in
		''|*[!0-9]*) count=0 ;;
	esac

	printf '%s\n' "$count"
}

# Reads speed samples on stdin, prints their median in hashes per second.
median() {
	sort -n | awk '
		{ v[NR] = $1 }
		END {
			if (NR == 0) { print 0; exit }
			if (NR % 2) { print v[(NR + 1) / 2] }
			else { print (v[NR / 2] + v[NR / 2 + 1]) / 2 }
		}'
}

# The speed counter is printed to stderr, overwriting itself with a carriage
# return roughly once per round, and formatted by Dispatcher::formatSpeed as a
# number followed by a unit out of " KMGT". Slice off everything written
# before the window opened, then normalize to hashes per second.
speeds_in_window() {
	local file="$1" offset="$2"

	tail -c "+$((offset + 1))" "$file" \
		| tr '\r' '\n' \
		| grep -oE 'Total: *[0-9.]+ *[KMGT]?H/s' \
		| awk '
			{
				match($0, /[0-9.]+/)
				v = substr($0, RSTART, RLENGTH) + 0
				if (index($0, "KH/s")) { v *= 1e3 }
				else if (index($0, "MH/s")) { v *= 1e6 }
				else if (index($0, "GH/s")) { v *= 1e9 }
				else if (index($0, "TH/s")) { v *= 1e12 }
				if (v > 0) { print v }
			}'
}

# Every hash matching the mask is printed, so the number of matches per second
# is a throughput measurement that does not go through the program's own
# timer: rate = matches / seconds * 16^(fixed nibbles).
matches_in_window() {
	local file="$1" offset="$2" nibbles="$3" seconds="$4"
	local count

	count="$(tail -c "+$((offset + 1))" "$file" | grep -c 'Private: 0x' || true)"
	awk -v c="$count" -v k="$nibbles" -v t="$seconds" \
		'BEGIN { printf "%.0f\n", c * (16 ^ k) / t }'
}

format_speed() {
	awk -v v="$1" 'BEGIN { printf "%.1f MH/s\n", v / 1e6 }'
}

wait_for_first_sample() {
	local file="$1" pid="$2" waited=0

	while [ "$waited" -lt "$STARTUP_TIMEOUT" ]; do
		if grep -qs 'Total:' "$file"; then
			return 0
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		sleep 2
		waited=$((waited + 2))
	done

	return 1
}

# Runs one revision once and prints the measured speed in hashes per second.
run_once() {
	local slot="$1"
	local dir="$ROOT/$slot"
	local out="/tmp/bench.$slot.out"
	local err="/tmp/bench.$slot.err"
	local args=()

	if [ "$MODE" = exact ]; then
		args=(--exact "$EXACT_MASK")
	else
		args=(--leading 0)
	fi

	: >"$out"
	: >"$err"

	# profanity2 reads keccak.cl and profanity.cl from the working directory
	# and caches the compiled kernel there, hence the cd into the revision's
	# own directory.
	# shellcheck disable=SC2086
	( cd "$dir" && exec ./profanity2.x64 "${args[@]}" -z "$SEED_KEY" $EXTRA_ARGS ) \
		>"$out" 2>"$err" &
	local pid=$!

	if ! wait_for_first_sample "$err" "$pid"; then
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		log "the run produced no speed samples, last output was:"
		tail -n 10 "$out" "$err" >&2 || true
		return 1
	fi

	sleep "$WARMUP"
	local out_offset err_offset
	out_offset="$(wc -c <"$out")"
	err_offset="$(wc -c <"$err")"

	sleep "$WINDOW"

	if ! kill -0 "$pid" 2>/dev/null; then
		log "the run stopped before the window closed, last output was:"
		tail -n 10 "$out" "$err" >&2 || true
		return 1
	fi

	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	if [ "$MODE" = exact ]; then
		matches_in_window "$out" "$out_offset" "$FIXED_NIBBLES" "$WINDOW"
	else
		speeds_in_window "$err" "$err_offset" | median
	fi
}

main() {
	trap cleanup EXIT

	case "$MODE" in
		leading|exact) ;;
		*) die "unknown mode '$MODE', expected 'leading' or 'exact'" ;;
	esac

	for value in "$WINDOW" "$WARMUP" "$REPEATS"; do
		case "$value" in
			''|*[!0-9]*) die "--seconds, --warmup and --repeats must be whole numbers" ;;
		esac
	done
	[ "$REPEATS" -ge 1 ] || die "--repeats must be at least 1"

	FIXED_NIBBLES="$(printf '%s' "$EXACT_MASK" | grep -o '[0-9a-fA-F]' | wc -l | tr -d ' ')"
	if [ "$MODE" = exact ] && { [ "$FIXED_NIBBLES" -lt 4 ] || [ "$FIXED_NIBBLES" -gt 10 ]; }; then
		die "--mask needs between 4 and 10 fixed hex characters, got $FIXED_NIBBLES"
	fi

	local platforms
	platforms="$(count_opencl_platforms)"
	if [ -n "${BENCH_SKIP_GPU_CHECK:-}" ]; then
		platforms=1
	fi
	if [ "$platforms" -eq 0 ]; then
		log "no OpenCL platform found inside the container"
		log "  installed ICDs: $(echo /etc/OpenCL/vendors/*.icd)"
		log "  start the container with GPU access (docker run --gpus all ...)"
		log "  or run this image with the argument \"clinfo\" to see what it finds"
		exit 1
	fi

	local describe="--leading 0"
	[ "$MODE" = exact ] && describe="--exact $EXACT_MASK"

	echo "profanity2 benchmark"
	echo "  A: $(label a)"
	echo "  B: $(label b)"
	echo "  workload: $describe $EXTRA_ARGS"
	echo "  window:   ${REPEATS} x ${WINDOW}s per revision, first ${WARMUP}s of each run dropped"
	echo "  order:    $(for _ in $(seq "$REPEATS"); do printf 'A B '; done)"
	echo "  key:      $KEY_SOURCE"
	if [ "$SEED_KEY" = "$GENERATOR_PUBLIC_KEY" ]; then
		echo "            a key everybody knows - never use a result from this run"
	fi
	echo

	local -A speeds=([a]="" [b]="")
	local repeat slot speed

	for repeat in $(seq "$REPEATS"); do
		for slot in a b; do
			log "run $repeat/$REPEATS, revision ${slot^^} ($(label "$slot"))"
			if ! speed="$(run_once "$slot")"; then
				die "revision ${slot^^} failed to produce a measurement"
			fi
			log "run $repeat/$REPEATS, revision ${slot^^}: $(format_speed "$speed")"
			speeds[$slot]="${speeds[$slot]} $speed"
		done
	done

	report "${speeds[a]}" "${speeds[b]}"
}

spread_pct() {
	# shellcheck disable=SC2086
	printf '%s\n' $1 | sort -n | awk '
		{ v[NR] = $1 }
		END {
			if (NR < 2 || v[1] == 0) { print "0.0"; exit }
			printf "%.1f", (v[NR] - v[1]) / v[1] * 100
		}'
}

report() {
	local a_runs="$1" b_runs="$2"
	local a_median b_median delta a_spread b_spread noise

	# shellcheck disable=SC2086
	a_median="$(printf '%s\n' $a_runs | median)"
	# shellcheck disable=SC2086
	b_median="$(printf '%s\n' $b_runs | median)"
	a_spread="$(spread_pct "$a_runs")"
	b_spread="$(spread_pct "$b_runs")"
	delta="$(awk -v a="$a_median" -v b="$b_median" \
		'BEGIN { if (a == 0) { print "n/a" } else { printf "%+.1f", (b / a - 1) * 100 } }')"
	noise="$(awk -v x="$a_spread" -v y="$b_spread" 'BEGIN { print (x > y) ? x : y }')"

	echo
	echo "=================== BENCHMARK RESULT ==================="
	printf 'A  %-24s median %-12s spread %s%%\n' "$(label a)" "$(format_speed "$a_median")" "$a_spread"
	printf '   runs:%s\n' "$(fmt_runs "$a_runs")"
	printf 'B  %-24s median %-12s spread %s%%\n' "$(label b)" "$(format_speed "$b_median")" "$b_spread"
	printf '   runs:%s\n' "$(fmt_runs "$b_runs")"
	echo
	echo "B vs A: ${delta}%"

	if awk -v n="$noise" -v d="$delta" \
		'BEGIN { exit !(d != "n/a" && n > 0 && n >= (d < 0 ? -d : d)) }'; then
		echo
		echo "warning: the difference is no larger than the spread between repeats of"
		echo "         the same revision (${noise}%), so it cannot be told apart from"
		echo "         noise - use a longer --seconds, more --repeats or another host"
	fi

	if [ "$MODE" = leading ] && [ "$(cat "$ROOT/timer.state")" = differs ]; then
		echo
		echo "warning: SpeedSample.cpp differs between the two revisions, so the two"
		echo "         numbers above were produced by different timers and are not"
		echo "         directly comparable. Rerun with --mode exact, which counts"
		echo "         matching addresses instead of trusting the program's clock."
	fi

	echo "========================================================"
	echo "BENCH_RESULT mode=$MODE a_hs=$a_median b_hs=$b_median delta_pct=$delta"
}

fmt_runs() {
	local run
	# shellcheck disable=SC2086
	for run in $1; do
		printf ' %s' "$(format_speed "$run")"
	done
}

if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
	exec "$@"
fi

while [ "$#" -gt 0 ]; do
	case "$1" in
		--mode) MODE="${2:?--mode needs a value}"; shift 2 ;;
		--seconds) WINDOW="${2:?--seconds needs a value}"; shift 2 ;;
		--warmup) WARMUP="${2:?--warmup needs a value}"; shift 2 ;;
		--repeats) REPEATS="${2:?--repeats needs a value}"; shift 2 ;;
		--extra-args) EXTRA_ARGS="${2:?--extra-args needs a value}"; shift 2 ;;
		--mask) EXACT_MASK="${2:?--mask needs a value}"; shift 2 ;;
		--public-key)
			SEED_KEY="${2:?--public-key needs a value}"
			KEY_SOURCE="--public-key"
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option '$1', try --help" ;;
	esac
done

main
