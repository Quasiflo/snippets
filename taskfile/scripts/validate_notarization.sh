#!/usr/bin/env bash
# Validate an Apple notarization result for a previous notarytool submission.
# Expects /tmp/notarization/info.json from the notarize_macos task
# (the client persists that file between jobs) and Apple credentials
# in the environment (provided by fnox). Waits for a terminal state with
# rcodesign, fetches the submission log, and fails unless Accepted.
set -euo pipefail

INFO_FILE="/tmp/notarization/info.json"
if [[ ! -f ${INFO_FILE} ]]; then
	echo "${INFO_FILE} not found (run notarize_macos first and persist it between jobs)" >&2
	exit 1
fi

: "${APPLE_API_KEY_CONTENT:?APPLE_API_KEY_CONTENT is required in the environment}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required in the environment}"
: "${APPLE_ISSUER_ID:?APPLE_ISSUER_ID is required in the environment}"

# The submission record is available here
jq . "${INFO_FILE}"

# Extract submission ID (notarytool submit --output-format json structure)
SUBMISSION_ID=$(jq -r '.id // .submission_id' "${INFO_FILE}")
if [[ -z ${SUBMISSION_ID} || ${SUBMISSION_ID} == "null" ]]; then
	echo "No submission ID found in ${INFO_FILE}" >&2
	exit 1
fi

# Block until Apple reaches a terminal state, then fetch the log for parsing
rcodesign notary-wait \
	--api-key-file <(
		rcodesign encode-app-store-connect-api-key \
			-o /dev/stdout \
			"$APPLE_ISSUER_ID" \
			"$APPLE_API_KEY_ID" \
			<(printf '%s\n' "$APPLE_API_KEY_CONTENT")
	) "$SUBMISSION_ID"

rcodesign notary-log \
	--api-key-file <(
		rcodesign encode-app-store-connect-api-key \
			-o /dev/stdout \
			"$APPLE_ISSUER_ID" \
			"$APPLE_API_KEY_ID" \
			<(printf '%s\n' "$APPLE_API_KEY_CONTENT")
	) "$SUBMISSION_ID" >notary-log.json

STATUS=$(jq -r '.status // .attributes.status' notary-log.json)

if [ "$STATUS" != "Accepted" ]; then
	echo "Notarization failed: $STATUS"
	cat notary-log.json
	exit 1
fi

echo "Notarization Accepted"
