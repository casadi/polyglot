#!/bin/bash
# Provision a relocatable Julia toolchain for the macOS arm64 libMad build.
# This is the macOS analogue of the `docker` branch's image build: it bakes
# the language toolchain (Julia + the JuliaC.jl `juliac` app) into a single
# tarball that the `main` branch consumes to build libMad. Docker can't run on
# macOS runners, so a published tarball stands in for a container image.
#
# The bundle is laid out under a FIXED absolute path ($BUNDLE_ROOT) so the
# depot's precompile caches stay valid when the consumer extracts it to the
# same location on an identical macos-14 image.
#
# Env:
#   JULIA_VERSION   Julia version to fetch        (default: 1.12.6)
#   BUNDLE_ROOT     where to lay out the bundle   (default: $HOME/polyglot-julia)
#   OUT_DIR         tarball output dir            (default: $PWD/out)
set -euo pipefail

JULIA_VERSION="${JULIA_VERSION:-1.12.6}"
BUNDLE_ROOT="${BUNDLE_ROOT:-$HOME/polyglot-julia}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
JULIA_MAJMIN="${JULIA_VERSION%.*}"

export JULIA_DEPOT_PATH="$BUNDLE_ROOT/depot"
export PATH="$BUNDLE_ROOT/julia/bin:$JULIA_DEPOT_PATH/bin:$PATH"
# libMad Manifest references public deps via git@github.com URLs; use HTTPS.
git config --global url."https://github.com/".insteadOf "git@github.com:"
export JULIA_PKG_USE_CLI_GIT=true

rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE_ROOT/julia" "$JULIA_DEPOT_PATH" "$OUT_DIR"

echo "=== 1) download official Julia $JULIA_VERSION (macaarch64) ==="
URL="https://julialang-s3.julialang.org/bin/mac/aarch64/${JULIA_MAJMIN}/julia-${JULIA_VERSION}-macaarch64.tar.gz"
echo "  $URL"
curl -fsSL "$URL" -o "$BUNDLE_ROOT/julia.tar.gz"
tar -xzf "$BUNDLE_ROOT/julia.tar.gz" -C "$BUNDLE_ROOT/julia" --strip-components=1
rm -f "$BUNDLE_ROOT/julia.tar.gz"
julia --version

echo "=== 2) install apozharski/JuliaC.jl as Pkg app (provides juliac) ==="
julia -e '
using Pkg
Pkg.add(url="https://github.com/apozharski/JuliaC.jl.git")
Pkg.Apps.add(url="https://github.com/apozharski/JuliaC.jl.git")
'
echo "  juliac at: $(command -v juliac || echo '<not on PATH>')"

echo "=== 3) record toolchain metadata ==="
cat > "$BUNDLE_ROOT/TOOLCHAIN.txt" <<META
julia_version=$JULIA_VERSION
bundle_root=$BUNDLE_ROOT
juliac=$(command -v juliac || echo missing)
META
cat "$BUNDLE_ROOT/TOOLCHAIN.txt"

echo "=== 4) tar bundle (relative to \$HOME so it restores to a fixed path) ==="
TARBALL="$OUT_DIR/julia-toolchain-osx-arm64.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$(dirname "$BUNDLE_ROOT")" "$(basename "$BUNDLE_ROOT")"
ls -lh "$TARBALL"
