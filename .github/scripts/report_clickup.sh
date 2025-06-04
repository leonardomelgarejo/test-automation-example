#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="tmp"
SCENARIO_CSV="$TMP_DIR/scenario_ids.csv"
ATTACH_CSV="$TMP_DIR/attachments_urls.csv"

mkdir -p "$TMP_DIR"
> "$SCENARIO_CSV"
> "$ATTACH_CSV"

echo "🔍 Reporting Test Scenarios to ClickUp…"
# Extract the name of each Feature (top-level array → .[].name)
readarray -t FEATURES < <(
  jq -r '.[].name' test-results/cucumber-report.json | sort -u
)

for FEATURE in "${FEATURES[@]}"; do
  # Check if any step in the Feature failed
  if jq -e --arg f "$FEATURE" \
       '[ .[] | select(.name==$f) | .elements? // [] | .[] | .steps[] | select(.result.status=="failed") ] | length>0' \
       test-results/cucumber-report.json >/dev/null; then
    NEW_STATUS="rejected"
  else
    NEW_STATUS="test complete"
  fi

  echo "🔎 Feature: '$FEATURE' → $NEW_STATUS"
  # Search for a task by name in the list
  RESPONSE=$(curl -s -G "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
    --data-urlencode "search=$FEATURE" \
    --data-urlencode "include_closed=true" \
    -H "Authorization: $CLICKUP_TOKEN")
  TASK_ID=$(echo "$RESPONSE" | jq -r --arg name "$FEATURE" \
    '.tasks[] | select(.name==$name) | .id // empty')
  EXISTING_STATUS=$(echo "$RESPONSE" | jq -r --arg name "$FEATURE" \
    '.tasks[] | select(.name==$name) | .status // empty')

  if [[ -n "$TASK_ID" ]]; then
    # If it already exists, update status if necessary
    if [[ "$EXISTING_STATUS" != "$NEW_STATUS" ]]; then
      echo "🔄 Updating status: $EXISTING_STATUS → $NEW_STATUS"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$TASK_ID" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"$NEW_STATUS\"}"
    else
      echo "✅ Already in '$EXISTING_STATUS'"
    fi
  else
    # Create the task (default type) with tag "test-scenario"
    echo "➕ Creating feature '$FEATURE' → $NEW_STATUS"
    CREATED=$(curl -s -X POST "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
            --arg name        "$FEATURE" \
            --arg description "Feature \"$FEATURE\" with status: $NEW_STATUS." \
            --arg status      "$NEW_STATUS" \
            '{name:$name,description:$description,status:$status,tags:["test-scenario"]}')")
    TASK_ID=$(echo "$CREATED" | jq -r '.id')
  fi

  # Save Feature ID to link subtasks later
  echo "${FEATURE}|${TASK_ID}" >> "$SCENARIO_CSV"
done

echo ""
echo "🔍 Reporting Test Cases (subtasks)…"
# Build map FEATURE → PARENT_ID
declare -A PARENT
while IFS='|' read -r FEATURE ID; do
  PARENT["$FEATURE"]=$ID
done < "$SCENARIO_CSV"

# Extract each scenario: only from features with elements != null
readarray -t SCENARIOS < <(
  jq -r '
    .[]
    | select(.elements != null)
    | .elements[]
    | .name
  ' test-results/cucumber-report.json \
    | sort -u
)

