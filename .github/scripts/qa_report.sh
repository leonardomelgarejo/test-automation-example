#!/usr/bin/env bash
set -euo pipefail

# Validate required environment variables
: "${CLICKUP_TOKEN:?Environment variable CLICKUP_TOKEN is not set}"
: "${WORKSPACE_ID:?Environment variable WORKSPACE_ID is not set}"
: "${DOC_ID:?Environment variable DOC_ID is not set}"
: "${PAGE_ID:?Environment variable PAGE_ID is not set}"

REPORT_JSON="test-results/cucumber-report.json"
if [[ ! -f "$REPORT_JSON" ]]; then
  echo "❌ File $REPORT_JSON not found!" >&2
  exit 1
fi

echo "📝 Generating QA Report in Markdown…"
mkdir -p tmp

# 1) Test Scenarios Indicators
TOTAL_SCENARIOS=$(jq 'length' "$REPORT_JSON")
FAILED_SCENARIOS=$(jq '[ .[] | select(any(.elements[]?.steps[]?; .result.status=="failed")) ] | length' "$REPORT_JSON")
EXECUTED_SCENARIOS=$((TOTAL_SCENARIOS - FAILED_SCENARIOS))

# 2) Test Case Indicators
TOTAL_CASES=$(jq '[ .[].elements[]?.name ] | unique | length' "$REPORT_JSON")
FAILED_CASES=$(jq '[ .[].elements[]? | select(any(.steps[]?; .result.status=="failed")) | .name ] | unique | length' "$REPORT_JSON")
EXECUTED_CASES=$((TOTAL_CASES - FAILED_CASES))

# 3) Report Header (with Drakkar logo to the left of the heading)
cat <<EOF > tmp/qa_report.md
![Drakkar](https://raw.githubusercontent.com/leonardomelgarejo/test-automation-example/main/assets/drakkar.jpeg)

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

# 4) Number of cases per scenario
mapfile -t FEATURES < <(jq -r '.[].name' "$REPORT_JSON" | sort -u)
for FEATURE in "${FEATURES[@]}"; do
  TOTAL=$(jq --arg f "$FEATURE" '[ .[] | select(.name==$f) | .elements[]?.name ] | unique | length' "$REPORT_JSON")
  FAILED=$(jq --arg f "$FEATURE" '[ .[] | select(.name==$f) | .elements[]? | select(any(.steps[]?; .result.status=="failed")) | .name ] | unique | length' "$REPORT_JSON")
  PASSED=$((TOTAL - FAILED))
  echo "| $FEATURE | $PASSED | $FAILED |" >> tmp/qa_report.md
done

# 5) Build evidence section grouped by Test Scenario
ATTACH_CSV="tmp/attachments_urls.csv"
if [[ -f "$ATTACH_CSV" ]]; then
  declare -A EVIDENCES

  # 5.1) Aggregate and label links by FEATURE and SCENARIO
  while IFS='|' read -r FEATURE SCENARIO URL; do
    KEY="${FEATURE}|||${SCENARIO}"
    [[ -z "$URL" ]] && continue
    ext="${URL##*.}"
    case "$ext" in
      json)  label="view json"  ;;
      png)   label="view image" ;;
      webm)  label="view video" ;;
      *)     label="view evidence" ;;
    esac
    EVIDENCES[$KEY]="${EVIDENCES[$KEY]:+${EVIDENCES[$KEY]}, }[${label}]($URL)"
  done < "$ATTACH_CSV"

  # 5.2) General evidence badge
  echo "" >> tmp/qa_report.md
  echo "![Test Evidence](https://img.shields.io/badge/Test%20Evidence-orange?style=for-the-badge)" >> tmp/qa_report.md

  # 5.3) For each Test Scenario, generate a table with ordered Test Cases
  mapfile -t FEATURES_BLOCK < <(
    printf '%s\n' "${!EVIDENCES[@]}" |
    cut -d '|' -f1 |
    sort -u
  )
  for FEATURE_BLOCK in "${FEATURES_BLOCK[@]}"; do
    # Header for this block
    echo "" >> tmp/qa_report.md
    echo "| **Test Scenario** | **Test Case** | **Test Evidence** |" >> tmp/qa_report.md
    echo "|:-----------------:|:-------------:|:-----------------:|" >> tmp/qa_report.md

    # List and sort the Test Cases
    mapfile -t SCENARIOS_BLOCK < <(
      printf '%s\n' "${!EVIDENCES[@]}" |
      grep -F "${FEATURE_BLOCK}|||" |
      cut -d '|' -f4 |
      sort
    )

    # Populate each row with all consolidated links
    for SCENARIO in "${SCENARIOS_BLOCK[@]}"; do
      KEY="${FEATURE_BLOCK}|||${SCENARIO}"
      LINKS="${EVIDENCES[$KEY]:-}"
      echo "| $FEATURE_BLOCK | $SCENARIO | $LINKS |" >> tmp/qa_report.md
    done
  done

else
  # No evidence
  echo "" >> tmp/qa_report.md
  echo "| **Test Scenario** | **Test Case** | **Test Evidence** |" >> tmp/qa_report.md
  echo "|:-----------------:|:-------------:|:-----------------:|" >> tmp/qa_report.md
  echo "🔍 No attachments found in $ATTACH_CSV" >> tmp/qa_report.md
fi

# 6) Add styled badge to trigger workflow_dispatch
cat <<EOF >> tmp/qa_report.md

---

### ▶️  Run QA Report Manually

[![Run QA Report](https://img.shields.io/badge/Run-QA%20Report-blue?style=for-the-badge)](https://github.com/leonardomelgarejo/test-automation-example/actions/workflows/cucumber-playwright.yml)

> By clicking the badge above, you will be directed to the GitHub Actions dispatch page.  
> There, select \`qa_report: yes\` in the input field (plus any other settings you want) and click **Run workflow**.
EOF

# 7) Update ClickUp Doc with QA Report
echo "🔄 Updating ClickUp Doc with QA Report..."
CONTENT=$(jq -Rs . tmp/qa_report.md)
cat <<JSON > tmp/payload.json
{"content_format":"text/md","content":$CONTENT}
JSON

curl -s -X PUT \
  "https://api.clickup.com/api/v3/workspaces/${WORKSPACE_ID}/docs/${DOC_ID}/pages/${PAGE_ID}" \
  -H "Authorization: ${CLICKUP_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @tmp/payload.json

echo "✅ QA Report sent to ClickUp"