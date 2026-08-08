# Running profanity2 on a rented GPU (vast.ai)

The [Dockerfile](../docker/Dockerfile) builds an image that contains the compiled binary, the OpenCL kernels and the OpenCL runtime glue needed inside a container. Nothing has to be installed on the rented machine: you pick the image, type the profanity2 options into the template and start the instance.

The image is published as `ghcr.io/1inch/profanity2` (see [Building your own image](#building-your-own-image) if you prefer your own registry). It works on any Docker host with an NVIDIA GPU, vast.ai is just the cheapest way to rent one.

## Why this is safe on someone else's machine

profanity2 never sees your private key. You pass a *public* key with `-z`, and the private key it prints is an offset that is worthless without the seed private key that stays on your machine — the two are added together locally afterwards, see [Adding private keys](../README.md#adding-private-keys-never-use-online-calculators) in the README. That is what makes renting GPU time from strangers acceptable here.

## Quick start on vast.ai

1. Generate a seed key pair as described in [Getting public key for mandatory `-z` parameter](../README.md#getting-public-key-for-mandatory--z-parameter). Keep the private key, you will need it when the search finishes.

2. Create a template ([cloud.vast.ai](https://cloud.vast.ai/templates/) → *New*):

   | Field | Value |
   |---|---|
   | Image Path:Tag | `ghcr.io/1inch/profanity2:latest` |
   | Launch Mode | **docker ENTRYPOINT** |
   | Arguments | `--matching dead -z YOUR_128_HEX_PUBLIC_KEY` |
   | Docker Options | *(optional)* `-e PROFANITY_TIMEOUT=6h` |
   | Disk Space | 12 GB (the image is under 100 MB, this is just the minimum) |

   Launch mode matters: in the SSH and Jupyter modes vast.ai replaces the image entrypoint with its own setup script, so the search would never start. The ENTRYPOINT mode runs the image as is and appends the *Arguments* field to the entrypoint, which is exactly the profanity2 command line.

3. Pick an offer on the [search page](https://cloud.vast.ai/create/) and rent it. profanity2 is pure compute, so sort by price and compare against the hashrate table in the [README](../README.md#benchmarks---current-version) — an RTX 4090 does about 1096 MH/s.

4. Watch the instance log (the log button on the instance card, or `vastai logs <instance_id>`). Every improvement is printed as it is found:

   ```
   Mode: matching
   Target: Address
   Devices:
     GPU0: NVIDIA GeForce RTX 4090, 25757220864 bytes available, 128 compute units (precompiled = no)
   ...
     Time:    31s Score:  4 Private: 0x5b9...c41 Address: 0xdead4b0...
   ```

5. Add the printed private key to your seed private key to get the final key, then verify the address by importing it into a wallet.

Everything that reaches stdout is also appended to `/workspace/profanity2.log` inside the instance, so a result is not lost when the log view scrolls away. In the ENTRYPOINT launch mode the instance log is the only channel out of the container, though - there is no SSH to copy that file over. Save what you need before destroying the instance:

```bash
vastai logs <INSTANCE_ID> --tail 500 > profanity2-results.log
```

If you want a shell as well, rent in the SSH launch mode instead and start the search from the on-start script shown under [Configuration](#configuration).

## The same thing from the CLI

```bash
pip install vastai
vastai set api-key YOUR_API_KEY

# find something cheap with a single 4090
vastai search offers 'gpu_name=RTX_4090 num_gpus=1' -o 'dph' | head

# rent it and start the search immediately
vastai create instance <OFFER_ID> \
    --image ghcr.io/1inch/profanity2:latest \
    --disk 12 \
    --label profanity2 \
    --env '-e PROFANITY_TIMEOUT=6h' \
    --args --matching dead -z YOUR_128_HEX_PUBLIC_KEY

vastai show instances
vastai logs <INSTANCE_ID>
vastai destroy instance <INSTANCE_ID>
```

There is no flag for the launch mode: passing `--args` is what selects it, the way `--ssh` and `--jupyter` select theirs. `--args` must be the **last** option, everything after it is passed to the container. Sorting by `dph` lists the cheapest offers first, `dph-` the most expensive.

## Configuration

Options can be given as container arguments (the *Arguments* field) or through environment variables (the *Docker Options* field, `-e NAME=value`). Environment variables are the only way to configure the run in the SSH and Jupyter launch modes, where the entrypoint is replaced and the on-start script has to start it:

```bash
env >> /etc/environment
/usr/local/bin/profanity2-entrypoint
```

| Variable | Effect |
|---|---|
| `PROFANITY_PUBLIC_KEY` | Added as `-z` unless the arguments already contain `-z` |
| `PUBLIC_KEY` | The same, but only when it holds 128 hexadecimal characters |
| `PROFANITY_ARGS` | Arguments to use when none are passed to the container, e.g. `--matching dead` |
| `PROFANITY_OUTPUT` | File the output is copied to, default `/workspace/profanity2.log`, empty value disables it |
| `PROFANITY_TIMEOUT` | Stop the search after this long, e.g. `30m`, `6h`. The container then exits with code 124 |
| `PROFANITY_SKIP_GPU_CHECK` | Start even when no OpenCL platform is detected |

So this template configuration

```
Arguments:      --matching dead -z YOUR_128_HEX_PUBLIC_KEY
```

and this one

```
Arguments:      (empty)
Docker Options: -e PROFANITY_PUBLIC_KEY=YOUR_128_HEX_PUBLIC_KEY -e PROFANITY_ARGS="--matching dead"
```

do the same thing. All scoring modes of the tool are available, see [Usage examples](../README.md#usage-examples) in the README.

`PUBLIC_KEY` works too, but prefer the longer name: rental platforms hand out that generic name for their own purposes (it is the SSH public key on RunPod, and it may already sit in your vast.ai account-wide environment variables), and a value that is not 128 hexadecimal characters is ignored with a warning rather than passed on to profanity2.

Note that most modes never finish on their own: `--matching` keeps looking for a better score and `--exact` keeps printing matches until it is stopped. Either set `PROFANITY_TIMEOUT` or destroy the instance yourself once you have what you wanted — a running instance keeps costing money.

An argument that does not start with a dash is run as a command instead of profanity2, which is what you want when an instance misbehaves:

```bash
docker run --rm --gpus all ghcr.io/1inch/profanity2:latest clinfo
docker run --rm --gpus all ghcr.io/1inch/profanity2:latest bash
```

## Running the image on your own GPU

```bash
docker run --rm --gpus all ghcr.io/1inch/profanity2:latest \
    --matching dead -z YOUR_128_HEX_PUBLIC_KEY
```

Requires the NVIDIA driver and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host. The OpenCL kernel is compiled again on every start; to keep the compiled kernel cache (`cache-opencl.*`) between runs, put a named volume on the working directory — Docker seeds a fresh named volume with the contents of the image, so the binary and the kernels stay in place:

```bash
docker run --rm --gpus all -v profanity2-cache:/opt/profanity2 \
    ghcr.io/1inch/profanity2:latest --matching dead -z YOUR_128_HEX_PUBLIC_KEY
```

## Building your own image

Build your own if you have local changes, if you want a revision that is not published yet, or if you would rather not depend on a registry someone else controls. A rented machine can only pull from a registry, so the image has to be pushed somewhere first - GHCR if you are going to use it more than once, ttl.sh for a single throwaway run.

```bash
git clone https://github.com/1inch/profanity2
cd profanity2
docker build --platform linux/amd64 -f docker/Dockerfile -t profanity2 .
```

`--platform linux/amd64` is not optional. The Linux branch of the Makefile passes `-mmmx` and `-mcmodel=large`, which do not exist on arm64, so a native build on an Apple Silicon Mac fails with `unrecognized command-line option '-mmmx'`. Rented GPU machines are x86_64 anyway. Under emulation the build takes a few minutes rather than the half minute it needs on an x86 host.

### GitHub Container Registry

The image stays until you delete it and the name is readable, which is what you want if you are going to rent machines more than once. Create a personal access token with the `write:packages` scope, then:

```bash
echo YOUR_TOKEN | docker login ghcr.io -u YOUR_USER --password-stdin
docker tag profanity2 ghcr.io/YOUR_USER/profanity2:latest
docker push ghcr.io/YOUR_USER/profanity2:latest
```

A package pushed to GHCR is **private by default**, so a rented machine cannot pull it yet. Either make it public once, under Packages on your GitHub profile, or hand the credentials to vast.ai:

```bash
# public package
vastai create instance <OFFER_ID> --image ghcr.io/YOUR_USER/profanity2:latest \
    --disk 12 --args --matching dead -z YOUR_128_HEX_PUBLIC_KEY

# private package
vastai create instance <OFFER_ID> --image ghcr.io/YOUR_USER/profanity2:latest \
    --login '-u YOUR_USER -p YOUR_TOKEN ghcr.io' \
    --disk 12 --args --matching dead -z YOUR_128_HEX_PUBLIC_KEY
```

In the GUI the same credentials go into the *Docker login* field of the template, next to the image path.

### ttl.sh

[ttl.sh](https://ttl.sh) is an anonymous registry that deletes what you push after the time given in the tag. No account, no login, no cleanup - convenient for a one-off search:

```bash
IMAGE=ttl.sh/profanity2-$(uuidgen | tr '[:upper:]' '[:lower:]'):24h
docker build --platform linux/amd64 -f docker/Dockerfile -t "$IMAGE" .
docker push "$IMAGE"
echo "$IMAGE"
```

The tag is the lifetime and 24 hours is the maximum, so the image needs a unique name instead - hence the UUID. Anyone who learns that name can pull the image, which is harmless here: it holds nothing but public source code and no key of yours. Do keep the lifetime longer than the search, because an instance that gets recreated or moved after the image expired will fail to start.

Whichever registry you use, its full name goes into the *Image Path:Tag* field of the template, or into `--image` on the command line.

## Troubleshooting

**`error: no OpenCL platform found inside the container`** — the container has no usable GPU driver. Run `clinfo` in the same image (`Arguments: clinfo`) to see what the ICD loader finds. On a self-hosted machine, check that the container was started with `--gpus all` and that the NVIDIA Container Toolkit is installed. On vast.ai, verify that the offer really has an NVIDIA GPU; if it does and the error persists, the host driver is broken — destroy the instance and rent another one, you should not pay for it.

**The instance stays in `loading` and never runs** — the image could not be pulled. A package you pushed to GHCR is private until you say otherwise, and a ttl.sh image is gone once the lifetime in its tag has passed. Check `status_msg` in `vastai show instance <id> --raw`.

**The instance shows as exited immediately** — read the log. Without arguments the entrypoint prints the help text and exits, and profanity2 itself refuses to start when `-z` is missing or is not exactly 128 hex characters (the `04` prefix of the public key must be removed). If the same startup banner appears several times over, the platform is restarting the failing container in a loop and billing you for it — destroy the instance.

**`error: public key must be 128 hexademical characters long` although you passed a correct key** — something else in the environment is called `PUBLIC_KEY`. Check the account-wide environment variables on your [account page](https://cloud.vast.ai/account/), and pass the key as `-z` or in `PROFANITY_PUBLIC_KEY` instead. Running the image with `env` as its only argument prints the whole environment.

**`Devices:` is printed but the list is empty** — an OpenCL platform exists but exposes no GPU device. This is usually a mismatched driver on the host.

**Results look wrong (the private key does not match the address)** — always verify a found key in a wallet before using it. On AMD hardware this used to be caused by old drivers, see issue [#13](https://github.com/1inch/profanity2/issues/13).

**AMD GPUs** — this image only ships the NVIDIA ICD. ROCm needs its own OpenCL runtime inside the image and access to `/dev/kfd` and `/dev/dri` in the container, which vast.ai does not expose on every AMD host. Building on [docs/BUILD_UBUNTU.md](BUILD_UBUNTU.md) and a `rocm/dev-ubuntu-24.04` base image is the starting point if you need it.
