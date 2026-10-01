#!/usr/bin/env bash
# Notarize a macOS binary with Apple notarytool.
# Expects tmp/binary/PROJECT_NAME from the build_rust task.
# Call with PROJECT_NAME set, e.g. `task notarize_macos PROJECT_NAME=myapp`.
# Requires Apple/CircleCI credentials in the environment (provided by fnox).
set -euo pipefail

PROJECT_NAME="{{.PROJECT_NAME}}"
if [[ -z ${PROJECT_NAME} ]]; then
	echo "PROJECT_NAME is required (call with PROJECT_NAME=<name>)" >&2
	exit 1
fi

: "${APPLE_API_KEY_CONTENT:?APPLE_API_KEY_CONTENT is required in the environment}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required in the environment}"
: "${APPLE_ISSUER_ID:?APPLE_ISSUER_ID is required in the environment}"
: "${CIRCLECI_PUBLISH_WEBHOOK_SECRET:?CIRCLECI_PUBLISH_WEBHOOK_SECRET is required in the environment}"

mkdir -p tmp/binary
zip -j "tmp/binary/$PROJECT_NAME.zip" "tmp/binary/$PROJECT_NAME"

xcrun notarytool submit "tmp/binary/$PROJECT_NAME.zip" \
	--key <(printf '%s\n' "$APPLE_API_KEY_CONTENT") \
	--key-id "$APPLE_API_KEY_ID" \
	--issuer "$APPLE_ISSUER_ID" \
	--webhook "https://internal.circleci.com/private/soc/e/ea4e821d-3ab0-42a0-b760-cecae09c789b?secret=${CIRCLECI_PUBLISH_WEBHOOK_SECRET}" \
	--output-format json
