#!/bin/sh
set -e

# ========== ARQUIVOS TEMPORÁRIOS ==========
CODENARC_RESULT="result.txt"
LINE_VIOLATIONS="line_violations.txt"
FILE_VIOLATIONS="file_violations.txt"
VIOLATIONS_FLAG="/tmp/found_violations.txt"
ALL_DIFF="/tmp/all_diff.txt"
CHANGED_LINES_CACHE="/tmp/changed_lines.txt"
CHANGED_FILES_CACHE="/tmp/changed_files.txt"
TMP_VIOLATIONS="/tmp/violations.tmp"

cleanup_temp_files() {
  rm -f "$CODENARC_RESULT" "$LINE_VIOLATIONS" "$FILE_VIOLATIONS" "$VIOLATIONS_FLAG" \
        "$ALL_DIFF" "$CHANGED_LINES_CACHE" "$CHANGED_FILES_CACHE" \
        "${FILE_VIOLATIONS}.formatted" "$TMP_VIOLATIONS" >/dev/null 2>&1
}
trap 'cleanup_temp_files' EXIT

# ========== ETAPA 1 - EXECUTA CODENARC ==========
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

  echo " "
  echo " "
  echo "📋 Saída do CodeNarc:"
  echo " "
  cat "$CODENARC_RESULT"
  echo " "
  echo " "
}

# ========== ETAPA 2 - REVIEWDOG ==========
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
  grep -E ':[0-9]+:' "$CODENARC_RESULT" > "$LINE_VIOLATIONS" || true
  grep -E ':null:|\|\|' "$CODENARC_RESULT" > "$FILE_VIOLATIONS" || true
}

run_reviewdog() {
  separate_violations

  if [ ! -s "$LINE_VIOLATIONS" ] && [ ! -s "$FILE_VIOLATIONS" ]; then
    if grep -qE ':[0-9]+:|:null:|\|\|' "$CODENARC_RESULT"; then
      echo "📤 Enviando resultados para reviewdog..."
      run_reviewdog_with_config "$CODENARC_RESULT" "%f:%l:%m" \
        "${INPUT_REPORTER:-github-pr-check}" "codenarc" \
        "${INPUT_FILTER_MODE}" "${INPUT_LEVEL}"
    fi
    return
  fi

  echo "📤 Enviando resultados para reviewdog..."

  if [ -s "$LINE_VIOLATIONS" ]; then
    run_reviewdog_with_config "$LINE_VIOLATIONS" "%f:%l:%m" \
      "${INPUT_REPORTER:-github-pr-check}" "codenarc" \
      "${INPUT_FILTER_MODE}" "${INPUT_LEVEL}"
  fi

  if [ -s "$FILE_VIOLATIONS" ]; then
    true > "${FILE_VIOLATIONS}.formatted"
    while read -r violation; do
      if echo "$violation" | grep -q '||'; then
        echo "$violation" | sed 's/||/::/g'
      else
        echo "$violation" | sed 's/:null:/::/g'
      fi
    done < "$FILE_VIOLATIONS" > "${FILE_VIOLATIONS}.formatted"

    if [ "${INPUT_REPORTER}" = "local" ]; then
      run_reviewdog_with_config "${FILE_VIOLATIONS}.formatted" "%f::%m" \
        "local" "codenarc" "nofilter" "${INPUT_LEVEL}"
    else
      run_reviewdog_with_config "${FILE_VIOLATIONS}.formatted" "%f::%m" \
        "github-pr-check" "codenarc" "nofilter" "warning"
    fi
  fi
}

generate_git_diff() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "⚠️  Diretório não é um repositório Git; nenhuma comparação de diff será feita."
    return 0
  fi

  if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
    git fetch origin "$GITHUB_BASE_SHA" --depth=1 2>/dev/null || true
    git fetch origin "$GITHUB_HEAD_SHA" --depth=1 2>/dev/null || true
    git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" -- '*.groovy'
  else
    if ! git rev-parse HEAD~1 >/dev/null 2>&1; then
      echo "⚠️  Nenhum commit anterior para comparar; diff vazio."
      return 0
    fi
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
  [ ! -s "$ALL_DIFF" ] && {
    echo "ℹ️  Nenhum diff detectado; prosseguindo com cache vazio."
    return 0
  }

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

