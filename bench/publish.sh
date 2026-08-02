#!/usr/bin/env bash
#
# Publishes a benchmark image to ttl.sh, an anonymous registry that deletes
# what you push after the time given in the tag, and prints its name.
#
# usage: bench/publish.sh REF_A REF_B [OPTIONS]
#        bench/publish.sh --image LOCAL_TAG [OPTIONS]
#
#   --ttl <5m|1h|24h>     how long the image stays on ttl.sh [default = 24h]
#   --registry <host>     registry to push to [default = ttl.sh]
#   --image <tag>         publish an already built local image
#   --repo <url>          passed to build.sh
#   --platform <p>        passed to build.sh
#   -h, --help            this text
#
# On ttl.sh the tag is the lifetime, so the image name has to be unique - the
# script generates a random one. Anyone who learns that name can pull the
# image, which is harmless here: it holds nothing but public source code.

set -euo pipefail

TTL="24h"
REGISTRY="${BENCH_REGISTRY:-ttl.sh}"
LOCAL_TAG=""
REFS=()
BUILD_ARGS=()

usage() {
	sed -n '/^# usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
}

die() {
	printf 'publish.sh: error: %s\n' "$*" >&2
	exit 1
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--ttl) TTL="${2:?--ttl needs a value}"; shift 2 ;;
		--registry) REGISTRY="${2:?--registry needs a value}"; shift 2 ;;
		--image) LOCAL_TAG="${2:?--image needs a value}"; shift 2 ;;
		--repo) BUILD_ARGS+=(--repo "${2:?--repo needs a value}"); shift 2 ;;
		--platform) BUILD_ARGS+=(--platform "${2:?--platform needs a value}"); shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option '$1', try --help" ;;
		*) REFS+=("$1"); shift ;;
	esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$LOCAL_TAG" ]; then
	[ "${#REFS[@]}" -eq 2 ] || die "two revisions are required, try --help"
	LOCAL_TAG="$("$script_dir/build.sh" "${REFS[@]}" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} | tail -1)"
	[ -n "$LOCAL_TAG" ] || die "the build produced no image"
fi

random_name() {
	if command -v uuidgen >/dev/null 2>&1; then
		uuidgen | tr 'A-Z' 'a-z'
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import uuid; print(uuid.uuid4())'
	else
		od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
	fi
}

remote="$REGISTRY/profanity2-bench-$(random_name):$TTL"

printf 'publish.sh: pushing %s as %s\n' "$LOCAL_TAG" "$remote" >&2
docker tag "$LOCAL_TAG" "$remote"
docker push "$remote" >&2

cat <<EOF

IMAGE: $remote

Rent a GPU and run it, entrypoint mode, no SSH needed:

  vastai create instance <OFFER_ID> --image $remote --disk 12 --args --mode leading

Locally, on a machine with an NVIDIA GPU:

  docker run --rm --gpus all $remote

EOF

printf '%s\n' "$remote"
