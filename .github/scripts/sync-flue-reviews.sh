#!/bin/bash
set -euo pipefail

UPSTREAM_REPO="axiononeproject/xcent-next"
DEV_REPO="JohnCarlosSebuco/xcent-next-dev"
AUTHOR="JohnCarlosSebuco"
BOT_LOGIN="github-actions[bot]"

# Helper function: Calculate SHA-256 hash of flue comment content
calculate_content_hash() {
  local comment_body="$1"

  # Hash the comment body
  echo -n "$comment_body" | sha256sum | awk '{print $1}'
}

# Helper function: Extract metadata value from HTML comment
extract_metadata() {
  local issue_body="$1"
  local key="$2"

  # Extract value from "KEY: value" pattern in metadata block
  echo "$issue_body" | tr -d '\r' | grep -oP "(?<=^${key}: )[^\r]*" || echo ""
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

  # Fetch ALL issue comments with pagination
  ALL_ISSUE_COMMENTS=$(gh api "repos/${UPSTREAM_REPO}/issues/${PR_NUMBER}/comments" --paginate \
    | jq -s "add // [] | [.[] | select(.user.login == \"${BOT_LOGIN}\")]")

  # Find the Flue PR Review comment
  FLUE_COMMENT_BODY=""
  while IFS= read -r ic; do
    IC_BODY=$(echo "$ic" | jq -r '.body')
    if echo "$IC_BODY" | grep -q 'Flue PR Review'; then
      FLUE_COMMENT_BODY="$IC_BODY"
      break
    fi
  done < <(echo "$ALL_ISSUE_COMMENTS" | jq -c '.[]')

  if [ -z "$FLUE_COMMENT_BODY" ]; then
    echo "No Flue PR Review comment found for PR #${PR_NUMBER}. Skipping."
    continue
  fi

  # Skip reviews with no blocking concerns (clean/tip-only reviews)
  if echo "$FLUE_COMMENT_BODY" | grep -q "No blocking concerns found" && ! echo "$FLUE_COMMENT_BODY" | grep -qE '\*\*(CRITICAL|HIGH|MEDIUM|LOW)\*\*'; then
    echo "Flue review has no blocking concerns. Skipping."
    continue
  fi

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

  # Calculate content hash
  CURRENT_HASH=$(calculate_content_hash "$FLUE_COMMENT_BODY")
  echo "Current content hash: ${CURRENT_HASH}"

  # Check if content changed
  if [ -n "$LATEST_CONTENT_HASH" ] && [ "$CURRENT_HASH" = "$LATEST_CONTENT_HASH" ]; then
    echo "Content unchanged from version ${HIGHEST_VERSION}. Skipping."
    continue
  fi

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
  METADATA="<!-- FLUE_METADATA
PR_NUMBER: ${PR_NUMBER}
CONTENT_HASH: ${CURRENT_HASH}
SYNCED_AT: ${SYNCED_AT}
VERSION: ${NEXT_VERSION}
-->"

  # Create issue body with metadata + flue comment
  ISSUE_BODY="${METADATA}

${FLUE_COMMENT_BODY}"

  # Create the issue
  ISSUE_FILE=$(mktemp)
  printf '%s\n' "$ISSUE_BODY" > "$ISSUE_FILE"
  ISSUE_URL=$(gh issue create --repo "$DEV_REPO" --title "$ISSUE_TITLE" --body-file "$ISSUE_FILE")
  ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -o '[0-9]*$')
  rm -f "$ISSUE_FILE"
  echo "Created issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}"

done

echo "=========="
echo "All PRs processed."
