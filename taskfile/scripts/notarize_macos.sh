#!/usr/bin/env bash
# Notarize a macOS binary with Apple notarytool.
# Expects tmp/binary/PROJECT_NAME from the build_rust task.
# Call with PROJECT_NAME set, e.g. `task notarize_macos PROJECT_NAME=myapp`.
# Requires Apple credentials in the environment (provided by fnox).
# Records the submission in /tmp/notarization/info.json for the
# validate_notarization task (the client persists that file between jobs).
set -euo pipefail

PROJECT_NAME="{{.PROJECT_NAME}}"
if [[ -z ${PROJECT_NAME} ]]; then
	echo "PROJECT_NAME is required (call with PROJECT_NAME=<name>)" >&2
	exit 1
fi

: "${APPLE_API_KEY_CONTENT:?APPLE_API_KEY_CONTENT is required in the environment}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required in the environment}"
: "${APPLE_ISSUER_ID:?APPLE_ISSUER_ID is required in the environment}"

mkdir -p tmp/binary /tmp/notarization
zip -j "tmp/binary/$PROJECT_NAME.zip" "tmp/binary/$PROJECT_NAME"

# Write the API key to a regular file: Task runs cmds via the mvdan/sh
# Go interpreter, whose <(...) process substitution becomes a
# sh-interp-* FIFO that sandboxed Apple binaries (notarytool) cannot
# open. A real temp file works everywhere.
# NOTE: mvdan/sh only supports `trap ... EXIT` (no INT/TERM), so keep
# EXIT-only for Task compatibility; real bash also accepts it.
KEY_FILE="$(mktemp /tmp/AuthKey_XXXXXX.p8)"
chmod 600 "$KEY_FILE"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$APPLE_API_KEY_CONTENT" >"$KEY_FILE"

xcrun notarytool submit "tmp/binary/$PROJECT_NAME.zip" \
	--key "$KEY_FILE" \
	--key-id "$APPLE_API_KEY_ID" \
	--issuer "$APPLE_ISSUER_ID" \
	--output-format json | tee /tmp/notarization/info.json

SUBMISSION_ID=$(jq -r '.id' /tmp/notarization/info.json)
echo "Submitted: $SUBMISSION_ID"
rm -f "$KEY_FILE"
