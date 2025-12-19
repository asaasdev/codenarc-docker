#!/bin/sh
set -e

# Constants
CODENARC_RESULT="result.txt"
LINE_VIOLATIONS="line_violations.txt"
FILE_VIOLATIONS="file_violations.txt"
VIOLATIONS_FLAG="/tmp/found_violations.txt"
ALL_DIFF="/tmp/all_diff.txt"
CHANGED_LINES_CACHE="/tmp/changed_lines.txt"
CHANGED_FILES_CACHE="/tmp/changed_files.txt"

cleanup_temp_files() {
  rm -f "$CODENARC_RESULT" "$LINE_VIOLATIONS" "$FILE_VIOLATIONS" "$VIOLATIONS_FLAG" \
        "$ALL_DIFF" "$CHANGED_LINES_CACHE" "$CHANGED_FILES_CACHE" \
        "${FILE_VIOLATIONS}.formatted" >/dev/null 2>&1
}

trap 'cleanup_temp_files' EXIT

run_codenarc() {
  report="${INPUT_REPORT:-compact:stdout}"
  includes_arg=""
  
  [ -n "$INPUT_SOURCE_FILES" ] && includes_arg="-includes=${INPUT_SOURCE_FILES}"
  
  echo "🔍 Executando CodeNarc..."
  java -jar /lib/codenarc-all.jar \
    -report="$report" \
    -rulesetfiles="${INPUT_RULESETFILES}" \
    -basedir="." \
    $includes_arg \
    > "$CODENARC_RESULT"
}

run_reviewdog_with_config() {
  input_file="$1"
  efm="$2"
  reporter="$3"
  name="$4"
  filter_mode="$5"
  level="$6"
  
  < "$input_file" reviewdog \
    -efm="$efm" \
    -reporter="$reporter" \
    -name="$name" \
    -filter-mode="$filter_mode" \
    -fail-on-error="false" \
    -level="$level" \
    ${INPUT_REVIEWDOG_FLAGS} || true
}

separate_violations() {
  echo "🔍 DEBUG: Conteúdo completo do CODENARC_RESULT:"
  echo "--- INÍCIO ---"
  cat "$CODENARC_RESULT"
  echo "--- FIM ---"
  
  # Capturar violações line-based (formato: arquivo:linha:regra)
  grep -E ':[0-9]+:' "$CODENARC_RESULT" > "$LINE_VIOLATIONS" || true
  
  # Capturar violações file-based (ambos os formatos: :null: e ||)
  grep -E ':null:|\|\|' "$CODENARC_RESULT" > "$FILE_VIOLATIONS" || true
  
  echo "🔍 DEBUG: Line violations encontradas:"
  [ -s "$LINE_VIOLATIONS" ] && head -3 "$LINE_VIOLATIONS" || echo "Nenhuma"
  echo "🔍 DEBUG: File violations encontradas:"
  [ -s "$FILE_VIOLATIONS" ] && head -3 "$FILE_VIOLATIONS" || echo "Nenhuma"
}

