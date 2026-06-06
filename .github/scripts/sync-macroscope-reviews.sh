#!/bin/bash
set -euo pipefail

UPSTREAM_REPO="axiononeproject/xcent-next"
DEV_REPO="JohnCarlosSebuco/xcent-next-dev"
AUTHOR="JohnCarlosSebuco"
BOT_LOGIN="macroscopeapp[bot]"

# Helper function: Calculate SHA-256 hash of macroscope comment content
calculate_content_hash() {
  local inline_comments="$1"
  local verdict_body="$2"

  # Sort inline comments deterministically by path, then line
  local sorted_inline=$(echo "$inline_comments" | jq -S 'sort_by(.path, .line)')

  # Concatenate all content and hash
  local combined="${sorted_inline}${verdict_body}"
  echo -n "$combined" | sha256sum | awk '{print $1}'
}

# Helper function: Extract metadata value from HTML comment
extract_metadata() {
  local issue_body="$1"
  local key="$2"

  # Extract value from "KEY: value" pattern in metadata block (portable across BSD and GNU grep)
  echo "$issue_body" | tr -d '\r' | grep "^${key}: " | sed "s/^${key}: //" | head -1 || echo ""
}

# List open PRs targeting staging or main authored by JohnCarlosSebuco
PRS_STAGING=$(gh pr list --repo "$UPSTREAM_REPO" --base staging --state open --author "$AUTHOR" \
  --json number,headRefName,baseRefName --jq '.[] | @base64' 2>/dev/null || echo "")

PRS_MAIN=$(gh pr list --repo "$UPSTREAM_REPO" --base main --state open --author "$AUTHOR" \
  --json number,headRefName,baseRefName --jq '.[] | @base64' 2>/dev/null || echo "")

PRS=$(printf '%s\n%s' "$PRS_STAGING" "$PRS_MAIN" | grep -v '^$' || true)

if [ -z "$PRS" ]; then
  echo "No open PRs targeting staging or main by ${AUTHOR}. Nothing to do."
  exit 0
fi

for PR_B64 in $PRS; do
  PR_JSON=$(echo "$PR_B64" | base64 --decode)
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
  PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')
  PR_BASE=$(echo "$PR_JSON" | jq -r '.baseRefName')

  echo "=========="
  echo "Processing PR #${PR_NUMBER} (branch: ${PR_BRANCH} → ${PR_BASE})"

  # Fetch ALL inline review comments with pagination
  ALL_INLINE_COMMENTS_RAW=$(gh api "repos/${UPSTREAM_REPO}/pulls/${PR_NUMBER}/comments" --paginate \
    | jq -s "add // [] | [.[] | select(.user.login == \"${BOT_LOGIN}\")]")
  ALL_INLINE_COMMENTS=$(echo "$ALL_INLINE_COMMENTS_RAW" | jq 'map({path: .path, line: .line, body: .body})')

  # Fetch ALL issue comments with pagination
  ALL_ISSUE_COMMENTS=$(gh api "repos/${UPSTREAM_REPO}/issues/${PR_NUMBER}/comments" --paginate \
    | jq -s "add // [] | [.[] | select(.user.login == \"${BOT_LOGIN}\")]")

  # Find the most recent Macroscope Approvability verdict comment
  VERDICT_BODY=""
  while IFS= read -r ic; do
    IC_BODY=$(echo "$ic" | jq -r '.body')
    if echo "$IC_BODY" | grep -q 'Approvability'; then
      VERDICT_BODY="$IC_BODY"
      # Don't break - keep updating to get the latest comment
    fi
  done < <(echo "$ALL_ISSUE_COMMENTS" | jq -c '.[]')

  if [ -z "$VERDICT_BODY" ]; then
    echo "No Macroscope Approvability verdict found for PR #${PR_NUMBER}. Skipping."
    continue
  fi

  # Skip if Approved (no review comments with findings needed)
  if echo "$VERDICT_BODY" | grep -q "Verdict.*Approved"; then
    echo "Macroscope review is Approved. Skipping."
    continue
  fi

  COMMENT_COUNT=$(echo "$ALL_INLINE_COMMENTS" | jq 'length')

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

    # Get the timestamp of the last sync and content hash from full API body
    ISSUE_BODY=$(gh api "repos/${DEV_REPO}/issues/${LATEST_ISSUE_NUMBER}" --jq '.body // ""')
    LATEST_SYNCED_AT=$(extract_metadata "$ISSUE_BODY" "SYNCED_AT")
    LATEST_CONTENT_HASH=$(extract_metadata "$ISSUE_BODY" "CONTENT_HASH")

    if [ -n "$LATEST_SYNCED_AT" ]; then
      echo "Last synced at: ${LATEST_SYNCED_AT}"
    fi
  else
    echo "No existing versions found for branch ${PR_BRANCH}"
  fi

  # Calculate content hash using all inline comments and verdict
  CURRENT_HASH=$(calculate_content_hash "$ALL_INLINE_COMMENTS" "$VERDICT_BODY")
  echo "Current content hash: ${CURRENT_HASH}"

  # Check if content changed
  if [ -n "$LATEST_CONTENT_HASH" ] && [ "$CURRENT_HASH" = "$LATEST_CONTENT_HASH" ]; then
    echo "Content unchanged from version ${HIGHEST_VERSION}. Skipping."
    continue
  fi

  # Check if there are any comments to display
  if [ "$COMMENT_COUNT" -eq 0 ]; then
    echo "No macroscope inline comments found. Skipping."
    continue
  fi

  echo "Found ${COMMENT_COUNT} inline comment(s) with verdict."

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
  METADATA="<!-- MACROSCOPE_METADATA
PR_NUMBER: ${PR_NUMBER}
CONTENT_HASH: ${CURRENT_HASH}
INLINE_COMMENTS: ${COMMENT_COUNT}
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
    LINE=$(echo "$comment" | jq -r '.line')
    COMMENT_BODY=$(echo "$comment" | jq -r '.body')

    HEADER="\`${FILE_PATH}\` (line ${LINE})"

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
  done < <(echo "$ALL_INLINE_COMMENTS" | jq -c '.[]')

  # Post the verdict comment
  VERDICT_FILE=$(mktemp)
  printf '%s\n' "$VERDICT_BODY" > "$VERDICT_FILE"
  for ATTEMPT in 1 2 3; do
    if gh issue comment "$ISSUE_NUMBER" --repo "$DEV_REPO" --body-file "$VERDICT_FILE"; then
      POSTED=$((POSTED + 1))
      break
    fi
    echo "Retry ${ATTEMPT}/3 for verdict comment..."
    sleep $((ATTEMPT * 2))
  done
  rm -f "$VERDICT_FILE"

  echo "Posted ${POSTED}/${COMMENT_COUNT} inline comments + verdict to issue #${ISSUE_NUMBER}."
  if [ "$POSTED" -lt $((COMMENT_COUNT + 1)) ]; then
    echo "::warning::Only posted ${POSTED} of $((COMMENT_COUNT + 1)) comments for PR #${PR_NUMBER}."
  fi

done

echo "=========="
echo "All PRs processed."
