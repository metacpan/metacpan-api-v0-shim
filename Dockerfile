ARG SLIM_BUILD
ARG MAYBE_BASE_BUILD=${SLIM_BUILD:+server-base-slim}
ARG BASE_BUILD=${MAYBE_BASE_BUILD:-server-base}

################### Web Server Base
FROM metacpan/metacpan-base:main-20260424-113420 AS server-base
FROM metacpan/metacpan-base:main-20260424-113420-slim AS server-base-slim

################### CPAN Prereqs
FROM server-base AS build-cpan-prereqs
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

WORKDIR /app/

COPY cpanfile cpanfile.snapshot ./
RUN \
    --mount=type=cache,target=/root/.perl-cpm,sharing=private \
<<EOT
    cpm install --show-build-log-on-failure --resolver=snapshot
EOT

################### Web Server
# false positive
# hadolint ignore=DL3006
FROM ${BASE_BUILD} AS server
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

WORKDIR /app/

ENV PERL5LIB="/app/lib:/app/local/lib/perl5"
ENV PATH="/app/local/bin:${PATH}"

COPY --from=build-cpan-prereqs /app/local local

COPY app.psgi ./
COPY lib lib

USER metacpan

CMD [ \
    "/uwsgi.sh", \
    "--http-socket", ":5001" \
]

EXPOSE 5001

HEALTHCHECK --start-period=3s CMD [ "curl", "--fail", "http://localhost:5001/healthcheck" ]

################### Dev Prereqs
FROM build-cpan-prereqs AS build-dev-prereqs
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

USER root

RUN \
    --mount=type=cache,target=/root/.perl-cpm \
<<EOT
    cpm install --show-build-log-on-failure --resolver=snapshot --with-develop --with-test
EOT

RUN <<EOT
    curl -sL \
        https://raw.githubusercontent.com/houseabsolute/ubi/master/bootstrap/bootstrap-ubi.sh \
        | TARGET=/tmp sh

    /tmp/ubi --project houseabsolute/omegasort --in /usr/local/bin
    /tmp/ubi --project houseabsolute/precious --in /usr/local/bin
EOT

################### Development Server
FROM server AS develop

ENV PLACK_ENV=development

COPY --from=build-dev-prereqs /app/local local
COPY --from=build-dev-prereqs /usr/local/bin/precious /usr/local/bin/omegasort /usr/local/bin/
COPY .perlcriticrc .perltidyrc perlimports.toml precious.toml .editorconfig ./
COPY t t

USER root
RUN [ "chown", "-R", "metacpan", "/app/local" ]
USER metacpan

################### Test Runner
FROM develop AS test
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

ENV PLACK_ENV=

CMD [ "prove", "-l", "-r", "-j", "2", "t" ]

################### Production Server
FROM server AS production
