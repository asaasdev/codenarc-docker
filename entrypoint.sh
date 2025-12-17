#!/bin/sh
set -e

trap 'rm -f result.txt reviewdog_output.txt >/dev/null 2>&1' EXIT

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
  < result.txt reviewdog \
    -efm="%f:%l:%m" -efm="%f:%r:%m" \
    -name="codenarc" \
    -reporter="${INPUT_REPORTER:-github-pr-check}" \
    -filter-mode="${INPUT_FILTER_MODE}" \
    -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
    -level="${INPUT_LEVEL}" \
    ${INPUT_REVIEWDOG_FLAGS} \
    -tee > reviewdog_output.txt
}

check_blocking_rules() {
  echo "🔎 Verificando violacoes bloqueantes (priority 1)..."

  p1_total=$(grep -Eo "p1=[0-9]+" result.txt | cut -d'=' -f2 | head -1)
  p1_total=${p1_total:-0}

  p1_commented=0
  if [ -f "reviewdog_output.txt" ]; then
    p1_commented=$(grep -cE "Priority[[:space:]]*1|priority[[:space:]]*1|P1" reviewdog_output.txt 2>/dev/null || echo 0)
  fi

  echo "📊 Resumo CodeNarc → total_p1=${p1_total}, commented_p1=${p1_commented}"

  echo "📑 Amostra do reviewdog_output.txt:"
  head -n 20 reviewdog_output.txt || true

  if [ "$p1_commented" -gt 0 ]; then
    echo "⛔ Reviewdog comentou ${p1_commented} violacao(oes) P1 nas linhas alteradas!"
    echo "💡 Corrija as violacoes P1 ou use o bypass autorizado pelo coordenador."
    exit 1
  elif [ "$p1_total" -gt 0 ]; then
    echo "⚠️ Existem ${p1_total} violacao(oes) P1 no arquivo, mas nao nas linhas alteradas (não bloqueia o merge)."
  else
    echo "✅ Nenhuma violacao P1 encontrada."
  fi
}

if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Finalizado com sucesso."
