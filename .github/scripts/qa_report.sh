#!/usr/bin/env bash
set -euo pipefail

# Valida variáveis de ambiente obrigatórias
: "${CLICKUP_TOKEN:?Environment variable CLICKUP_TOKEN is not set}"
: "${WORKSPACE_ID:?Environment variable WORKSPACE_ID is not set}"
: "${DOC_ID:?Environment variable DOC_ID is not set}"
: "${PAGE_ID:?Environment variable PAGE_ID is not be set}"

REPORT_JSON="test-results/cucumber-report.json"
if [[ ! -f "$REPORT_JSON" ]]; then
  echo "❌ Arquivo $REPORT_JSON não encontrado!" >&2
  exit 1
fi

echo "📝 Gerando QA Report em Markdown…"
mkdir -p tmp

# 1) Indicadores de Test Scenarios
TOTAL_SCENARIOS=$(jq 'length' "$REPORT_JSON")
FAILED_SCENARIOS=$(jq '[ .[] | select(any(.elements[]?.steps[]?; .result.status=="failed")) ] | length' "$REPORT_JSON")
EXECUTED_SCENARIOS=$((TOTAL_SCENARIOS - FAILED_SCENARIOS))

# 2) Indicadores de Test Cases
TOTAL_CASES=$(jq '[ .[].elements[]?.name ] | unique | length' "$REPORT_JSON")
FAILED_CASES=$(jq '[ .[].elements[]? | select(any(.steps[]?; .result.status=="failed")) | .name ] | unique | length' "$REPORT_JSON")
EXECUTED_CASES=$((TOTAL_CASES - FAILED_CASES))

# 3) Cabeçalho do relatório
cat <<EOF > tmp/qa_report.md
## Test Results

![Totals](https://img.shields.io/badge/Totals-green?style=for-the-badge)
| **Type**       | **Total** | **Executed** | **Failed** |
|:--------------:|:---------:|:------------:|:----------:|
| Scenarios      | $TOTAL_SCENARIOS | $EXECUTED_SCENARIOS | $FAILED_SCENARIOS |
| Cases          | $TOTAL_CASES     | $EXECUTED_CASES     | $FAILED_CASES     |

![Cases per Scenario](https://img.shields.io/badge/Cases%20%20Per%20Scenario-purple?style=for-the-badge)
| **Scenario**      | **Passed**   | **Failed** |
|:-----------------:|:-----------:|:----------:|
EOF

# 4) Número de casos por cenário
mapfile -t FEATURES < <(jq -r '.[].name' "$REPORT_JSON" | sort -u)
for FEATURE in "${FEATURES[@]}"; do
  TOTAL=$(jq --arg f "$FEATURE" '[ .[] | select(.name==$f) | .elements[]?.name ] | unique | length' "$REPORT_JSON")
  FAILED=$(jq --arg f "$FEATURE" '[ .[] | select(.name==$f) | .elements[]? | select(any(.steps[]?; .result.status=="failed")) | .name ] | unique | length' "$REPORT_JSON")
  PASSED=$((TOTAL - FAILED))
  echo "| $FEATURE | $PASSED | $FAILED |" >> tmp/qa_report.md
done

# 5) Montar seção de evidências em blocos por Test Scenario
ATTACH_CSV="tmp/attachments_urls.csv"
if [[ -f "$ATTACH_CSV" ]]; then
  declare -A EVIDENCES

  # 5.1) Acumula e etiqueta links por FEATURE e SCENARIO
  while IFS='|' read -r FEATURE SCENARIO URL; do
    KEY="${FEATURE}|||${SCENARIO}"
    [[ -z "$URL" ]] && continue
    ext="${URL##*.}"
    case "$ext" in
      json)  label="ver json"  ;;
      png)   label="ver imagem";;
      webm)  label="ver video" ;;
      *)     label="ver evidência";;
    esac
    EVIDENCES[$KEY]="${EVIDENCES[$KEY]:+${EVIDENCES[$KEY]}, }[${label}]($URL)"
  done < "$ATTACH_CSV"

  # 5.2) Badge geral de evidências
  echo "" >> tmp/qa_report.md
  echo "![Test Evidence](https://img.shields.io/badge/Test%20Evidence-orange?style=for-the-badge)" >> tmp/qa_report.md

  # 5.3) Para cada Test Scenario, gera tabela com Test Cases ordenados
  mapfile -t FEATURES_BLOCK < <(
    printf '%s\n' "${!EVIDENCES[@]}" |
    cut -d '|' -f1 |
    sort -u
  )
  for FEATURE_BLOCK in "${FEATURES_BLOCK[@]}"; do
    # Cabeçalho deste bloco
    echo "" >> tmp/qa_report.md
    echo "| **Test Scenario** | **Test Case** | **Test Evidence** |" >> tmp/qa_report.md
    echo "|:-----------------:|:-------------:|:-----------------:|" >> tmp/qa_report.md

    # Lista e ordena os Test Cases
    mapfile -t SCENARIOS_BLOCK < <(
      printf '%s\n' "${!EVIDENCES[@]}" |
      grep -F "${FEATURE_BLOCK}|||" |
      cut -d '|' -f4 |
      sort
    )

    # Preenche cada linha com todos os links consolidados
    for SCENARIO in "${SCENARIOS_BLOCK[@]}"; do
      KEY="${FEATURE_BLOCK}|||${SCENARIO}"
      LINKS="${EVIDENCES[$KEY]:-}"
      echo "| $FEATURE_BLOCK | $SCENARIO | $LINKS |" >> tmp/qa_report.md
    done
  done

else
  # Sem evidências
  echo "" >> tmp/qa_report.md
  echo "| **Test Scenario** | **Test Case** | **Test Evidence** |" >> tmp/qa_report.md
  echo "|:-----------------:|:-------------:|:-----------------:|" >> tmp/qa_report.md
  echo "🔍 Nenhum attachment encontrado em $ATTACH_CSV" >> tmp/qa_report.md
fi

# 6) Atualiza documento no ClickUp no ClickUp
echo "🔄 Atualizando ClickUp Doc com QA Report..."
CONTENT=$(jq -Rs . tmp/qa_report.md)
cat <<JSON > tmp/payload.json
{"content_format":"text/md","content":$CONTENT}
JSON

curl -s -X PUT \
  "https://api.clickup.com/api/v3/workspaces/${WORKSPACE_ID}/docs/${DOC_ID}/pages/${PAGE_ID}" \
  -H "Authorization: ${CLICKUP_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @tmp/payload.json

echo "✅ QA Report enviado para ClickUp"