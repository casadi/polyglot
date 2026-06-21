#!/bin/bash
# Build libMad natively on macOS arm64 (Apple Silicon). No Docker on macOS, so
# this is the native counterpart of build-libmad.sh (which runs in the Linux
# polyglot container). Expects the casadi/action-setup-compiler toolchain env
# (CC / CXX / FC / SDKROOT / CMAKE_BUILD_TYPE) and a Julia 1.12.x on PATH.
#
# Env:
#   SRC_DIR        libMad source tree            (default: $PWD/libMad)
#   BUILD_DIR      build + install scratch       (default: $PWD/build)
#   OUT_DIR        final zip output              (default: $PWD/out)
#   OSX_ARCH       cmake CMAKE_OSX_ARCHITECTURES (default: arm64)
#   CC/CXX/FC      compilers                     (from action-setup-compiler)
#   SDKROOT        macOS SDK path                (from action-setup-compiler)
set -euo pipefail

SRC_DIR="${SRC_DIR:-$PWD/libMad}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
OSX_ARCH="${OSX_ARCH:-arm64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Deploy-arch label mirrors casadi/casadi's osx-<target> convention.
DEPLOY_ARCH="osx-${OSX_ARCH}"

export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-$BUILD_DIR/.julia}"
export PATH="$JULIA_DEPOT_PATH/bin:$PATH"

# libMad Manifest references some public deps via git@github.com URLs; rewrite
# to HTTPS so no SSH key is needed.
git config --global url."https://github.com/".insteadOf "git@github.com:"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

echo "=== tooling ==="
julia --version
which julia juliac 2>/dev/null || true
"${CC:-cc}" --version | head -1 || true
"${FC:-gfortran}" --version | head -1 || true
cmake --version | head -1
echo "SDKROOT=${SDKROOT:-<unset>}  OSX_ARCH=${OSX_ARCH}"
echo

echo "=== 1) install apozharski/JuliaC.jl as Pkg app ==="
julia -e '
using Pkg
Pkg.add(url="https://github.com/apozharski/JuliaC.jl.git")
Pkg.Apps.add(url="https://github.com/apozharski/JuliaC.jl.git")
'

echo "=== 2) pre-instantiate libMad project ==="
julia --project="$SRC_DIR" -e 'using Pkg; Pkg.instantiate()'

echo "=== 3) patch CUDA_Driver_jll default (best-effort; Linux-only wrappers) ==="
# The patcher only targets *-linux-gnu.jl wrappers and hard-exits when none
# exist. On Apple Silicon CUDA is unsupported so there is nothing to patch —
# tolerate a non-zero exit rather than failing the build.
python3 "$SCRIPT_DIR/patch-cuda-driver-jll.py" || \
  echo "  (no CUDA_Driver_jll wrappers to patch on macOS — skipping)"

echo "=== 4) cmake configure ==="
cmake -S "$SRC_DIR" -B "$BUILD_DIR/cmake" \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
  -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
  -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
  ${SDKROOT:+-DCMAKE_OSX_SYSROOT="$SDKROOT"} \
  ${CC:+-DCMAKE_C_COMPILER="$CC"} \
  ${CXX:+-DCMAKE_CXX_COMPILER="$CXX"} \
  ${FC:+-DCMAKE_Fortran_COMPILER="$FC"}

# juliac's multi-target AOT compile threads race with `make -j>1` and SIGTERM
# each other; use -j1 for the outer make (same as the Linux build).
echo "=== 5) cmake build (--target install -- -j1) ==="
cmake --build "$BUILD_DIR/cmake" --target install --config Release -- -j1

echo "=== 6) trim unused CUDA artifacts (best effort) ==="
if [ -f "$SRC_DIR/scripts/trim_cuda_artifacts.jl" ] && \
   [ -d "$BUILD_DIR/install/share/julia/artifacts" ]; then
  cd "$BUILD_DIR/install/share/julia/artifacts"
  TRIM=$(julia --project="$SRC_DIR" "$SRC_DIR/scripts/trim_cuda_artifacts.jl" 2>/dev/null || true)
  if [ -n "${TRIM:-}" ]; then
    # shellcheck disable=SC2086
    rm -rf $TRIM
  fi
fi

echo "=== 7) zip bundle ==="
cd "$BUILD_DIR/install"
ZIP="$OUT_DIR/libMad-${DEPLOY_ARCH}.zip"
rm -f "$ZIP"
zip -rqy "$ZIP" .
ls -lh "$ZIP"
