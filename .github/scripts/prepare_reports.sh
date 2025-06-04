#!/usr/bin/env bash
set -euo pipefail

# Script to prepare HTML and JSON reports for deployment on GitHub Pages
# Ensures that index.html exists and that report.json is in the correct directory

OUTPUT_DIR="test-results"
HTML_REPORT="${OUTPUT_DIR}/cucumber-report.html"
JSON_REPORT="${OUTPUT_DIR}/cucumber-report.json"

# 1) Rename HTML to index.html
if [[ -f "$HTML_REPORT" ]]; then
  cp "$HTML_REPORT" "${OUTPUT_DIR}/index.html"
  echo "✅ HTML report renamed to index.html"
else
  echo "⚠️ File $HTML_REPORT not found, skipping HTML rename."
fi

# 2) Prepare JSON for deployment
mkdir -p "$OUTPUT_DIR"
if [[ -f "$JSON_REPORT" ]]; then
  cp "$JSON_REPORT" "${OUTPUT_DIR}/report.json"
  echo "✅ JSON report renamed to report.json"
else
  echo "⚠️ File $JSON_REPORT not found, skipping JSON rename."
fi