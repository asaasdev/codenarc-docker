#!/bin/sh
set -e

trap 'rm -f result.txt reviewdog_output.txt /tmp/diff.txt >/dev/null 2>&1' EXIT

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

generate_diff() {
  echo "🔎 Gerando diff entre commits..."
  if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
    echo "   Base: $GITHUB_BASE_SHA"
    echo "   Head: $GITHUB_HEAD_SHA"
    git fetch origin $GITHUB_BASE_SHA --depth=1 2>/dev/null || true
    git fetch origin $GITHUB_HEAD_SHA --depth=1 2>/dev/null || true
    git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" > /tmp/diff.txt || true
  else
    echo "⚠️  Refs base/head nao encontradas, usando HEAD~1..."
    git diff -U0 HEAD~1 > /tmp/diff.txt || true
  fi
}

check_blocking_rules() {
  echo "🔎 Verificando violacoes bloqueantes (priority 1)..."
  p1_total=$(grep -Eo "p1=[0-9]+" result.txt | cut -d'=' -f2 | head -1)
  p1_total=${p1_total:-0}

  echo "📊 Total de P1 encontradas pelo CodeNarc: ${p1_total}"
  [ "$p1_total" -eq 0 ] && echo "✅ Nenhuma violacao P1 detectada." && return 0

  echo "🔍 Cruzando violacoes P1 com linhas alteradas..."
  found=0

  grep -E ':[0-9]+:' result.txt | while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    if grep -q "$file" /tmp/diff.txt; then
      match=$(awk -v f="$file" -v l="$line" '
        BEGIN { in_file=0; hit=0 }
        $0 ~ ("diff --git a/"f) { in_file=1 }
        in_file && /^@@/ {
          if (match($0, /\+([0-9]+)(,([0-9]+))?/, m)) {
            start = m[1]; len = (m[3]=="" ? 1 : m[3])
            if (l >= start && l < start+len) { hit=1; exit }
          }
        }
        END { if (hit==1) print "hit" }
      ' /tmp/diff.txt)
      if [ "$match" = "hit" ]; then
        echo "🚨 Violacao P1 no diff: $file:$line"
        found=1
      fi
    fi
  done

  if [ "$found" -eq 1 ]; then
    echo "⛔ Foram encontradas violacoes P1 em linhas alteradas."
    echo "💡 Corrija as violacoes ou utilize o bypass autorizado."
    exit 1
  else
    echo "⚠️ Existem violacoes P1 no arquivo, mas fora das linhas alteradas (nao bloqueia o merge)."
  fi
}

if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
generate_diff
check_blocking_rules

echo "🏁 Finalizado com sucesso."
