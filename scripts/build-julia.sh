#!/bin/bash
# Build Julia from source with the polyglot image's settings:
#   - USE_BINARYBUILDER=0          → fully self-contained source build
#   - multi-target sysimage       → official JuliaCI x86_64 / aarch64 target list
#   - DISABLE_LIBUNWIND=1         → no libunwind in the bundle (Matlab clash workaround)
#                                    requires the JuliaLang/julia#61899 fix patched
#                                    into src/{signals-unix.c,stackwalk.c}
#
# Args: $1 = path to extracted Julia source tree (containing Make.inc)
# Env:  JULIA_TARGET_ARCH  (x86_64 | aarch64)   — defaults to native
#       BUILD_JOBS                         — make parallelism (default 4)
set -euo pipefail
SRC="${1:?Julia source tree path required}"
JULIA_TARGET_ARCH="${JULIA_TARGET_ARCH:-$(uname -m)}"
BUILD_JOBS="${BUILD_JOBS:-4}"

# GNU make's built-in implicit recipe for `%.o: %.c` is
#   $(CC) $(CFLAGS) $(CPPFLAGS) $(TARGET_ARCH) -c $<
# so an inherited TARGET_ARCH env var (e.g. "x86_64") leaks in as a positional
# gcc arg via Julia's sub-makes (libwhich, OpenBLAS, ...), failing with
# `gcc: error: x86_64: linker input file not found`. Strip it defensively.
unset TARGET_ARCH

cd "$SRC"

# JULIA_CPU_TARGET — multi-target string matching JuliaCI's official binary
# builds (utilities/build_envs.sh).
case "$JULIA_TARGET_ARCH" in
  x86_64)
    JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)"
    ;;
  aarch64)
    # JuliaCI ships only "generic" for aarch64-linux.
    JULIA_CPU_TARGET="generic"
    ;;
  *)
    echo "Unsupported JULIA_TARGET_ARCH=$JULIA_TARGET_ARCH" >&2; exit 1
    ;;
esac

cat > Make.user <<EOF
USE_BINARYBUILDER=0
JULIA_CPU_TARGET=${JULIA_CPU_TARGET}
DISABLE_LIBUNWIND:=1
EOF
echo "=== Make.user ==="
cat Make.user
echo
echo "=== Toolchain ==="
set +o pipefail  # SIGPIPE on `head -1` would otherwise abort under `set -e`
gcc --version 2>/dev/null | head -1 || true
g++ --version 2>/dev/null | head -1 || true
gfortran --version 2>/dev/null | head -1 || true
cmake --version 2>/dev/null | head -1 || true
make --version 2>/dev/null | head -1 || true
echo -n "glibc: "; ldd --version 2>&1 | head -1 || true
set -o pipefail
echo

echo "=== Env vars Julia's Make.inc reads ==="
for v in ARCH CC CXX FC HOSTCC HOSTCXX MARCH MCPU MTUNE CFLAGS CXXFLAGS \
         CPPFLAGS LDFLAGS XC_HOST CROSS_TRIPLE CROSS_ROOT MAKEFLAGS MFLAGS; do
  eval "val=\${$v-<unset>}"
  printf '  %-15s = %s\n' "$v" "$val"
done
echo
echo "=== Make's view (single-shot, no build) ==="
# Print what Julia's outer make computes for the suspect vars without
# actually building anything. Helps diagnose the libwhich x86_64 issue.
make --no-print-directory print-CC print-HOSTCC print-CFLAGS \
                          print-MARCH print-MCPU print-MTUNE 2>&1 \
  | head -20 || true
echo

# Apply DISABLE_LIBUNWIND fix patches in-place via python string replacement.
# This is more robust than `patch` against minor line-number drift across
# Julia versions (the same fix submitted as JuliaLang/julia#61899). When the
# upstream Julia version baked in here already has the fix, the script no-ops.
echo "=== Apply DISABLE_LIBUNWIND fix patches ==="
python3 <<'PY'
import re, sys

# Patch 1 — signals-unix.c: move signal_bt_data/_size declarations out of
# the libunwind guard so they always exist. signal_listener uses them
# unconditionally; with libunwind disabled they stay at zero.
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
    open(p, 'w').write(s.replace(needle, replacement, 1))
    print(f'patched {p}')
elif 'polyglot patch (also JuliaLang/julia#61899)' in s or \
     'declare these\n// unconditionally' in s:
    print(f'{p} already patched, skipping')
else:
    sys.exit(f'PATCH1 FAILED: needle not found in {p}')

# Patch 2 — stackwalk.c: short-circuit jl_simulate_longjmp under
# JL_DISABLE_LIBUNWIND (bt_context_t becomes int, the function body's
# uc_mcontext etc. don't compile).
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
    open(p, 'w').write(s.replace(needle, replacement, 1))
    print(f'patched {p}')
elif '#if defined(JL_DISABLE_LIBUNWIND)\n    (void)mctx; (void)c;' in s:
    print(f'{p} already patched, skipping')
else:
    sys.exit(f'PATCH2 FAILED: needle not found in {p}')
PY
echo

echo "=== Build ==="
date
time make -j"$BUILD_JOBS"
date
echo

echo "=== Smoke test ==="
./julia -e 'println("Julia ", VERSION, " — LLVM ", Base.libllvm_version); println("CPU ", Sys.CPU_NAME)'

echo "=== libunwind check (must be empty) ==="
if compgen -G "usr/lib/libunwind*" > /dev/null; then
  echo "ERROR: libunwind made it into usr/lib even with DISABLE_LIBUNWIND=1" >&2
  ls usr/lib/libunwind* >&2
  exit 1
fi
echo "(no libunwind in usr/lib — good)"

echo "=== Done ==="
