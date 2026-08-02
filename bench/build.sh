#!/usr/bin/env bash
#
# Builds a benchmark image containing two revisions of profanity2.
#
# usage: bench/build.sh REF_A REF_B [OPTIONS]
#
#   REF_A, REF_B          anything the repository can resolve: a branch, a
#                         tag, a SHA, or pr/<number> for a pull request head
#   --repo <url>          repository to build from
#                         [default = https://github.com/1inch/profanity2]
#   --platform <p>        target platform [default = linux/amd64]
#   --tag <name>          local image tag [default = derived from the SHAs]
#   -h, --help            this text
#
# The image name is printed on the last line so the script can be used from
# other scripts:
#
#   IMAGE=$(bench/build.sh master pr/57 | tail -1)

set -euo pipefail

REPO="${BENCH_REPO:-https://github.com/1inch/profanity2}"
# vast.ai and every other GPU rental platform worth using is x86_64, and the
# Linux branch of the Makefile passes -mmmx and -mcmodel=large, which do not
# exist on arm64. Building for amd64 on an Apple Silicon machine goes through
# emulation and takes a few minutes.
PLATFORM="${BENCH_PLATFORM:-linux/amd64}"
TAG=""
REF_A=""
REF_B=""

usage() {
	sed -n '/^# usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
}

die() {
	printf 'build.sh: error: %s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
		--platform) PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
		--tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
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

[ -n "$REF_A" ] && [ -n "$REF_B" ] || die "two revisions are required, try --help"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sanitize() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '-'
}

if [ -z "$TAG" ]; then
	TAG="profanity2-bench:$(sanitize "$REF_A")__$(sanitize "$REF_B")"
fi

# A branch moves, a SHA does not. Without this the layer cache would happily
# rebuild yesterday's master and report it as today's.
cachebust=""
for ref in "$REF_A" "$REF_B"; do
	if ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
		cachebust="$(date +%s)"
		break
	fi
done

printf 'build.sh: building %s\n' "$TAG" >&2
printf 'build.sh:   A = %s\n' "$REF_A" >&2
printf 'build.sh:   B = %s\n' "$REF_B" >&2
printf 'build.sh:   repository = %s, platform = %s\n' "$REPO" "$PLATFORM" >&2

docker build \
	--platform "$PLATFORM" \
	--build-arg "REPO=$REPO" \
	--build-arg "REF_A=$REF_A" \
	--build-arg "REF_B=$REF_B" \
	--build-arg "CACHEBUST=$cachebust" \
	--tag "$TAG" \
	--file "$script_dir/Dockerfile" \
	"$script_dir" >&2

printf '%s\n' "$TAG"
