#!/usr/bin/env bash
set -euo pipefail

# script para criar ou reabrir bugs no ClickUp para cenários com falha
# espera as seguintes variáveis de ambiente definidas:
# CLICKUP_LIST_ID, CLICKUP_API_TOKEN, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID

# 1) Extrai Feature e Scenario juntos, separados por '||'
readarray -t FAILED_ITEMS < <(
  jq -r '
    .[] as $f
    | $f.elements[]?
    | select(.steps[].result.status=="failed")
    | "\($f.name)||\(.name)"
  ' test-results/cucumber-report.json | sort -u
)

if [ ${#FAILED_ITEMS[@]} -eq 0 ]; then
  echo "✅ Nenhum cenário com falha encontrado."
  exit 0
fi

for ITEM in "${FAILED_ITEMS[@]}"; do
  FEATURE="${ITEM%%||*}"
  SCENARIO="${ITEM##*||}"
  echo "🔍 Verificando tarefas existentes para: $FEATURE — $SCENARIO"

  # 2) Busca tasks que contenham o nome do scenario
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
    echo "🔎 Tarefa encontrada: ID=$MATCHING_TASK_ID com status=$MATCHING_TASK_STATUS"

    # 3) Se estiver fechada ou in uat, reabre e comenta
    if [[ "$MATCHING_TASK_STATUS" == "Closed" || "$MATCHING_TASK_STATUS" == "in uat" ]]; then
      echo "♻️ Alterando status para BACKLOG…"
      curl -s -X PUT "https://api.clickup.com/api/v2/task/$MATCHING_TASK_ID" \
        -H "Authorization: ${CLICKUP_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"status":"backlog"}'

      echo "💬 Adicionando comentário com o passo que falhou…"
      FAILED_STEP=$(jq -r --arg scenario "$SCENARIO" '
        .[]?.elements[]?
        | select(.name == $scenario)
        | .steps[]
        | select(.result.status=="failed")
        | .keyword + .name + " 💥 " + (.result.error_message // "Erro não especificado")
      ' test-results/cucumber-report.json)
      COMMENT_TEXT=$(printf "🔄 Bug reaberto no pipeline.\n\n📋 Passo que falhou:\n%s" "$FAILED_STEP")

      curl -s -X POST "https://api.clickup.com/api/v2/task/$MATCHING_TASK_ID/comment" \
        -H "Authorization: ${CLICKUP_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg text "$COMMENT_TEXT" '{notify_all:true,comment_text:$text}')"
    else
      echo "⚠️ Bug já existe com status ativo ($MATCHING_TASK_STATUS) – sem alterações."
    fi

  else
    echo "🐞 Nenhuma tarefa encontrada – criando nova para: $FEATURE — $SCENARIO"

    # 4) Monta descrição com passos
    STEPS=$(jq -r --arg scenario "$SCENARIO" '
      .[]?.elements[]?
      | select(.name == $scenario)
      | .steps[]
      | "- " + .keyword + .name + " (" + .result.status + ")"
        + (if .result.error_message then "\n  💥 " + ( .result.error_message | gsub("\n";" ") | gsub("\r";"") ) else "" end)
    ' test-results/cucumber-report.json)

    DESCRIPTION=$(printf "Falha no cenário automatizado: \"%s\" — Feature: \"%s\"\n\n🔗 Workflow: %s/%s/actions/runs/%s\n\n📋 Passos:\n%s" \
      "$SCENARIO" "$FEATURE" "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID" "$STEPS")

    echo "📝 Criando nova tarefa no ClickUp…"
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

    # 5) Anexa relatório HTML, se existir
    if [ -f test-results/cucumber-report.html ]; then
      echo "📎 Anexando cucumber-report.html à tarefa $NEW_TASK_ID…"
      curl -s -X POST "https://api.clickup.com/api/v2/task/$NEW_TASK_ID/attachment" \
        -H "Authorization: ${CLICKUP_API_TOKEN}" \
        -F "attachment=@test-results/cucumber-report.html"
    else
      echo "⚠️ Arquivo cucumber-report.html não encontrado – pulando anexo."
    fi
  fi
done