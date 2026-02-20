#!/bin/bash
set -euo pipefail

UPSTREAM_REPO="axiononeproject/xcent-next"
DEV_REPO="JohnCarlosSebuco/xcent-next-dev"
AUTHOR="JohnCarlosSebuco"
BOT_LOGIN="greptile-apps[bot]"

# Helper function: Calculate SHA-256 hash of greptile comment content
calculate_content_hash() {
  local inline_comments="$1"
  local additional_body="$2"

  # Sort inline comments deterministically by path, then line
  local sorted_inline=$(echo "$inline_comments" | jq -S 'sort_by(.path, .line)')

  # Concatenate all content and hash
  local combined="${sorted_inline}${additional_body}"
  echo -n "$combined" | sha256sum | awk '{print $1}'
}

# Helper function: Extract metadata value from HTML comment
extract_metadata() {
  local issue_body="$1"
  local key="$2"

  # Extract value from "KEY: value" pattern in metadata block
  echo "$issue_body" | tr -d '\r' | grep -oP "(?<=^${key}: )[^\r]*" || echo ""
}

# List open PRs targeting staging authored by JohnCarlosSebuco
PRS=$(gh pr list --repo "$UPSTREAM_REPO" --base staging --state open --author "$AUTHOR" --json number,headRefName --jq '.[] | @base64')

if [ -z "$PRS" ]; then
  echo "No open PRs targeting staging by ${AUTHOR}. Nothing to do."
  exit 0
fi