run_reviewdog() {
  echo "📤 Enviando resultados para reviewdog..."
  
  separate_violations
  
  # Violações line-based com reporter configurado
  if [ -s "$LINE_VIOLATIONS" ]; then
    echo "📤 Enviando violações com linha (${INPUT_REPORTER:-github-pr-check})..."
    run_reviewdog_with_config "$LINE_VIOLATIONS" "%f:%l:%m" \
      "${INPUT_REPORTER:-github-pr-check}" "codenarc" \
      "${INPUT_FILTER_MODE}" "${INPUT_LEVEL}"
  fi
  
  # Violações file-based forçando github-pr-check
  if [ -s "$FILE_VIOLATIONS" ]; then
    echo "📤 Enviando violações file-based (github-pr-check)..."
    
    # Criar arquivo temporário com formato correto para reviewdog
    > "${FILE_VIOLATIONS}.formatted"
    while read -r violation; do
      if echo "$violation" | grep -q '||'; then
        # Formato CI: arquivo||regra mensagem -> arquivo::regra mensagem
        echo "$violation" | sed 's/||/::/'
      else
        # Formato local: arquivo:null:regra mensagem -> arquivo::regra mensagem
        echo "$violation" | sed 's/:null:/::/'
      fi
    done < "$FILE_VIOLATIONS" > "${FILE_VIOLATIONS}.formatted"
    
    run_reviewdog_with_config "${FILE_VIOLATIONS}.formatted" "%f::%m" \
      "github-pr-check" "codenarc" "nofilter" "warning"
  fi
  
  # Fallback se não houver violações categorizadas
  if [ ! -s "$LINE_VIOLATIONS" ] && [ ! -s "$FILE_VIOLATIONS" ]; then
    echo "📝 Executando reviewdog padrão..."
    run_reviewdog_with_config "$CODENARC_RESULT" "%f:%l:%m" \
      "${INPUT_REPORTER:-github-pr-check}" "codenarc" \
      "${INPUT_FILTER_MODE}" "${INPUT_LEVEL}"
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

parse_diff_range() {
  range="$1"
  if echo "$range" | grep -q ","; then
    echo "$(echo "$range" | cut -d',' -f1) $(echo "$range" | cut -d',' -f2)"
  else
    echo "$range 1"
  fi
}

build_changed_lines_cache() {
  true > "$CHANGED_LINES_CACHE"
  true > "$CHANGED_FILES_CACHE"
  
  generate_git_diff > "$ALL_DIFF" 2>/dev/null || true
  [ ! -s "$ALL_DIFF" ] && return 0
  
  current_file=""
  while read -r line; do
    case "$line" in
      "diff --git"*)
        current_file=$(echo "$line" | sed 's|^diff --git a/\(.*\) b/.*|\1|')
        [ -n "$current_file" ] && echo "$current_file" >> "$CHANGED_FILES_CACHE"
        ;;
      "@@"*)
        [ -z "$current_file" ] && continue
        range=$(echo "$line" | sed 's/.*+\([0-9,]*\).*/\1/')
        range_info=$(parse_diff_range "$range")
        start=$(echo "$range_info" | cut -d' ' -f1)
        count=$(echo "$range_info" | cut -d' ' -f2)
        
        case "$start" in ''|*[!0-9]*) continue ;; esac
        case "$count" in ''|*[!0-9]*) continue ;; esac
        
        i="$start"
        while [ "$i" -lt "$((start + count))" ]; do
          echo "$current_file:$i" >> "$CHANGED_LINES_CACHE"
          i=$((i + 1))
        done
        ;;
    esac
  done < "$ALL_DIFF"
}

get_p1_count() {
  p1_count=$(grep -Eo "p1=[0-9]+" "$CODENARC_RESULT" | cut -d'=' -f2 | head -1)
  echo "${p1_count:-0}"
}

get_allowed_patterns() {
  [ -n "$INPUT_SOURCE_FILES" ] && echo "$INPUT_SOURCE_FILES" | tr ',' '\n' | sed 's/\*\*/.*/g'
}

file_matches_patterns() {
  file="$1"
  patterns="$2"
  
  [ -z "$patterns" ] && return 0
  
  for pattern in $patterns; do
    echo "$file" | grep -Eq "$pattern" && return 0
  done
  return 1
}

is_line_changed() {
  grep -q "^$2:$1$" "$CHANGED_LINES_CACHE"
}

is_file_changed() {
  grep -q "^$1$" "$CHANGED_FILES_CACHE"
}

check_blocking_rules() {
  echo "🔎 Verificando violações bloqueantes (priority 1)..."
  
  [ ! -f "$CODENARC_RESULT" ] && echo "❌ Resultado não encontrado" && return 1
  
  p1_count=$(get_p1_count)
  echo "📊 Total de P1: $p1_count"
  
  [ "$p1_count" -eq 0 ] && echo "✅ Nenhuma P1 → merge permitido" && return 0
  
  echo "⚠️  Verificando P1s em linhas alteradas..."
  build_changed_lines_cache
  
  allowed_patterns=$(get_allowed_patterns)
  [ -n "$allowed_patterns" ] && echo "🧩 Filtrando por INPUT_SOURCE_FILES"
  
  echo "0" > "$VIOLATIONS_FLAG"
  
  grep -E ':[0-9]+:|:null:|\|\|' "$CODENARC_RESULT" | while IFS=: read -r file line rest; do
    # Tratar formato || (ambiente CI)
    if echo "$file" | grep -q '||'; then
      file=$(echo "$file" | cut -d'|' -f1)
      line=""
    fi
    [ -z "$file" ] && continue
    file_matches_patterns "$file" "$allowed_patterns" || continue
    
    if [ -z "$line" ] || [ "$line" = "null" ]; then
      if is_file_changed "$file"; then
        echo "📍 Violação file-based em arquivo alterado: $file"
        echo "1" > "$VIOLATIONS_FLAG" && break
      fi
    elif is_line_changed "$line" "$file"; then
      echo "📍 Violação em linha alterada: $file:$line"
      echo "1" > "$VIOLATIONS_FLAG" && break
    fi
  done
  
  if [ "$(cat "$VIOLATIONS_FLAG")" -eq 1 ]; then
    echo "⛔ P1s existem E há violações em linhas alteradas → DEVERIA bloquear merge"
    echo "🔧 Exit desabilitado temporariamente para monitoramento"
    # exit 1
  else
    echo "✅ P1s existem mas FORA das linhas alteradas → merge permitido"
  fi
}

# Setup
if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

# Execute pipeline
run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Concluído com sucesso"