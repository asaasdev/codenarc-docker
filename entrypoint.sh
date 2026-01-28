#!/bin/sh
set -e

# --- Configuração de Debug ---
# Para ativar o debug, defina DEBUG_MODE="true" nas variáveis de ambiente do seu workflow, por exemplo:
# env:
#   DEBUG_MODE: "true"
DEBUG_MODE="${DEBUG_MODE:-false}" # Default é false

# Funções auxiliares para logs de debug
debug_log() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "::debug::$@"
    fi
}

debug_group() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "::group::$@"
    fi
}

debug_endgroup() {
    if [ "$DEBUG_MODE" = "true" ]; then
        echo "::endgroup::"
    fi
}

# --- Início do Script e Setup de Ambiente (Adição de logs) ---
debug_group "Início da Análise e Setup de Ambiente"
    debug_log "DEBUG_MODE está ${DEBUG_MODE}."
    debug_log "GITHUB_REF: ${GITHUB_REF}"
    debug_log "GITHUB_HEAD_REF: ${GITHUB_HEAD_REF:-N/A}"
    debug_log "GITHUB_BASE_REF: ${GITHUB_BASE_REF:-N/A}"
    debug_log "GITHUB_WORKSPACE: ${GITHUB_WORKSPACE}"
    debug_log "INPUT_WORKDIR: ${INPUT_WORKDIR}"
    debug_log "PWD antes de CD: $(pwd)"
    debug_log "CodeNarc jar path: /lib/codenarc-all.jar"
    debug_log "jq path: $(which jq 2>/dev/null || echo 'Not found')"
    debug_log "reviewdog path: $(which reviewdog 2>/dev/null || echo 'Not found')"
debug_endgroup


CODENARC_JSON="result.json"
CODENARC_COMPACT="result.txt"
ALL_DIFF="/tmp/all_diff.txt"
CHANGED_LINES_CACHE="/tmp/changed_lines.txt"
CHANGED_FILES_CACHE="/tmp/changed_files.txt"

cleanup_temp_files() {
  rm -f "$CODENARC_JSON" "$CODENARC_COMPACT" "$ALL_DIFF" \
        "$CHANGED_LINES_CACHE" "$CHANGED_FILES_CACHE" >/dev/null 2>&1
  debug_log "Arquivos temporários limpos."
}
trap 'cleanup_temp_files' EXIT

run_codenarc() {
  includes_arg=""
  [ -n "$INPUT_SOURCE_FILES" ] && includes_arg="-includes=${INPUT_SOURCE_FILES}"
  
  echo ""
  echo "🔍 Executando CodeNarc para análise estática..."
  # Adição de logs de debug para CodeNarc
  debug_group "Execução do CodeNarc"
    debug_log "Comando CodeNarc: java -jar /lib/codenarc-all.jar -report=\"json:${CODENARC_JSON}\" -rulesetfiles=\"${INPUT_RULESETFILES}\" -basedir=\".\" ${includes_arg}"
    java -jar /lib/codenarc-all.jar \
      -report="json:${CODENARC_JSON}" \
      -rulesetfiles="${INPUT_RULESETFILES}" \
      -basedir="." \
      $includes_arg >/dev/null 2>&1
    debug_log "CodeNarc concluído. Output JSON em: ${CODENARC_JSON}"
    if [ -f "$CODENARC_JSON" ]; then
        debug_log "Conteúdo RAW do JSON (primeiras 100 linhas):\n$(head -n 100 "$CODENARC_JSON")"
        debug_log "Conteúdo RAW do JSON (od -c, primeiras 100 linhas):\n$(od -c "$CODENARC_JSON" | head -n 100)" # Novo log
    else
        debug_log "ERRO: Arquivo JSON ($CODENARC_JSON) não foi gerado."
    fi
  debug_endgroup
  
  echo ""
  echo "📋 Processando violações encontradas:"
  convert_json_to_compact
  cat "$CODENARC_COMPACT"
}

