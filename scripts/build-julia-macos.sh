#!/bin/bash
# Build Julia from source on macOS arm64 WITHOUT bundling libunwind, then bake
# it (+ the JuliaC.jl `juliac` app) into a relocatable toolchain tarball
# consumed by the `main` branch to build libMad. macOS analogue of the
# `docker` branch's scripts/build-julia.sh.
#
# Why from source: the official Julia macOS binary BUNDLES libunwind.dylib,
# which clashes when libMad is loaded into a host that already has one (the
# "Matlab clash" the Linux build avoids via DISABLE_LIBUNWIND). On macOS the
# system unwinder is always present (libSystem), so USE_SYSTEM_LIBUNWIND=1 is
# the supported equivalent: Julia links the system libunwind and bundles none.
# (DISABLE_LIBUNWIND itself is unsupported on macOS — signals-mach.c hard-wires
# libunwind with no JL_DISABLE_LIBUNWIND guards.)
#
# Env:
#   JULIA_VERSION     Julia version to build         (default: 1.12.6)
#   BUNDLE_ROOT       toolchain layout root          (default: $HOME/polyglot-julia)
#   OUT_DIR           tarball output dir             (default: $PWD/out)
#   USE_BINARYBUILDER 0 = deps from source (parity); 1 = official BB binaries
#                     (much faster on 3-core macos-14, same no-libunwind result)
#                                                    (default: 0)
#   BUILD_JOBS        make parallelism               (default: hw.ncpu)
#   CC/CXX/FC         compilers (from action-setup-compiler)
set -euo pipefail

JULIA_VERSION="${JULIA_VERSION:-1.12.6}"
BUNDLE_ROOT="${BUNDLE_ROOT:-$HOME/polyglot-julia}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
USE_BINARYBUILDER="${USE_BINARYBUILDER:-0}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
WORK="${WORK:-$PWD/julia-build}"

# Apple Silicon multi-target string, matching JuliaCI's official
# aarch64-apple-darwin binaries (JuliaCI/julia-buildkite build_envs.sh).
JULIA_CPU_TARGET="generic;apple-m1,clone_all"

export JULIA_DEPOT_PATH="$BUNDLE_ROOT/depot"
git config --global url."https://github.com/".insteadOf "git@github.com:"
export JULIA_PKG_USE_CLI_GIT=true

# GNU make's implicit `%.o: %.c` recipe injects $(TARGET_ARCH); an inherited
# TARGET_ARCH env var would leak in as a bogus positional cc arg. Strip it.
unset TARGET_ARCH || true

rm -rf "$BUNDLE_ROOT" "$WORK"
mkdir -p "$BUNDLE_ROOT" "$JULIA_DEPOT_PATH" "$OUT_DIR" "$WORK"

echo "=== toolchain ==="
"${CC:-cc}" --version | head -1 || true
"${FC:-gfortran}" --version | head -1 || true
cmake --version | head -1 || true
echo "cores=$BUILD_JOBS  USE_BINARYBUILDER=$USE_BINARYBUILDER  SDKROOT=${SDKROOT:-<unset>}"
echo

echo "=== use native macOS toolchain for Julia-from-source ==="
# casadi/action-setup-compiler points CC/CXX/SDKROOT at an old cross SDK
# (MacOSX11.1) whose libc++ headers break Julia's C/C++ dep builds (p7zip
# 'new' not found, openlibm malformed LC_DYSYMTAB) on the macos-14 linker.
# Julia-from-source expects the runner's NATIVE Apple clang + current SDK
# (as JuliaCI builds it). Drop the cross-SDK env; keep only gfortran (FC)
# for the Fortran deps. clang falls back to `xcrun --show-sdk-path`.
unset SDKROOT CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CC CXX CPP || true
echo "native SDK: $(xcrun --show-sdk-path 2>/dev/null || echo '<xcrun failed>')"
echo "clang: $(clang --version | head -1)"

echo "=== 1) fetch Julia $JULIA_VERSION full source ==="
# The -full tarball bundles dependency sources needed for USE_BINARYBUILDER=0.
URL="https://github.com/JuliaLang/julia/releases/download/v${JULIA_VERSION}/julia-${JULIA_VERSION}-full.tar.gz"
echo "  $URL"
curl -fL "$URL" -o "$WORK/julia-src.tar.gz"
mkdir -p "$WORK/src"
tar -xzf "$WORK/julia-src.tar.gz" -C "$WORK/src" --strip-components=1
cd "$WORK/src"

echo "=== 2) Make.user (USE_SYSTEM_LIBUNWIND) ==="
cat > Make.user <<EOF
USE_BINARYBUILDER=${USE_BINARYBUILDER}
JULIA_CPU_TARGET=${JULIA_CPU_TARGET}
# Link macOS's system unwinder (always in libSystem) instead of building +
# bundling LLVMLibUnwind, so the bundle ships no libunwind.dylib (the Matlab
# clash fix). DISABLE_LIBUNWIND is unsupported on macOS (signals-mach.c).
USE_SYSTEM_LIBUNWIND:=1
# macOS always ships system zlib; building it from source gave LLVM's bootstrap
# tablegen tools an unresolvable @rpath/libz.dylib. zlib isn't parity-sensitive.
USE_SYSTEM_ZLIB:=1
EOF
cat Make.user
echo

