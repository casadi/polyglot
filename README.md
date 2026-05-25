# casadi/polyglot — docker-manylinux_2_28-aarch64 branch

Single-image branch that builds `ghcr.io/casadi/manylinux_2_28-aarch64-polyglot:production`.

Layered on `quay.io/pypa/manylinux_2_28_aarch64:latest` (PyPA upstream —
a native aarch64 image; the jgillis dockcross variant is mislabeled amd64
and would exec-format-error on ARM runners):

- GCC + cmake (from base, AlmaLinux 8 aarch64)
- Rust stable + cargo + cbindgen 0.28 (installed here via
  `scripts/install-rust.sh` — pypa base lacks Rust by default)
- Cargo cross-link env (`CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu`)
- Julia 1.12.x built from source with `JULIA_CPU_TARGET=generic`
  (JuliaCI's official aarch64-linux target) and `DISABLE_LIBUNWIND=1`
  (incl. the JuliaLang/julia#61899 source patches).

CI runs on `ubuntu-24.04-arm` (GitHub-hosted ARM runner) for a native
build. Do NOT use QEMU emulation — Julia's LLVM source build is
impractical under emulation. If `ubuntu-24.04-arm` isn't available to
the casadi org, swap the runner for a self-hosted ARM machine.

Build is ~2-3 h wall (LLVM dominates; aarch64 runners tend to be slower
than x64 ubuntu-latest).

Sister branches:
- `docker-manylinux_2_28-x64` — native Linux x64
- `docker-windows-shared-x64-posix` — Windows cross-build
- `main` — libMad consumer workflow
