# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        opencl-headers \
        ocl-icd-opencl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Makefile ./
COPY *.cpp *.hpp *.cl ./
RUN make -j"$(nproc)"

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

LABEL org.opencontainers.image.title="profanity2" \
      org.opencontainers.image.description="GPU vanity address generator for Ethereum (OpenCL)" \
      org.opencontainers.image.source="https://github.com/1inch/profanity2" \
      org.opencontainers.image.licenses="MIT"

# ocl-icd-libopencl1 is the ICD loader the binary links against, clinfo is kept
# for diagnosing "no devices found" on rented machines.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ocl-icd-libopencl1 \
        clinfo \
    && rm -rf /var/lib/apt/lists/*

# The NVIDIA container runtime mounts libnvidia-opencl.so.1 into the container
# but does not register it with the ICD loader, so the vendor file has to be
# part of the image:
# https://github.com/NVIDIA/nvidia-container-toolkit/issues/682
RUN mkdir -p /etc/OpenCL/vendors \
    && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

# compute enables the OpenCL driver libraries, utility enables nvidia-smi.
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# profanity2 loads keccak.cl/profanity.cl and stores its compiled kernel cache
# relative to the working directory, so the binary has to run from here.
WORKDIR /opt/profanity2
COPY --from=build /src/profanity2.x64 /src/keccak.cl /src/profanity.cl ./
COPY LICENSE ./
COPY docker/entrypoint.sh /usr/local/bin/profanity2-entrypoint
RUN chmod +x /usr/local/bin/profanity2-entrypoint && mkdir -p /workspace

ENTRYPOINT ["/usr/local/bin/profanity2-entrypoint"]
