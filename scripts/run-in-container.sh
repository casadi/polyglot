#!/bin/bash
# Orchestrate the full polyglot image build inside the base manylinux container.
# Invoked by the CI workflow under `docker run --name polyglot-build ...`;
# the workflow then `docker commit`s the resulting container into the image.
#
# Required env vars:
#   JULIA_VERSION       e.g. 1.12.6
#   JULIA_TARGET_ARCH   x86_64 | aarch64   (NOT named TARGET_ARCH — that name
#                                           collides with GNU make's built-in
#                                           implicit-rule variable and poisons
#                                           the `%.o: %.c` recipe — see skill
#                                           gnu-make-target-arch-env-collision)
#   BUILD_JOBS          make parallelism (CI defaults to 4)
set -euo pipefail

: "${JULIA_VERSION:?JULIA_VERSION required}"
: "${JULIA_TARGET_ARCH:?JULIA_TARGET_ARCH required}"
: "${BUILD_JOBS:=4}"

# Defensive: this var must NEVER reach `make`. See skill referenced above.
unset TARGET_ARCH

echo "=== Install build-time packages ==="
# flex     — not pre-installed in manylinux_2_28 / pypa bases
# perl-core — OpenSSL Configure needs Data::Dumper + IPC::Cmd
( dnf install -y flex perl-core 2>&1 | tail -5 ) \
  || ( yum install -y flex perl-core 2>&1 | tail -5 )
( dnf clean all 2>/dev/null || yum clean all ) >/dev/null 2>&1 || true
rm -rf /var/cache/dnf /var/cache/yum 2>/dev/null || true

echo
echo "=== Fetch Julia ${JULIA_VERSION} source ==="
mkdir -p /build
cd /build
curl -fsSL -o "julia-${JULIA_VERSION}-full.tar.gz" \
  "https://github.com/JuliaLang/julia/releases/download/v${JULIA_VERSION}/julia-${JULIA_VERSION}-full.tar.gz"
tar xzf "julia-${JULIA_VERSION}-full.tar.gz"
rm "julia-${JULIA_VERSION}-full.tar.gz"

echo
echo "=== Build Julia (delegates to scripts/build-julia.sh) ==="
JULIA_TARGET_ARCH="$JULIA_TARGET_ARCH" BUILD_JOBS="$BUILD_JOBS" \
  /work/scripts/build-julia.sh "/build/julia-${JULIA_VERSION}"

echo
echo "=== Move julia install into /opt/julia ==="
mv "/build/julia-${JULIA_VERSION}/usr" /opt/julia
# Strip everything else — sources, srccache, scratch, intermediate artifacts.
# Leaves /opt/julia as the only thing committed into the final image.
rm -rf "/build/julia-${JULIA_VERSION}" /build/*.tar.gz
rmdir /build 2>/dev/null || true

echo
echo "=== Install Rust + cbindgen (idempotent: skips if already present) ==="
/work/scripts/install-rust.sh

# Add the per-target Rust triple.
case "${JULIA_TARGET_ARCH}" in
  x86_64)  RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/rustup/cargo rustup target add x86_64-unknown-linux-gnu ;;
  aarch64) RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/rustup/cargo rustup target add aarch64-unknown-linux-gnu ;;
esac

echo
echo "=== Drop cargo profile shim into /etc/profile.d ==="
UP=$(echo "${JULIA_TARGET_ARCH}_unknown_linux_gnu" | tr '[:lower:]' '[:upper:]')
GCC=$( command -v "${CC:-gcc}" 2>/dev/null || command -v gcc )
printf 'export CARGO_TARGET_%s_LINKER=%s\nexport CARGO_TARGET_%s_RUSTFLAGS=-C prefer-dynamic\n' \
    "$UP" "$GCC" "$UP" > /etc/profile.d/polyglot-cargo.sh

echo
echo "=== In-container smoketest ==="
export PATH=/opt/julia/bin:/opt/rustup/cargo/bin:$PATH
julia --version
julia -e 'println("Julia ", VERSION, " — LLVM ", Base.libllvm_version, " — CPU ", Sys.CPU_NAME)'
rustc --version
cargo --version
cbindgen --version
test ! -e /opt/julia/lib/libunwind.so
echo "polyglot pre-commit OK"