convert_json_to_compact() {
  # Adição de logs de debug para JQ
  debug_group "Conversão JSON para Compacto"
    debug_log "Input JSON para JQ: ${CODENARC_JSON}"
    debug_log "Output Compacto: ${CODENARC_COMPACT}"
    jq_command='
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
    '
    debug_log "Comando JQ usado:\n${jq_command}"
    jq -r "$jq_command" "$CODENARC_JSON" > "$CODENARC_COMPACT" 2>/dev/null || true
    debug_log "JQ concluído. Conteúdo do $CODENARC_COMPACT (primeiras 50 linhas):\n$(head -n 50 "$CODENARC_COMPACT")"
    debug_log "Conteúdo do $CODENARC_COMPACT (od -c, primeiras 50 linhas):\n$(od -c "$CODENARC_COMPACT" | head -n 50)" # Novo log
  debug_endgroup
}

run_reviewdog() {
  [ ! -s "$CODENARC_COMPACT" ] && debug_log "Arquivo $CODENARC_COMPACT está vazio, pulando reviewdog." && return
  echo ""
  echo "📤 Enviando resultados para reviewdog..."
  
  # Adição de logs de debug para Reviewdog
  debug_group "Execução do Reviewdog"
    debug_log "INPUT_REPORTER: ${INPUT_REPORTER}"
    debug_log "INPUT_FILTER_MODE: ${INPUT_FILTER_MODE}"
    debug_log "INPUT_LEVEL: ${INPUT_LEVEL}"
    debug_log "INPUT_REVIEWDOG_FLAGS: ${INPUT_REVIEWDOG_FLAGS}"

    if [ "${INPUT_REPORTER}" = "local" ]; then
      debug_log "Modo local do reviewdog."
      < "$CODENARC_COMPACT" reviewdog \
        -efm="%f:%l:%m" \
        -efm="%f::%m" \
        -reporter="local" \
        -name="codenarc" \
        -filter-mode="${INPUT_FILTER_MODE}" \
        -level="${INPUT_LEVEL}" \
        ${INPUT_REVIEWDOG_FLAGS} >/dev/null || true
      debug_log "Reviewdog (local) executado."
    else
      line_violations=$(grep -E ':[0-9]+:' "$CODENARC_COMPACT" || true)
      debug_log "Violações de linha para reviewdog (primeiras 20 linhas):\n$(echo "${line_violations}" | head -n 20)"
      debug_log "Violações de linha para reviewdog (od -c, primeiras 20 linhas):\n$(echo "${line_violations}" | od -c | head -n 20)" # Novo log
      if [ -n "$line_violations" ]; then
        echo "$line_violations" | reviewdog \
          -efm="%f:%l:%m" \
          -reporter="github-pr-review" \
          -name="codenarc" \
          -filter-mode="${INPUT_FILTER_MODE}" \
          -level="${INPUT_LEVEL}" \
          ${INPUT_REVIEWDOG_FLAGS} >/dev/null || true
        debug_log "Reviewdog (github-pr-review) executado."
      fi
      file_violations=$(grep -E '::' "$CODENARC_COMPACT" || true)
      debug_log "Violações de arquivo para reviewdog (primeiras 20 linhas):\n$(echo "${file_violations}" | head -n 20)"
      debug_log "Violações de arquivo para reviewdog (od -c, primeiras 20 linhas):\n$(echo "${file_violations}" | od -c | head -n 20)" # Novo log
      if [ -n "$file_violations" ]; then
        echo "$file_violations" | reviewdog \
          -efm="%f::%m" \
          -reporter="github-pr-check" \
          -name="codenarc" \
          -filter-mode="nofilter" \
          -level="warning" \
          ${INPUT_REVIEWDOG_FLAGS} >/dev/null || true
        debug_log "Reviewdog (github-pr-check) executado."
      fi
    fi
  debug_endgroup
}

