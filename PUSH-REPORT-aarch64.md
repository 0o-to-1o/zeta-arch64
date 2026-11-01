# Push report — Linux arm64 (aarch64) support for `main`

**Branch:** `aarch64-support` (3 commits on top of `main` @ `ec83f3f`)
**Target:** `murphsicles/zeta` → `main`
**Not touched:** the `bootstrap` branch, `src/**.z`, any Rust/Cargo file, and the
`zeta-complete` work (TypescriptSV / ZetaSV / zetaOS / zippy-v2).

---

## 1. Why

`main` ships `bin/zetac` (Linux x86-64) and two macOS binaries. On a 64-bit ARM Linux
host — Raspberry Pi 5, Graviton, Ampere, Apple silicon VM — the repository is unusable:

```
$ ./bin/zetac tests/simple.z -o simple
-bash: ./bin/zetac: cannot execute binary file: Exec format error
```

Two independent blockers were found and fixed:

| # | Blocker | Where |
| --- | --- | --- |
| 1 | No arm64 compiler artifact is shipped | `bin/` |
| 2 | `runtime/zenith_runtime.c` does not compile on arm64 (x86 inline asm) | `runtime/zenith_runtime.c:151` |

Blocker 2 is the one that matters beyond a missing file: even with an arm64 compiler,
every AOT program needs `zenith_runtime.o`, and that object could not be built. GCC/Clang
stopped at five errors:

```
zenith_runtime.c:152:19: error: invalid register name for ‘rax’
zenith_runtime.c:153:19: error: invalid register name for ‘rdi’
zenith_runtime.c:154:19: error: invalid register name for ‘rsi’
zenith_runtime.c:159:5:  error: unknown register name ‘rcx’ in ‘asm’
```

## 2. What the branch changes

```
 .github/workflows/aarch64.yml |  41 +++++++++++++++++
 README.md                     |  21 ++++++++-
 bin/zetac-linux-arm64         | Bin 0 -> 8802368 bytes
 docs/ARM64-AARCH64-SUPPORT.md | 101 ++++++++++++++++++++++++++++++++++++++++++
 runtime/zenith_runtime.c      |  19 ++++++++
 scripts/smoke-aarch64.sh      |  63 ++++++++++++++++++++++++
 6 files changed, 244 insertions(+), 1 deletion(-)
```

1. **`runtime: make zenith_syscall portable across x86-64 and aarch64`**
   The wrapper is split by architecture: the x86-64 path is byte-for-byte unchanged, aarch64
   gets its own convention (number in `x8`, args in `x0..x5`, `svc #0`), and every other
   target falls back to glibc's `syscall()`. 19 added lines, no deleted lines.

2. **`bin: ship a Linux arm64 compiler, verify it in CI`**
   Adds `bin/zetac-linux-arm64`, `scripts/smoke-aarch64.sh` and
   `.github/workflows/aarch64.yml`.

3. **`docs: document Linux arm64 support`**
   Quick Start section in `README.md`, plus `docs/ARM64-AARCH64-SUPPORT.md`.

### The compiler artifact

```
file      ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
          interpreter /lib/ld-linux-aarch64.so.1
size      8 802 368 bytes
sha256    d161634f8ce5fbce579d4b6f573539b75e2da8b6ea285d66f33cc60713a207f1
build id  02075eead4b2373985563529882c6d11ccdd1dcb
NEEDED    libLLVM.so.21.1, libgcc_s.so.1, libm.so.6, libc.so.6
```

It is a **complete compiler**, not a stub: it parses, typechecks, lowers through
MIR, emits aarch64 objects and links executables on its own. It carries the same LLVM 21.1
dependency that `bin/zetac` already has, so no new constraint is introduced.

## 3. Verification (reproducible)

Host: Raspberry Pi 5 class, Cortex-A76, Debian 13 (trixie), LLVM 21.1.8, `cc` = GCC 14.

```console
$ uname -m
aarch64

$ export LD_LIBRARY_PATH=/usr/lib/llvm-21/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

$ ./bin/zetac-linux-arm64 tests/simple.z -o simple
Compiled to simple
$ ./simple; echo $?
42
$ file simple
simple: ELF 64-bit LSB executable, ARM aarch64, ... dynamically linked

$ bash scripts/smoke-aarch64.sh
ok    zetac-linux-arm64 (libLLVM 21.1 from /usr/lib/llvm-21/lib)
ok    runtime/zenith_runtime.c -> ELF 64-bit LSB relocatable, ARM aarch64
ok    zenith_syscall() matches glibc syscall()
ok    tests/simple.z -> simple (exit 42)

aarch64 smoke test passed.
```

Three things were checked beyond "it compiles":

**1. No regression on x86-64 — the object is byte-identical.**

