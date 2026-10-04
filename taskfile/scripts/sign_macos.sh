#!/usr/bin/env bash
# Sign a macOS binary with a Developer ID Application certificate.
# Expects tmp/binary/PROJECT_NAME from the build_rust task.
# Call with PROJECT_NAME set, e.g. `task sign_macos PROJECT_NAME=myapp`.
# Requires signing credentials in the environment (provided by fnox).
# Overwrites release/<name>.tar.gz with the signed binary so downstream
# `gh release upload` publishes the signed asset. Notarization itself is
# not stapled here and remains a separate step.
set -euo pipefail

PROJECT_NAME="{{.PROJECT_NAME}}"
if [[ -z ${PROJECT_NAME} ]]; then
	echo "PROJECT_NAME is required (call with PROJECT_NAME=<name>)" >&2
	exit 1
fi

: "${APPLE_CERTIFICATE:?APPLE_CERTIFICATE is required in the environment (base64-encoded .p12)}"
: "${APPLE_CERT_PASSWORD:?APPLE_CERT_PASSWORD is required in the environment}"
: "${APPLE_SIGN_IDENTITY:?APPLE_SIGN_IDENTITY is required in the environment (e.g. 'Developer ID Application: Name (TEAMID)')}"

# Ephemeral keychain password: the keychain lives only for this job run,
# so invent a random password per run instead of storing one in Infisical.
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"

# Resolve Rust target triple (same mapping as build_rust.sh) so we can
# overwrite the matching release tarball with the signed binary.
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
darwin) OS="apple" ;;
*)
	echo "sign_macos is only supported on macOS (got: $OS)" >&2
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

case "$OS-$ARCH" in
apple-amd64) RUST_TARGET="x86_64-apple-darwin" ;;
apple-arm64) RUST_TARGET="aarch64-apple-darwin" ;;
*)
	echo "Unsupported OS/arch combination: $OS-$ARCH"
	exit 1
	;;
esac

NAME="$PROJECT_NAME-$RUST_TARGET"
TARBALL="release/$NAME.tar.gz"
BINARY="tmp/binary/$PROJECT_NAME"

if [[ ! -f ${BINARY} ]]; then
	echo "${BINARY} not found (run build_rust first)" >&2
	exit 1
fi

# NOTE: mvdan/sh (Task's interpreter) only supports `trap ... EXIT`
# (no INT/TERM), so keep EXIT-only for Task compatibility.
CERT_FILE="$(mktemp /tmp/AppleCert_XXXXXX.p12)"
chmod 600 "$CERT_FILE"
KEYCHAIN="build-sign.keychain"
trap 'rm -f "$CERT_FILE"; security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true' EXIT
printf '%s' "$APPLE_CERTIFICATE" | base64 --decode -o "$CERT_FILE"

KEYCHAIN="build-sign.keychain"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT_FILE" -k "$KEYCHAIN" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# Prepend our keychain so codesign finds the imported identity without
# disturbing the login keychain search order for anything else.
security list-keychains -d user -s "$KEYCHAIN" "$(security list-keychains -d user | tr -d '",[]')"

codesign --sign "$APPLE_SIGN_IDENTITY" \
	--timestamp --options runtime \
	--force --verify --verbose \
	"$BINARY"

codesign --verify --deep --strict --verbose=2 "$BINARY"

# Overwrite the release tarball with the signed binary so the uploaded
# release asset is signed. Contents (single top-level binary) match the
# unsigned tarball layout from build_rust.sh.
mkdir -p release
tar -czf "$TARBALL" -C "tmp/binary" "$PROJECT_NAME"
echo "Repackaged signed: $TARBALL"

rm -f "$CERT_FILE"
security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
