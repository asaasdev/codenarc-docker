#!/bin/sh
set -e
trap 'cleanup_temp_files' EXIT

CODENARC_RESULT="result.txt"
VIOLATIONS_FLAG="/tmp/found_violations.txt"
FILE_DIFF="/tmp/file_diff.txt"

cleanup_temp_files() {
  rm -f "$CODENARC_RESULT" "$VIOLATIONS_FLAG" "$FILE_DIFF" >/dev/null 2>&1
}

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
    > "$CODENARC_RESULT"
}

run_reviewdog() {
  echo "📤 Enviando resultados para reviewdog..."
  < "$CODENARC_RESULT" reviewdog \
    -efm="%f:%l:%m" -efm="%f:%r:%m" \
    -name="codenarc" \
    -reporter="${INPUT_REPORTER:-github-pr-check}" \
    -filter-mode="${INPUT_FILTER_MODE}" \
    -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
    -level="${INPUT_LEVEL}" \
    ${INPUT_REVIEWDOG_FLAGS}
}

generate_git_diff() {
  if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
    git fetch origin "$GITHUB_BASE_SHA" --depth=1 2>/dev/null || true
    git fetch origin "$GITHUB_HEAD_SHA" --depth=1 2>/dev/null || true
    git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" -- "$1" 2>/dev/null || true
  else
    git diff -U0 HEAD~1 -- "$1" 2>/dev/null || true
  fi
}

get_p1_violations_count() {
  grep -Eo "p1=[0-9]+" "$CODENARC_RESULT" | cut -d'=' -f2 | head -1 | grep -o '[0-9]*' || echo "0"
}

parse_allowed_file_patterns() {
  [ -n "$INPUT_SOURCE_FILES" ] && echo "$INPUT_SOURCE_FILES" | tr ',' '\n' | sed 's/\*\*/.*/g'
}

file_matches_patterns() {
  file="$1"
  patterns="$2"
  
  [ -z "$patterns" ] && return 0
  
  echo "$patterns" | while read -r pattern; do
    if echo "$file" | grep -Eq "$pattern"; then
      return 0
    fi
  done
  return 1
}

parse_diff_range() {
  range=$(echo "$1" | sed 's/.*+\([0-9,]*\).*/\1/')
  
  if echo "$range" | grep -q ","; then
    echo "$(echo "$range" | cut -d',' -f1) $(echo "$range" | cut -d',' -f2)"
  else
    echo "$range 1"
  fi
}

line_is_in_changed_range() {
  target_line="$1"
  file="$2"
  
  generate_git_diff "$file" > "$FILE_DIFF"
  
  while read -r diff_line; do
    if echo "$diff_line" | grep -q "^@@"; then
      range_info=$(parse_diff_range "$diff_line")
      start=$(echo "$range_info" | cut -d' ' -f1)
      count=$(echo "$range_info" | cut -d' ' -f2)
      
      if [ "$target_line" -ge "$start" ] && [ "$target_line" -lt "$((start + count))" ]; then
        return 0
      fi
    fi
  done < "$FILE_DIFF"
  
  return 1
}

check_blocking_rules() {
  
  echo "🔎 Verificando violacoes bloqueantes (priority 1)..."
  
  p1_count=$(get_p1_violations_count)
  echo "📊 Total de P1 encontradas: $p1_count"
  
  [ "$p1_count" -eq 0 ] && echo "✅ Nenhuma violacao P1 detectada." && return 0
  
  allowed_patterns=$(parse_allowed_file_patterns)
  if [ -n "$allowed_patterns" ]; then
    echo "🧩 Analisando apenas arquivos filtrados por INPUT_SOURCE_FILES"
  fi
  
  echo "0" > "$VIOLATIONS_FLAG"
  
  grep -E ':[0-9]+:' "$CODENARC_RESULT" | while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    
    if ! file_matches_patterns "$file" "$allowed_patterns"; then
      continue
    fi
    
    if line_is_in_changed_range "$line" "$file"; then
      echo "🚨 Violacao P1 em linha alterada: $file:$line"
      echo "1" > "$VIOLATIONS_FLAG"
    fi
  done
  
  violations_in_diff=$(cat "$VIOLATIONS_FLAG")
  
  if [ "$violations_in_diff" -eq 1 ]; then
    echo "⛔ Violacoes P1 encontradas em linhas alteradas - bloqueando merge"
    echo "💡 Corrija as violacoes ou utilize bypass autorizado"
    exit 1
  else
    echo "⚠️  Violacoes P1 existem mas fora das linhas alteradas - merge permitido"
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

echo "🏁 Concluido com sucesso"