```console
$ x86_64-linux-gnu-gcc -O2 -fPIC -c runtime/zenith_runtime.c -o new.o   # this branch
$ x86_64-linux-gnu-gcc -O2 -fPIC -c runtime/zenith_runtime.c -o old.o   # from main
$ sha256sum old.o new.o
43477b1f424439df73f4bdf38feab69076a0dd62d3ab4a72608aa1b9fffd526a  old.o
43477b1f424439df73f4bdf38feab69076a0dd62d3ab4a72608aa1b9fffd526a  new.o
```

Both architectures also compile warning-free under `-Wall -Wextra`.

**2. `zenith_syscall()` returns what the kernel returns.** The smoke test links a probe
against the runtime and compares it with glibc's `syscall()` on `SYS_getpid` — portable, so
the same probe could run on any target.

**3. The probe actually fails when the wrapper is wrong.** With `x8` deliberately loaded
from the wrong argument the check reports `zenith_syscall=… syscall=… ` and exits 1
(`-14` = `-EFAULT`), so a future regression cannot pass silently.

The JIT path also works on arm64 — `bin/zetac-linux-arm64 hello.z` (no `-o`) prints
`Result: 42` and emits the LLVM IR on stderr, identical to the x86-64 behaviour.

## 4. What is deliberately *not* in this push

- **No `bootstrap` branch dependency.** Nothing here builds from Rust or Cargo. `main` stays
  Zeta-only; the arm64 compiler is an artifact, exactly like `bin/zetac`.
- **No `src/**.z` changes.** Two known arm64 issues in the self-hosted sources are documented
  instead of patched, because they are not reachable today and could not be compiled and
  tested on this host:
  - `src/backend/codegen/codegen.z:13-14` pins
    `target triple = "x86_64-unknown-linux-gnu"` and an x86-64 datalayout. A self-hosted
    compiler running on arm64 would therefore emit x86-64 IR. The *shipped* binaries are not
    affected (they emit no triple and let LLVM pick the host).
  - The shipped compiler resolves imports within a single translation unit only, so
    `src/main.z` cannot be rebuilt on **any** architecture yet (see §5).
- **No unrelated projects.** The TypeScript/BSV, ZetaSV benchmark and zetaOS trees from our
  working repository are out of scope for this PR.
- **No new release/build job for arm64.** Producing a fresh arm64 build needs an aarch64 host
  with LLVM 21; CI *verifies* the shipped artifact instead of pretending to rebuild it.

## 5. Known limitation the maintainer should know about

Self-hosting on arm64 is **not** available, and this PR does not claim it is. Compiling
`src/main.z` with the shipped compiler stops at:

```
error[E4001]: No main function found.
     = suggestion: Define `fn main() -> i64 { ... }` as the entry point.
```

The imports are not resolved into the unit, so the 51 self-hosted files never reach codegen.
That is architecture-independent and pre-existing. Once the module resolver handles multi-file
compilation, `./bin/zetac-linux-arm64 src/main.z -o zetac` should close the loop — at which
point the `target triple` in `codegen.z` becomes the next thing to fix.

## 6. Suggested PR description

> **Add Linux arm64 (aarch64) support**
>
> `main` ships only x86-64 and macOS compilers, and `runtime/zenith_runtime.c` does not
> compile on arm64 because `zenith_syscall()` hardcodes x86-64 registers.
>
> - `runtime`: split `zenith_syscall()` by architecture (x86-64 unchanged, aarch64
>   `x8`+`x0..x5`+`svc #0`, glibc `syscall()` as portable fallback).
> - `bin`: add `zetac-linux-arm64` (8.8 MB, sha256 `d161634f…`, needs `libLLVM.so.21.1`).
> - `scripts/smoke-aarch64.sh` + `.github/workflows/aarch64.yml` on `ubuntu-24.04-arm`.
> - `docs`: `docs/ARM64-AARCH64-SUPPORT.md` with requirements, verification and the
>   remaining self-hosting gap.
>
> Verified on Cortex-A76 / Debian 13 / LLVM 21.1.8: `tests/simple.z` → aarch64 ELF, exit 42;
> runtime warning-free on both architectures; `zenith_syscall(172, …) == getpid()`.
> No Rust/Cargo involved.

## 7. Open questions for the maintainer

1. Is a prebuilt arm64 artifact welcome in `bin/`, or would you rather keep binaries out of the
   tree and publish them only as release assets?
2. Is `ubuntu-24.04-arm` acceptable as the CI runner for the smoke job?
3. Do you want the `target triple` in `src/backend/codegen/codegen.z` made host-derived now
   (unverifiable on this host) or after multi-file self-hosting lands?
4. Both compilers need `LD_LIBRARY_PATH` to find `libLLVM.so.21.1` on a stock distro. Should the
   release build set an rpath (`/usr/lib/llvm-21/lib`) or link LLVM statically? That would affect
   `bin/zetac` too, so it is out of scope for this branch and documented as a prerequisite instead.
