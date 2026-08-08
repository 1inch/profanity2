# Comparing the speed of two profanity2 revisions

This directory builds a **separate image** from the one in [docker/](../docker/Dockerfile). That one ships profanity2; this one measures it. It contains two revisions of profanity2 side by side and runs them alternately on the same GPU, so a change can be judged without trusting that two rented machines are equally fast.

There are two ways to put the two revisions side by side. [bench/build.sh](build.sh) bakes them into an image for a rented NVIDIA GPU, which is the rest of this document; [bench/prepare-native.sh](prepare-native.sh) builds them on the machine you are sitting at, which is the only way to measure an Apple GPU - see [Running natively](#running-natively-no-docker). Both then hand over to the same [run-benchmark.sh](run-benchmark.sh).

The result of a run looks like this:

```
=================== BENCHMARK RESULT ===================
A  master (069d100)         median 1390.4 MH/s  spread 0.3%
   runs: 1392.6 MH/s 1388.1 MH/s
B  pr/57 (aad8e13)          median 1212.7 MH/s  spread 0.4%
   runs: 1210.3 MH/s 1215.0 MH/s

B vs A: -12.8%
========================================================
BENCH_RESULT mode=leading a_hs=1390400000 b_hs=1212700000 delta_pct=-12.8
```

## Publishing to GHCR

The GitHub Container Registry is the place to put the image if you are going to run more than one comparison: the image stays until you delete it, the name is readable, and pushing costs nothing.

Create a personal access token with the `write:packages` scope, log in once, then build and push:

```bash
echo YOUR_TOKEN | docker login ghcr.io -u YOUR_USER --password-stdin
bench/publish.sh master pr/57 --registry ghcr.io/YOUR_USER
```

The script prints the full image name, which is derived from the two revisions:

```
IMAGE: ghcr.io/YOUR_USER/profanity2-bench:master__pr-57
```

A package pushed to GHCR is **private by default**, so a rented machine cannot pull it yet. Either make it public once, under Packages on your GitHub profile, or hand the credentials to vast.ai:

```bash
# public package
vastai create instance <OFFER_ID> --image ghcr.io/YOUR_USER/profanity2-bench:master__pr-57 \
    --disk 12 --args --mode leading

# private package
vastai create instance <OFFER_ID> --image ghcr.io/YOUR_USER/profanity2-bench:master__pr-57 \
    --login '-u YOUR_USER -p YOUR_TOKEN ghcr.io' --disk 12 --args --mode leading
```

Pushing the same pair of revisions again overwrites the same tag, so the registry does not fill up with junk. Use `--name` if you want to keep several builds of one pair side by side:

```bash
bench/publish.sh master pr/57 --registry ghcr.io/YOUR_USER --name profanity2-bench:run-2
```

## Publishing to ttl.sh

[ttl.sh](https://ttl.sh) is an anonymous registry that deletes what you push after the time given in the tag. No account, no login, no cleanup - useful for a one-off comparison or when you do not want to bother with tokens:

```bash
bench/publish.sh master pr/57 --registry ttl.sh --ttl 24h
```

```
IMAGE: ttl.sh/profanity2-bench-1f0c9a3e-...:24h
```

On ttl.sh the tag is the lifetime and the maximum is 24 hours, so the image needs a unique name instead - the script generates a random one. Anyone who learns that name can pull the image, which is harmless here: it holds nothing but public source code. Do keep the lifetime longer than your experiment, because a machine that has to pull the image again after it expired will fail to start.

## What can be passed as a revision

Anything a clone of the repository can resolve:

| Revision | Meaning |
|---|---|
| `master`, `v1.2` | branch or tag |
| `9011bcd`, full SHA | any commit, including one that only exists in a pull request |
| `pr/57` | the head of pull request 57 |

Pull request heads are fetched explicitly during the build, which is why a commit like `9011bcd` resolves even though it never landed on a branch.

Both revisions are compiled inside the image from a fresh clone, so your working tree, your local branches and your uncommitted changes play no part. Point the build at a fork with `--repo`:

```bash
bench/build.sh master pr/57 --repo https://github.com/YOUR_USER/profanity2
```

A native build resolves the same set of revisions, but reads the local repository rather than a clone, so a local branch works as a revision too and `--repo` is only needed for a fork or for pull request refs you never fetched.

## Running it

```bash
# build only, prints the local tag on the last line
bench/build.sh master pr/57

# push an image that is already built
bench/publish.sh --image profanity2-bench:master__pr-57 --registry ghcr.io/YOUR_USER

# on your own machine, if it has an NVIDIA GPU
docker run --rm --gpus all profanity2-bench:master__pr-57
```

The image is built for `linux/amd64` by default because the Linux branch of the Makefile passes `-mmmx` and `-mcmodel=large`, which do not exist on arm64, and because GPU rental platforms are x86_64 anyway. On Apple Silicon the build therefore runs under emulation and takes a few minutes.

## Running natively (no Docker)

On macOS a container is a Linux virtual machine, and the Apple GPU is not passed into it: there is no counterpart to the NVIDIA Container Toolkit, the Ubuntu base image cannot reach `OpenCL.framework` on the host, and this directory's Dockerfile registers the NVIDIA ICD in any case. Rebuilding the image for `linux/arm64` changes the CPU architecture and nothing else, so a container on a Mac measures at best a CPU OpenCL runtime. To compare two revisions on an Apple GPU, build them on the host:

```bash
WORK=$(bench/prepare-native.sh 9011bcd pr57-head)
BENCH_ROOT=$WORK bench/run-benchmark.sh --mode leading --repeats 3
```

[prepare-native.sh](prepare-native.sh) does on the host what the `src` and `build` stages of the Dockerfile do inside the image: it resolves both revisions, exports each one with `git archive`, runs `make` in it, and leaves the layout the runner expects.

```
<workdir>/a/{profanity2.x64,keccak.cl,profanity.cl}
<workdir>/b/{profanity2.x64,keccak.cl,profanity.cl}
<workdir>/{a,b}.ref, <workdir>/{a,b}.sha, <workdir>/timer.state
```

By default the revisions come from **the local repository, used as is** - a commit you already have needs no network, and an export rather than a checkout keeps your working tree and its stale object files out of the build. `--repo <url>` clones instead, which is what a `pr/<number>` revision needs when its refs were never fetched. The workdir sits under `TMPDIR` and is named after the two commits, so rerunning the same pair skips the compilation; `--force` rebuilds anyway.

The runner is the same script the image runs, so everything under [Options](#options) and [Getting a number that means something](#getting-a-number-that-means-something) applies unchanged. It only needs `BENCH_ROOT`, which is the one thing `prepare-native.sh` prints on stdout.

Nothing here is macOS-only: on a Linux box with a working OpenCL runtime the same two commands compare two revisions without building an image.

### What to watch for on a Mac

**`clinfo` is usually not installed**, and macOS has no ICD loader to interrogate. The runner treats a Darwin host without `clinfo` as having one platform and lets profanity2's own device enumeration be the real check - a machine with no usable device fails at the first run with its output printed. Install `clinfo` from Homebrew if you want the check back.

**Thermal throttling is the thing most likely to ruin the result.** A laptop that heats up during the second half of a comparison hands the penalty to whichever revision ran last, which is exactly what the alternating A B A B order and the reported `spread` exist to expose. Keep the machine plugged in, and if the spread comes out anywhere near the difference between the revisions, the runner says so and the answer is more `--repeats` or a longer `--seconds`.

**Check the work size once.** The default `-w 64` is accepted by an M4 Max, but on a GPU that rejects it profanity2 prints `warning: local work size abandoned on GPU0` and lets the driver choose. That is not fatal, but it has to happen for both revisions or the comparison is between two different work sizes - the warning goes to stdout, so a short run with `--seconds 20 --warmup 10 --repeats 1` is the cheapest way to see it before committing to the full run.

**The MH/s figure is not comparable to the NVIDIA table** in the root [README](../README.md#benchmarks---current-version). What a native run gives you is A against B on one machine.

## Options

Everything has a flag and an environment variable; flags are easier on platforms that pass arguments to the entrypoint, variables are the only option on platforms that replace it.

| Flag | Variable | Default | Meaning |
|---|---|---|---|
| `--mode` | `BENCH_MODE` | `leading` | `leading` reads the program's speed counter, `exact` counts matching addresses |
| `--seconds` | `BENCH_SECONDS` | `120` | length of the measured window per run |
| `--warmup` | `BENCH_WARMUP` | `30` | seconds dropped after the run starts reporting speed |
| `--repeats` | `BENCH_REPEATS` | `2` | how many times each revision runs |
| `--extra-args` | `BENCH_EXTRA_ARGS` | `-i 255 -I 16384 -w 64` | options given to both revisions |
| `--mask` | `BENCH_EXACT_MASK` | `deadbee` | mask for `--mode exact`, 4 to 10 fixed hex characters |
| `--public-key` | `BENCH_PUBLIC_KEY` | secp256k1 generator | seed public key |
| | `BENCH_SKIP_GPU_CHECK` | unset | start even when no OpenCL platform is detected |
| | `BENCH_ROOT` | `/opt/bench` | directory holding the two revisions, for a native run |

A plain `PUBLIC_KEY` is honoured as well, but only when it holds 128 hexadecimal characters. Rental platforms hand out that generic name for their own SSH key, and it may already sit in your account-wide environment variables, so a value that is not a seed public key is ignored and the run falls back to the default. The header of every run says which key it used:

```
  key:      the secp256k1 generator (PUBLIC_KEY ignored, not 128 hex characters)
```

With the defaults a full comparison takes about ten minutes plus kernel compilation, which is around six cents on an RTX 4090.

An argument that does not start with a dash is executed instead of the benchmark, which is the quickest way to inspect a rented machine:

```bash
docker run --rm --gpus all profanity2-bench:master__pr-57 clinfo
```

The default seed public key is the generator point of secp256k1. It is a valid public key whose private key is the publicly known value 1, which is fine for a benchmark and useless for anything else - never treat a key found during a benchmark run as yours.

## Getting a number that means something

**The two revisions take turns.** The order is A, B, A, B, never A, A, B, B: a GPU that heats up or gets throttled halfway through would otherwise hand the whole penalty to whichever revision ran last. The reported `spread` is how far apart the repeats of one revision landed. If it is as large as the difference between the revisions, the machine is too noisy and the result means nothing - the runner says so explicitly.

**Each revision has its own directory and its own kernel cache.** profanity2 compiles its OpenCL kernel on first use and caches it next to the binary; two revisions sharing a directory would run each other's compiled kernel.

**The first seconds of every run are discarded.** The window only opens once the program starts reporting speed, so kernel compilation and device initialization never land inside it, no matter how slow the device is.

**`--benchmark` is deliberately not supported.** In a revision where the scoring kernel is fused into the iterate kernel, a scoring function that does nothing lets the compiler delete the keccak as well, and the resulting number is meaningless. That is why pull request 57 carries a `benchmark` scoring function whose comment reads *"Prevent the compiler from deleting the keccak behind profanity_iterate"*. Real scoring modes do not have this problem.

**Watch out for revisions that changed the speed counter itself.** Until commit `9011bcd` the duration of a round was truncated to whole milliseconds:

```c++
auto delta = std::chrono::duration_cast<std::chrono::milliseconds>(newTime - m_lastTime).count();
m_lSpeeds.push_back((1000 * V) / delta);
```

A round with default settings is `255 * 16384 = 4177920` keys, which on a 4090 takes about 3.8 ms and gets counted as 3 ms - the printed speed is then 27% above the truth, and on a faster card a sub-millisecond round divides by zero. Comparing such a build against one that measures in microseconds measures the fix, not the kernels.

The build detects this: if `SpeedSample.cpp` differs between the two revisions, the result block ends with a warning. Then either compare against a baseline carrying the same timer,

```bash
bench/publish.sh 9011bcd pr/57 --registry ghcr.io/YOUR_USER
```

or measure without the program's clock at all:

```bash
docker run --rm --gpus all IMAGE --mode exact
```

`--mode exact` uses `--exact <mask>`, which prints every address matching the mask, and derives the throughput from how many appear per second: `rate = matches / seconds * 16^fixed`. Nothing in that number comes from the program's own timer. It is a counting measurement, so its precision is `1/sqrt(matches)`: the default 7-character mask on a 1 GH/s card yields about four matches per second, so a 120 second window gives roughly 450 matches and 5% precision. Widen `--seconds` to resolve smaller differences.

## Recorded runs

[logs/](logs) holds the output of comparisons that were actually run, one file per machine, named after the GPU and where it was rented. They are the raw output of the runner, so each one still carries the revisions it compared and the settings it used.
