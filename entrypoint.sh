#!/bin/sh
set -e

CODENARC_SARIF="result.sarif.json"
CODENARC_SARIF_LINE="result_line.sarif.json"
CODENARC_SARIF_FILE="result_file.sarif.json"
CODENARC_COMPACT="result.txt"
LINE_VIOLATIONS="line_violations.txt"
FILE_VIOLATIONS="file_violations.txt"
VIOLATIONS_FLAG="/tmp/found_violations.txt"
ALL_DIFF="/tmp/all_diff.txt"
CHANGED_LINES_CACHE="/tmp/changed_lines.txt"
CHANGED_FILES_CACHE="/tmp/changed_files.txt"

cleanup_temp_files() {
  rm -f "$CODENARC_SARIF" "$CODENARC_SARIF_LINE" "$CODENARC_SARIF_FILE" "$CODENARC_COMPACT" "$LINE_VIOLATIONS" "$FILE_VIOLATIONS" \
        "$VIOLATIONS_FLAG" "$ALL_DIFF" "$CHANGED_LINES_CACHE" "$CHANGED_FILES_CACHE" \
        "${FILE_VIOLATIONS}.formatted" >/dev/null 2>&1
}

trap 'cleanup_temp_files' EXIT

run_codenarc() {
  includes_arg=""
  [ -n "$INPUT_SOURCE_FILES" ] && includes_arg="-includes=${INPUT_SOURCE_FILES}"

  echo "🔍 Executando CodeNarc..."
  java -jar /lib/codenarc-all.jar \
    -report="sarif:${CODENARC_SARIF}" \
    -rulesetfiles="${INPUT_RULESETFILES}" \
    -basedir="." \
    $includes_arg

  convert_sarif_to_compact
  split_sarif_by_type
  
  echo ""
  echo "📋 Violações encontradas:"
  echo ""
  cat "$CODENARC_COMPACT"
  echo ""
}

