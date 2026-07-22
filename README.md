# profanity2

Profanity is a high performance (probably the fastest!) vanity address generator for Ethereum. Create cool customized addresses that you never realized you needed! Recieve Ether in style! Wow!

![Screenshot](/img/screenshot.png?raw=true "Wow! That's a lot of zeros!")

# Important to know

A previous version of this project has a known critical issue due to a bad source of randomness. The issue enables attackers to recover private key from public key: https://blog.1inch.io/a-vulnerability-disclosed-in-profanity-an-ethereum-vanity-address-tool

This project "profanity2" was forked from the original project and modified to guarantee **safety by design**. This means source code of this project do not require any audits, but still guarantee safe usage.

Project "profanity2" is not generating key anymore, instead it adjusts user-provided public key until desired vanity address will be discovered. Users provide seed public key in form of 128-symbol hex string with `-z` parameter flag. Resulting private key should be used to be added to seed private key to achieve final private key of the desired vanity address (private keys are just 256-bit numbers). Running "profanity2" can even be outsourced to someone completely unreliable - it is still safe by design.

## Getting public key for mandatory `-z` parameter

Generate private key and public key via openssl in terminal (remove prefix "04" from public key):
```bash
$ openssl ecparam -genkey -name secp256k1 -text -noout -outform DER | xxd -p -c 1000 | sed 's/41534e31204f49443a20736563703235366b310a30740201010420/Private Key: /' | sed 's/a00706052b8104000aa144034200/\'$'\nPublic Key: /'
```

Derive public key from existing private key via openssl in terminal (remove prefix "04" from public key):
```bash
$ openssl ec -inform DER -text -noout -in <(cat <(echo -n "302e0201010420") <(echo -n "PRIVATE_KEY_HEX") <(echo -n "a00706052b8104000a") | xxd -r -p) 2>/dev/null | tail -6 | head -5 | sed 's/[ :]//g' | tr -d '\n' && echo
```

## Adding private keys (never use online calculators!)

### Terminal:

Use private keys as 64-symbol hexadecimal string WITHOUT `0x` prefix:
```bash
(echo 'ibase=16;obase=10' && (echo '(PRIVATE_KEY_A + PRIVATE_KEY_B) % FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141' | tr '[:lower:]' '[:upper:]')) | bc
```

### Python

Use private keys as 64-symbol hexadecimal string WITH `0x` prefix:
```bash
$ python3
>>> "%064x" % ((PRIVATE_KEY_A + PRIVATE_KEY_B) % 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141)
```

### Leading zeros

The combined private key must be used as a **64-symbol** hexadecimal string. Neither `bc` nor Python's `hex()` prints leading zeros, so whenever the sum has fewer than 64 symbols (about 1 chance in 16), pad it with leading zeros. The Python snippet above does this automatically thanks to `"%064x"`. Example:

```
PRIVATE_KEY_A =        0bc657b0af28b743c7f0d49c4de78efd47a5c8923dabfdef051fff5cdc7c30e7
PRIVATE_KEY_B =        0000f8ba428990fca1e618a252ac3614f5de19b20ff00c2ded57bfb6933830aa
sum (63 symbols):       bc7506af1b2484069d6ed3ea093c5123d83e2444d9c0a1cf277bf136fb46191
private key (padded):  0bc7506af1b2484069d6ed3ea093c5123d83e2444d9c0a1cf277bf136fb46191
```

# Building

### macOS

OpenCL ships with the system, so only the Xcode Command Line Tools are needed:

```bash
xcode-select --install   # skip if already installed
make
```

This produces `profanity2.x64` in the repository root. Works on both Intel and
Apple Silicon (M1/M2/M3/M4) Macs.

### Ubuntu / Linux

See [docs/BUILD_UBUNTU.md](docs/BUILD_UBUNTU.md). In short:

```bash
sudo apt install -y build-essential opencl-headers ocl-icd-opencl-dev clinfo
make
```

plus the OpenCL runtime (driver) of your GPU vendor — the document covers
NVIDIA/AMD/Intel setup and common errors.

### Windows

See [docs/BUILD_WINDOWS.md](docs/BUILD_WINDOWS.md) — building with MSYS2/MinGW-w64
or against a vendor OpenCL SDK, plus troubleshooting for the most common errors
(`CL/cl.h: No such file or directory`, `CreateProcess(NULL, uname -s, ...) failed`,
empty device list, WSL2 limitations).

