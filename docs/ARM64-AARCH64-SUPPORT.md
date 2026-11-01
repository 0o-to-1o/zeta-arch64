# Linux arm64 (aarch64) support

Zeta runs natively on 64-bit ARM Linux — Raspberry Pi 5, Ampere/Graviton, Apple silicon
VMs, and anything else exposing `aarch64`. No Rust bootstrap, no cross-compilation and no
extra toolchain are involved: `bin/zetac-linux-arm64` is the compiler.

## What ships

| Path | Purpose |
| --- | --- |
| `bin/zetac-linux-arm64` | Prebuilt Zeta compiler for Linux/arm64 (ELF, PIE) |
| `runtime/zenith_runtime.c` | Portable runtime; builds on x86-64 and aarch64 |
| `scripts/smoke-aarch64.sh` | Four-step verification of the compiler + runtime |
| `.github/workflows/aarch64.yml` | Runs the smoke test on `ubuntu-24.04-arm` |

Provenance of the shipped binary:

```
file      ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked
build id  02075eead4b2373985563529882c6d11ccdd1dcb
sha256    d161634f8ce5fbce579d4b6f573539b75e2da8b6ea285d66f33cc60713a207f1
size      8802368 bytes
```

## Requirements

- `uname -m` reports `aarch64`
- **LLVM 21.1** — the compiler links `libLLVM.so.21.1` dynamically. Debian 13 and
  Ubuntu 24.04 ship LLVM 19, so install LLVM 21 from `apt.llvm.org`:

  ```bash
  wget -q https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
  sudo ./llvm.sh 21 && sudo apt-get install -y libllvm21
  ```

  The library lands in `/usr/lib/llvm-21/lib/libLLVM.so.21.1`. If it lives somewhere
  else, point `LD_LIBRARY_PATH` there or set `ZETAC_LIBLLVM=/path/to/dir`.
- A C compiler (`cc`) and `libzstd` for the runtime object.

## Quick start

```bash
export LD_LIBRARY_PATH=/usr/lib/llvm-21/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
./bin/zetac-linux-arm64 tests/simple.z -o simple
./simple; echo $?        # 42
```

Full verification (architecture, runtime build, syscall correctness, compile-and-run):

```bash
bash scripts/smoke-aarch64.sh
```

## Runtime support

Programs link against `runtime/zenith_runtime.c`. It builds natively:

```bash
cc -O2 -fPIC -c runtime/zenith_runtime.c -o zenith_runtime_c.o
```

`zenith_syscall()` (the `syscall()` built-in) previously hardcoded the x86-64 register
names `rax`/`rdi`/`rsi`/`rdx`/`r10`/`r8`/`r9` and `syscall` — on aarch64 those are not
registers, so the file did not compile at all. It is now split per architecture:

| Architecture | Calling convention |
| --- | --- |
| `__x86_64__` | number in `rax`, args in `rdi,rsi,rdx,r10,r8,r9`, `syscall` |
| `__aarch64__` | number in `x8`, args in `x0..x5`, `svc #0` |
| anything else | glibc `syscall()` |

The two per-architecture paths preserve the existing x86-64 behaviour unchanged; the
`libc` path is the portable fallback for every other target.

The `io_uring_*` wrappers already go through glibc `syscall()`, and the `SYS_io_uring_*`
fallbacks are the generic (asm-generic) numbers, which are correct on aarch64.

## Verified on arm64

Cortex-A76, Debian 13 (trixie), LLVM 21.1.8:

- `zetac-linux-arm64 tests/simple.z -o simple` → aarch64 ELF, exit code `42`
- the JIT path also runs on arm64 (`Result: 42` on stdout, `zetac <file>` without `-o`)
- `cc -O2 -fPIC -Wall -Wextra -c runtime/zenith_runtime.c` → clean, no warnings
- `zenith_syscall(SYS_getpid, …)` returns the same value as glibc `syscall()`
- the x86-64 object is **byte-identical** to the one built from the previous version of the
  file, so the split changed nothing on the existing target

## Known limitations

- **Self-hosting on arm64 is not available yet.** The shipped compiler resolves imports
  within a single translation unit only, so `src/main.z` cannot be rebuilt from `src/*.z`
  on any architecture. `bin/zetac-linux-arm64` is a prebuilt artifact, and CI verifies it
  rather than rebuilding it.
- **The binary is pinned to LLVM 21.1.** `bin/zetac` on x86-64 has the same pin, so this is
  a repository-wide constraint, not an arm64 one.
- **Producing a new arm64 build** needs an aarch64 host with LLVM 21 and the same procedure
  used for `bin/zetac` (see `.github/workflows/release.yml`). Once the module resolver can
  handle multi-file compilation, `./bin/zetac-linux-arm64 src/main.z -o zetac` should close
  the loop — that is the next milestone for this port.
- **`src/backend/codegen/codegen.z` still pins `x86_64-unknown-linux-gnu`** as the emitted
  LLVM target triple. It does not affect the shipped compiler (which emits no triple and
  lets LLVM pick the host), but it is the first thing to fix when self-hosting on arm64:
  a self-hosted compiler on ARM would otherwise emit x86-64 IR.