generate_git_diff() {
  # Adição de logs de debug para Git Diff
  debug_group "Geração do Git Diff"
    debug_log "GITHUB_BASE_SHA: ${GITHUB_BASE_SHA:-N/A}"
    debug_log "GITHUB_HEAD_SHA: ${GITHUB_HEAD_SHA:-N/A}"

    if [ -n "$GITHUB_BASE_SHA" ] && [ -n "$GITHUB_HEAD_SHA" ]; then
      debug_log "Comparando entre SHA base (${GITHUB_BASE_SHA}) e head (${GITHUB_HEAD_SHA})."
      git fetch origin "$GITHUB_BASE_SHA" --depth=1 >/dev/null 2>&1 || debug_log "WARN: Falha ao fetch $GITHUB_BASE_SHA"
      git fetch origin "$GITHUB_HEAD_SHA" --depth=1 >/dev/null 2>&1 || debug_log "WARN: Falha ao fetch $GITHUB_HEAD_SHA"
      git diff -U0 "$GITHUB_BASE_SHA" "$GITHUB_HEAD_SHA" -- '*.groovy'
    else
      debug_log "SHAs não definidos. Comparando com HEAD~1."
      git diff -U0 HEAD~1 -- '*.groovy'
    fi
    debug_log "Comando git diff executado."
  debug_endgroup
}

