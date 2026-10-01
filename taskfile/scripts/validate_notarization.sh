#!/usr/bin/env bash
# Validate an Apple notarization result from a notarytool webhook payload.
# Expects the raw webhook body in WEBHOOK_BODY and Apple credentials in the environment (provided by fnox). Fetches the submission log with rcodesign and fails unless the status is Accepted.
set -euo pipefail

: "${WEBHOOK_BODY:?WEBHOOK_BODY is required in the environment}"
: "${APPLE_API_KEY_CONTENT:?APPLE_API_KEY_CONTENT is required in the environment}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required in the environment}"
: "${APPLE_ISSUER_ID:?APPLE_ISSUER_ID is required in the environment}"

# The raw body is available here
echo "$WEBHOOK_BODY" | jq .

# Extract submission ID (Apple's payload structure)
SUBMISSION_ID=$(echo "$WEBHOOK_BODY" | jq -r '.payload.submission_id // .submission_id')

# Confirm status using rcodesign
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
