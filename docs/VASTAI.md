# Running profanity2 on a rented GPU (vast.ai)

The [Dockerfile](../Dockerfile) in the repository root builds an image that
contains the compiled binary, the OpenCL kernels and the OpenCL runtime glue
needed inside a container. Nothing has to be installed on the rented machine:
you pick the image, type the profanity2 options into the template and start the
instance.

The image is published as `ghcr.io/1inch/profanity2` (see
[Building your own image](#building-your-own-image) if you prefer your own
registry). It works on any Docker host with an NVIDIA GPU, vast.ai is just the
cheapest way to rent one.

## Why this is safe on someone else's machine

profanity2 never sees your private key. You pass a *public* key with `-z`, and
the private key it prints is an offset that is worthless without the seed
private key that stays on your machine — the two are added together locally
afterwards, see [Adding private keys](../README.md#adding-private-keys-never-use-online-calculators)
in the README. That is what makes renting GPU time from strangers acceptable
here.

## Quick start on vast.ai

1. Generate a seed key pair as described in
   [Getting public key for mandatory `-z` parameter](../README.md#getting-public-key-for-mandatory--z-parameter).
   Keep the private key, you will need it when the search finishes.

2. Create a template ([cloud.vast.ai](https://cloud.vast.ai/templates/) → *New*):

   | Field | Value |
   |---|---|
   | Image Path:Tag | `ghcr.io/1inch/profanity2:latest` |
   | Launch Mode | **docker ENTRYPOINT** |
   | Arguments | `--matching dead -z YOUR_128_HEX_PUBLIC_KEY` |
   | Docker Options | *(optional)* `-e PROFANITY_TIMEOUT=6h` |
   | Disk Space | 12 GB (the image is under 100 MB, this is just the minimum) |

   Launch mode matters: in the SSH and Jupyter modes vast.ai replaces the image
   entrypoint with its own setup script, so the search would never start. The
   ENTRYPOINT mode runs the image as is and appends the *Arguments* field to the
   entrypoint, which is exactly the profanity2 command line.

3. Pick an offer on the [search page](https://cloud.vast.ai/create/) and rent it.
   profanity2 is pure compute, so sort by price and compare against the hashrate
   table in the [README](../README.md#benchmarks---current-version) — an RTX 4090
   does about 1096 MH/s.

4. Watch the instance log (the log button on the instance card, or
   `vastai logs <instance_id>`). Every improvement is printed as it is found:

   ```
   Mode: matching
   Target: Address
   Devices:
     GPU0: NVIDIA GeForce RTX 4090, 25757220864 bytes available, 128 compute units (precompiled = no)
   ...
     Time:    31s Score:  4 Private: 0x5b9...c41 Address: 0xdead4b0...
   ```

5. Add the printed private key to your seed private key to get the final key,
   then verify the address by importing it into a wallet.

Everything that reaches stdout is also appended to `/workspace/profanity2.log`
inside the instance, so a result is not lost when the log view scrolls away.
Fetch it with `vastai copy C.<instance_id>:/workspace/ local:results/` before
destroying the instance.

## The same thing from the CLI

```bash
pip install vastai
vastai set api-key YOUR_API_KEY

# find something cheap with a single 4090
vastai search offers 'gpu_name=RTX_4090 num_gpus=1 rentable=true' -o 'dph+' | head

# rent it and start the search immediately
vastai create instance <OFFER_ID> \
    --image ghcr.io/1inch/profanity2:latest \
    --disk 12 \
    --label profanity2 \
    --runtype args \
    --env '-e PROFANITY_TIMEOUT=6h' \
    --args --matching dead -z YOUR_128_HEX_PUBLIC_KEY

vastai show instances
vastai logs <INSTANCE_ID>
vastai destroy instance <INSTANCE_ID>
```

`--runtype args` is the CLI name of the ENTRYPOINT launch mode. `--args` must be
the **last** option, everything after it is passed to the container.

## Configuration

Options can be given as container arguments (the *Arguments* field) or through
environment variables (the *Docker Options* field, `-e NAME=value`). Environment
variables are the only way to configure the run in the SSH and Jupyter launch
modes, where the entrypoint is replaced and the on-start script has to start it:

```bash
env >> /etc/environment
/usr/local/bin/profanity2-entrypoint
```

| Variable | Effect |
|---|---|
| `PUBLIC_KEY` | Added as `-z` unless the arguments already contain `-z` |
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
Docker Options: -e PUBLIC_KEY=YOUR_128_HEX_PUBLIC_KEY -e PROFANITY_ARGS="--matching dead"
```

do the same thing. All scoring modes of the tool are available, see
[Usage examples](../README.md#usage-examples) in the README.

Note that most modes never finish on their own: `--matching` keeps looking for a
better score and `--exact` keeps printing matches until it is stopped. Either set
`PROFANITY_TIMEOUT` or destroy the instance yourself once you have what you
wanted — a running instance keeps costing money.

An argument that does not start with a dash is run as a command instead of
profanity2, which is what you want when an instance misbehaves:

```bash
docker run --rm --gpus all ghcr.io/1inch/profanity2:latest clinfo
docker run --rm --gpus all ghcr.io/1inch/profanity2:latest bash
```

## Running the image on your own GPU

```bash
docker run --rm --gpus all ghcr.io/1inch/profanity2:latest \
    --matching dead -z YOUR_128_HEX_PUBLIC_KEY
```

Requires the NVIDIA driver and the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
on the host. The OpenCL kernel is compiled again on every start; to keep the
compiled kernel cache (`cache-opencl.*`) between runs, put a named volume on the
working directory — Docker seeds a fresh named volume with the contents of the
image, so the binary and the kernels stay in place:

```bash
docker run --rm --gpus all -v profanity2-cache:/opt/profanity2 \
    ghcr.io/1inch/profanity2:latest --matching dead -z YOUR_128_HEX_PUBLIC_KEY
```

## Building your own image

If you have local changes, or would rather not depend on a registry someone else
controls, building your own takes about a minute:

```bash
git clone https://github.com/1inch/profanity2
cd profanity2
docker build -t YOUR_DOCKERHUB_USER/profanity2 .
docker push YOUR_DOCKERHUB_USER/profanity2
```

Then use `YOUR_DOCKERHUB_USER/profanity2` as the image path in the vast.ai
template. Private repositories work too, vast.ai has a field for the
`docker login` credentials in the template.

## Troubleshooting

**`error: no OpenCL platform found inside the container`** — the container has no
usable GPU driver. Run `clinfo` in the same image (`Arguments: clinfo`) to see
what the ICD loader finds. On a self-hosted machine, check that the container was
started with `--gpus all` and that the NVIDIA Container Toolkit is installed. On
vast.ai, verify that the offer really has an NVIDIA GPU; if it does and the error
persists, the host driver is broken — destroy the instance and rent another one,
you should not pay for it.

**The instance shows as exited immediately** — read the log. Without arguments
the entrypoint prints the help text and exits, and profanity2 itself refuses to
start when `-z` is missing or is not exactly 128 hex characters (the `04` prefix
of the public key must be removed).

**`Devices:` is printed but the list is empty** — an OpenCL platform exists but
exposes no GPU device. This is usually a mismatched driver on the host.

**Results look wrong (the private key does not match the address)** — always
verify a found key in a wallet before using it. On AMD hardware this used to be
caused by old drivers, see issue
[#13](https://github.com/1inch/profanity2/issues/13).

**AMD GPUs** — this image only ships the NVIDIA ICD. ROCm needs its own OpenCL
runtime inside the image and access to `/dev/kfd` and `/dev/dri` in the
container, which vast.ai does not expose on every AMD host. Building on
[docs/BUILD_UBUNTU.md](BUILD_UBUNTU.md) and a `rocm/dev-ubuntu-24.04` base image
is the starting point if you need it.
