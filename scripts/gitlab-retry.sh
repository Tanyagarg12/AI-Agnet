#!/usr/bin/env bash
# gitlab-retry.sh — Wrapper around glab api with rate limiting and exponential backoff.
# Usage: ./scripts/gitlab-retry.sh <glab-api-args...>
# Example: ./scripts/gitlab-retry.sh "/projects/30407646/merge_requests?state=merged&per_page=100"
#
# Features:
# - 1-second delay between calls (rate limiting)
# - Exponential backoff (1s, 2s, 4s) on 429/5xx errors
# - Max 3 retries before failing

set -euo pipefail

MAX_RETRIES=3
RETRY_DELAY=1

# Rate limit: sleep 1s before every call
sleep 1

ATTEMPT=0
while [ $ATTEMPT -le $MAX_RETRIES ]; do
    # Capture both stdout and HTTP status
    HTTP_OUTPUT=$(glab api "$@" 2>&1) && {
        echo "$HTTP_OUTPUT"
        exit 0
    }

    EXIT_CODE=$?
    ATTEMPT=$((ATTEMPT + 1))

    # Check if it's a rate limit or server error worth retrying
    if echo "$HTTP_OUTPUT" | grep -qE '(429|500|502|503|504|rate limit)'; then
        if [ $ATTEMPT -le $MAX_RETRIES ]; then
            WAIT=$((RETRY_DELAY * (2 ** (ATTEMPT - 1))))
            echo "[gitlab-retry] Attempt $ATTEMPT/$MAX_RETRIES failed (rate limited/server error). Retrying in ${WAIT}s..." >&2
            sleep $WAIT
            continue
        fi
    fi

    # Non-retryable error or max retries exceeded
    echo "$HTTP_OUTPUT" >&2
    exit $EXIT_CODE
done

echo "[gitlab-retry] All $MAX_RETRIES retries exhausted." >&2
exit 1
