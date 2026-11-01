#!/usr/bin/env bash
#
# smoke-aarch64.sh - verifies the shipped Linux/arm64 compiler without the Rust bootstrap.
#
#   bash scripts/smoke-aarch64.sh
#
# Four checks against bin/zetac-linux-arm64:
#   1. the binary is an aarch64 ELF and its LLVM 21.1 dependency is resolvable
#   2. runtime/zenith_runtime.c compiles natively
#   3. zenith_syscall() agrees with glibc syscall() on this host
#   4. tests/simple.z compiles to a native executable whose exit code is 42
#
# Exit codes: 0 pass, 1 check failed, 2 environment prerequisite missing.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZETAC="$ROOT/bin/zetac-linux-arm64"

BUILD="${BUILD:-}"
if [ -z "$BUILD" ]; then
    BUILD="$(mktemp -d)"
    trap 'rm -rf "$BUILD"' EXIT
fi
mkdir -p "$BUILD"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$1" >&2; exit 2; }

[ -x "$ZETAC" ] || fail "missing $ZETAC"
command -v file >/dev/null || skip "'file' is required (apt-get install file)"
command -v cc >/dev/null || skip "a C compiler is required (apt-get install gcc)"

# ---- 1. architecture and the LLVM 21.1 runtime dependency --------------------
arch="$(file -b "$ZETAC" | sed -n 's/.*\(ARM aarch64\|x86-64\).*/\1/p')"
[ "$arch" = "ARM aarch64" ] || fail "$ZETAC is not an aarch64 ELF (got: ${arch:-unknown})"

[ "$(uname -m)" = "aarch64" ] || skip "host is $(uname -m); the arm64 compiler only runs on aarch64"

llvm_lib=""
if [ -n "${ZETAC_LIBLLVM:-}" ]; then
    [ -e "$ZETAC_LIBLLVM/libLLVM.so.21.1" ] \
        || skip "ZETAC_LIBLLVM=$ZETAC_LIBLLVM does not contain libLLVM.so.21.1"
    llvm_lib="$ZETAC_LIBLLVM"
else
    for d in /usr/lib/llvm-21/lib /usr/lib/aarch64-linux-gnu /usr/lib64 \
             /usr/local/lib "$HOME/.local/llvm21/usr/lib/aarch64-linux-gnu"; do
        if [ -e "$d/libLLVM.so.21.1" ]; then llvm_lib="$d"; break; fi
    done
fi
[ -n "$llvm_lib" ] || skip "libLLVM.so.21.1 not found - install LLVM 21 (apt.llvm.org) or set ZETAC_LIBLLVM"

export LD_LIBRARY_PATH="$llvm_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
printf 'ok    %s (libLLVM 21.1 from %s)\n' "$(basename "$ZETAC")" "$llvm_lib"

# ---- 2. the runtime object builds natively -----------------------------------
cc -O2 -fPIC -Wall -c "$ROOT/runtime/zenith_runtime.c" -o "$BUILD/zenith_runtime.o" \
    || fail "runtime/zenith_runtime.c does not compile on $(uname -m)"
printf 'ok    runtime/zenith_runtime.c -> %s\n' "$(file -b "$BUILD/zenith_runtime.o" | cut -d, -f1-2)"

# ---- 3. zenith_syscall() agrees with glibc -----------------------------------
# One function per section, so the probe links without libzstd.
cc -O2 -fPIC -ffunction-sections -fdata-sections \
   -c "$ROOT/runtime/zenith_runtime.c" -o "$BUILD/zenith_runtime_gc.o" \
    || fail "could not build the runtime for the syscall probe"

cat > "$BUILD/syscall_probe.c" <<'PROBE'
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>

long zenith_syscall(long number, long a1, long a2, long a3, long a4, long a5, long a6);

int main(void) {
    long zeta = zenith_syscall(SYS_getpid, 0, 0, 0, 0, 0, 0);
    long libc = syscall(SYS_getpid, 0, 0, 0, 0, 0, 0);
    if (zeta != libc) {
        printf("zenith_syscall=%ld syscall=%ld\n", zeta, libc);
        return 1;
    }
    return 0;
}
PROBE

cc -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections \
   "$BUILD/syscall_probe.c" "$BUILD/zenith_runtime_gc.o" -o "$BUILD/syscall_probe" \
    || fail "could not link the syscall probe"
"$BUILD/syscall_probe" || fail "zenith_syscall() disagrees with glibc syscall()"
printf 'ok    zenith_syscall() matches glibc syscall()\n'

# ---- 4. compile and run ------------------------------------------------------
"$ZETAC" "$ROOT/tests/simple.z" -o "$BUILD/simple" >/dev/null 2>&1 \
    || fail "zetac could not compile tests/simple.z"

set +e
"$BUILD/simple"
rc=$?
set -e
[ "$rc" -eq 42 ] || fail "tests/simple.z exited $rc, expected 42"
printf 'ok    tests/simple.z -> %s (exit 42)\n' "$(basename "$BUILD/simple")"

printf '\naarch64 smoke test passed.\n'
