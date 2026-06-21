#!/bin/bash
# Build libMad natively on macOS arm64, consuming the prebuilt Julia toolchain
# provisioned by the `macos` branch (restored under $BUNDLE_ROOT, with juliac
# already installed in its depot). No Docker on macOS, so this is the native
# counterpart of build-libmad.sh. Expects the casadi/action-setup-compiler
# toolchain env (CC / CXX / FC / SDKROOT / CMAKE_BUILD_TYPE).
#
# Env:
#   BUNDLE_ROOT    extracted Julia toolchain root (default: $HOME/polyglot-julia)
#   SRC_DIR        libMad source tree            (default: $PWD/libMad)
#   BUILD_DIR      build + install scratch       (default: $PWD/build)
#   OUT_DIR        final zip output              (default: $PWD/out)
#   OSX_ARCH       CMAKE_OSX_ARCHITECTURES       (default: arm64)
set -euo pipefail

BUNDLE_ROOT="${BUNDLE_ROOT:-$HOME/polyglot-julia}"
SRC_DIR="${SRC_DIR:-$PWD/libMad}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
OSX_ARCH="${OSX_ARCH:-arm64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ARCH="osx-${OSX_ARCH}"

# Use the provisioned toolchain's Julia + depot (juliac lives in depot/bin).
export JULIA_DEPOT_PATH="$BUNDLE_ROOT/depot"
export PATH="$BUNDLE_ROOT/julia/bin:$JULIA_DEPOT_PATH/bin:$PATH"
export JULIA_PKG_USE_CLI_GIT=true
git config --global url."https://github.com/".insteadOf "git@github.com:"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

echo "=== tooling (from provisioned toolchain) ==="
julia --version
command -v juliac || { echo "juliac not found in provisioned depot" >&2; exit 1; }
"${CC:-cc}" --version | head -1 || true
"${FC:-gfortran}" --version | head -1 || true
cmake --version | head -1
echo "SDKROOT=${SDKROOT:-<unset>}  OSX_ARCH=${OSX_ARCH}  BUNDLE_ROOT=${BUNDLE_ROOT}"
echo

echo "=== 1) pre-instantiate libMad project ==="
julia --project="$SRC_DIR" -e 'using Pkg; Pkg.instantiate()'

echo "=== 2) patch CUDA_Driver_jll default (best-effort; Linux-only wrappers) ==="
python3 "$SCRIPT_DIR/patch-cuda-driver-jll.py" || \
  echo "  (no CUDA_Driver_jll wrappers to patch on macOS — skipping)"

echo "=== 3) cmake configure ==="
cmake -S "$SRC_DIR" -B "$BUILD_DIR/cmake" \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
  -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}" \
  -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
  ${SDKROOT:+-DCMAKE_OSX_SYSROOT="$SDKROOT"} \
  ${CC:+-DCMAKE_C_COMPILER="$CC"} \
  ${CXX:+-DCMAKE_CXX_COMPILER="$CXX"} \
  ${FC:+-DCMAKE_Fortran_COMPILER="$FC"}

# juliac's multi-target AOT compile threads race with `make -j>1`; use -j1.
echo "=== 4) cmake build (--target install -- -j1) ==="
cmake --build "$BUILD_DIR/cmake" --target install --config Release -- -j1

echo "=== 5) trim unused CUDA artifacts (best effort) ==="
if [ -f "$SRC_DIR/scripts/trim_cuda_artifacts.jl" ] && \
   [ -d "$BUILD_DIR/install/share/julia/artifacts" ]; then
  cd "$BUILD_DIR/install/share/julia/artifacts"
  TRIM=$(julia --project="$SRC_DIR" "$SRC_DIR/scripts/trim_cuda_artifacts.jl" 2>/dev/null || true)
  if [ -n "${TRIM:-}" ]; then
    # shellcheck disable=SC2086
    rm -rf $TRIM
  fi
fi

echo "=== 6) zip bundle ==="
cd "$BUILD_DIR/install"
ZIP="$OUT_DIR/libMad-${DEPLOY_ARCH}.zip"
rm -f "$ZIP"
zip -rqy "$ZIP" .
ls -lh "$ZIP"
