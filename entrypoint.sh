#!/bin/sh
set -e
trap 'cleanup_temp_files' EXIT

CODENARC_RESULT="result.txt"
VIOLATIONS_FLAG="/tmp/found_violations.txt"
ALL_DIFF="/tmp/all_diff.txt"
CHANGED_LINES_CACHE="/tmp/changed_lines.txt"
CHANGED_FILES_CACHE="/tmp/changed_files.txt"
TEMP_VIOLATIONS="/tmp/temp_violations.txt"

cleanup_temp_files() {
  rm -f "$CODENARC_RESULT" "$VIOLATIONS_FLAG" "$ALL_DIFF" "$CHANGED_LINES_CACHE" "$CHANGED_FILES_CACHE" "$TEMP_VIOLATIONS" >/dev/null 2>&1
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

generate_all_diff() {
  if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
    git fetch origin "$GITHUB_BASE_SHA" --depth=1 2>/dev/null || true
    git fetch origin "$GITHUB_HEAD_SHA" --depth=1 2>/dev/null || true
    git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" -- '*.groovy' > "$ALL_DIFF" 2>/dev/null || true
  else
    git diff -U0 HEAD~1 -- '*.groovy' > "$ALL_DIFF" 2>/dev/null || true
  fi
}

build_changed_lines_cache() {
  true > "$CHANGED_LINES_CACHE"
  true > "$CHANGED_FILES_CACHE"
  current_file=""
  
  [ ! -s "$ALL_DIFF" ] && return 0
  
  while read -r line; do
    if echo "$line" | grep -q "^diff --git"; then
      current_file=$(echo "$line" | sed 's|^diff --git a/\(.*\) b/.*|\1|')
      if [ -n "$current_file" ]; then
        echo "$current_file" >> "$CHANGED_FILES_CACHE"
      fi
    elif echo "$line" | grep -q "^@@"; then
      if [ -n "$current_file" ]; then
        range=$(echo "$line" | sed 's/.*+\([0-9,]*\).*/\1/')
        if echo "$range" | grep -q ","; then
          start=$(echo "$range" | cut -d',' -f1)
          count=$(echo "$range" | cut -d',' -f2)
        else
          start="$range"
          count=1
        fi

        case "$start" in ''|*[!0-9]*) continue ;; esac
        case "$count" in ''|*[!0-9]*) continue ;; esac
        
        i="$start"
        while [ "$i" -lt "$((start + count))" ]; do
          echo "$current_file:$i" >> "$CHANGED_LINES_CACHE"
          i=$((i + 1))
        done
      fi
    fi
  done < "$ALL_DIFF"
}

get_p1_violations_count() {
  p1_count=$(grep -Eo "p1=[0-9]+" "$CODENARC_RESULT" | cut -d'=' -f2 | head -1)
  echo "${p1_count:-0}"
}

parse_allowed_file_patterns() {
  [ -n "$INPUT_SOURCE_FILES" ] && echo "$INPUT_SOURCE_FILES" | tr ',' '\n' | sed 's/\*\*/.*/g'
}

file_matches_patterns() {
  file="$1"
  patterns="$2"
  
  [ -z "$patterns" ] && return 0
  
  for pattern in $patterns; do
    if echo "$file" | grep -Eq "$pattern"; then
      return 0
    fi
  done
  
  return 1
}

line_is_in_changed_range() {
  target_line="$1"
  file="$2"
  
  grep -q "^$file:$target_line$" "$CHANGED_LINES_CACHE"
}

file_was_changed() {
  file="$1"
  grep -q "^$file$" "$CHANGED_FILES_CACHE"
}

check_blocking_rules() {
  echo "🔎 Verificando violações bloqueantes (priority 1)..."
  
  [ ! -f "$CODENARC_RESULT" ] && echo "❌ Arquivo de resultado não encontrado" && return 1
  
  p1_count=$(get_p1_violations_count)
  echo "📊 Total de P1 encontradas: $p1_count"
  
  if [ "$p1_count" -eq 0 ]; then
    echo "✅ Nenhuma P1 detectada → merge permitido (análise de diff desnecessária)"
    return 0
  fi
  
  echo "⚠️  P1s detectadas → verificando se estão em linhas alteradas..."
  generate_all_diff
  build_changed_lines_cache
  
  allowed_patterns=$(parse_allowed_file_patterns)
  if [ -n "$allowed_patterns" ]; then
    echo "🧩 Analisando apenas arquivos filtrados por INPUT_SOURCE_FILES"
  fi
  
  echo "0" > "$VIOLATIONS_FLAG"
  
  grep -E ':[0-9]+:|:[0-9]*:' "$CODENARC_RESULT" > "$TEMP_VIOLATIONS"
  
  [ ! -s "$TEMP_VIOLATIONS" ] && echo "✅ Nenhuma violação encontrada no resultado" && return 0
  
  while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    
    if ! file_matches_patterns "$file" "$allowed_patterns"; then
      continue
    fi
    
    if [ -z "$line" ]; then
      if file_was_changed "$file"; then
        echo "📍 Violação file-based em arquivo alterado: $file"
        echo "1" > "$VIOLATIONS_FLAG"
        break
      fi
    elif line_is_in_changed_range "$line" "$file"; then
      echo "📍 Violação em linha alterada: $file:$line"
      echo "1" > "$VIOLATIONS_FLAG"
      break
    fi
  done < "$TEMP_VIOLATIONS"
  
  violations_in_diff=$(cat "$VIOLATIONS_FLAG")
  
  if [ "$violations_in_diff" -eq 1 ]; then
    echo "⛔ P1s existem E há violações em linhas alteradas → DEVERIA bloquear merge"
    echo "🔧 Exit desabilitado temporariamente para monitoramento"
    # exit 1
  else
    echo "✅ P1s existem mas FORA das linhas alteradas → merge permitido"
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

echo "🏁 Concluído com sucesso"
