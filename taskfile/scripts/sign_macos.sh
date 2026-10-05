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
INTERMED_DIR="$(mktemp -d)"
KEYCHAIN="$HOME/Library/Keychains/build-sign.keychain-db"
# NOTE: $ORIG_KEYCHAINS is intentionally unquoted in the restore so it
# word-splits back into separate keychain paths (it is set below before use;
# the :- default keeps `set -u` happy if we exit before that).
trap 'security list-keychains -d user -s ${ORIG_KEYCHAINS-} >/dev/null 2>&1 || true; rm -rf "$INTERMED_DIR"; rm -f "$CERT_FILE"; security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true' EXIT
printf '%s' "$APPLE_CERTIFICATE" | base64 --decode -o "$CERT_FILE"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# Put our keychain on the user search list so policy evaluation can see the
# intermediates it holds (evaluation walks the search list, not just the file
# handed to --keychain/find-identity). Unquoted expansion is intentional
# (word-splitting); the old quoted form collapsed the list into one bogus path.
# Unquoted $ORIG_KEYCHAINS expansion is intentional (word-splitting back into
# separate paths); the old quoted form collapsed the list into one bogus path.
ORIG_KEYCHAINS="$(security list-keychains -d user | tr -d '",[]')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $ORIG_KEYCHAINS

# Install Apple's Developer ID intermediate so the fresh keychain can build
# a trusted chain. Without it `find-identity -p codesigning` reports
# 0 valid identities even with the correct leaf+key (public cert, Apple PKI).
curl -fsSL -o "$INTERMED_DIR/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security add-certificates -k "$KEYCHAIN" "$INTERMED_DIR/DeveloperIDG2CA.cer"

security import "$CERT_FILE" -k "$KEYCHAIN" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# Fail fast unless a valid Developer ID identity is present. `grep`
# without -q reads all input (avoids grep -q + pipefail SIGPIPE).
security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application" >/dev/null ||
	{
		echo "error: no valid Developer ID identity (check certificate + G2 intermediate)" >&2
		exit 1
	}

# Derive the signing SHA-1 at runtime from the just-imported keychain.
IDENT_SHA="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application" | head -1 | awk '{print $2}')"
if [[ -z ${IDENT_SHA} ]]; then
	echo "error: could not resolve Developer ID identity SHA-1" >&2
	exit 1
fi

# Sign by SHA-1, derived at runtime from the just-imported keychain.
codesign --keychain "$KEYCHAIN" --sign "$IDENT_SHA" \
	--timestamp --options runtime \
	--force --verbose \
	"$BINARY"

codesign --verify --deep --strict --verbose=2 "$BINARY"

# `verify` passes for adhoc too, so gate on Authority instead.
CODESIGN_INFO="$(codesign -dvv "$BINARY" 2>&1)"
printf '%s\n' "$CODESIGN_INFO"
case "$CODESIGN_INFO" in
*"Authority=Developer ID Application"*) ;;
*)
	echo "error: signing did not produce a Developer ID signature (still adhoc?)" >&2
	exit 1
	;;
esac

# Overwrite the release tarball with the signed binary so the uploaded
# release asset is signed. Contents (single top-level binary) match the
# unsigned tarball layout from build_rust.sh.
mkdir -p release
tar -czf "$TARBALL" -C "tmp/binary" "$PROJECT_NAME"
echo "Repackaged signed: $TARBALL"

rm -rf "$INTERMED_DIR"
rm -f "$CERT_FILE"
# Restore the user search list (trap re-does this on abnormal exit).
# shellcheck disable=SC2086
security list-keychains -d user -s $ORIG_KEYCHAINS >/dev/null 2>&1 || true
security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
