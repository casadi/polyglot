#!/bin/bash
# Build libMad inside the polyglot image. Bind-mounts expected:
#   /work/libMad           libMad source (ro)
#   /work/scripts          this directory (ro) — for the CUDA_Driver_jll patcher
#   /work/build            build + install (rw)
#   /work/out              final tar.gz output (rw)
# Env:
#   ARCH (optional)        used only to name the output tarball; defaults to native
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
esac

export JULIA_DEPOT_PATH=/work/build/.julia
export PATH="$JULIA_DEPOT_PATH/bin:$PATH"

# libMad Manifest references some deps via git@github.com URLs that are
# actually public; rewrite to HTTPS so no SSH key is needed.
git config --global url."https://github.com/".insteadOf "git@github.com:"

echo "=== tooling ==="
julia --version
which julia juliac 2>/dev/null || true
rustc --version || true
cmake --version | head -1
gcc --version | head -1
echo

echo "=== 1) install apozharski/JuliaC.jl as Pkg app ==="
julia -e '
using Pkg
Pkg.add(url="https://github.com/apozharski/JuliaC.jl.git")
Pkg.Apps.add(url="https://github.com/apozharski/JuliaC.jl.git")
'

echo "=== 2) pre-instantiate libMad project ==="
julia --project=/work/libMad -e 'using Pkg; Pkg.instantiate()'

echo "=== 3) patch CUDA_Driver_jll default ==="
python3 /work/scripts/patch-cuda-driver-jll.py

echo "=== 4) cmake configure ==="
cmake -S /work/libMad -B /work/build/cmake \
  -DCMAKE_INSTALL_PREFIX=/work/build/install

# juliac's multi-target AOT compile threads race with `make -j>1` and
# SIGTERM each other; use -j1 for the outer make.
echo "=== 5) cmake build (--target install -- -j1) ==="
cmake --build /work/build/cmake --target install --config Release -- -j1

echo "=== 6) trim unused CUDA artifacts (best effort) ==="
if [ -f /work/libMad/scripts/trim_cuda_artifacts.jl ] && \
   [ -d /work/build/install/share/julia/artifacts ]; then
  cd /work/build/install/share/julia/artifacts
  TRIM=$(julia --project=/work/libMad /work/libMad/scripts/trim_cuda_artifacts.jl 2>/dev/null || true)
  if [ -n "${TRIM:-}" ]; then
    # shellcheck disable=SC2086
    rm -rf $TRIM
  fi
fi

echo "=== 7) tar bundle ==="
cd /work/build
tar -czf "/work/out/libMad-${ARCH}.tar.gz" -C install .
ls -lh "/work/out/libMad-${ARCH}.tar.gz"
