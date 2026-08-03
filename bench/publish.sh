#!/usr/bin/env bash
#
# Pushes a benchmark image to a registry a rented machine can pull from, and
# prints its name.
#
# usage: bench/publish.sh REF_A REF_B [OPTIONS]
#        bench/publish.sh --image LOCAL_TAG [OPTIONS]
#
#   --registry <host[/owner]>  where to push, e.g. ghcr.io/YOUR_USER or ttl.sh
#                              (also read from BENCH_REGISTRY)
#   --name <repo:tag>          name to push under, overrides the default
#   --ttl <5m|1h|24h>          lifetime on ttl.sh, ignored elsewhere
#                              [default = 24h]
#   --image <tag>              publish an already built local image
#   --repo <url>               passed to build.sh
#   --platform <p>             passed to build.sh
#   -h, --help                 this text
#
# The name is chosen to suit the registry. On ttl.sh the tag is the lifetime,
# so the image needs a unique random name and expires by itself. Everywhere
# else the local tag is reused, which keeps one repository with one tag per
# pair of revisions.

set -euo pipefail

TTL="24h"
REGISTRY="${BENCH_REGISTRY:-}"
NAME=""
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

random_name() {
	if command -v uuidgen >/dev/null 2>&1; then
		uuidgen | tr '[:upper:]' '[:lower:]'
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import uuid; print(uuid.uuid4())'
	else
		od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
	fi
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--registry) REGISTRY="${2:?--registry needs a value}"; shift 2 ;;
		--name) NAME="${2:?--name needs a value}"; shift 2 ;;
		--ttl) TTL="${2:?--ttl needs a value}"; shift 2 ;;
		--image) LOCAL_TAG="${2:?--image needs a value}"; shift 2 ;;
		--repo) BUILD_ARGS+=(--repo "${2:?--repo needs a value}"); shift 2 ;;
		--platform) BUILD_ARGS+=(--platform "${2:?--platform needs a value}"); shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option '$1', try --help" ;;
		*) REFS+=("$1"); shift ;;
	esac
done

REGISTRY="${REGISTRY%/}"

if [ -z "$REGISTRY" ]; then
	printf 'publish.sh: error: no registry given, pick one:\n' >&2
	printf '  --registry ghcr.io/YOUR_USER   keeps the image, needs docker login ghcr.io\n' >&2
	printf '  --registry ttl.sh              anonymous, expires after --ttl\n' >&2
	exit 1
fi

case "$REGISTRY" in
	ghcr.io|docker.io)
		die "$REGISTRY needs your account in the path, e.g. --registry $REGISTRY/YOUR_USER"
		;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$LOCAL_TAG" ]; then
	[ "${#REFS[@]}" -eq 2 ] || die "two revisions are required, try --help"
	LOCAL_TAG="$("$script_dir/build.sh" "${REFS[@]}" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} | tail -1)"
	[ -n "$LOCAL_TAG" ] || die "the build produced no image"
fi

if [ -z "$NAME" ]; then
	case "$REGISTRY" in
		ttl.sh|*.ttl.sh) NAME="profanity2-bench-$(random_name):$TTL" ;;
		*) NAME="${LOCAL_TAG##*/}" ;;
	esac
fi

remote="$REGISTRY/$NAME"

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
