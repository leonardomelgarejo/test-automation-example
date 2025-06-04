#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="tmp"
SCENARIO_CSV="$TMP_DIR/scenario_ids.csv"
ATTACH_CSV="$TMP_DIR/attachments_urls.csv"

mkdir -p "$TMP_DIR"
> "$SCENARIO_CSV"
> "$ATTACH_CSV"

echo "🔍 Reportando Test Scenarios em ClickUp…"
# Extrai o nome de cada Feature (array principal → .[].name)
readarray -t FEATURES < <(
  jq -r '.[].name' test-results/cucumber-report.json | sort -u
)

for FEATURE in "${FEATURES[@]}"; do
  # Verifica se algum passo da Feature falhou
  if jq -e --arg f "$FEATURE" \
       '[ .[] | select(.name==$f) | .elements? // [] | .[] | .steps[] | select(.result.status=="failed") ] | length>0' \
       test-results/cucumber-report.json >/dev/null; then
    NEW_STATUS="rejected"
  else
    NEW_STATUS="test complete"
  fi

  echo "🔎 Feature: '$FEATURE' → $NEW_STATUS"
  # Busca tarefa pelo nome na lista
  RESPONSE=$(curl -s -G "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
    --data-urlencode "search=$FEATURE" \
    --data-urlencode "include_closed=true" \
    -H "Authorization: $CLICKUP_TOKEN")
  TASK_ID=$(echo "$RESPONSE" | jq -r --arg name "$FEATURE" \
    '.tasks[] | select(.name==$name) | .id // empty')
  EXISTING_STATUS=$(echo "$RESPONSE" | jq -r --arg name "$FEATURE" \
    '.tasks[] | select(.name==$name) | .status // empty')

  if [[ -n "$TASK_ID" ]]; then
    # Se já existe, atualiza status se necessário
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
    # Cria a tarefa (tipo padrão) com tag "test-scenario"
    echo "➕ Criando feature '$FEATURE' → $NEW_STATUS"
    CREATED=$(curl -s -X POST "https://api.clickup.com/api/v2/list/$LIST_ID/task" \
      -H "Authorization: $CLICKUP_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
            --arg name        "$FEATURE" \
            --arg description "Feature \"$FEATURE\" com status: $NEW_STATUS." \
            --arg status      "$NEW_STATUS" \
            '{name:$name,description:$description,status:$status,tags:["test-scenario"]}')")
    TASK_ID=$(echo "$CREATED" | jq -r '.id')
  fi

  # Guarda ID da feature para vincular subtasks depois
  echo "${FEATURE}|${TASK_ID}" >> "$SCENARIO_CSV"
done

echo ""
echo "🔍 Reportando Test Cases (subtasks)…"
# Constroi mapa FEATURE → PARENT_ID
declare -A PARENT
while IFS='|' read -r FEATURE ID; do
  PARENT["$FEATURE"]=$ID
done < "$SCENARIO_CSV"

# Extrai cada cenário: só de features que têm elements != null
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
  # Descobre a feature-pai que contém esse cenário
  FEATURE=$(jq -r --arg s "$SCENARIO" '
    .[]
    | select((.elements // []) | map(.name) | index($s))
    | .name
  ' test-results/cucumber-report.json)
  PARENT_ID=${PARENT["$FEATURE"]}

  if [[ -z "$PARENT_ID" ]]; then
    echo "⚠️ Pai não encontrado para '$SCENARIO'"
    continue
  fi

  # Define status do cenário (rejected ou test complete)
  if jq -e --arg s "$SCENARIO" \
       '[ .[] | .elements? // [] | .[] | select(.name==$s) | .steps[] | select(.result.status=="failed") ] | length>0' \
       test-results/cucumber-report.json >/dev/null; then
    NEW_STATUS="rejected"
  else
    NEW_STATUS="test complete"
  fi

  TASK_NAME="$SCENARIO"
  echo ""
  echo "🔎 Subtask: '$TASK_NAME' (↑ $FEATURE) → $NEW_STATUS"

  # Busca subtasks do pai
  RESPONSE=$(curl -s -G "https://api.clickup.com/api/v2/task/$PARENT_ID" \
    --data-urlencode "include_subtasks=true" \
    -H "Authorization: $CLICKUP_TOKEN")
  SUBS=$(echo "$RESPONSE" | jq '.subtasks // []')
  TASK_ID=$(echo "$SUBS" | jq -r --arg name "$TASK_NAME" \
    '.[] | select(.name==$name) | .id // empty')
  EXISTING_STATUS=$(echo "$SUBS" | jq -r --arg name "$TASK_NAME" \
    '.[] | select(.name==$name) | .status // empty')

  # Monta comentário com todos os steps e possíveis mensagens de erro
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

  # Extrai todos os embeddings (prints, vídeos, etc) e grava em arquivos
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

  if [[ -n "$TASK_ID" ]]; then
    # Se subtask já existe, atualiza o status se mudou e adiciona comentário
    if [[ "$EXISTING_STATUS" != "$NEW_STATUS" ]]; then
      echo "🔄 Atualizando status: $EXISTING_STATUS → $NEW_STATUS"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$TASK_ID" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"status\":\"$NEW_STATUS\"}"

      # Comenta no task com detalhes de logs/erros
      curl -s -X POST "https://api.clickup.com/api/v2/task/$TASK_ID/comment" \
        -H "Authorization: $CLICKUP_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg text "$COMMENT" '{comment_text:$text}')"
    else
      echo "✅ Já está em '$EXISTING_STATUS'"
    fi
  else
    # Cria a subtask (tipo padrão) com tag "test-case"
    echo "➕ Criando subtask '$TASK_NAME'"
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

  # Anexa arquivos, caso existam, e registra a URL no CSV
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