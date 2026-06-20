#!/bin/bash
# Build the real Clarabel C library (Clarabel.cpp -> Rust crate via cargo +
# cbindgen) inside the polyglot image, producing a portable manylinux_2_28
# libclarabel_c bundle. Bind-mounts expected:
#   /work/clarabel   Clarabel.cpp source (rw; cargo builds in-source: Cargo.lock, target/)
#   /work/build      build + install (rw)
#   /work/out        final tar.gz output (rw)
# Env:
#   ARCH (optional)  used only to name the output tarball; defaults to native
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
esac

# Clarabel's rust_wrapper may reference deps via git@github.com; rewrite to HTTPS.
git config --global url."https://github.com/".insteadOf "git@github.com:"

echo "=== tooling ==="
cmake --version | head -1
gcc --version | head -1
rustc --version || true
cargo --version || true
cbindgen --version || true
echo

# Examples OFF -> no Eigen3 needed; only the C library (clarabel_c) is built.
# Header layout (include/clarabel) matches CasADi's WITH_BUILD_CLARABEL path.
echo "=== configure ==="
cmake -S /work/clarabel -B /work/build/cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DCLARABEL_BUILD_EXAMPLES=OFF \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_INCLUDEDIR=include/clarabel \
  -DCMAKE_INSTALL_PREFIX=/work/build/install

echo "=== build + install ==="
cmake --build /work/build/cmake --target install --config Release -- -j"$(nproc)"

echo "=== tar bundle ==="
cd /work/build
tar -czf "/work/out/clarabel-${ARCH}.tar.gz" -C install .
ls -lh "/work/out/clarabel-${ARCH}.tar.gz"