for PR_B64 in $PRS; do
  PR_JSON=$(echo "$PR_B64" | base64 --decode)
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
  PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')

  echo "=========="
  echo "Processing PR #${PR_NUMBER} (branch: ${PR_BRANCH})"

  # Version detection: find all "Code Review * - {branch}" issues
  SEARCH_PATTERN="Code Review"
  ALL_ISSUES=$(gh issue list --repo "$DEV_REPO" --state all --limit 100 --search "\"${SEARCH_PATTERN}\" in:title ${PR_BRANCH}" --json number,title,state,body --jq '.[]')

  HIGHEST_VERSION=0
  LATEST_CONTENT_HASH=""
  LATEST_ISSUE_NUMBER=""
  LATEST_ISSUE_STATE=""

  while IFS= read -r issue; do
    ISSUE_TITLE_FOUND=$(echo "$issue" | jq -r '.title')
    ISSUE_NUMBER_FOUND=$(echo "$issue" | jq -r '.number')
    ISSUE_STATE_FOUND=$(echo "$issue" | jq -r '.state')
    ISSUE_BODY_FOUND=$(echo "$issue" | jq -r '.body // ""')

    # Match pattern: "Code Review {version} - {branch}"
    if [[ "$ISSUE_TITLE_FOUND" =~ ^Code\ Review\ ([0-9]+)\ -\ ${PR_BRANCH}$ ]]; then
      VERSION_NUM="${BASH_REMATCH[1]}"

      if [ "$VERSION_NUM" -gt "$HIGHEST_VERSION" ]; then
        HIGHEST_VERSION="$VERSION_NUM"
        LATEST_ISSUE_NUMBER="$ISSUE_NUMBER_FOUND"
        LATEST_ISSUE_STATE="$ISSUE_STATE_FOUND"

        # Extract content hash from metadata
        LATEST_CONTENT_HASH=$(extract_metadata "$ISSUE_BODY_FOUND" "CONTENT_HASH")
      fi
    fi
  done < <(echo "$ALL_ISSUES" | jq -c '.')

  # Extract last sync timestamp from metadata
  LATEST_SYNCED_AT=""
  if [ "$HIGHEST_VERSION" -gt 0 ]; then
    echo "Found existing version ${HIGHEST_VERSION} (issue #${LATEST_ISSUE_NUMBER}, ${LATEST_ISSUE_STATE})"
    echo "Previous content hash: ${LATEST_CONTENT_HASH}"

    # Get the timestamp of the last sync and content hash from full API body (not truncated search result)
    ISSUE_BODY=$(gh api "repos/${DEV_REPO}/issues/${LATEST_ISSUE_NUMBER}" --jq '.body // ""')
    LATEST_SYNCED_AT=$(extract_metadata "$ISSUE_BODY" "SYNCED_AT")
    LATEST_CONTENT_HASH=$(extract_metadata "$ISSUE_BODY" "CONTENT_HASH")

    if [ -n "$LATEST_SYNCED_AT" ]; then
      echo "Last synced at: ${LATEST_SYNCED_AT}"
    fi
  else
    echo "No existing versions found for branch ${PR_BRANCH}"
  fi

  # Fetch ALL greptile inline comments (for hash calculation)
  ALL_COMMENTS=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUMBER}/comments" --jq "[.[] | select(.user.login == \"${BOT_LOGIN}\")] | map({path: .path, start_line: .start_line, line: .line, body: .body})")

  # Fetch ALL greptile issue comments (for hash calculation)
  ALL_ISSUE_COMMENTS=$(gh api "repos/${UPSTREAM_REPO}/issues/${PR_NUMBER}/comments" \
    --jq "[.[] | select(.user.login == \"${BOT_LOGIN}\")]")

  # Filter for NEW comments only (for display)
  if [ -n "$LATEST_SYNCED_AT" ]; then
    echo "Filtering comments created after ${LATEST_SYNCED_AT}"
    COMMENTS=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUMBER}/comments" --jq "[.[] | select(.user.login == \"${BOT_LOGIN}\" and .created_at > \"${LATEST_SYNCED_AT}\")] | map({path: .path, start_line: .start_line, line: .line, body: .body})")
    ISSUE_COMMENTS=$(gh api "repos/${UPSTREAM_REPO}/issues/${PR_NUMBER}/comments" \
      --jq "[.[] | select(.user.login == \"${BOT_LOGIN}\" and .created_at > \"${LATEST_SYNCED_AT}\")]")
  else
    # First version: use all comments for both hash and display
    COMMENTS="$ALL_COMMENTS"
    ISSUE_COMMENTS="$ALL_ISSUE_COMMENTS"
  fi

  COMMENT_COUNT=$(echo "$COMMENTS" | jq 'length')

  # Process ALL issue comments for hash calculation
  ALL_ADDITIONAL_BODY=""
  while IFS= read -r ic; do
    IC_BODY=$(echo "$ic" | jq -r '.body')
    if echo "$IC_BODY" | grep -q 'Additional Comments'; then
      CLEANED=$(echo "$IC_BODY" | sed -e '/Edit Code Review Agent Settings/d')
      if [ -n "$CLEANED" ]; then
        ALL_ADDITIONAL_BODY="$CLEANED"
      fi
    fi
  done < <(echo "$ALL_ISSUE_COMMENTS" | jq -c '.[]')

  # Process NEW issue comments for display
  ADDITIONAL_BODY=""
  while IFS= read -r ic; do
    IC_BODY=$(echo "$ic" | jq -r '.body')
    if echo "$IC_BODY" | grep -q 'Additional Comments'; then
      CLEANED=$(echo "$IC_BODY" | sed -e '/Edit Code Review Agent Settings/d')
      if [ -n "$CLEANED" ]; then
        ADDITIONAL_BODY="$CLEANED"
      fi
    fi
  done < <(echo "$ISSUE_COMMENTS" | jq -c '.[]')

  ADDITIONAL_COUNT=0
  if [ -n "$ADDITIONAL_BODY" ]; then
    ADDITIONAL_COUNT=1
  fi
  TOTAL_COUNT=$((COMMENT_COUNT + ADDITIONAL_COUNT))

  # Calculate content hash using ALL comments (for change detection)
  CURRENT_HASH=$(calculate_content_hash "$ALL_COMMENTS" "$ALL_ADDITIONAL_BODY")
  echo "Current content hash: ${CURRENT_HASH}"

  # Check if total state changed
  if [ -n "$LATEST_CONTENT_HASH" ] && [ "$CURRENT_HASH" = "$LATEST_CONTENT_HASH" ]; then
    echo "Content unchanged from version ${HIGHEST_VERSION}. Skipping."
    continue
  fi

  # Check if there are any NEW comments to display
  if [ "$TOTAL_COUNT" -eq 0 ]; then
    echo "No new greptile comments since last sync. Skipping."
    continue
  fi

  echo "Found ${COMMENT_COUNT} new inline + ${ADDITIONAL_COUNT} new additional = ${TOTAL_COUNT} total new comment(s)."

  # Calculate next version number
  NEXT_VERSION=$((HIGHEST_VERSION + 1))
  ISSUE_TITLE="Code Review ${NEXT_VERSION} - ${PR_BRANCH}"

  if [ "$HIGHEST_VERSION" -gt 0 ]; then
    echo "Creating new version ${NEXT_VERSION} (previous: #${LATEST_ISSUE_NUMBER}, ${LATEST_ISSUE_STATE})"
  else
    echo "Creating first version for branch ${PR_BRANCH}"
  fi

  # Generate metadata block
  SYNCED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  METADATA="<!-- GREPTILE_METADATA
PR_NUMBER: ${PR_NUMBER}
CONTENT_HASH: ${CURRENT_HASH}
INLINE_COMMENTS: ${COMMENT_COUNT}
ADDITIONAL_COMMENTS: ${ADDITIONAL_COUNT}
TOTAL_COMMENTS: ${TOTAL_COUNT}
SYNCED_AT: ${SYNCED_AT}
VERSION: ${NEXT_VERSION}
-->"

  # Create the issue with metadata
  METADATA_FILE=$(mktemp)
  printf '%s\n' "$METADATA" > "$METADATA_FILE"
  ISSUE_URL=$(gh issue create --repo "$DEV_REPO" --title "$ISSUE_TITLE" --body-file "$METADATA_FILE")
  ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -o '[0-9]*$')
  rm -f "$METADATA_FILE"
  echo "Created issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

  # Post each inline comment as a separate issue comment
  POSTED=0
  while IFS= read -r comment; do
    FILE_PATH=$(echo "$comment" | jq -r '.path')
    START_LINE=$(echo "$comment" | jq -r '.start_line')
    END_LINE=$(echo "$comment" | jq -r '.line')
    COMMENT_BODY=$(echo "$comment" | jq -r '.body')

    if [ "$START_LINE" != "null" ] && [ "$START_LINE" != "$END_LINE" ]; then
      HEADER="\`${FILE_PATH}\` (lines ${START_LINE}-${END_LINE})"
    else
      HEADER="\`${FILE_PATH}\` (line ${END_LINE})"
    fi

    COMMENT_FILE=$(mktemp)
    printf '%s\n\n%s\n' "$HEADER" "$COMMENT_BODY" > "$COMMENT_FILE"

    # Retry up to 3 times per comment
    for ATTEMPT in 1 2 3; do
      if gh issue comment "$ISSUE_NUMBER" --repo "$DEV_REPO" --body-file "$COMMENT_FILE"; then
        POSTED=$((POSTED + 1))
        break
      fi
      echo "Retry ${ATTEMPT}/3 for comment on ${FILE_PATH}..."
      sleep $((ATTEMPT * 2))
    done

    rm -f "$COMMENT_FILE"
    sleep 1
  done < <(echo "$COMMENTS" | jq -c '.[]')

  # Post the additional comment (if any)
  if [ -n "$ADDITIONAL_BODY" ]; then
    COMMENT_FILE=$(mktemp)
    printf '%s\n' "$ADDITIONAL_BODY" > "$COMMENT_FILE"
    for ATTEMPT in 1 2 3; do
      if gh issue comment "$ISSUE_NUMBER" --repo "$DEV_REPO" --body-file "$COMMENT_FILE"; then
        POSTED=$((POSTED + 1))
        break
      fi
      echo "Retry ${ATTEMPT}/3 for additional comment..."
      sleep $((ATTEMPT * 2))
    done
    rm -f "$COMMENT_FILE"
  fi

  echo "Posted ${POSTED}/${TOTAL_COUNT} comments to issue #${ISSUE_NUMBER}."
  if [ "$POSTED" -ne "$TOTAL_COUNT" ]; then
    echo "::warning::Only posted ${POSTED} of ${TOTAL_COUNT} comments for PR #${PR_NUMBER}."
  fi
done

echo "=========="
echo "All PRs processed."