echo "=== 3b) fortran shim ==="
# Julia's Make.inc hardcodes `FC := gfortran` (bare name, := overrides env FC)
# and probes `gfortran -dM -E -` for FC_VERSION; if the action-setup-compiler
# gfortran isn't named exactly `gfortran` on PATH, FC_VERSION is empty and the
# OpenBLAS/SuiteSparse source build aborts. Shim a bare `gfortran` -> real FC
# (also fixes bare-gfortran calls inside those sub-builds) and pass FC=
# explicitly on the make command line (beats the makefile := and propagates).
FC_BIN="$(command -v "${FC:-gfortran}" || true)"
test -n "$FC_BIN" || { echo "no gfortran found (FC=${FC:-<unset>})" >&2; exit 1; }
mkdir -p "$WORK/fcbin"
ln -sf "$FC_BIN" "$WORK/fcbin/gfortran"
export PATH="$WORK/fcbin:$PATH"
echo "  FC_BIN=$FC_BIN"
gfortran -dM -E - < /dev/null | grep __GNUC__ \
  || { echo "gfortran probe still failing" >&2; exit 1; }

echo "=== 3c) dedupe duplicate LC_RPATH in gfortran runtime dylibs ==="
# The action-setup-compiler conda gfortran ships libgfortran/libquadmath with
# TWO identical '@loader_path' LC_RPATHs; the macos-14 linker (ld-prime) treats
# duplicate LC_RPATH as a fatal error (breaks the OpenBLAS test link). Drop the
# extras and re-sign. (install_name_tool invalidates the ad-hoc signature.)
GF_LIBDIR="$(cd "$(dirname "$FC_BIN")/../lib" && pwd)"
echo "  gfortran runtime libdir: $GF_LIBDIR"
for f in "$GF_LIBDIR"/libgfortran*.dylib "$GF_LIBDIR"/libquadmath*.dylib \
         "$GF_LIBDIR"/libgcc_s*.dylib "$GF_LIBDIR"/libgomp*.dylib; do
  [ -e "$f" ] || continue
  while [ "$(otool -l "$f" | grep -c 'path @loader_path ')" -gt 1 ]; do
    install_name_tool -delete_rpath @loader_path "$f" 2>/dev/null || break
  done
  codesign -f -s - "$f" 2>/dev/null || true
done
# Embed an absolute rpath to the gfortran runtime so binaries that load
# libgfortran AT BUILD TIME (OpenBLAS's utest, Julia's sysimage/juliac) find
# it — DYLD_* env can't help here, SIP strips it from the protected make/sh.
# Threads into OpenBLAS via openblas.mk's LDFLAGS. Resolves on the consumer
# too (same runner type + same action-setup-compiler conda env path).
export LDFLAGS="-Wl,-rpath,$GF_LIBDIR${LDFLAGS:+ $LDFLAGS}"
echo "  LDFLAGS=$LDFLAGS"

echo "=== 4) build (make -j$BUILD_JOBS) ==="
date
time make -j"$BUILD_JOBS" FC="$FC_BIN"
date

echo "=== 5) smoke test ==="
./julia -e 'println("Julia ", VERSION, " — LLVM ", Base.libllvm_version); println("CPU ", Sys.CPU_NAME)'

echo "=== 6) libunwind gate (bundle must ship none) ==="
# With USE_SYSTEM_LIBUNWIND=1 Julia links the system unwinder and installs no
# libunwind.dylib of its own — that is the whole point (no Matlab clash).
if compgen -G "usr/lib/libunwind*" > /dev/null || compgen -G "usr/lib/julia/libunwind*" > /dev/null; then
  echo "ERROR: libunwind bundled despite USE_SYSTEM_LIBUNWIND=1" >&2
  ls usr/lib/libunwind* usr/lib/julia/libunwind* 2>/dev/null >&2
  exit 1
fi
echo "(no libunwind in usr/lib — good)"

echo "=== 7) stage Julia into bundle ==="
# usr/ is the self-contained, runnable Julia install.
cp -a usr "$BUNDLE_ROOT/julia"
export PATH="$BUNDLE_ROOT/julia/bin:$JULIA_DEPOT_PATH/bin:$PATH"
julia --version

echo "=== 8) install apozharski/JuliaC.jl as Pkg app (provides juliac) ==="
julia -e '
using Pkg
Pkg.add(url="https://github.com/apozharski/JuliaC.jl.git")
Pkg.Apps.add(url="https://github.com/apozharski/JuliaC.jl.git")
'
echo "  juliac at: $(command -v juliac || echo '<not on PATH>')"

echo "=== 9) record metadata + tar ==="
cat > "$BUNDLE_ROOT/TOOLCHAIN.txt" <<META
julia_version=$JULIA_VERSION
built_from_source=1
use_system_libunwind=1
bundles_libunwind=0
use_binarybuilder=$USE_BINARYBUILDER
cpu_target=$JULIA_CPU_TARGET
bundle_root=$BUNDLE_ROOT
META
cat "$BUNDLE_ROOT/TOOLCHAIN.txt"
TARBALL="$OUT_DIR/julia-toolchain-osx-arm64.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$BUNDLE_ROOT")" "$(basename "$BUNDLE_ROOT")"
ls -lh "$TARBALL"
