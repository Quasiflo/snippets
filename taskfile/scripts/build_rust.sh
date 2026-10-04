#!/usr/bin/env bash
# Build a Rust project for the host OS/arch Rust target triple.
# Call with PROJECT_NAME set, e.g. `task build_rust PROJECT_NAME=myapp`.
set -euo pipefail

PROJECT_NAME="{{.PROJECT_NAME}}"
if [[ -z ${PROJECT_NAME} ]]; then
	echo "PROJECT_NAME is required (call with PROJECT_NAME=<name>)" >&2
	exit 1
fi

# Resolve OS and arch
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
darwin) OS="apple" ;;
linux) OS="linux" ;;
*)
	echo "Unsupported OS: $OS"
	exit 1
	;;
esac

ARCH=$(uname -m)
case "$ARCH" in
x86_64) ARCH="amd64" ;;
aarch64 | arm64) ARCH="arm64" ;;
*)
	echo "Unsupported arch: $ARCH"
	exit 1
	;;
esac

# Resolve Rust target triple
case "$OS-$ARCH" in
linux-amd64) RUST_TARGET="x86_64-unknown-linux-musl" ;;
linux-arm64) RUST_TARGET="aarch64-unknown-linux-musl" ;;
apple-amd64) RUST_TARGET="x86_64-apple-darwin" ;;
apple-arm64) RUST_TARGET="aarch64-apple-darwin" ;;
*)
	echo "Unsupported OS/arch combination: $OS-$ARCH"
	exit 1
	;;
esac

NAME="$PROJECT_NAME-$RUST_TARGET"
TARBALL="release/$NAME.tar.gz"

mkdir -p release

# Ensure the musl C toolchain is present for musl targets.
# cc-rs (e.g. aws-lc-sys) probes for <target>-gcc and fails with
# ToolNotFound when musl-tools/musl-dev are missing on Debian images
# (cimg/base, ubuntu-2204). musl-dev ships the wrapper, so once the
# packages are installed the compiler is picked up automatically.
case "$RUST_TARGET" in
*-unknown-linux-musl)
	MUSL_CC=""
	case "$RUST_TARGET" in
	x86_64-*) MUSL_CC="x86_64-linux-musl-gcc" ;;
	aarch64-*) MUSL_CC="aarch64-linux-musl-gcc" ;;
	esac
	if ! command -v "$MUSL_CC" >/dev/null 2>&1 && ! command -v musl-gcc >/dev/null 2>&1; then
		if command -v apt-get >/dev/null 2>&1; then
			if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi
			$SUDO apt-get update && $SUDO apt-get install -y musl-tools musl-dev
		else
			echo "warning: $MUSL_CC not found and apt-get unavailable (musl build may fail)" >&2
		fi
	fi
	;;
esac

# Install target & precompiled std & build release
rustup target add "$RUST_TARGET"
rustup component add rust-std --target "$RUST_TARGET"
cargo build --release --target "$RUST_TARGET"

tar -czf "$TARBALL" -C "target/$RUST_TARGET/release" "$PROJECT_NAME"
echo "Created: $TARBALL"

# Copy unpacked binary for downstream tasks (stable path, no re-resolution needed)
mkdir -p tmp/binary
cp "target/$RUST_TARGET/release/$PROJECT_NAME" "tmp/binary/$PROJECT_NAME"
echo "Copied: tmp/binary/$PROJECT_NAME"
