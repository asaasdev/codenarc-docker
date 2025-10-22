#!/bin/sh
set -e

if [ -n "${GITHUB_WORKSPACE}" ] ; then
  cd "${GITHUB_WORKSPACE}/${INPUT_WORKDIR}" || exit

  git config --global --add safe.directory "$GITHUB_WORKSPACE" || exit
fi

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

if [ -n "$INPUT_SOURCE_FILES" ]; then
  java -jar /lib/codenarc-all.jar \
      -report="${INPUT_REPORT:-compact:stdout}" \
      -rulesetfiles="${INPUT_RULESETFILES}" \
      -basedir="." \
      -includes="${INPUT_SOURCE_FILES}" \
      > result.txt
else
  echo "Nenhum arquivo Groovy alterado encontrado. Pulando análise do CodeNarc."
  exit 0
fi


< result.txt reviewdog -efm="%f:%l:%m" -efm="%f:%r:%m" \
    -name="codenarc" \
    -reporter="${INPUT_REPORTER:-github-pr-check}" \
    -filter-mode="${INPUT_FILTER_MODE}" \
    -fail-on-error="${INPUT_FAIL_ON_ERROR}" \
    -level="${INPUT_LEVEL}" \
    ${INPUT_REVIEWDOG_FLAGS}
