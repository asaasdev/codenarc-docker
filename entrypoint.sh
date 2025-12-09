#!/bin/sh
set -e
trap 'rm -f result.txt >/dev/null 2>&1' EXIT

# --- auxiliares -------------------------------------------------------

run_codenarc() {
  local report="${INPUT_REPORT:-compact:stdout}"
  local includes_arg=""

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
  if [ "${INPUT_GRAILS_VERSION}" = "4" ]; then
    echo "🔎 Verificando violacoes bloqueantes (priority 1 ou 2)..."

    local p1_count=$(grep -Eo "p1=[0-9]+" result.txt | cut -d'=' -f2 | tail -1)
    local p2_count=$(grep -Eo "p2=[0-9]+" result.txt | cut -d'=' -f2 | tail -1)

    p1_count=${p1_count:-0}
    p2_count=${p2_count:-0}

    echo "📊 Resumo CodeNarc -> p1=${p1_count}, p2=${p2_count}"

    if [ "$p1_count" -gt 0 ] || [ "$p2_count" -gt 0 ]; then
      echo "⛔ Encontradas violacoes bloqueantes (priority 1 ou 2)."
      echo "💡 Corrija as violacoes ou faca bypass autorizado."
      exit 1
    else
      echo "✅ Nenhuma violacao bloqueante encontrada."
    fi
  else
    echo "ℹ️ Modo Grails 2 detectado (sem bloqueio automatico)."
  fi
}

# --- principal -------------------------------------------------------

if [ -n "${GITHUB_WORKSPACE}" ] ; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Finalizado com sucesso."
