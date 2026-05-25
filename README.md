# casadi/polyglot — docker-manylinux_2_28-x64 branch

Single-image branch that builds `ghcr.io/casadi/manylinux_2_28-x64-polyglot:production`.

Layered on `ghcr.io/jgillis/manylinux_2_28-x64:production`:
- GCC 14 toolset + cmake (from base)
- Rust stable + cargo (from base) + cbindgen 0.28 (installed here)
- Cargo cross-link env (`CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu`)
- Julia 1.12.x built from source with multi-target sysimage and
  `DISABLE_LIBUNWIND=1` (incl. the JuliaLang/julia#61899 source patches).

CI: pushes to this branch fire `.github/workflows/build-image.yml`. Build is
~90 min wall (LLVM compile dominates). `BUILD_JOBS=1` to sidestep the
BuildKit `docker build` parallel-make race in Julia's deps phase.

Sister branches:
- `docker-windows-shared-x64-posix` — Windows cross-build image
- `docker-manylinux_2_28-aarch64` *(not yet created)*
- `main` — libMad consumer workflow that pulls these images
