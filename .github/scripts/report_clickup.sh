#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="tmp"
SCENARIO_CSV="$TMP_DIR/scenario_ids.csv"
ATTACH_CSV="$TMP_DIR/attachments_urls.csv"

mkdir -p "$TMP_DIR"
> "$SCENARIO_CSV"
> "$ATTACH_CSV"

echo "🔍 Reportando Test Scenarios em ClickUp…"
readarray -t FEATURES < <(jq -r '.[].name' test-results/cucumber-report.json | sort -u)
for FEATURE in "${FEATURES[@]}"; do
  if jq -e --arg f "$FEATURE" \
       '[ .[] | select(.name==$f) | .elements[] | .steps[] | select(.result.status=="failed") ] | length>0' \
       test-results/cucumber-report.json >/dev/null; then
    NEW_STATUS="rejected"
  else
    NEW_STATUS="test complete"
  fi

  echo "🔎 Feature: '$FEATURE' → $NEW_STATUS"
  RESPONSE=$(curl -s -G "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
    --data-urlencode "search=$FEATURE" \
    --data-urlencode "include_closed=true" \
    -H "Authorization: $CLICKUP_TOKEN")
  TASK_ID=$(echo "$RESPONSE" | jq -r --arg name "$FEATURE" \
    '.tasks[] | select(.name==$name) | .id // empty')
  EXISTING_STATUS=$(echo "$RESPONSE" | jq -r --arg name "$FEATURE" \
    '.tasks[] | select(.name==$name) | .status // empty')

  if [[ -n "$TASK_ID" ]]; then
    if [[ "$EXISTING_STATUS" != "$NEW_STATUS" ]]; then
      echo "🔄 Atualizando status: $EXISTING_STATUS → $NEW_STATUS"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$TASK_ID" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"$NEW_STATUS\"}"
    else
      echo "✅ Já está em '$EXISTING_STATUS'"
    fi
  else
    echo "➕ Criando feature '$FEATURE' → $NEW_STATUS"
    CREATED=$(curl -s -X POST "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
            --arg name        "$FEATURE" \
            --arg description "Feature \"$FEATURE\" com status: $NEW_STATUS." \
            --arg status      "$NEW_STATUS" \
            --argjson custom_item_id 1009 \
            '{name:$name,description:$description,status:$status,custom_item_id:$custom_item_id}')")
    TASK_ID=$(echo "$CREATED" | jq -r '.id')
  fi

  echo "${FEATURE}|${TASK_ID}" >> "$SCENARIO_CSV"
done

echo ""
echo "🔍 Reportando Test Cases (subtasks)…"
declare -A PARENT
while IFS='|' read -r FEATURE ID; do
  PARENT["$FEATURE"]=$ID
done < "$SCENARIO_CSV"

readarray -t SCENARIOS < <(jq -r '.[].elements[].name' test-results/cucumber-report.json | sort -u)
for idx in "${!SCENARIOS[@]}"; do
  SCENARIO="${SCENARIOS[idx]}"
  FEATURE=$(jq -r --arg s "$SCENARIO" \
    '.[] | select([.elements[].name]|index($s)) | .name' \
    test-results/cucumber-report.json)
  PARENT_ID=${PARENT["$FEATURE"]}

  if [[ -z "$PARENT_ID" ]]; then
    echo "⚠️ Pai não encontrado para '$SCENARIO'"
    continue
  fi

  if jq -e --arg s "$SCENARIO" \
       '[ .[] | .elements[] | select(.name==$s) | .steps[] | select(.result.status=="failed") ] | length>0' \
       test-results/cucumber-report.json >/dev/null; then
    NEW_STATUS="rejected"
  else
    NEW_STATUS="test complete"
  fi

  TASK_NAME="$SCENARIO"
  echo ""
  echo "🔎 Subtask: '$TASK_NAME' (↑ $FEATURE) → $NEW_STATUS"

  RESPONSE=$(curl -s -G "https://api.clickup.com/api/v2/task/$PARENT_ID" \
    --data-urlencode "include_subtasks=true" \
    -H "Authorization: $CLICKUP_TOKEN")
  SUBS=$(echo "$RESPONSE" | jq '.subtasks // []')
  TASK_ID=$(echo "$SUBS" | jq -r --arg name "$TASK_NAME" \
    '.[] | select(.name==$name) | .id // empty')
  EXISTING_STATUS=$(echo "$SUBS" | jq -r --arg name "$TASK_NAME" \
    '.[] | select(.name==$name) | .status // empty')

  # coleta de logs e mensagens de erro para comentário
  RAW=$(jq -r --arg s "$SCENARIO" '
    .[]
    | .elements[]
    | select(.name==$s)
    | .steps[]
    | select((.keyword|test("^(Before|After)";"i"))|not)
    | .keyword + " " + .name
      + (if .result.status=="failed"
         then "\nError: " + (.result.error_message|gsub("\r?\n";"\n"))
         else ""
        end)
  ' test-results/cucumber-report.json)
  COMMENT="Scenario: $SCENARIO"$'\n'"$RAW"

  # extrai todos os embeddings (prints, vídeos, etc)
  readarray -t EMBEDS < <(jq -r --arg s "$SCENARIO" '
    .[]
    | select([.elements[].name]|index($s))
    | (
        (.elements[] | select(.name==$s) | .steps[]?.embeddings[]?),
        (.elements[] | select(.name==$s) | .embeddings[]?)
      )
    | select(.mime_type != null)
    | .mime_type + "," + (.data // "")
  ' test-results/cucumber-report.json)

  ATTACH_FILES=()
  for e in "${EMBEDS[@]}"; do
    MTYPE=${e%%,*}; B64=${e#*,}
    [[ -z "$B64" ]] && continue
    case "$MTYPE" in
      video/webm)       EXT="webm" ;;
      application/json) EXT="json" ;;
      text/plain)       EXT="txt"  ;;
      image/png)        EXT="png"  ;;
      *)                EXT="bin"  ;;
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

  # cria ou atualiza subtask e anexa arquivos, capturando o campo `url`
  if [[ -n "$TASK_ID" ]]; then
    if [[ "$EXISTING_STATUS" != "$NEW_STATUS" ]]; then
      echo "🔄 Atualizando status: $EXISTING_STATUS → $NEW_STATUS"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$TASK_ID" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"$NEW_STATUS\"}"
      curl -s -X POST "https://api.clickup.com/api/v2/task/$TASK_ID/comment" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg text "$COMMENT" '{comment_text:$text}')"
    else
      echo "✅ Já está em '$EXISTING_STATUS'"
    fi
  else
    echo "➕ Criando subtask '$TASK_NAME'"
    PAYLOAD=$(jq -n \
      --arg name        "$TASK_NAME" \
      --arg description "$COMMENT" \
      --arg status      "$NEW_STATUS" \
      --arg parent      "$PARENT_ID" \
      --argjson custom_item_id 1010 \
      '{name:$name,description:$description,status:$status,parent:$parent,custom_item_id:$custom_item_id}')
    CREATED=$(curl -s -X POST "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD")
    TASK_ID=$(echo "$CREATED" | jq -r '.id')
  fi

  for F in "${ATTACH_FILES[@]}"; do
    echo "📎 Anexando $F"
    ATTACH_RES=$(curl -s -X POST "https://api.clickup.com/api/v2/task/$TASK_ID/attachment" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -F "attachment=@${F}")
    URL=$(echo "$ATTACH_RES" | jq -r .url)
    echo "${FEATURE}|${SCENARIO}|${URL}" >> "$ATTACH_CSV"
  done
done

echo ""
echo "🎉 Tudo reportado em ClickUp!"