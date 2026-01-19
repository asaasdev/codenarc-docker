# codenarc-docker

CodeNarc image with reviewdog.

- codenarc/codenarc:2.2.0-groovy3.0.8
- reviewdog v0.13.0

## Test local

### build image

```bash
docker build -t docker.io/asaasdev/codenarc .
```

# run container

```bash
docker run --rm \
    --workdir /testdata \
    -e INPUT_REPORTER=local \
    -e INPUT_FILTER_MODE=nofilter \
    -e INPUT_FAIL_ON_ERROR=false \
    -e INPUT_LEVEL=error \
    -e INPUT_RULESETFILES=file:basic.xml \
    -e INPUT_RULESETS_CONTENT="$(cat testdata/basic.xml)" \
    -v $(pwd)/testdata:/testdata \
    docker.io/asaasdev/codenarc
```