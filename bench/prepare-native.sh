#!/usr/bin/env bash
#
# Builds two revisions of profanity2 on this machine so that their speed can be
# compared without Docker. It does on the host what the src and build stages of
# bench/Dockerfile do inside the image, and lays the result out the way
# bench/run-benchmark.sh expects:
#
#   <workdir>/a/{profanity2.x64,keccak.cl,profanity.cl}
#   <workdir>/b/{profanity2.x64,keccak.cl,profanity.cl}
#   <workdir>/{a,b}.ref, <workdir>/{a,b}.sha, <workdir>/timer.state
#
# This is the only way to measure an Apple GPU: a container on macOS is a Linux
# virtual machine with no access to it.
#
# usage: bench/prepare-native.sh REF_A REF_B [OPTIONS]
#
#   REF_A, REF_B          anything the repository can resolve: a branch, a
#                         tag, a SHA, or pr/<number> for a pull request head
#   --repo <url|path>     repository to take the revisions from, cloned into a
#                         cache directory [default = the repository this
#                         script lives in, used as is]
#   --workdir <dir>       where to build [default = a directory under TMPDIR
#                         named after the two commits]
#   --force               rebuild even when the binaries are already there
#   -h, --help            this text
#
# The workdir is printed on the last line, so the two steps compose:
#
#   WORK=$(bench/prepare-native.sh 9011bcd pr57-head)
#   BENCH_ROOT=$WORK bench/run-benchmark.sh

set -euo pipefail

REPO="${BENCH_REPO:-}"
WORKDIR="${BENCH_WORKDIR:-}"
FORCE=0
REF_A=""
REF_B=""

tmp_root="${TMPDIR:-/tmp}"
readonly CACHE_ROOT="${tmp_root%/}/profanity2-bench"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	sed -n '/^# usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
}

log() {
	printf 'prepare-native.sh: %s\n' "$*" >&2
}

die() {
	printf 'prepare-native.sh: error: %s\n' "$*" >&2
	exit 1
}

sanitize() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
		--workdir) WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option '$1', try --help" ;;
		*)
			if [ -z "$REF_A" ]; then
				REF_A="$1"
			elif [ -z "$REF_B" ]; then
				REF_B="$1"
			else
				die "expected exactly two revisions, got a third: '$1'"
			fi
			shift
			;;
	esac
done

if [ -z "$REF_A" ] || [ -z "$REF_B" ]; then
	die "two revisions are required, try --help"
fi

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v make >/dev/null 2>&1 || die "make is not installed - run xcode-select --install on macOS"

# ---------------------------------------------------------------------------
# Where the revisions come from
# ---------------------------------------------------------------------------
# Without --repo the local repository is used directly: the commits are almost
# always already there, and nothing has to be downloaded. Only a clone is ever
# fetched into, so the user's own repository is never modified.
if [ -n "$REPO" ]; then
	SRC_REPO="$CACHE_ROOT/clones/$(sanitize "$REPO")"
	if git -C "$SRC_REPO" rev-parse --git-dir >/dev/null 2>&1; then
		log "updating the clone of $REPO"
		git -C "$SRC_REPO" fetch --quiet --tags origin || die "cannot fetch from $REPO"
	else
		log "cloning $REPO"
		mkdir -p "$(dirname "$SRC_REPO")"
		git clone --quiet --no-checkout "$REPO" "$SRC_REPO" || die "cannot clone $REPO"
	fi
	# Pull request heads live outside refs/heads and have to be asked for by
	# name, otherwise a commit that exists only in a pull request cannot be
	# resolved.
	git -C "$SRC_REPO" fetch --quiet origin '+refs/pull/*/head:refs/remotes/origin/pr/*' \
		|| log "warning: could not fetch pull request refs from $REPO"
else
	SRC_REPO="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" \
		|| die "$script_dir is not inside a git repository, pass --repo"
fi

