# casadi/polyglot

Cross-language build environment + per-language artifact builders for the
casadi ecosystem. Today it ships:

- **Image**: `ghcr.io/casadi/polyglot:manylinux_2_28-{x64,aarch64}` —
  multi-language manylinux_2_28 build container with GCC 14, Rust + cbindgen,
  and a custom-built Julia 1.12.x (multi-target sysimage, no libunwind).
  Source lives on the [`docker`](../../tree/docker) branch.

- **Workflow**: `.github/workflows/build-libmad.yml` — pulls the polyglot
  image, builds [`jgillis/libMad`](https://github.com/jgillis/libMad) into
  a portable manylinux_2_28-compliant bundle, and uploads the result as
  a workflow artifact.

## Branches

| Branch  | Purpose                                                   |
|---------|-----------------------------------------------------------|
| `main`  | Consumer workflows that USE the polyglot image            |
| `docker`| Dockerfile + scripts that BUILD the polyglot image        |

`main` and `docker` evolve independently. Pushing to `docker` triggers a
new image build; pushing to `main` (or dispatching `build-libmad`) runs
the libMad bundler against whatever `:manylinux_2_28-{arch}` tag is
currently on ghcr.io.

## Building libMad locally

```sh
docker run --rm \
  -v "$PWD/build:/build" \
  -v "$PWD/libMad:/work/libMad" \
  ghcr.io/casadi/polyglot:manylinux_2_28-x64 \
  bash -c '
    set -e
    export JULIA_DEPOT_PATH=/build/.julia
    export PATH=$JULIA_DEPOT_PATH/bin:$PATH
    export JULIA_PKG_USE_CLI_GIT=true
    git config --global url."https://github.com/".insteadOf "git@github.com:"

    # Install patched JuliaC.jl as a Pkg app
    julia -e "using Pkg; Pkg.add(url=\"https://github.com/apozharski/JuliaC.jl.git\"); Pkg.Apps.add(url=\"https://github.com/apozharski/JuliaC.jl.git\")"

    # Pre-instantiate so we can patch CUDA_Driver_jll before juliac sees it
    julia --project=/work/libMad -e "using Pkg; Pkg.instantiate()"

    # Default JULIA_CUDA_USE_COMPAT to false in the wrapper (no env var
    # needed at runtime). See casadi/polyglot main-branch script.
    python3 /work/libMad/scripts/patch-cuda-driver-jll.py || true

    cmake -S /work/libMad -B /build/libMad-build \
      -DCMAKE_INSTALL_PREFIX=/build/libMad-install
    # juliac races with parallel make during multi-target AOT compile; use -j1.
    cmake --build /build/libMad-build --target install -- -j1
  '
```

(The workflow at `.github/workflows/build-libmad.yml` does the same plus
artifact upload + auditwheel compliance check.)