# Usage
```
usage: ./profanity2 [OPTIONS]

  Mandatory args:
    -z                      Seed public key to start, add it's private key
                            to the "profanity2" resulting private key.

  Basic modes:
    --benchmark             Run without any scoring, a benchmark.
    --zeros                 Score on zeros anywhere in hash.
    --letters               Score on letters anywhere in hash.
    --numbers               Score on numbers anywhere in hash.
    --mirror                Score on mirroring from center.
    --leading-doubles       Score on hashes leading with hexadecimal pairs
    -b, --zero-bytes        Score on hashes containing the most zero bytes

  Modes with arguments:
    --leading <single hex>  Score on hashes leading with given hex character.
    --matching <hex string> Score on hashes matching given hex string.

  Advanced modes:
    --contract              Instead of account address, score the contract
                            address created by the account's zeroth transaction.
    --leading-range         Scores on hashes leading with characters within
                            given range.
    --range                 Scores on hashes having characters within given
                            range anywhere.

  Range:
    -m, --min <0-15>        Set range minimum (inclusive), 0 is '0' 15 is 'f'.
    -M, --max <0-15>        Set range maximum (inclusive), 0 is '0' 15 is 'f'.

  Device control:
    -s, --skip <index>      Skip device given by index.
    -n, --no-cache          Don't load cached pre-compiled version of kernel.

  Tweaking:
    -w, --work <size>       Set OpenCL local work size. [default = 64]
    -W, --work-max <size>   Set OpenCL maximum work size. [default = -i * -I]
    -i, --inverse-size      Set size of modular inverses to calculate in one
                            work item. [default = 255]
    -I, --inverse-multiple  Set how many above work items will run in
                            parallell. [default = 16384]

  Examples:
    ./profanity2 --leading f -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --matching dead -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --matching badXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXbad -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --leading-range -m 0 -M 1 -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --leading-range -m 10 -M 12 -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --range -m 0 -M 1 -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --contract --leading 0 -z HEX_PUBLIC_KEY_128_CHARS_LONG
    ./profanity2 --contract --zero-bytes -z HEX_PUBLIC_KEY_128_CHARS_LONG

  About:
    profanity2 is a vanity address generator for Ethereum that utilizes
    computing power from GPUs using OpenCL.

  Forked "profanity2":
    Author: 1inch Network <info@1inch.io>
    Disclaimer:
      This project "profanity2" was forked from the original project and
      modified to guarantee "SAFETY BY DESIGN". This means source code of
      this project doesn't require any audits, but still guarantee safe usage.

  From original "profanity":
    Author: Johan Gustafsson <profanity@johgu.se>
    Beer donations: 0x000dead000ae1c8e8ac27103e4ff65f42a4e9203
    Disclaimer:
      Always verify that a private key generated by this program corresponds to
      the public key printed by importing it to a wallet of your choice. This
      program like any software might contain bugs and it does by design cut
      corners to improve overall performance.
```

## Usage examples

