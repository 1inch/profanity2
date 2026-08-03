# syntax=docker/dockerfile:1
#
# Builds a self-contained image holding two revisions of profanity2 so their
# speed can be compared back to back on the same GPU. This image is a
# measuring tool, not the shipping image - see the Dockerfile in the
# repository root for that one.
#
#   docker build --build-arg REF_A=master --build-arg REF_B=pr/57 -t bench bench/
#
# REF_A and REF_B accept anything the clone can resolve: a branch, a tag, a
# full or short SHA, or pr/<number> for the head of a pull request.

# ---------------------------------------------------------------------------
# Export both revisions
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS src

ARG REPO=https://github.com/1inch/profanity2
ARG REF_A
ARG REF_B
# Changed by bench/build.sh whenever a revision is mutable (a branch), so that
# a moving branch is not silently served from the layer cache.
ARG CACHEBUST=

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

# Pull request heads live outside refs/heads and have to be fetched
# explicitly, otherwise a commit that only exists in a pull request cannot be
# resolved. The last step records whether the two revisions time a round the
# same way: if they do not, the speeds they print come from different clocks
# and the runner has to warn about it.
RUN set -eu; \
    echo "cachebust: ${CACHEBUST}"; \
    test -n "${REF_A}" || { echo "error: REF_A build argument is empty" >&2; exit 1; }; \
    test -n "${REF_B}" || { echo "error: REF_B build argument is empty" >&2; exit 1; }; \
    git clone --quiet --no-checkout "${REPO}" /repo; \
    git -C /repo fetch --quiet origin '+refs/pull/*/head:refs/remotes/origin/pr/*' || \
        echo "warning: could not fetch pull request refs from ${REPO}" >&2; \
    for slot_ref in "a:${REF_A}" "b:${REF_B}"; do \
        slot="${slot_ref%%:*}"; \
        ref="${slot_ref#*:}"; \
        sha="$(git -C /repo rev-parse --verify --quiet "${ref}^{commit}" \
            || git -C /repo rev-parse --verify --quiet "origin/${ref}^{commit}" \
            || true)"; \
        if [ -z "${sha}" ]; then \
            echo "error: cannot resolve revision '${ref}' in ${REPO}" >&2; \
            exit 1; \
        fi; \
        mkdir -p "/src/${slot}"; \
        git -C /repo archive --format=tar "${sha}" | tar -x -C "/src/${slot}"; \
        printf '%s' "${ref}" > "/src/${slot}.ref"; \
        git -C /repo rev-parse --short=7 "${sha}" > "/src/${slot}.sha"; \
        echo "${slot}: ${ref} -> ${sha}"; \
    done; \
    if cmp -s /src/a/SpeedSample.cpp /src/b/SpeedSample.cpp; then \
        echo same > /src/timer.state; \
    else \
        echo differs > /src/timer.state; \
    fi

# ---------------------------------------------------------------------------
# Compile both revisions
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        opencl-headers \
        ocl-icd-opencl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=src /src /src
RUN make -C /src/a -j"$(nproc)" && make -C /src/b -j"$(nproc)"

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

LABEL org.opencontainers.image.title="profanity2-bench" \
      org.opencontainers.image.description="Compares the speed of two profanity2 revisions on one GPU" \
      org.opencontainers.image.source="https://github.com/1inch/profanity2" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ocl-icd-libopencl1 \
        clinfo \
    && rm -rf /var/lib/apt/lists/*

# The NVIDIA container runtime mounts libnvidia-opencl.so.1 but does not
# register it with the ICD loader:
# https://github.com/NVIDIA/nvidia-container-toolkit/issues/682
RUN mkdir -p /etc/OpenCL/vendors \
    && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Each revision keeps its own directory: profanity2 loads keccak.cl and
# profanity.cl from the working directory and caches the compiled kernel
# there, so the two builds must never share one.
COPY --from=build /src/a/profanity2.x64 /src/a/keccak.cl /src/a/profanity.cl /opt/bench/a/
COPY --from=build /src/b/profanity2.x64 /src/b/keccak.cl /src/b/profanity.cl /opt/bench/b/
COPY --from=src /src/a.ref /src/a.sha /src/b.ref /src/b.sha /src/timer.state /opt/bench/

COPY run-benchmark.sh /usr/local/bin/bench
RUN chmod +x /usr/local/bin/bench

WORKDIR /opt/bench
ENTRYPOINT ["/usr/local/bin/bench"]
