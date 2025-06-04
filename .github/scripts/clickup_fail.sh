#!/usr/bin/env bash
set -euo pipefail

# Script to create or reopen bugs in ClickUp for failed scenarios
# Expects the following environment variables to be set:
# CLICKUP_LIST_ID, CLICKUP_API_TOKEN, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID

# 1) Extract Feature and Scenario together, separated by '||'
readarray -t FAILED_ITEMS < <(
  jq -r '
    .[] as $f
    | $f.elements[]?
    | select(.steps[].result.status=="failed")
    | "\($f.name)||\(.name)"
  ' test-results/cucumber-report.json | sort -u
)

if [ ${#FAILED_ITEMS[@]} -eq 0 ]; then
  echo "✅ No failed scenarios found."
  exit 0
fi

for ITEM in "${FAILED_ITEMS[@]}"; do
  FEATURE="${ITEM%%||*}"
  SCENARIO="${ITEM##*||}"
  echo "🔍 Checking existing tasks for: $FEATURE — $SCENARIO"

  # 2) Search for tasks containing the scenario name
  EXISTING_TASKS=$(curl -s -G "https://api.clickup.com/api/v2/list/${CLICKUP_LIST_ID}/task" \
    --data-urlencode "search=$SCENARIO" \
    --data-urlencode "include_closed=true" \
    -H "Authorization: ${CLICKUP_API_TOKEN}" \
    -H "Content-Type: application/json")

  MATCHING_TASK=$(echo "$EXISTING_TASKS" | jq -r --arg scenario "$SCENARIO" '
    .tasks[] | select(.name | test($scenario)) | {id: .id, status: .status.status}
  ')
  MATCHING_TASK_ID=$(echo "$MATCHING_TASK" | jq -r '.id')
  MATCHING_TASK_STATUS=$(echo "$MATCHING_TASK" | jq -r '.status')

  if [ -n "$MATCHING_TASK_ID" ]; then
    echo "🔎 Found task: ID=$MATCHING_TASK_ID with status=$MATCHING_TASK_STATUS"

    # 3) If it's closed or in UAT, reopen and comment
    if [[ "$MATCHING_TASK_STATUS" == "Closed" || "$MATCHING_TASK_STATUS" == "in uat" ]]; then
      echo "♻️ Changing status to BACKLOG…"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$MATCHING_TASK_ID" \
        -H "Authorization: ${CLICKUP_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"status":"backlog"}'

      echo "💬 Adding comment with the failed step…"
      FAILED_STEP=$(jq -r --arg scenario "$SCENARIO" '
        .[]?.elements[]?
        | select(.name == $scenario)
        | .steps[]
        | select(.result.status=="failed")
        | .keyword + .name + " 💥 " + (.result.error_message // "Unspecified error")
      ' test-results/cucumber-report.json)
      COMMENT_TEXT=$(printf "🔄 Bug reopened in pipeline.\n\n📋 Failed step:\n%s" "$FAILED_STEP")

      curl -s -X POST "https://api.clickup.com/api/v2/task/$MATCHING_TASK_ID/comment" \
        -H "Authorization: ${CLICKUP_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg text "$COMMENT_TEXT" '{notify_all:true,comment_text:$text}')"
    else
      echo "⚠️ Bug already exists with active status ($MATCHING_TASK_STATUS) – no changes."
    fi

  else
    echo "🐞 No existing task found – creating new one for: $FEATURE — $SCENARIO"

    # 4) Build description with steps
    STEPS=$(jq -r --arg scenario "$SCENARIO" '
      .[]?.elements[]?
      | select(.name == $scenario)
      | .steps[]
      | "- " + .keyword + .name + " (" + .result.status + ")"
        + (if .result.error_message then "\n  💥 " + ( .result.error_message | gsub("\n";" ") | gsub("\r";"") ) else "" end)
    ' test-results/cucumber-report.json)

    DESCRIPTION=$(printf "Automated scenario failure: \"%s\" — Feature: \"%s\"\n\n🔗 Workflow: %s/%s/actions/runs/%s\n\n📋 Steps:\n%s" \
      "$SCENARIO" "$FEATURE" "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$STEPS")

    echo "📝 Creating new task in ClickUp…"
    NEW_TASK_RESPONSE=$(curl -s -X POST "https://api.clickup.com/api/v2/list/${CLICKUP_LIST_ID}/task" \
      -H "Authorization: ${CLICKUP_API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg feature "$FEATURE" \
        --arg scenario "$SCENARIO" \
        --arg description "$DESCRIPTION" \
        '{
          name: ("CI Fail : " + $feature + " | " + $scenario),
          description: $description,
          status: "backlog",
          priority: 3,
          custom_item_id: 1003
        }')"
    )
    NEW_TASK_ID=$(echo "$NEW_TASK_RESPONSE" | jq -r '.id')

    # 5) Attach HTML report, if it exists
    if [ -f test-results/cucumber-report.html ]; then
      echo "📎 Attaching cucumber-report.html to task $NEW_TASK_ID…"
      curl -s -X POST "https://api.clickup.com/api/v2/task/$NEW_TASK_ID/attachment" \
        -H "Authorization: ${CLICKUP_API_TOKEN}" \
        -F "attachment=@test-results/cucumber-report.html"
    else
      echo "⚠️ File cucumber-report.html not found – skipping attachment."
    fi
  fi
done