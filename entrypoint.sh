#!/bin/sh
set -e

CODENARC_JSON="result.json"
CODENARC_COMPACT="result.txt"
ALL_DIFF="/tmp/all_diff.txt"
CHANGED_LINES_CACHE="/tmp/changed_lines.txt"
CHANGED_FILES_CACHE="/tmp/changed_files.txt"

cleanup_temp_files() {
  rm -f "$CODENARC_JSON" "$CODENARC_COMPACT" "$ALL_DIFF" \
        "$CHANGED_LINES_CACHE" "$CHANGED_FILES_CACHE" >/dev/null 2>&1
}

trap 'cleanup_temp_files' EXIT

run_codenarc() {
  includes_arg=""
  [ -n "$INPUT_SOURCE_FILES" ] && includes_arg="-includes=${INPUT_SOURCE_FILES}"
  
  echo ""
  echo "🔍 Executando CodeNarc para análise estática..."
  java -jar /lib/codenarc-all.jar \
    -report="json:${CODENARC_JSON}" \
    -rulesetfiles="${INPUT_RULESETFILES}" \
    -basedir="." \
    $includes_arg >/dev/null 2>&1
  
  echo ""
  echo "📋 Processando violações encontradas:"
  convert_json_to_compact
  cat "$CODENARC_COMPACT"
}

