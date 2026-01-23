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

  echo "🔍 Executando CodeNarc..."
  java -jar /lib/codenarc-all.jar \
    -report="json:${CODENARC_JSON}" \
    -rulesetfiles="${INPUT_RULESETFILES}" \
    -basedir="." \
    $includes_arg

  echo ""
  echo "📋 Violações encontradas:"
  echo ""
  convert_json_to_compact
  cat "$CODENARC_COMPACT"
  echo ""
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

  echo "📤 Enviando resultados para reviewdog..."

  if [ "${INPUT_REPORTER}" = "local" ]; then
    < "$CODENARC_COMPACT" reviewdog \
      -efm="%f:%l:%m" \
      -efm="%f::%m" \
      -reporter="local" \
      -name="codenarc" \
      -filter-mode="${INPUT_FILTER_MODE}" \
      -level="${INPUT_LEVEL}" \
      ${INPUT_REVIEWDOG_FLAGS} || true
  else
    line_violations=$(grep -E ':[0-9]+:' "$CODENARC_COMPACT" || true)
    if [ -n "$line_violations" ]; then
      echo "$line_violations" | reviewdog \
        -efm="%f:%l:%m" \
        -reporter="github-pr-review" \
        -name="codenarc" \
        -filter-mode="${INPUT_FILTER_MODE}" \
        -level="${INPUT_LEVEL}" \
        ${INPUT_REVIEWDOG_FLAGS} || true
    fi

    file_violations=$(grep -E '::' "$CODENARC_COMPACT" || true)
    if [ -n "$file_violations" ]; then
      echo "$file_violations" | reviewdog \
        -efm="%f::%m" \
        -reporter="github-pr-check" \
        -name="codenarc" \
        -filter-mode="nofilter" \
        -level="warning" \
        ${INPUT_REVIEWDOG_FLAGS} || true
    fi
  fi
}

generate_git_diff() {
  if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
    git fetch origin "$GITHUB_BASE_SHA" --depth=1 2>/dev/null || true
    git fetch origin "$GITHUB_HEAD_SHA" --depth=1 2>/dev/null || true
    git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" -- '*.groovy'
  else
    git diff -U0 HEAD~1 -- '*.groovy'
  fi
}

build_changed_lines_cache() {
  generate_git_diff > "$ALL_DIFF" 2>/dev/null || return
  [ ! -s "$ALL_DIFF" ] && return

  awk '
    /^diff --git/ {
      file = $3
      sub(/^a\//, "", file)
      print file > "/tmp/changed_files.txt"
    }
    /^@@/ {
      match($0, /\+([0-9]+)(,([0-9]+))?/)
      range = substr($0, RSTART, RLENGTH)
      sub(/^\+/, "", range)
      split(range, parts, ",")
      start = parts[1]
      count = parts[2]
      if (count == "") count = 1
      for (i = start; i < start + count; i++)
        print file ":" i > "/tmp/changed_lines.txt"
    }
  ' "$ALL_DIFF"
}

file_matches_filter() {
  [ -z "$INPUT_SOURCE_FILES" ] && return 0
  echo "$INPUT_SOURCE_FILES" | tr ',' '\n' | sed 's/\*\*/.*/g' | grep -qE "$(echo "$1" | sed 's/\./\\./g')"
}

is_changed() {
  [ -f "$CHANGED_LINES_CACHE" ] && grep -q "^$1:$2$" "$CHANGED_LINES_CACHE" && return 0
  [ -f "$CHANGED_FILES_CACHE" ] && grep -q "^$1$" "$CHANGED_FILES_CACHE" && return 0
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
  echo "🔎 Verificando violações bloqueantes (priority 1)..."

  [ ! -f "$CODENARC_JSON" ] && echo "❌ Resultado não encontrado" && return 1

  p1_violations=$(extract_p1_violations)

  if [ -z "$p1_violations" ]; then
    echo "✅ Nenhuma P1 detectada → merge permitido"
    return 0
  fi

  p1_count=$(echo "$p1_violations" | wc -l | tr -d ' ')
  echo "📊 Total de P1 encontradas: $p1_count"
  echo ""
  echo "⛔ Violações P1:"
  echo "$p1_violations"
  echo ""

  if [ "${INPUT_REPORTER}" = "local" ]; then
    echo "🏠 Modo local - todas as P1s são bloqueantes"
    echo "💡 Corrija as violações antes de prosseguir."
    exit 1
  fi

  echo "⚠️  Verificando se P1s estão em linhas alteradas..."
  build_changed_lines_cache

  if [ ! -s "$ALL_DIFF" ]; then
    echo "⚠️  Diff vazio - considerando todas as P1s como bloqueantes"
    echo "💡 Corrija as violações ou use o bypass autorizado."
    exit 1
  fi

  [ -n "$INPUT_SOURCE_FILES" ] && echo "🧩 Analisando apenas arquivos filtrados"
  
  echo "📝 Debug - Linhas alteradas:"
  cat "$CHANGED_LINES_CACHE" 2>/dev/null || echo "(cache vazio)"
  echo ""
  echo "📝 Debug - Arquivos alterados:"
  cat "$CHANGED_FILES_CACHE" 2>/dev/null || echo "(cache vazio)"
  echo ""

  echo "$p1_violations" | while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    file_matches_filter "$file" || continue

    echo "🔍 Verificando: $file:$line"

    if [ -z "$line" ]; then
      is_changed "$file" "" && echo "⛔ $file (file-level): $rest" && exit 1
    else
      if is_changed "$file" "$line"; then
        echo "⛔ $file:$line: $rest"
        exit 1
      fi
    fi
  done

  [ $? -eq 1 ] && echo "" && echo "💡 Corrija as violações ou use o bypass autorizado." && exit 1

  echo "✅ P1s existem mas fora das linhas alteradas → merge permitido"
}

if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Concluído com sucesso"