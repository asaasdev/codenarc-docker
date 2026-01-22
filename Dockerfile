# Build CodeNarc from source
FROM gradle:8.5-jdk17 AS builder

WORKDIR /build
RUN git clone https://github.com/CodeNarc/CodeNarc.git && \
    cd CodeNarc && \
    git checkout master && \
    ./gradlew shadowJar && \
    ls -la build/libs/

# Runtime image
FROM eclipse-temurin:11-jre-jammy

RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get install --no-install-recommends -y wget git jq && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/CodeNarc/build/libs/CodeNarc-*.jar /lib/codenarc-all.jar

ENV REVIEWDOG_VERSION=v0.20.3

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN wget -O - -q https://raw.githubusercontent.com/reviewdog/reviewdog/master/install.sh| sh -s -- -b /usr/local/bin/ ${REVIEWDOG_VERSION}

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]