convert_json_to_compact() {
  jq -r '
    .packages[]? |
    .path as $pkg_path |
    .files[]? |
    ($pkg_path // "") as $rawpath |
    .name as $filename |
    (if $rawpath == "" then $filename else ($rawpath | ltrimstr("/")) + "/" + $filename end) as $file |
    ($file | ltrimstr("/")) as $cleanfile |
    .violations[]? |
    if .lineNumber then
      "\($cleanfile):\(.lineNumber):\(.ruleName) \(.message // "") [P\(.priority)]"
    else
      "\($cleanfile)::\(.ruleName) \(.message // "") [P\(.priority)]"
    end
  ' "$CODENARC_JSON" > "$CODENARC_COMPACT" 2>/dev/null || true
}

run_reviewdog() {
  [ ! -s "$CODENARC_COMPACT" ] && return
  echo ""
  echo "📤 Enviando resultados para reviewdog..."
  
  if [ "${INPUT_REPORTER}" = "local" ]; then
    < "$CODENARC_COMPACT" reviewdog \
      -efm="%f:%l:%m" \
      -efm="%f::%m" \
      -reporter="local" \
      -name="codenarc" \
      -filter-mode="${INPUT_FILTER_MODE}" \
      -level="${INPUT_LEVEL}" \
      ${INPUT_REVIEWDOG_FLAGS} >/dev/null || true
  else
    line_violations=$(grep -E ':[0-9]+:' "$CODENARC_COMPACT" || true)
    if [ -n "$line_violations" ]; then
      echo "$line_violations" | reviewdog \
        -efm="%f:%l:%m" \
        -reporter="github-pr-review" \
        -name="codenarc" \
        -filter-mode="${INPUT_FILTER_MODE}" \
        -level="${INPUT_LEVEL}" \
        ${INPUT_REVIEWDOG_FLAGS} >/dev/null || true
    fi
    file_violations=$(grep -E '::' "$CODENARC_COMPACT" || true)
    if [ -n "$file_violations" ]; then
      echo "$file_violations" | reviewdog \
        -efm="%f::%m" \
        -reporter="github-pr-check" \
        -name="codenarc" \
        -filter-mode="nofilter" \
        -level="warning" \
        ${INPUT_REVIEWDOG_FLAGS} >/dev/null || true
    fi
  fi
}

generate_git_diff() {
  if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
    git fetch origin "$GITHUB_BASE_SHA" --depth=1 >/dev/null 2>&1 || true
    git fetch origin "$GITHUB_HEAD_SHA" --depth=1 >/dev/null 2>&1 || true
    git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" -- '*.groovy'
  else
    git diff -U0 HEAD~1 -- '*.groovy'
  fi
}

build_changed_lines_cache() {
  true > "$CHANGED_FILES_CACHE"
  true > "$CHANGED_LINES_CACHE"

  generate_git_diff > "$ALL_DIFF" 2>/dev/null || return
  [ ! -s "$ALL_DIFF" ] && return

  awk '
    BEGIN { file = ""; line_num = 0 }
    /^diff --git/ {
      file = $3
      sub(/^a\//, "", file)
      if (file != "") print file >> "'"$CHANGED_FILES_CACHE"'"
      line_num = 0
    }
    /^@@/ {
      if (match($0, /\+([0-9]+)/)) {
        line_num = substr($0, RSTART+1, RLENGTH-1)
        line_num = int(line_num)
      }
      next
    }
    /^\+/ && !/^\+\+\+/ {
      if (file != "" && line_num > 0) {
        print file ":" line_num >> "'"$CHANGED_LINES_CACHE"'"
        line_num++
      }
    }
  ' "$ALL_DIFF"
}

is_changed() {
  file="$1"
  line="$2"
  
  if [ -z "$line" ]; then
    [ -f "$CHANGED_FILES_CACHE" ] && grep -qF "$file" "$CHANGED_FILES_CACHE" && return 0
    return 1
  fi
  
  [ -f "$CHANGED_LINES_CACHE" ] && grep -qF "${file}:${line}" "$CHANGED_LINES_CACHE" && return 0
  return 1
}

extract_p1_violations() {
  jq -r '
    .packages[]? |
    .path as $pkg_path |
    .files[]? |
    ($pkg_path // "") as $rawpath |
    .name as $filename |
    (if $rawpath == "" then $filename else ($rawpath | ltrimstr("/")) + "/" + $filename end) as $file |
    ($file | ltrimstr("/")) as $cleanfile |
    .violations[]? | select(.priority == 1) |
    if .lineNumber then
      "\($cleanfile):\(.lineNumber):\(.ruleName) \(.message // "")"
    else
      "\($cleanfile)::\(.ruleName) \(.message // "")"
    end
  ' "$CODENARC_JSON" 2>/dev/null
}

check_blocking_rules() {
  echo ""
  echo "🔎 Verificando violações bloqueantes (P1)..."
  [ ! -f "$CODENARC_JSON" ] && echo "❌ Erro: Resultado do CodeNarc não encontrado." && return 1
  
  p1_violations=$(extract_p1_violations)
  if [ -z "$p1_violations" ]; then
    echo "✅ Nenhuma violação P1 detectada → merge permitido"
    return 0
  fi

  p1_count=$(echo "$p1_violations" | wc -l | tr -d ' ')
  echo "📊 Total de P1 encontradas: $p1_count"
  echo ""
  echo "⛔ Violações P1:"
  echo "$p1_violations"

  if [ "${INPUT_REPORTER}" = "local" ]; then
    echo ""
    echo "🏠 Modo local: todas as violações P1 são bloqueantes."
    echo "💡 Corrija as violações antes de prosseguir."
    exit 1
  fi

  echo ""
  echo "⚠️  Analisando se as P1s estão em linhas alteradas..."
  build_changed_lines_cache

  if [ ! -s "$ALL_DIFF" ]; then
    echo ""
    echo "⚠️  Diff vazio: todas as P1s são consideradas bloqueantes."
    echo "💡 Corrija as violações ou use o bypass autorizado."
    exit 1
  fi
  
  echo ""
  echo "📝 DEBUG - Primeiras 20 linhas do cache:"
  head -20 "$CHANGED_LINES_CACHE" 2>/dev/null || echo "(vazio)"
  echo ""
  
  found_blocking=0
  while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    
    if [ -z "$line" ]; then
      echo "⚠️  Violação P1 file-level detectada em: $file"
      echo "   → Violações sem linha específica não podem ser verificadas contra o diff."
      echo "   → Considerando como não-bloqueante (código legado)."
    else
      if is_changed "$file" "$line"; then
        echo "🚨 BLOQUEADO: Violação P1 em linha alterada: $file:$line"
        echo "   Regra: $rest"
        found_blocking=1
        break
      fi
    fi
  done <<EOF
$p1_violations
EOF

  if [ $found_blocking -eq 1 ]; then
    echo ""
    echo "🚨 Merge bloqueado: Violações P1 críticas em código alterado."
    echo "💡 Corrija as violações ou use o bypass autorizado."
    exit 1
  fi

  echo ""
  echo "✅ Todas as violações P1 estão fora das linhas alteradas → merge permitido"
}

if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit 1
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo ""
echo "🏁 Análise de CodeNarc concluída com sucesso."
