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
trap 'rm -rf "$INTERMED_DIR"; rm -f "$CERT_FILE"; security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true' EXIT
printf '%s' "$APPLE_CERTIFICATE" | base64 --decode -o "$CERT_FILE"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# Install Apple's Developer ID intermediate so the fresh keychain can build
# a trusted chain. Without it `find-identity -p codesigning` reports
# 0 valid identities even with the correct leaf+key (public cert, Apple PKI).
curl -fsSL -o "$INTERMED_DIR/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
security add-certificates -k "$KEYCHAIN" "$INTERMED_DIR/DeveloperIDG2CA.cer"
# Confer explicit trust (mirrors the manual System-keychain trustRoot install
# that fixed this locally): bare add-certificates alone does not make the
# fresh keychain's chain evaluate on some images. No sudo needed (user domain).
# TEMP: keep until green, then decide permanent vs revert based on result.
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$INTERMED_DIR/DeveloperIDG2CA.cer" || echo "DIAG: add-trusted-cert failed ($?)"

security import "$CERT_FILE" -k "$KEYCHAIN" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# TEMP CI DIAGNOSTICS (remove after debug). Prints only non-secret data:
# SHA fingerprints and cert subjects are public; passwords are never printed.
echo "DIAG: keychain info:"
security show-keychain-info "$KEYCHAIN" || true
echo "DIAG: all identities in scoped keychain:"
security find-identity -v -p codesigning "$KEYCHAIN" || true
echo "DIAG: keychain cert/key record counts:"
security dump-keychain "$KEYCHAIN" 2>/dev/null | grep -c "class: 0x80001000" || true
security dump-keychain "$KEYCHAIN" 2>/dev/null | grep -c "class: 0x00000010" || true
echo "DIAG: G2 intermediate present:"
security find-certificate -c "Developer ID Certification Authority" "$KEYCHAIN" | head -5 || true
echo "DIAG: leaf subject + keybag (from uploaded blob):"
openssl pkcs12 -legacy -in "$CERT_FILE" -passin env:APPLE_CERT_PASSWORD -clcerts -nokeys 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo "DIAG: leaf subject unreadable"
openssl pkcs12 -legacy -in "$CERT_FILE" -passin env:APPLE_CERT_PASSWORD -nocerts -nodes 2>/dev/null | grep -c 'PRIVATE KEY' || true
echo "DIAG: end diagnostics"

# TEMP CI DIAGNOSTICS (remove after debug): pinpoint the chain failure.
# verify-cert prints the exact reason (NOT_TRUSTED/expired/revoked/anchor).
openssl pkcs12 -legacy -in "$CERT_FILE" -passin env:APPLE_CERT_PASSWORD -clcerts -nokeys 2>/dev/null | openssl x509 -out "$INTERMED_DIR/leaf.cer" 2>/dev/null || echo "DIAG: leaf extract failed"
date -u
echo "DIAG: verify-cert (codeSign policy; 'codeSigning' is invalid):"
security verify-cert -p codeSign -c "$INTERMED_DIR/leaf.cer" || true
echo "DIAG: user trust settings (bare = user domain; -d takes no arg):"
security dump-trust-settings || true
echo "DIAG: end chain diagnostics"

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

# TEMP CI DIAGNOSTICS (remove after debug): trial sign that changes nothing.
echo "DIAG: dryrun with SHA [$IDENT_SHA]:"
codesign --keychain "$KEYCHAIN" --sign "$IDENT_SHA" --dryrun --force --verbose "$BINARY" || echo "DIAG: dryrun failed ($?)"
echo "DIAG: end dryrun"

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
security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