build_changed_lines_cache() {
  # Adição de logs de debug para cache de linhas alteradas
  debug_group "Construção do Cache de Linhas Alteradas"
    debug_log "Criando caches vazios para $CHANGED_FILES_CACHE e $CHANGED_LINES_CACHE."
    true > "$CHANGED_FILES_CACHE"
    true > "$CHANGED_LINES_CACHE"
    
    debug_log "Gerando git diff para $ALL_DIFF."
    generate_git_diff > "$ALL_DIFF" 2>/dev/null || debug_log "WARN: Falha ao gerar ALL_DIFF." && return
    
    if [ ! -s "$ALL_DIFF" ]; then
      debug_log "WARN: $ALL_DIFF está vazio, não há linhas alteradas para cache."
      debug_endgroup
      return
    fi
    debug_log "Conteúdo de $ALL_DIFF (primeiras 50 linhas):\n$(head -n 50 "$ALL_DIFF")"
    debug_log "Conteúdo de $ALL_DIFF (od -c, primeiras 50 linhas):\n$(od -c "$ALL_DIFF" | head -n 50)" # Novo log

    debug_log "Processando $ALL_DIFF com awk para construir caches."
    awk '
      /^diff --git/ {
        file = $3
        sub(/^a\//, "", file)
        print file >> "'"$CHANGED_FILES_CACHE"'"
      }
      /^@@/ {
        match($0, /\+([0-9]+)/)
        line_num = substr($0, RSTART+1, RLENGTH-1)
        next
      }
      /^\+/ && !/^\+\+\+/ {
        print file ":" line_num >> "'"$CHANGED_LINES_CACHE"'"
        line_num++
      }
    ' "$ALL_DIFF"
    debug_log "Awk concluído."
    debug_log "Conteúdo de $CHANGED_FILES_CACHE:\n$(cat "$CHANGED_FILES_CACHE")"
    debug_log "Conteúdo de $CHANGED_FILES_CACHE (od -c):\n$(od -c "$CHANGED_FILES_CACHE")" # Novo log
    debug_log "Conteúdo de $CHANGED_LINES_CACHE:\n$(cat "$CHANGED_LINES_CACHE")"
    debug_log "Conteúdo de $CHANGED_LINES_CACHE (od -c):\n$(od -c "$CHANGED_LINES_CACHE")" # Novo log
  debug_endgroup
}

is_changed() {
  file="$1"
  line="$2"
  
  # Adição de logs de debug detalhados para is_changed
  debug_group "is_changed: Verificando '${file}:${line}'"
    SEARCH_TERM="${file}:${line}"
    debug_log "  String de busca (com caracteres invisíveis): '$(echo "$SEARCH_TERM" | od -c)'"
    debug_log "  Conteúdo de '$CHANGED_LINES_CACHE' (primeiras 50 linhas com caracteres invisíveis):\n$(od -c "$CHANGED_LINES_CACHE" | head -n 50)"

    if [ -z "$line" ]; then
      debug_log "  Modo: file-based. Buscando '$file' em '$CHANGED_FILES_CACHE'."
      if [ -f "$CHANGED_FILES_CACHE" ] && grep -qF "$file" "$CHANGED_FILES_CACHE"; then
        debug_log "  Resultado: Arquivo '$file' ENCONTRADO no cache de arquivos alterados."
        debug_endgroup
        return 0
      else
        debug_log "  Resultado: Arquivo '$file' NÃO encontrado no cache de arquivos alterados."
        debug_endgroup
        return 1
      fi
    else
      debug_log "  Modo: line-based. Buscando '${SEARCH_TERM}' em '$CHANGED_LINES_CACHE'."
      if [ -f "$CHANGED_LINES_CACHE" ] && grep -qF "${SEARCH_TERM}" "$CHANGED_LINES_CACHE"; then
        debug_log "  Resultado: Linha '${SEARCH_TERM}' ENCONTRADA no cache de linhas alteradas."
        debug_endgroup
        return 0
      else
        debug_log "  Resultado: Linha '${SEARCH_TERM}' NÃO encontrada no cache de linhas alteradas."
        debug_endgroup
        return 1
      fi
    fi
}

extract_p1_violations() {
  # Adição de logs de debug para extração de P1s
  debug_group "Extração de Violações P1 (JQ)"
    debug_log "Extraindo P1s de ${CODENARC_JSON}."
    jq_command='
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
    '
    debug_log "Comando JQ para P1s:\n${jq_command}"
    p1s=$(jq -r "$jq_command" "$CODENARC_JSON" 2>/dev/null)
    debug_log "P1s extraídas:\n${p1s}"
    debug_log "P1s extraídas (od -c):\n$(echo "${p1s}" | od -c)" # Novo log
    echo "$p1s"
  debug_endgroup
}

check_blocking_rules() {
  echo ""
  echo "🔎 Verificando violações bloqueantes (P1)..."
  # Adição de logs de debug para verificação de regras bloqueantes
  debug_group "Verificação de Regras Bloqueantes (P1)"
    if [ ! -f "$CODENARC_JSON" ]; then
      echo "❌ Erro: Resultado do CodeNarc não encontrado. Não é possível verificar P1s."
      debug_log "Erro: $CODENARC_JSON não existe."
      debug_endgroup
      return 1
    fi
    
    p1_violations=$(extract_p1_violations)
    if [ -z "$p1_violations" ]; then
      echo "✅ Nenhuma violação P1 detectada → merge permitido"
      debug_log "Nenhuma P1 encontrada."
      debug_endgroup
      return 0
    fi
    p1_count=$(echo "$p1_violations" | wc -l | tr -d ' ')
    echo "📊 Total de P1 encontradas: $p1_count"
    echo "⛔ Violações P1:"
    echo "$p1_violations"

    if [ "${INPUT_REPORTER}" = "local" ]; then
      echo ""
      echo "🏠 Modo de execução local: todas as violações P1 são bloqueantes."
      echo "💡 Corrija as violações antes de prosseguir."
      debug_log "Modo local ativo, bloqueando por todas as P1s."
      debug_endgroup
      exit 1
    fi

    echo ""
    echo "⚠️  Analisando se as P1s estão em linhas alteradas..."
    build_changed_lines_cache
    
    # Adição de log RAW do CHANGED_LINES_CACHE aqui
    debug_group "Conteúdo RAW de $CHANGED_LINES_CACHE (pós build_changed_lines_cache)"
        if [ -f "$CHANGED_LINES_CACHE" ]; then
            debug_log "Conteúdo (od -c, primeiras 50 linhas):\n$(od -c "$CHANGED_LINES_CACHE" | head -n 50)"
        else
            debug_log "Arquivo $CHANGED_LINES_CACHE não encontrado."
        fi
    debug_endgroup

    if [ ! -s "$ALL_DIFF" ]; then
      echo ""
      echo "⚠️  Diff vazio: Sem informações de linhas alteradas. Todas as P1s são consideradas bloqueantes."
      echo "💡 Corrija as violações ou use um bypass autorizado."
      debug_log "ALL_DIFF vazio, bloqueando por todas as P1s como medida de segurança."
      debug_endgroup
      exit 1
    fi
    
    echo ""
    echo "=== DEBUG: Conteúdo do diff ==="
    head -50 "$ALL_DIFF"
    echo "=== FIM DEBUG DIFF ==="
    echo ""
    
    echo "=== DEBUG: Arquivos alterados (primeiras 20 linhas) ==="
    head -20 "$CHANGED_FILES_CACHE" 2>/dev/null || echo "(vazio)"
    echo "=== FIM DEBUG ARQUIVOS ==="
    echo ""
    
    echo "=== DEBUG: Linhas adicionadas (primeiras 30 linhas) ==="
    head -30 "$CHANGED_LINES_CACHE" 2>/dev/null || echo "(vazio)"
    echo "=== FIM DEBUG LINHAS ==="
    echo ""
    
    found_blocking=0
    debug_log "Iniciando loop de verificação de P1s em linhas alteradas."
    while IFS=: read -r file line rest; do
      [ -z "$file" ] && debug_log "Linha P1 vazia, pulando." && continue
      debug_log "Verificando P1: file='${file}', line='${line}', rest='${rest}'"
      
      if [ -z "$line" ]; then
        echo "   → Violação a nível de arquivo (sem linha específica)"
        if is_changed "$file" ""; then
          echo "   → Arquivo ESTÁ na lista de alterados"
          echo "🚨 BLOQUEADO: Violação P1 a nível de arquivo encontrada no arquivo alterado: $file"
          found_blocking=1
          break
        else
          echo "   → Arquivo NÃO está na lista de alterados"
        fi
      else
        echo "   → Violação em linha específica: $line"
        echo "   → Procurando por: '${file}:${line}' no cache"
        if is_changed "$file" "$line"; then
          echo "   → Linha ESTÁ na lista de adicionadas"
          echo "🚨 BLOQUEADO: Violação P1 encontrada na linha alterada: $file:$line"
          found_blocking=1
          break
        else
          echo "   → Linha NÃO está na lista de adicionadas"
        fi
      fi
    done <<EOF
$p1_violations
EOF
    if [ $found_blocking -eq 1 ]; then
      echo ""
      echo "🚨 Merge bloqueado: Violações P1 críticas encontradas em código alterado."
      echo "💡 Corrija as violações antes de prosseguir com o merge ou use o bypass autorizado."
      debug_log "Bloqueio final: P1s em linhas alteradas detectadas."
      debug_endgroup
      exit 1
    fi
    echo ""
    echo "✅ Todas as violações P1 estão fora das linhas alteradas → merge permitido"
    debug_log "Nenhuma P1 bloqueante encontrada em linhas alteradas."
  debug_endgroup
}

# --- Execução Principal do Script ---
if [ -n "${GITHUB_WORKSPACE}" ]; then
  debug_log "Mudando para diretório de trabalho: ${GITHUB_WORKSPACE}/${INPUT_WORKDIR}"
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || (echo "::error::Não foi possível mudar para o diretório de trabalho: ${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" && exit 1)
  debug_log "PWD após CD: $(pwd)"
  git config --global --add safe.directory "$GITHUB_WORKSPACE"
  debug_log "Adicionado $GITHUB_WORKSPACE como safe.directory para git."
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"
debug_log "REVIEWDOG_GITHUB_API_TOKEN exportado."

run_codenarc
run_reviewdog
check_blocking_rules

echo "🏁 Análise de CodeNarc concluída com sucesso."
debug_log "Script CodeNarc finalizado."