#!/bin/bash
# Install rustup + Rust stable + cbindgen if not already present.
# Mirrors jgillis/dockcross's imagefiles/install-rust.sh (commit 6a0fa8d
# "Adding rust") so polyglot images built from a pypa-style base end up
# with the same Rust layout as the jgillis/dockcross variants.
set -euo pipefail

if command -v cargo >/dev/null 2>&1; then
    echo "cargo already on PATH ($(cargo --version)); skipping rustup install"
else
    echo "installing rustup + Rust stable into /opt/rustup ..."
    case "$(uname -m)" in
      x86_64)  TRIPLE=x86_64-unknown-linux-gnu ;;
      aarch64) TRIPLE=aarch64-unknown-linux-gnu ;;
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
    curl --proto '=https' --tlsv1.2 -sSf \
      "https://static.rust-lang.org/rustup/dist/${TRIPLE}/rustup-init" \
      -o rustup-init
    chmod +x rustup-init
    RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/rustup/cargo \
      ./rustup-init -y --default-toolchain=stable --default-host="${TRIPLE}" \
                    --no-modify-path
    rm rustup-init
    # Shim every cargo/rustup binary into /usr/local/bin so they're on PATH
    # regardless of how the image is invoked.
    for FILE in /opt/rustup/cargo/bin/*; do
      [ -x "$FILE" ] && [ -f "$FILE" ] || continue
      cat > "/usr/local/bin/${FILE##*/}" <<EOF
#!/bin/sh
RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/rustup/cargo exec /opt/rustup/cargo/bin/\${0##*/} "\$@"
EOF
      chmod +x "/usr/local/bin/${FILE##*/}"
    done
fi

# cbindgen — matches dockcross 6a0fa8d (Rust 1.84.1 + cbindgen 0.28.0
# combo, but we don't pin Rust here since the base might already have a
# newer toolchain).
if command -v cbindgen >/dev/null 2>&1; then
    echo "cbindgen already present ($(cbindgen --version)); skipping"
else
    RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/rustup/cargo \
      cargo install cbindgen --version 0.28.0
    # Drop registry+git cache (saves ~500MB in the final image)
    rm -rf /opt/rustup/cargo/registry /opt/rustup/cargo/git
fi
