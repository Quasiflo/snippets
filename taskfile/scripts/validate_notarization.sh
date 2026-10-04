#!/usr/bin/env bash
# Validate an Apple notarization result for a previous notarytool submission.
# Expects /tmp/notarization/info.json from the notarize_macos task
# (the client persists that file between jobs) and Apple credentials
# in the environment (provided by fnox). Waits for a terminal state with
# rcodesign, fetches the submission log, and fails unless Accepted.
set -euo pipefail

: "${APPLE_API_KEY_CONTENT:?APPLE_API_KEY_CONTENT is required in the environment}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required in the environment}"
: "${APPLE_ISSUER_ID:?APPLE_ISSUER_ID is required in the environment}"

INFO_FILE="/tmp/notarization/info.json"
if [[ ! -f ${INFO_FILE} ]]; then
	echo "${INFO_FILE} not found (run notarize_macos first and persist it between jobs)" >&2
	exit 1
fi

LOG_FILE=tmp/notarization/notary-log.json

mkdir -p tmp/notarization

# The submission record is available here
jq . "${INFO_FILE}"

# Extract submission ID (notarytool submit --output-format json structure)
SUBMISSION_ID=$(jq -r '.id // .submission_id' "${INFO_FILE}")
if [[ -z ${SUBMISSION_ID} || ${SUBMISSION_ID} == "null" ]]; then
	echo "No submission ID found in ${INFO_FILE}" >&2
	exit 1
fi

# Materialize credentials as regular files: Task runs cmds via the
# mvdan/sh Go interpreter, whose <(...) becomes a sh-interp-* FIFO
# that sandboxed tools cannot reliably open. Regular temp files work
# everywhere (macOS notarytool path and Linux rcodesign path alike).
# NOTE: mvdan/sh only supports `trap ... EXIT` (no INT/TERM), so keep
# EXIT-only for Task compatibility; real bash also accepts it.
KEY_FILE="$(mktemp /tmp/AuthKey_XXXXXX.p8)"
chmod 600 "$KEY_FILE"
ENCODED_FILE="$(mktemp /tmp/ApiKey_XXXXXX.json)"
chmod 600 "$ENCODED_FILE"
trap 'rm -f "$KEY_FILE" "$ENCODED_FILE"' EXIT
printf '%s' "$APPLE_API_KEY_CONTENT" >"$KEY_FILE"
rcodesign encode-app-store-connect-api-key \
	-o "$ENCODED_FILE" \
	"$APPLE_ISSUER_ID" \
	"$APPLE_API_KEY_ID" \
	"$KEY_FILE"

# Block until Apple reaches a terminal state, then fetch the log for parsing
rcodesign notary-wait \
	--api-key-file "$ENCODED_FILE" "$SUBMISSION_ID"

rcodesign notary-log \
	--api-key-file "$ENCODED_FILE" "$SUBMISSION_ID" >"$LOG_FILE"

STATUS=$(jq -r '.status // .attributes.status' $LOG_FILE)

if [ "$STATUS" != "Accepted" ]; then
	echo "Notarization failed: $STATUS"
	cat $LOG_FILE
	exit 1
fi

echo "Notarization Accepted"
rm -f "$KEY_FILE" "$ENCODED_FILE"
