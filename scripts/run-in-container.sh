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
echo "=== Materialize share/julia symlinks ==="
# Julia's in-source-tree `usr/` install layout symlinks every stdlib package
# AND several top-level dirs (test/, base/, Compiler/) back to the source
# tree at /build/julia-X.Y.Z/{stdlib,test,base,Compiler,deps/scratch/...}.
# After we rm-rf the source tree below, those dangle, and:
#   - `using Pkg` / `using LinearAlgebra` fail with "Package X not found".
#   - REPL precompile fails at `include("test/testhelpers/FakePTYs.jl")`.
#   - Stack traces lose source-line info from base/.
# Some symlinks (e.g. base/JuliaSyntax → deps/scratch/JuliaSyntax-<hash>)
# are themselves children of other symlinked dirs; materializing the
# parent surfaces these nested ones, so iterate until stable. Only
# follow symlinks whose target lies OUTSIDE the install tree (the
# only ones that go dangling when /build is wiped); leave internal
# relative symlinks alone so packages with their own layout still work.
SJ="/build/julia-${JULIA_VERSION}/usr/share/julia"
INSTALL_ROOT="/build/julia-${JULIA_VERSION}/usr"
while :; do
  did_one=0
  while IFS= read -r link; do
    tgt=$(readlink -f "$link") || continue
    case "$tgt" in
      "$INSTALL_ROOT"/*) continue ;;
    esac
    [ -e "$tgt" ] || continue
    rm "$link"
    cp -a "$tgt" "$link"
    did_one=1
  done < <(find "$SJ" -type l)
  [ "$did_one" = 0 ] && break
done

echo
echo "=== Move julia install into /opt/julia ==="
# build-julia.sh left us inside /build/julia-${JULIA_VERSION}. Step out before
# the rm-rf below, otherwise subsequent subshells inherit a deleted cwd and
# fail with "getcwd: No such file or directory" / "Unable to proceed. Could
# not locate working directory.".
cd /
mv "/build/julia-${JULIA_VERSION}/usr" /opt/julia
# Strip everything else — sources, srccache, scratch, intermediate artifacts.
# Leaves /opt/julia as the only thing committed into the final image.
rm -rf "/build/julia-${JULIA_VERSION}" /build/*.tar.gz
rmdir /build 2>/dev/null || true
cd /

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
# Quote the multi-token RUSTFLAGS value — without quotes the file expands to
# `export VAR=-C prefer-dynamic` which bash parses as two args (VAR=-C and
# prefer-dynamic) and complains: "export: 'prefer-dynamic': not a valid
# identifier".
printf 'export CARGO_TARGET_%s_LINKER=%s\nexport CARGO_TARGET_%s_RUSTFLAGS="-C prefer-dynamic"\n' \
    "$UP" "$GCC" "$UP" > /etc/profile.d/polyglot-cargo.sh

echo
echo "=== In-container smoketest ==="
# Some base images (pypa manylinux aarch64) don't pre-export RUSTUP_HOME /
# CARGO_HOME, so the rustup-proxy binaries at /opt/rustup/cargo/bin can't
# locate their config and fail with "rustup could not choose a version of
# rustc to run". The /usr/local/bin shims install-rust.sh drops do export
# them, but only when invoked through them. Belt-and-braces: export here,
# and put /usr/local/bin ahead of /opt/rustup/cargo/bin so the shims win.
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/rustup/cargo
export PATH=/opt/julia/bin:/usr/local/bin:/opt/rustup/cargo/bin:$PATH
julia --version
julia -e 'println("Julia ", VERSION, " — LLVM ", Base.libllvm_version, " — CPU ", Sys.CPU_NAME)'
# Exercise stdlib loading — catches dangling symlink regressions like
# the one that shipped before stdlib materialization was added below.
julia -e 'using Pkg, LinearAlgebra, Random; println("stdlib loadable: Pkg ", pkgversion(Pkg))'
rustc --version
cargo --version
cbindgen --version
test ! -e /opt/julia/lib/libunwind.so
echo "polyglot pre-commit OK"
