#!/usr/bin/env bash
set -euo pipefail

# Script para preparar relatórios HTML e JSON para deploy no GitHub Pages
# Garante que index.html existe e que o report.json está no diretório correto

OUTPUT_DIR="test-results"
HTML_REPORT="${OUTPUT_DIR}/cucumber-report.html"
JSON_REPORT="${OUTPUT_DIR}/cucumber-report.json"

# 1) Renomeia HTML para index.html
if [[ -f "$HTML_REPORT" ]]; then
  cp "$HTML_REPORT" "${OUTPUT_DIR}/index.html"
  echo "✅ HTML report renomeado para index.html"
else
  echo "⚠️ Arquivo $HTML_REPORT não encontrado, pulando rename HTML."
fi

# 2) Prepara JSON para deploy
mkdir -p "$OUTPUT_DIR"
if [[ -f "$JSON_REPORT" ]]; then
  cp "$JSON_REPORT" "${OUTPUT_DIR}/report.json"
  echo "✅ JSON report renomeado para report.json"
else
  echo "⚠️ Arquivo $JSON_REPORT não encontrado, pulando rename JSON."
fi