All examples below require the mandatory `-z` argument: your seed public key as a 128-symbol
hex string without the `04` prefix (see
[Getting public key for mandatory `-z` parameter](#getting-public-key-for-mandatory--z-parameter)).
In the examples it is abbreviated as `$PUBLIC_KEY`:

```bash
export PUBLIC_KEY="HEX_PUBLIC_KEY_128_CHARS_LONG"
```

### Prefix (`--leading`)

Score on addresses starting with as many repetitions of a single hex character as possible.
The score is the number of leading characters, so the tool keeps running and prints better
and better results:

```bash
# 0x00000... (as many leading zeros as possible)
./profanity2.x64 --leading 0 -z $PUBLIC_KEY

# 0xaaaaa... (as many leading "a"s as possible)
./profanity2.x64 --leading a -z $PUBLIC_KEY
```

### Exact pattern (`--matching`)

`--matching` takes a hex pattern up to 40 characters long (the length of an address without `0x`).
Every position that is **not** a valid hex character (conventionally `X`) is a wildcard that
matches anything. The score is the number of matched fixed positions.

**Prefix** — a short pattern is anchored to the beginning of the address:

```bash
# 0xdead...
./profanity2.x64 --matching dead -z $PUBLIC_KEY
```

**Suffix** — pad the beginning of a full 40-character pattern with `X` wildcards:

```bash
# 0x...999999
./profanity2.x64 --matching XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX999999 -z $PUBLIC_KEY
```

**Prefix and suffix at the same time** — fix both ends, wildcard the middle:

```bash
# 0x1111...2222
./profanity2.x64 --matching 1111XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX2222 -z $PUBLIC_KEY

# 0xbad...bad
./profanity2.x64 --matching badXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXbad -z $PUBLIC_KEY
```

**Arbitrary positions** — any mix of fixed characters and wildcards works:

```bash
# 0xXXXXcafeXXXX...XXXX (characters 5-8 are "cafe")
./profanity2.x64 --matching XXXXcafeXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX -z $PUBLIC_KEY
```

Note: only results improving the best score so far are printed, so after a result matching
all fixed positions is found nothing better can appear — stop the program with `Ctrl-C`.
Keep in mind that every additional fixed character multiplies the expected search time by 16.

### Character classes anywhere (`--zeros`, `--letters`, `--numbers`)

Score on the total amount of matching characters anywhere in the address:

```bash
# As many "0" characters as possible, e.g. 0x00aa0e050bb03c0b066e00c0f70a03d0d000b0d7
./profanity2.x64 --zeros -z $PUBLIC_KEY

# Only letters (a-f), e.g. 0xffcadbfaecfcdeaddeedabadfeedfacebeefcafe
./profanity2.x64 --letters -z $PUBLIC_KEY

# Only numbers (0-9), e.g. 0x8896339129744478701529940603494328137361
./profanity2.x64 --numbers -z $PUBLIC_KEY
```

### Ranges (`--leading-range`, `--range`)

Score on characters within a given hex range, set with `-m/--min` and `-M/--max`
(0 is `0`, 15 is `f`):

```bash
# Leading characters in range 0-1, e.g. 0x0110100...
./profanity2.x64 --leading-range -m 0 -M 1 -z $PUBLIC_KEY

# Leading characters in range a-c, e.g. 0xcbabacc...
./profanity2.x64 --leading-range -m 10 -M 12 -z $PUBLIC_KEY

# Characters in range 0-1 anywhere in the address
./profanity2.x64 --range -m 0 -M 1 -z $PUBLIC_KEY
```

### Other scoring modes (`--mirror`, `--leading-doubles`, `--zero-bytes`)

```bash
# Address mirrored around its center, e.g. 0x...abccba...
./profanity2.x64 --mirror -z $PUBLIC_KEY

# Leading pairs of identical characters, e.g. 0x00fFcc55...
./profanity2.x64 --leading-doubles -z $PUBLIC_KEY

# As many zero BYTES (pairs "00" at even positions) as possible; such addresses
# save gas when used in calldata, e.g. 0x00815e00c0fd4a2d00ae00fa00e300ee00fc0034
./profanity2.x64 --zero-bytes -z $PUBLIC_KEY
```

### Vanity contract address (`--contract`)

Add `--contract` to any scoring mode to score the address of the **contract deployed by the
zeroth transaction** of the found account instead of the account address itself:

```bash
# Account whose first deployed contract gets a 0x00000... address
./profanity2.x64 --contract --leading 0 -z $PUBLIC_KEY

# Account whose first deployed contract address has the most zero bytes
./profanity2.x64 --contract --zero-bytes -z $PUBLIC_KEY
```

### Benchmark and device control

```bash
# Measure hashrate without any scoring
./profanity2.x64 --benchmark -z $PUBLIC_KEY

# Multiple GPUs are used automatically; skip a device (e.g. an integrated GPU) by index
./profanity2.x64 --leading 0 -s 1 -z $PUBLIC_KEY
```

### Benchmarks - Current version
|Model|Clock Speed|Memory Speed|Modified straps|Speed|Time to match eight characters
|:-:|:-:|:-:|:-:|:-:|:-:|
|GTX 1070 OC|1950|4450|NO|179.0 MH/s| ~24s
|GTX 1070|1750|4000|NO|163.0 MH/s| ~26s
|RX 480|1328|2000|YES|120.0 MH/s| ~36s
|RTX 4090|-|-|-|1096 MH/s| ~3s
|Apple Silicon M1<br/>(8-core GPU)|-|-|-|45.0 MH/s| ~97s
|Apple Silicon M1 Max<br/>(32-core GPU)|-|-|-|172.0 MH/s| ~25s
|Apple Silicon M3 Pro<br/>(18-core GPU)|-|-|-|97 MH/s| ~45s
|Apple Silicon M4 Max<br/>(40-core GPU)|-|-|-|350 MH/s| ~12s

# License

This project is licensed under the [MIT License](LICENSE).

