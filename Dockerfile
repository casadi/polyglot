# syntax=docker/dockerfile:1.6
#
# casadi/polyglot — Linux native build (x86_64 or aarch64).
#
# Works on top of either:
#   - jgillis/dockcross-style image (manylinux_2_28 base with gcc-toolset,
#     Rust already at /opt/rustup, dockcross CC/CXX env vars set), or
#   - upstream pypa manylinux image (manylinux_2_28 base, no Rust yet —
#     scripts/install-rust.sh installs it).
#
# Bakes Julia from source with multi-target sysimage and DISABLE_LIBUNWIND.
#
# Build x64 (jgillis dockcross base, has Rust):
#   docker build -f Dockerfile.linux \
#     --build-arg BASE_IMAGE=ghcr.io/jgillis/manylinux_2_28-x64:production \
#     --build-arg TARGET_ARCH=x86_64 \
#     -t ghcr.io/casadi/polyglot:manylinux_2_28-x64 .
#
# Build aarch64 (pypa upstream — native aarch64 image, no Rust):
#   docker build -f Dockerfile.linux \
#     --build-arg BASE_IMAGE=quay.io/pypa/manylinux_2_28_aarch64:latest \
#     --build-arg TARGET_ARCH=aarch64 \
#     -t ghcr.io/casadi/polyglot:manylinux_2_28-aarch64 .

ARG BASE_IMAGE=ghcr.io/jgillis/manylinux_2_28-x64:production

# ───────────────────────── Stage 1: build Julia ──────────────────────────────

FROM ${BASE_IMAGE} AS julia-builder

ARG JULIA_VERSION=1.12.6
ARG TARGET_ARCH=x86_64
ARG BUILD_JOBS=4
ENV JULIA_VERSION=${JULIA_VERSION} \
    TARGET_ARCH=${TARGET_ARCH} \
    BUILD_JOBS=${BUILD_JOBS}

# Tools Julia source build needs.
#   - flex        absent from manylinux bases
#   - perl-core   OpenSSL's Configure needs Data::Dumper + IPC::Cmd; bare
#                 system Perl on pypa/CentOS-derived bases is minimal
RUN ( dnf install -y flex perl-core 2>/dev/null && dnf clean all ) \
 || ( yum install -y flex perl-core && yum clean all ) ; \
    rm -rf /var/cache/dnf /var/cache/yum 2>/dev/null || true

WORKDIR /build
RUN curl -fsSL -o "julia-${JULIA_VERSION}-full.tar.gz" \
      "https://github.com/JuliaLang/julia/releases/download/v${JULIA_VERSION}/julia-${JULIA_VERSION}-full.tar.gz" \
 && tar xzf "julia-${JULIA_VERSION}-full.tar.gz" \
 && rm "julia-${JULIA_VERSION}-full.tar.gz"

COPY scripts/build-julia.sh /tmp/build-julia.sh
RUN /tmp/build-julia.sh "/build/julia-${JULIA_VERSION}"

# ───────────────────────── Stage 2: final image ──────────────────────────────

FROM ${BASE_IMAGE}

ARG JULIA_VERSION=1.12.6
ARG TARGET_ARCH=x86_64

# Install Rust if not present + cbindgen on top. Idempotent — when the base
# already has Rust (jgillis dockcross), only cbindgen is installed.
COPY scripts/install-rust.sh /tmp/install-rust.sh
RUN /tmp/install-rust.sh && rm /tmp/install-rust.sh
ENV CARGO_HOME=/opt/rustup/cargo \
    RUSTUP_HOME=/opt/rustup \
    PATH=/opt/rustup/cargo/bin:${PATH}

# Add the per-target Rust triple (so `cargo build --target ...` works without
# a network fetch at run time).
RUN case "${TARGET_ARCH}" in \
      x86_64)  rustup target add x86_64-unknown-linux-gnu ;; \
      aarch64) rustup target add aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported TARGET_ARCH=${TARGET_ARCH}" >&2; exit 1 ;; \
    esac

# Default cargo to build for the image's native triple.
ENV TARGET_ARCH=${TARGET_ARCH} \
    CARGO_BUILD_TARGET=${TARGET_ARCH}-unknown-linux-gnu

# CARGO_TARGET_<TRIPLE>_LINKER + RUSTFLAGS=-C prefer-dynamic per jgillis/
# dockcross 6a0fa8d. Linker path differs across bases (gcc-toolset-14 on
# jgillis, plain /usr/bin/gcc on pypa), so resolve at build time.
RUN UP=$(echo "${TARGET_ARCH}_unknown_linux_gnu" | tr '[:lower:]' '[:upper:]'); \
    GCC=$( command -v "${CC:-gcc}" 2>/dev/null || command -v gcc ); \
    printf 'export CARGO_TARGET_%s_LINKER=%s\nexport CARGO_TARGET_%s_RUSTFLAGS=-C prefer-dynamic\n' \
        "$UP" "$GCC" "$UP" > /etc/profile.d/polyglot-cargo.sh

# Julia install. The Julia source tree's `usr/` IS the install prefix.
COPY --from=julia-builder /build/julia-${JULIA_VERSION}/usr /opt/julia
ENV JULIA_HOME=/opt/julia \
    JULIA_PATH=/opt/julia \
    JULIA_VERSION=${JULIA_VERSION}
ENV PATH=/opt/julia/bin:${PATH}

# Smoke test at image-build time so a broken build doesn't ship.
RUN julia --version && \
    julia -e 'println("Julia ", VERSION, " — LLVM ", Base.libllvm_version, " — CPU ", Sys.CPU_NAME)' && \
    rustc --version && cargo --version && cbindgen --version && \
    test ! -e /opt/julia/lib/libunwind.so && \
    echo "polyglot image OK"

LABEL org.opencontainers.image.title="manylinux_2_28 polyglot (Julia + Rust + C/C++)" \
      org.opencontainers.image.description="Multi-language build environment with manylinux_2_28 ABI: gcc/clang toolset, Rust stable + cbindgen, Julia built from source with multi-target sysimage and no libunwind." \
      org.opencontainers.image.source="https://github.com/casadi/polyglot" \
      org.opencontainers.image.licenses="MIT" \
      casadi.polyglot.julia.version="${JULIA_VERSION}" \
      casadi.polyglot.base="${BASE_IMAGE}" \
      casadi.polyglot.arch="${TARGET_ARCH}"

WORKDIR /work
