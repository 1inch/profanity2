# Building and running on Windows

The repository ships with a `Makefile` written for Unix-like environments, so the
easiest way to build on Windows is the [MSYS2](https://www.msys2.org/) environment,
which provides `g++`, `make` and prebuilt OpenCL packages. Plain MinGW or `g++`
called from `cmd.exe`/Git Bash will fail with errors like
`CL/cl.h: No such file or directory` or
`process_begin: CreateProcess(NULL, uname -s, ...) failed` — use MSYS2 instead.

## Option A (recommended): MSYS2 / MinGW-w64

### 1. Install MSYS2

Download and install from [msys2.org](https://www.msys2.org/), then open the
**"MSYS2 UCRT64"** shell (not the plain "MSYS2 MSYS" one).

### 2. Install the toolchain and OpenCL packages

```bash
pacman -Syu
pacman -S --needed make mingw-w64-ucrt-x86_64-gcc \
                   mingw-w64-ucrt-x86_64-opencl-headers \
                   mingw-w64-ucrt-x86_64-opencl-icd
```

- `opencl-headers` provides `CL/cl.h`;
- `opencl-icd` provides the import library for `OpenCL.dll`, the system OpenCL
  loader that dispatches to your GPU driver at runtime.

### 3. Build

From the repository root inside the UCRT64 shell:

```bash
g++ -std=c++11 -Wall -O2 Dispatcher.cpp Mode.cpp precomp.cpp profanity.cpp SpeedSample.cpp \
    -lOpenCL -o profanity2.exe
```

> Note: the stock `Makefile` passes `-mcmodel=large`, which some MinGW builds of
> GCC do not support. The direct command above builds the same sources without it;
> alternatively run `make CFLAGS="-c -std=c++11 -Wall -O2" LDFLAGS="-lOpenCL -s" EXECUTABLE=profanity2.exe`.

### 4. Run

Your GPU driver must be installed (NVIDIA and AMD drivers include the OpenCL
runtime on Windows). Then:

```bash
./profanity2.exe --leading 0 -z HEX_PUBLIC_KEY_128_CHARS_LONG
```

If you launch `profanity2.exe` outside the MSYS2 shell (e.g. from Explorer or
`cmd.exe`) and get missing-DLL errors, copy the required runtime DLLs
(`libstdc++-6.dll`, `libgcc_s_seh-1.dll`, `libwinpthread-1.dll`) from
`C:\msys64\ucrt64\bin` next to the executable, or link statically by adding
`-static` to the build command.

## Option B: linking against a vendor OpenCL SDK

If you prefer not to install the MSYS2 OpenCL packages, any vendor OpenCL SDK
works, e.g. the [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads)
(NVIDIA) or the [OpenCL SDK](https://github.com/KhronosGroup/OpenCL-SDK/releases)
(any vendor). Point the compiler at the SDK's include and library directories:

```bash
g++ -std=c++11 -Wall -O2 \
    -I"C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.4/include" \
    -L"C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.4/lib/x64" \
    Dispatcher.cpp Mode.cpp precomp.cpp profanity.cpp SpeedSample.cpp \
    -lOpenCL -o profanity2.exe
```

## What about WSL2?

Building under WSL2 works (follow the [Ubuntu instructions](BUILD_UBUNTU.md)), but
**GPU OpenCL devices are generally not available inside WSL2** — the GPU
paravirtualization exposes CUDA/DirectML but not a full OpenCL stack, so
profanity2 will print an empty device list. Build natively with MSYS2 instead.

## Troubleshooting

| Symptom | Fix | Seen in |
|---|---|---|
| `fatal error: CL/cl.h: No such file or directory` | OpenCL headers not installed / not in include path — see steps above | [#31](https://github.com/1inch/profanity2/issues/31), [#27](https://github.com/1inch/profanity2/issues/27), [#23](https://github.com/1inch/profanity2/issues/23), [#20](https://github.com/1inch/profanity2/issues/20) |
| `process_begin: CreateProcess(NULL, uname -s, ...) failed` | You ran `make` outside an MSYS2 shell; use the MSYS2 UCRT64 shell or the direct `g++` command | [#26](https://github.com/1inch/profanity2/issues/26), [#21](https://github.com/1inch/profanity2/issues/21) |
| `cannot find -lOpenCL` | Install `mingw-w64-ucrt-x86_64-opencl-icd` or pass `-L<path to OpenCL.lib/libOpenCL.dll.a>` | |
| Output stops after `Devices:` (empty list) | Install/update your GPU driver; don't run under WSL2 | [#17](https://github.com/1inch/profanity2/issues/17) |
| `error: code model 'large' not supported` | Build without `-mcmodel=large` (see the note in step 3) | |
