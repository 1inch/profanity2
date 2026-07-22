# Building and running on Ubuntu / Linux

These instructions are written for Ubuntu 20.04+, but apply to any Debian-like
distribution. For other distributions replace `apt` packages with their
equivalents.

## 1. Install build dependencies

```bash
sudo apt update
sudo apt install -y build-essential opencl-headers ocl-icd-opencl-dev clinfo
```

- `build-essential` — `g++` and `make`;
- `opencl-headers` — the `CL/cl.h` header;
- `ocl-icd-opencl-dev` — the `libOpenCL.so` loader that the binary links against (`-lOpenCL`);
- `clinfo` — a diagnostic tool that lists available OpenCL devices.

## 2. Install an OpenCL runtime for your GPU

The packages above only provide the build-time dependencies. To actually *run*
profanity2 you need the OpenCL driver (ICD) of your GPU vendor:

### NVIDIA

The proprietary NVIDIA driver already includes the OpenCL runtime:

```bash
sudo ubuntu-drivers install        # or: sudo apt install nvidia-driver-550
```

If devices still don't show up (common on cloud/headless instances), install the
CUDA toolkit, which ships the OpenCL ICD as well:

```bash
sudo apt install -y nvidia-cuda-toolkit
```

On container platforms (Docker, RunPod, vast.ai etc.) make sure the OpenCL ICD is
registered inside the container:

```bash
sudo mkdir -p /etc/OpenCL/vendors
echo "libnvidia-opencl.so.1" | sudo tee /etc/OpenCL/vendors/nvidia.icd
```

### AMD

Install a recent [ROCm](https://rocm.docs.amd.com/) release; old drivers are known to
miscompile the OpenCL kernel and produce invalid keys (see issue
[#13](https://github.com/1inch/profanity2/issues/13)):

```bash
sudo apt install -y rocm-opencl-runtime
```

### Intel (integrated graphics)

```bash
sudo apt install -y intel-opencl-icd
```

## 3. Verify OpenCL sees your GPU

```bash
clinfo
```

`clinfo` must list at least one platform and device. If it prints
`Number of platforms 0`, profanity2 will not find any devices either — fix the
driver installation first.

## 4. Build

```bash
make
```

This produces the `profanity2.x64` executable in the repository root.

## 5. Run

```bash
./profanity2.x64 --leading 0 -z HEX_PUBLIC_KEY_128_CHARS_LONG
```

See the [README](../README.md) for how to generate the public key for the `-z`
parameter and for usage examples of all scoring modes.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `fatal error: CL/cl.h: No such file or directory` | `sudo apt install opencl-headers` |
| `/usr/bin/ld: cannot find -lOpenCL` | `sudo apt install ocl-icd-opencl-dev` |
| Output stops after `Devices:` (empty list) | No OpenCL runtime installed — see step 2, verify with `clinfo` |
| Garbage device name, `unknown exception occured` | Broken/mismatched GPU driver — reinstall the vendor driver |
| Works but private keys don't match addresses (AMD) | Update to a recent ROCm driver (see issue [#13](https://github.com/1inch/profanity2/issues/13)) |