convert_sarif_to_compact() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "⚠️  jq não encontrado"
    return
  fi

  jq -r '
    .runs[0]? as $run |
    ($run.tool.driver.rules // []) as $rules |
    ($run.results // [])[] |
    .ruleId as $ruleId |
    ($rules | map(select(.id == $ruleId)) | .[0].properties.priority // 2) as $priority |
    (.locations[0].physicalLocation // {}) as $loc |
    ($loc.artifactLocation.uri // "unknown") as $file |
    ($loc.region.startLine // null) as $line |
    (.message.text // "No message") as $msg |
    if $line == null then
      "\($file):\($ruleId) \($msg) => Priority \($priority)"
    else
      "\($file):\($line):\($ruleId) \($msg) => Priority \($priority)"
    end
  ' "$CODENARC_SARIF" > "$CODENARC_COMPACT" 2>/dev/null || echo "" > "$CODENARC_COMPACT"
}

split_sarif_by_type() {
  if ! command -v jq >/dev/null 2>&1; then
    return
  fi

  # Line-based
  jq '{
    "$schema": ."$schema",
    "version": .version,
    "runs": [
      .runs[0] | {
        "tool": .tool,
        "results": [.results[] | select(.locations[0].physicalLocation.region.startLine != null)]
      }
    ]
  }' "$CODENARC_SARIF" > "$CODENARC_SARIF_LINE" 2>/dev/null

  # File-based
  jq '{
    "$schema": ."$schema",
    "version": .version,
    "runs": [
      .runs[0] | {
        "tool": .tool,
        "results": [.results[] | select(.locations[0].physicalLocation.region.startLine == null)]
      }
    ]
  }' "$CODENARC_SARIF" > "$CODENARC_SARIF_FILE" 2>/dev/null
}

run_reviewdog() {
  echo "📤 Enviando resultados para reviewdog..."
  
  if [ ! -s "$CODENARC_SARIF" ]; then
    echo "⚠️  Nenhum resultado SARIF encontrado"
    return
  fi

  if [ "${INPUT_REPORTER}" = "local" ]; then
    echo "🏠 Executando reviewdog em modo local..."
    < "$CODENARC_SARIF" reviewdog \
      -f=sarif \
      -reporter="local" \
      -name="codenarc" \
      -filter-mode="${INPUT_FILTER_MODE}" \
      -level="${INPUT_LEVEL}" \
      ${INPUT_REVIEWDOG_FLAGS} || true
    return
  fi

  # line-based github-pr-review
  if [ -s "$CODENARC_SARIF_LINE" ] && [ "$(jq '.runs[0].results | length' "$CODENARC_SARIF_LINE")" -gt 0 ]; then
    echo "📍 Enviando violações line-based para github-pr-review..."
    < "$CODENARC_SARIF_LINE" reviewdog \
      -f=sarif \
      -reporter="github-pr-review" \
      -name="codenarc" \
      -filter-mode="${INPUT_FILTER_MODE}" \
      -fail-on-error="false" \
      -level="${INPUT_LEVEL}" \
      ${INPUT_REVIEWDOG_FLAGS} || true
  fi

  # file-based github-pr-check
  if [ -s "$CODENARC_SARIF_FILE" ] && [ "$(jq '.runs[0].results | length' "$CODENARC_SARIF_FILE")" -gt 0 ]; then
    echo "📄 Enviando violações file-based para github-pr-check..."
    < "$CODENARC_SARIF_FILE" reviewdog \
      -f=sarif \
      -reporter="github-pr-check" \
      -name="codenarc" \
      -filter-mode="nofilter" \
      -fail-on-error="false" \
      -level="warning" \
      ${INPUT_REVIEWDOG_FLAGS} || true
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

extract_p1_violations_from_sarif() {
  if ! command -v jq >/dev/null 2>&1; then
    grep 'Priority 1' "$CODENARC_COMPACT" 2>/dev/null || echo ""
    return
  fi

  jq -r '
    .runs[0]? as $run |
    ($run.tool.driver.rules // []) as $rules |
    ($run.results // [])[] |
    .ruleId as $ruleId |
    ($rules | map(select(.id == $ruleId)) | .[0].properties.priority // 2) as $priority |
    select($priority == 1) |
    (.locations[0].physicalLocation // {}) as $loc |
    ($loc.artifactLocation.uri // "unknown") as $file |
    ($loc.region.startLine // null) as $line |
    (.message.text // "No message") as $msg |
    if $line == null then
      "\($file)::\($ruleId) \($msg)"
    else
      "\($file):\($line):\($ruleId) \($msg)"
    end
  ' "$CODENARC_SARIF" 2>/dev/null || echo ""
}

check_blocking_rules() {
  echo "🔎 Verificando violações bloqueantes (priority 1)..."
  
  [ ! -f "$CODENARC_SARIF" ] && echo "❌ Resultado não encontrado" && return 1
  
  p1_violations=$(extract_p1_violations_from_sarif)
  
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
    echo "🏠 Modo local - não é possível verificar linhas alteradas"
    echo "⚠️  Todas as P1s serão consideradas bloqueantes"
    echo ""
    echo "⛔ Violação P1 encontrada → bloqueando execução"
    echo "💡 Corrija as violações antes de prosseguir."
    exit 1
  fi
  
  echo "⚠️  Verificando se P1s estão em linhas alteradas..."
  build_changed_lines_cache
  
  if [ ! -s "$ALL_DIFF" ]; then
    echo "⚠️  Não foi possível gerar diff - considerando todas as P1s como bloqueantes"
    echo ""
    echo "⛔ Violação P1 encontrada → bloqueando merge"
    echo "💡 Corrija as violações ou use o bypass autorizado pelo coordenador."
    exit 1
  fi
  
  allowed_patterns=$(get_allowed_patterns)
  [ -n "$allowed_patterns" ] && echo "🧩 Analisando apenas arquivos filtrados"
  
  echo "0" > "$VIOLATIONS_FLAG"
  
  echo "$p1_violations" | while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    file_matches_patterns "$file" "$allowed_patterns" || continue
    
    if [ "$line" = "" ] || [ -z "$line" ]; then
      if is_file_changed "$file"; then
        echo "⛔ Violação P1 file-based em arquivo alterado: $file"
        echo "   $rest"
        echo "1" > "$VIOLATIONS_FLAG"
        break
      fi
    elif is_line_changed "$line" "$file"; then
      echo "⛔ Violação P1 em linha alterada: $file:$line"
      echo "   $rest"
      echo "1" > "$VIOLATIONS_FLAG"
      break
    fi
  done
  
  if [ "$(cat "$VIOLATIONS_FLAG")" -eq 1 ]; then
    echo ""
    echo "⛔ Violação P1 encontrada em linha alterada → bloqueando merge"
    echo "💡 Corrija as violações ou use o bypass autorizado pelo coordenador."
    exit 1
  else
    echo "✅ P1s existem mas fora das linhas alteradas → merge permitido"
  fi
}

if [ -n "${GITHUB_WORKSPACE}" ]; then
  git config --global --add safe.directory "$GITHUB_WORKSPACE" 2>/dev/null || true
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Concluído com sucesso"