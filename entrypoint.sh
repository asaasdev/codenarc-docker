#!/bin/sh
set -e
trap 'rm -f result.txt >/dev/null 2>&1' EXIT

# --- auxiliares -------------------------------------------------------
run_codenarc() {
  report="${INPUT_REPORT:-compact:stdout}"
  includes_arg=""

  if [ -n "$INPUT_SOURCE_FILES" ]; then
    includes_arg="-includes=${INPUT_SOURCE_FILES}"
  fi

  echo "🔍 Executando CodeNarc..."
  java -jar /lib/codenarc-all.jar \
    -report="$report" \
    -rulesetfiles="${INPUT_RULESETFILES}" \
    -basedir="." \
    $includes_arg \
    > result.txt
}

run_reviewdog() {
  echo "📤 Enviando resultados para reviewdog..."
  < result.txt reviewdog -efm="%f:%l:%m" -efm="%f:%r:%m" \
    -name="codenarc" \
    -reporter="${INPUT_REPORTER:-github-pr-check}" \
    -filter-mode="${INPUT_FILTER_MODE}" \
    -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
    -level="${INPUT_LEVEL}" \
    ${INPUT_REVIEWDOG_FLAGS}
}

check_blocking_rules() {
  echo "🔎 Verificando violacoes bloqueantes (priority 1)..."

  p1_count=$(grep -Eo "p1=[0-9]+" result.txt | cut -d'=' -f2 | head -1)
  p1_count=${p1_count:-0}

  echo "📊 Resumo CodeNarc -> priority 1=${p1_count}"

  if [ "$p1_count" -gt 0 ]; then
    echo "⛔ Foram encontradas violacoes bloqueantes (priority 1)."
    echo "💡 Corrija as violacoes ou use o bypass autorizado pelo coordenador."
    exit 1
  else
    echo "✅ Nenhuma violacao bloqueante (priority 1) encontrada."
  fi
}

# --- principal -------------------------------------------------------
if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Finalizado com sucesso."