# ========== FUNÇÕES AUXILIARES ==========
get_rule_priority() {
  rule_name="$1"
  
  # Busca por property name='RuleName' primeiro (override no XML)
  priority=$(echo "$INPUT_RULESETS_CONTENT" | grep -B 2 "name='$rule_name'" | grep -o 'priority" value="[0-9]' | head -1 | cut -d'"' -f3)
  
  # Se não encontrou, busca por class que termina com RuleNameRule (adiciona sufixo Rule)
  if [ -z "$priority" ]; then
    priority=$(echo "$INPUT_RULESETS_CONTENT" | grep "class='[^']*${rule_name}Rule'" -A 5 | grep -o 'priority" value="[0-9]' | head -1 | cut -d'"' -f3)
  fi
  
  # Se ainda não encontrou, tenta sem adicionar Rule (pode já ter o sufixo)
  if [ -z "$priority" ]; then
    priority=$(echo "$INPUT_RULESETS_CONTENT" | grep "class='[^']*${rule_name}'" -A 5 | grep -o 'priority" value="[0-9]' | head -1 | cut -d'"' -f3)
  fi
  
  # Se ainda não encontrou, busca em rule-script com property name
  if [ -z "$priority" ]; then
    priority=$(echo "$INPUT_RULESETS_CONTENT" | grep -A 3 "path='[^']*${rule_name}" | grep -o 'priority" value="[0-9]' | head -1 | cut -d'"' -f3)
  fi
  
  echo "${priority:-2}"
}

extract_rule_name() {
  violation_line="$1"
  
  # Formato: file:line:RuleName Message ou file:null:RuleName Message
  # Extrai apenas o RuleName (terceiro campo após os dois pontos)
  echo "$violation_line" | sed -E 's/^[^:]+:[^:]+:([A-Za-z0-9]+).*/\1/'
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

# ========== ETAPA 4 - BLOQUEIO POR P1 ==========
check_blocking_rules() {
  echo "🔎 Verificando violações bloqueantes (priority 1)..."
  
  [ ! -f "$CODENARC_RESULT" ] && echo "❌ Resultado não encontrado" && return 1

  p1_count=$(get_p1_count)
  
  if [ "$p1_count" -eq 0 ]; then
    echo "✅ Nenhuma violação P1 detectada"
    return 0
  fi

  echo "📊 Violações P1 nos arquivos analisados: ${p1_count:-0}"
  echo "⚙️ Analisando diff para identificar P1 em linhas/arquivos alterados..."
  build_changed_lines_cache
  allowed_patterns=$(get_allowed_patterns)
  [ -n "$allowed_patterns" ] && echo "🧩 Aplicando filtro de arquivos: INPUT_SOURCE_FILES"

  echo "0" > "$VIOLATIONS_FLAG"
  p1_in_diff=0
  grep -E ':[0-9]+:|:null:|\|\|' "$CODENARC_RESULT" > "$TMP_VIOLATIONS" || true

  while IFS=: read -r file line rest; do
    [ -z "$file" ] && continue
    
    # Trata file-based violations (formato com ||)
    if echo "$file" | grep -q '||'; then
      file=$(echo "$file" | cut -d'|' -f1)
      line=""
    fi
    
    file_matches_patterns "$file" "$allowed_patterns" || continue

    # Extrai o nome da regra e busca a priority no XML
    rule_name=$(extract_rule_name "$file:$line:$rest")
    priority=$(get_rule_priority "$rule_name")
    
    [ "$priority" != "1" ] && continue

    # Verifica se é file-based ou line-based
    if [ -z "$line" ] || [ "$line" = "null" ]; then
      if is_file_changed "$file"; then
        p1_in_diff=$((p1_in_diff + 1))
        echo "  ⛔ P1 #$p1_in_diff: $rule_name (file-based) em $file"
        echo "1" > "$VIOLATIONS_FLAG"
      fi
    elif is_line_changed "$line" "$file"; then
      p1_in_diff=$((p1_in_diff + 1))
      echo "  ⛔ P1 #$p1_in_diff: $rule_name na linha $line de $file"
      echo "1" > "$VIOLATIONS_FLAG"
    fi
  done < "$TMP_VIOLATIONS"

  rm -f "$TMP_VIOLATIONS"

  echo ""
  if [ "$(cat "$VIOLATIONS_FLAG")" -eq 1 ]; then
    echo "❌ BLOQUEIO: $p1_in_diff violação(ões) P1 encontrada(s) em linhas/arquivos alterados do PR"
    echo "💡 Corrija as violações acima ou utilize o bypass autorizado"
    exit 1
  else
    p1_outside_diff=$((p1_count - p1_in_diff))
    echo "✅ APROVADO: Nenhuma violação P1 em linhas/arquivos alterados do PR"
    [ "$p1_outside_diff" -gt 0 ] && echo "ℹ️  ${p1_outside_diff} violação(ões) P1 em código não modificado (não bloqueia)"
  fi
}

# ========== EXECUÇÃO PRINCIPAL ==========
if [ -n "${GITHUB_WORKSPACE}" ]; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Concluído com sucesso"