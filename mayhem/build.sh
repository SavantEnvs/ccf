#!/usr/bin/env bash
#
# mayhem/build.sh — build CCF's fuzz harnesses (cbor_fuzz, msgpack_fuzz) and unit-test oracle.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# CCF's crypto layer links a Rust static library (cargo, pinned toolchain + registry cache under
# /opt/toolchains/rust via CARGO_HOME/RUSTUP_HOME in the Dockerfile). The first (online) build fills the
# cache; the air-gapped re-run resolves from it (rlenv exports CARGO_NET_OFFLINE=true), so no --offline.
# cmake/version.cmake runs `git describe --match=ccf-*`, but the savantenvs fork carries no upstream tags,
# so configure would fail. Fall back to a local lightweight tag named after the newest CHANGELOG release.
if ! git describe --tags --match='ccf-*' --exclude='ccf-0.0.0*' >/dev/null 2>&1; then
  git tag "ccf-$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n 1)" HEAD
fi

CMAKE_COMMON=(-G Ninja -DUSE_SNMALLOC=OFF -DCMAKE_BUILD_TYPE=RelWithDebInfo
              -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX")

# 1) Sanitized project build: ccfcrypto (+ ccf_rs, ccf_threading) with ASan+UBSan and DWARF 3.
#    Build dir "build-fuzz" is covered by upstream's `build*/` .gitignore rule.
cmake -S . -B build-fuzz "${CMAKE_COMMON[@]}" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
ninja -C build-fuzz -j"$MAYHEM_JOBS" ccfcrypto

# 2) Harnesses, each linked twice: libFuzzer engine + run-once standalone reproducer.
#    Same compile flags as upstream's add_fuzz_test (incl. -fno-sanitize=vptr, see cmake/common.cmake).
CXXFLAGS_H=(-std=gnu++23 -O2 -DNDEBUG -fno-sanitize=vptr
            -I"$SRC/include" -I"$SRC/src"
            -isystem "$SRC/3rdparty/exported" -isystem "$SRC/3rdparty/internal"
            -isystem "$SRC/3rdparty/internal/tee-attestation-verification/ffi/include")
LIBS_CRYPTO=(build-fuzz/libccfcrypto.a build-fuzz/libccf_threading.a build-fuzz/libccf_rs.a
             -lcrypto -lssl -pthread -ldl -lm)

B=build-fuzz/harness
mkdir -p "$B"
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$B/lsan_off.o"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

build_harness() {  # <name> <source> <lib...>
  local name="$1" src="$2"; shift 2
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${CXXFLAGS_H[@]}" -c "$src" -o "$B/$name.o"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/$name.o" "$B/lsan_off.o" "$@" -o "$SRC/$name"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$B/$name.o" "$B/standalone_main.o" "$B/lsan_off.o" "$@" -o "$SRC/$name-standalone"
}
build_harness cbor_fuzz    src/crypto/test/cbor_fuzz.cpp       "${LIBS_CRYPTO[@]}"
build_harness msgpack_fuzz src/msgpack/test/msgpack_fuzz.cpp   -pthread

# 3) Unit-test oracle with the project's NORMAL flags (no sanitizers, no fuzzer): an independent build
#    in "build-tests" (gitignored by `build*/`); mayhem/test.sh only runs the doctest binaries.
cmake -S . -B build-tests "${CMAKE_COMMON[@]}" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
ninja -C build-tests -j"$MAYHEM_JOBS" cbor_test msgpack_test crypto_test sharing_test key_exchange_test