resolve_ref() {
	local ref="$1"
	local candidate sha

	for candidate in "$ref" "origin/$ref" "refs/pull/${ref#pr/}/head"; do
		sha="$(git -C "$SRC_REPO" rev-parse --verify --quiet "${candidate}^{commit}" 2>/dev/null || true)"
		if [ -n "$sha" ]; then
			printf '%s\n' "$sha"
			return 0
		fi
	done

	return 1
}

die_unresolved() {
	local ref="$1"

	log "error: cannot resolve revision '$ref' in $SRC_REPO"
	case "$ref" in
		pr/*|pull/*)
			log "  a pull request head has to be fetched before it can be used:"
			log "    git -C $SRC_REPO fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'"
			log "  or take both revisions from a clone: --repo <url>"
			;;
		*)
			log "  a branch, tag or commit that this repository does not have"
			log "  has to come from a clone: --repo <url>"
			;;
	esac
	exit 1
}

SHA_A="$(resolve_ref "$REF_A")" || die_unresolved "$REF_A"
SHA_B="$(resolve_ref "$REF_B")" || die_unresolved "$REF_B"

SHORT_A="$(git -C "$SRC_REPO" rev-parse --short=7 "$SHA_A")"
SHORT_B="$(git -C "$SRC_REPO" rev-parse --short=7 "$SHA_B")"

if [ "$SHA_A" = "$SHA_B" ]; then
	die "both revisions resolve to $SHORT_A, there is nothing to compare"
fi

# Naming the workdir after the commits rather than the refs means a branch that
# moved gets a fresh directory instead of quietly reusing yesterday's build,
# and that rerunning the same pair skips the compilation.
if [ -z "$WORKDIR" ]; then
	WORKDIR="$CACHE_ROOT/${SHORT_A}__${SHORT_B}"
fi

log "A = $REF_A ($SHORT_A)"
log "B = $REF_B ($SHORT_B)"
log "repository = $SRC_REPO"
log "workdir    = $WORKDIR"

jobs_count="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# Each revision gets its own directory because profanity2 reads keccak.cl and
# profanity.cl from the working directory and caches the compiled kernel there
# as cache-opencl.*; sharing one directory would have the revisions run each
# other's kernel.
build_slot() {
	local slot="$1" ref="$2" sha="$3" short="$4"
	local src="$WORKDIR/src-$slot" dst="$WORKDIR/$slot"

	if [ "$FORCE" -eq 0 ] && [ -x "$dst/profanity2.x64" ]; then
		log "$slot: reusing the existing build of $short"
	else
		log "$slot: exporting $short"
		rm -rf "$src" "$dst"
		mkdir -p "$src" "$dst"
		# An export rather than a checkout, so that the working tree, its
		# stale object files and any uncommitted change stay out of the
		# build.
		git -C "$SRC_REPO" archive --format=tar "$sha" | tar -x -C "$src"

		log "$slot: building $short with make -j$jobs_count"
		make -C "$src" -j"$jobs_count" >&2 || die "$slot: build of $short failed"

		mkdir -p "$dst"
		cp "$src/profanity2.x64" "$src/keccak.cl" "$src/profanity.cl" "$dst/"
	fi

	printf '%s' "$ref" > "$WORKDIR/$slot.ref"
	printf '%s' "$short" > "$WORKDIR/$slot.sha"
}

mkdir -p "$WORKDIR"

build_slot a "$REF_A" "$SHA_A" "$SHORT_A"
build_slot b "$REF_B" "$SHA_B" "$SHORT_B"

# Whether the two revisions time a round the same way. If they do not, the
# speeds they print come from different clocks and the runner warns about it.
if git -C "$SRC_REPO" diff --quiet "$SHA_A" "$SHA_B" -- SpeedSample.cpp; then
	printf 'same\n' > "$WORKDIR/timer.state"
else
	printf 'differs\n' > "$WORKDIR/timer.state"
	log "warning: SpeedSample.cpp differs between the two revisions"
fi

log "ready, run the comparison with:"
log "  BENCH_ROOT=$WORKDIR $script_dir/run-benchmark.sh"

printf '%s\n' "$WORKDIR"
