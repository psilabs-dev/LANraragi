#!/bin/sh

# Determine the integration testing origin based on pull request description.
# Example usage: "!integration-test-override https://github.com/psilabs-dev/aio-lanraragi.git@dev-openapi"

set -eu

EVENT_NAME="${GITHUB_EVENT_NAME:-}"
BODY="${BODY:-}"
AUTHOR_OWNER="${AUTHOR_OWNER:-}"
DEFAULT_REPO="${DEFAULT_REPO:-psilabs-dev/aio-lanraragi}"
DEFAULT_REF="${DEFAULT_REF:-a6b6780fe89698a133c0f5561f60a55ab0f75dcb}"

selected_repo="$DEFAULT_REPO"
selected_ref="$DEFAULT_REF"

if [ "${EVENT_NAME}" = "pull_request" ] && [ -n "$BODY" ]; then
  line=$(printf '%s\n' "$BODY" | grep -Eim1 '^!integration-test-override[[:space:]]+') || true
  if [ -n "${line:-}" ]; then
    raw=$(printf '%s' "$line" | sed -E 's/^!integration-test-override[[:space:]]+//')
    repo_part="${raw%@*}"
    ref_part="${raw##*@}"

    case "$repo_part" in
      https://github.com/*)
        repo_part=$(printf '%s' "$repo_part" | sed -E 's#^https://github.com/##; s#\.git$##')
        ;;
      git@github.com:*)
        repo_part=$(printf '%s' "$repo_part" | sed -E 's#^git@github.com:##; s#\.git$##')
        ;;
    esac

    if printf '%s' "$repo_part" | grep -Eq '^[^/]+/[^/]+$'; then
      owner="${repo_part%%/*}"
      if [ "$owner" = "$AUTHOR_OWNER" ] && [ -n "$ref_part" ] && [ "$ref_part" != "$raw" ]; then
        selected_repo="$repo_part"
        selected_ref="$ref_part"
      fi
    fi
  fi
fi

if [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo "repo=$selected_repo"
  echo "ref=$selected_ref"
else
  printf 'repo=%s\n' "$selected_repo" >> "$GITHUB_OUTPUT"
  printf 'ref=%s\n' "$selected_ref" >> "$GITHUB_OUTPUT"
fi
