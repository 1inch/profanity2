#!/usr/bin/env bash
#
# Entrypoint of the profanity2 container image.
#
# Arguments are passed straight to profanity2, which is what the "docker
# ENTRYPOINT" launch mode of vast.ai needs: whatever is typed into its
# Arguments field ends up here. Launch modes that replace the entrypoint
# (SSH/Jupyter) only offer environment variables, so the same options can be
# given through PROFANITY_ARGS and PUBLIC_KEY instead.
#
#   PROFANITY_PUBLIC_KEY  seed public key, added as `-z` unless already given
#   PUBLIC_KEY            same, but only when it holds 128 hexadecimal
#                         characters - GPU rental platforms hand out that name
#                         for their own SSH key
#   PROFANITY_ARGS        arguments to use when none are passed on the command
#                         line, split on whitespace (no shell quoting)
#   PROFANITY_OUTPUT      file the output is copied to, empty value disables it
#                         [default = /workspace/profanity2.log]
#   PROFANITY_TIMEOUT     stop after this long, e.g. 30m or 6h (exit code 124)
#   PROFANITY_SKIP_GPU_CHECK  skip the OpenCL device check before starting

set -euo pipefail

readonly BINARY=/opt/profanity2/profanity2.x64

log() {
	printf 'profanity2-entrypoint: %s\n' "$*" >&2
}

count_opencl_platforms() {
	local count=

	if command -v clinfo >/dev/null 2>&1; then
		count="$(clinfo -l 2>/dev/null | grep -c '^Platform #' || true)"

		# Older clinfo releases format the compact listing differently, so fall
		# back to the summary line of the full report before giving up.
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

no_opencl_platform() {
	log "error: no OpenCL platform found inside the container"
	log ""
	log "  installed ICDs: $(echo /etc/OpenCL/vendors/*.icd)"
	log "  libnvidia-opencl.so.1: $(ldconfig -p | grep -c libnvidia-opencl.so.1) entries in the linker cache"
	log ""
	log "  The container is running without a usable GPU driver. Start it with the"
	log "  NVIDIA runtime (docker run --gpus all ...) and keep \"compute\" in"
	log "  NVIDIA_DRIVER_CAPABILITIES. On vast.ai make sure the offer has an NVIDIA"
	log "  GPU. Run this image with the argument \"clinfo\" for the full diagnosis,"
	log "  or set PROFANITY_SKIP_GPU_CHECK=1 to start anyway."
}

args=("$@")

# Anything that does not look like a profanity2 option (they all start with a
# dash) is treated as a command to run instead, e.g. `clinfo` or `bash`.
if [ ${#args[@]} -gt 0 ] && [ "${args[0]#-}" = "${args[0]}" ]; then
	exec "${args[@]}"
fi

if [ ${#args[@]} -eq 0 ] && [ -n "${PROFANITY_ARGS:-}" ]; then
	read -r -a args <<<"$PROFANITY_ARGS"
fi

if [ ${#args[@]} -eq 0 ]; then
	log "no arguments given, printing help"
	log "pass the scoring mode as container arguments or in PROFANITY_ARGS"
	args=(--help)
fi

wants_help=0
has_public_key=0
for arg in "${args[@]}"; do
	case "$arg" in
		-h|--help) wants_help=1 ;;
		-z|--publicKey) has_public_key=1 ;;
	esac
done

public_key="${PROFANITY_PUBLIC_KEY:-}"
if [ -z "$public_key" ] && [ -n "${PUBLIC_KEY:-}" ]; then
	if printf '%s' "$PUBLIC_KEY" | grep -qE '^[0-9a-fA-F]{128}$'; then
		public_key="$PUBLIC_KEY"
	else
		log "warning: ignoring PUBLIC_KEY, it does not hold 128 hexadecimal characters"
		log "         rental platforms set that name to their own SSH key; use"
		log "         PROFANITY_PUBLIC_KEY, or pass -z, to be unambiguous"
	fi
fi

if [ "$has_public_key" -eq 0 ] && [ -n "$public_key" ]; then
	args+=(-z "$public_key")
fi

if [ "$wants_help" -eq 0 ] && [ -z "${PROFANITY_SKIP_GPU_CHECK:-}" ]; then
	platforms="$(count_opencl_platforms)"

	if [ "$platforms" -eq 0 ]; then
		no_opencl_platform
		exit 1
	fi

	log "OpenCL platforms found: $platforms"
fi

cmd=("$BINARY" "${args[@]}")
if [ -n "${PROFANITY_TIMEOUT:-}" ]; then
	log "run time limited to $PROFANITY_TIMEOUT"
	cmd=(timeout "$PROFANITY_TIMEOUT" "${cmd[@]}")
fi

output="${PROFANITY_OUTPUT-/workspace/profanity2.log}"
if [ "$wants_help" -eq 1 ]; then
	output=
fi

if [ -n "$output" ]; then
	if mkdir -p "$(dirname "$output")" 2>/dev/null && touch "$output" 2>/dev/null; then
		log "results are also appended to $output"
	else
		log "warning: $output is not writable, results only go to the container log"
		output=
	fi
fi

log "running: profanity2.x64 ${args[*]}"

if [ -n "$output" ]; then
	# Only stdout is copied: the hashrate counter is printed to stderr with
	# carriage returns and would fill the file with terminal escapes.
	"${cmd[@]}" | tee -a "$output"
else
	exec "${cmd[@]}"
fi
