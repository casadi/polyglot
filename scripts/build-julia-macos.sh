#!/bin/bash
# Build Julia from source on macOS arm64 with libunwind DISABLED, then bake it
# (+ the JuliaC.jl `juliac` app) into a relocatable toolchain tarball consumed
# by the `main` branch to build libMad. This is the macOS analogue of the
# `docker` branch's scripts/build-julia.sh.
#
# Why from source: the official Julia macOS binary bundles libunwind, which
# clashes when libMad is loaded into a host that already has one (the same
# "Matlab clash" the Linux build avoids). DISABLE_LIBUNWIND=1 + the
# JuliaLang/julia#61899 source patches produce a Julia with no libunwind.
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

echo "=== 1) fetch Julia $JULIA_VERSION full source ==="
# The -full tarball bundles dependency sources needed for USE_BINARYBUILDER=0.
URL="https://github.com/JuliaLang/julia/releases/download/v${JULIA_VERSION}/julia-${JULIA_VERSION}-full.tar.gz"
echo "  $URL"
curl -fL "$URL" -o "$WORK/julia-src.tar.gz"
mkdir -p "$WORK/src"
tar -xzf "$WORK/julia-src.tar.gz" -C "$WORK/src" --strip-components=1
cd "$WORK/src"

echo "=== 2) Make.user (DISABLE_LIBUNWIND) ==="
cat > Make.user <<EOF
USE_BINARYBUILDER=${USE_BINARYBUILDER}
JULIA_CPU_TARGET=${JULIA_CPU_TARGET}
DISABLE_LIBUNWIND:=1
EOF
cat Make.user
echo

echo "=== 3) apply DISABLE_LIBUNWIND fix (JuliaLang/julia#61899) ==="
python3 <<'PY'
import sys
# Patch 1 — signals-unix.c: declare signal_bt_data/_size outside the libunwind
# guard so signal_listener (which uses them unconditionally) always links.
p = 'src/signals-unix.c'
s = open(p).read()
needle = ('#if !defined(JL_DISABLE_LIBUNWIND)\n\n'
          'static jl_bt_element_t signal_bt_data[JL_MAX_BT_SIZE + 1];\n'
          'static size_t signal_bt_size = 0;\n')
replacement = (
    '// polyglot patch (also JuliaLang/julia#61899): declare these\n'
    '// unconditionally — signal_listener uses them outside any libunwind guard.\n'
    'static jl_bt_element_t signal_bt_data[JL_MAX_BT_SIZE + 1];\n'
    'static size_t signal_bt_size = 0;\n\n'
    '#if !defined(JL_DISABLE_LIBUNWIND)\n\n'
)
if needle in s:
    open(p, 'w').write(s.replace(needle, replacement, 1)); print(f'patched {p}')
elif 'polyglot patch (also JuliaLang/julia#61899)' in s:
    print(f'{p} already patched, skipping')
else:
    sys.exit(f'PATCH1 FAILED: needle not found in {p}')

# Patch 2 — stackwalk.c: short-circuit jl_simulate_longjmp under
# JL_DISABLE_LIBUNWIND (its body uses bt_context_t/uc_mcontext, absent then).
p = 'src/stackwalk.c'
s = open(p).read()
needle = ('int jl_simulate_longjmp(jl_jmp_buf mctx, bt_context_t *c) JL_NOTSAFEPOINT\n'
          '{\n'
          '#if (defined(_COMPILER_ASAN_ENABLED_) || defined(_COMPILER_TSAN_ENABLED_))\n')
replacement = (
    'int jl_simulate_longjmp(jl_jmp_buf mctx, bt_context_t *c) JL_NOTSAFEPOINT\n'
    '{\n'
    '#if defined(JL_DISABLE_LIBUNWIND)\n'
    '    (void)mctx; (void)c;\n'
    '    return 0;\n'
    '#elif (defined(_COMPILER_ASAN_ENABLED_) || defined(_COMPILER_TSAN_ENABLED_))\n'
)
if needle in s:
    open(p, 'w').write(s.replace(needle, replacement, 1)); print(f'patched {p}')
elif '#if defined(JL_DISABLE_LIBUNWIND)\n    (void)mctx; (void)c;' in s:
    print(f'{p} already patched, skipping')
else:
    sys.exit(f'PATCH2 FAILED: needle not found in {p}')
PY
echo

echo "=== 4) build (make -j$BUILD_JOBS) ==="
date
time make -j"$BUILD_JOBS"
date

echo "=== 5) smoke test ==="
./julia -e 'println("Julia ", VERSION, " — LLVM ", Base.libllvm_version); println("CPU ", Sys.CPU_NAME)'

echo "=== 6) libunwind gate (usr/lib must have none) ==="
if compgen -G "usr/lib/libunwind*" > /dev/null || compgen -G "usr/lib/julia/libunwind*" > /dev/null; then
  echo "ERROR: libunwind present despite DISABLE_LIBUNWIND=1" >&2
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
disable_libunwind=1
use_binarybuilder=$USE_BINARYBUILDER
cpu_target=$JULIA_CPU_TARGET
bundle_root=$BUNDLE_ROOT
META
cat "$BUNDLE_ROOT/TOOLCHAIN.txt"
TARBALL="$OUT_DIR/julia-toolchain-osx-arm64.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$BUNDLE_ROOT")" "$(basename "$BUNDLE_ROOT")"
ls -lh "$TARBALL"