for idx in "${!SCENARIOS[@]}"; do
  SCENARIO="${SCENARIOS[idx]}"
  # Find the parent feature that contains this scenario
  FEATURE=$(jq -r --arg s "$SCENARIO" '
    .[]
    | select((.elements // []) | map(.name) | index($s))
    | .name
  ' test-results/cucumber-report.json)
  PARENT_ID=${PARENT["$FEATURE"]}

  if [[ -z "$PARENT_ID" ]]; then
    echo "⚠️ Parent not found for '$SCENARIO'"
    continue
  fi

  # Determine scenario status (rejected or test complete)
  if jq -e --arg s "$SCENARIO" \
       '[ .[] | .elements? // [] | .[] | select(.name==$s) | .steps[] | select(.result.status=="failed") ] | length>0' \
       test-results/cucumber-report.json >/dev/null; then
    NEW_STATUS="rejected"
  else
    NEW_STATUS="test complete"
  fi

  TASK_NAME="$SCENARIO"
  echo ""
  echo "🔎 Subtask: '$TASK_NAME' (parent: $FEATURE) → $NEW_STATUS"

  # Fetch subtasks of the parent
  RESPONSE=$(curl -s -G "https://api.clickup.com/api/v2/task/$PARENT_ID" \
    --data-urlencode "include_subtasks=true" \
    -H "Authorization: $CLICKUP_TOKEN")
  SUBS=$(echo "$RESPONSE" | jq '.subtasks // []')
  TASK_ID=$(echo "$SUBS" | jq -r --arg name "$TASK_NAME" \
    '.[] | select(.name==$name) | .id // empty')
  EXISTING_STATUS=$(echo "$SUBS" | jq -r --arg name "$TASK_NAME" \
    '.[] | select(.name==$name) | .status // empty')

  # Build comment with all steps and possible error messages
  RAW=$(jq -r --arg s "$SCENARIO" '
    .[]
    | .elements? // []
    | .[]
    | select(.name==$s)
    | .steps[]?
    | select((.keyword|test("^(Before|After)";"i"))|not)
    | .keyword + " " + .name
      + (if .result.status=="failed"
         then "\nError: " + (.result.error_message|gsub("\r?\n";"\n"))
         else ""
        end)
  ' test-results/cucumber-report.json)
  COMMENT="Scenario: $SCENARIO"$'\n'"$RAW"

  # Extract all embeddings (screenshots, videos, etc.) and save to files
  readarray -t EMBEDS < <(
    jq -r --arg s "$SCENARIO" '
      .[]
      | select((.elements? // []) | map(.name) | index($s))
      | (
          (.elements[] | select(.name==$s) | .steps[]?.embeddings[]?),
          (.elements[] | select(.name==$s) | .embeddings[]?)
        )
      | select(.mime_type != null)
      | .mime_type + "," + (.data // "")
    ' test-results/cucumber-report.json
  )

  ATTACH_FILES=()
  for e in "${EMBEDS[@]}"; do
    MTYPE=${e%%,*}
    B64=${e#*,}
    [[ -z "$B64" ]] && continue
    case "$MTYPE" in
      video/webm)       EXT="webm"  ;;
      application/json) EXT="json"  ;;
      text/plain)       EXT="txt"   ;;
      image/png)        EXT="png"   ;;
      *)                EXT="bin"   ;;
    esac
    BASE="$TMP_DIR/${idx}_${SCENARIO// /_}"
    FILE="${BASE}.${EXT}"
    COUNT=1
    while [[ -e "$FILE" ]]; do
      FILE="${BASE}_${COUNT}.${EXT}"
      ((COUNT++))
    done
    echo "$B64" | base64 -d > "$FILE"
    ATTACH_FILES+=( "$FILE" )
  done

  if [[ -n "$TASK_ID" ]]; then
    # If subtask already exists, update status if changed and add comment
    if [[ "$EXISTING_STATUS" != "$NEW_STATUS" ]]; then
      echo "🔄 Updating status: $EXISTING_STATUS → $NEW_STATUS"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$TASK_ID" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"$NEW_STATUS\"}"

      # Post a comment with log/error details
      curl -s -X POST "https://api.clickup.com/api/v2/task/$TASK_ID/comment" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg text "$COMMENT" '{comment_text:$text}')"
    else
      echo "✅ Already in '$EXISTING_STATUS'"
    fi
  else
    # Create the subtask (default type) with tag "test-case"
    echo "➕ Creating subtask '$TASK_NAME'"
    PAYLOAD=$(jq -n \
      --arg name        "$TASK_NAME" \
      --arg description "$COMMENT" \
      --arg status      "$NEW_STATUS" \
      --arg parent      "$PARENT_ID" \
      '{name:$name,description:$description,status:$status,parent:$parent,tags:["test-case"]}')
    CREATED=$(curl -s -X POST "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD")
    TASK_ID=$(echo "$CREATED" | jq -r '.id')
  fi

  # Attach files, if any exist, and record their URLs in the CSV
  for F in "${ATTACH_FILES[@]}"; do
    echo "📎 Attaching $F"
    ATTACH_RES=$(curl -s -X POST "https://api.clickup.com/api/v2/task/$TASK_ID/attachment" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -F "attachment=@${F}")
    URL=$(echo "$ATTACH_RES" | jq -r .url)
    echo "${FEATURE}|${SCENARIO}|${URL}" >> "$ATTACH_CSV"
  done
done

echo ""
echo "🎉 All items reported to ClickUp!"