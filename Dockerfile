################### Web Server
# hadolint ignore=DL3007
FROM metacpan/metacpan-base:latest AS server
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

WORKDIR /metacpan-api-v0-shim/

COPY cpanfile cpanfile.snapshot ./
RUN \
    --mount=type=cache,target=/root/.perl-cpm,sharing=private \
<<EOT /bin/bash -euo pipefail
    cpm install --show-build-log-on-failure
EOT

ENV PERL5LIB="/metacpan-api-v0-shim/local/lib/perl5"
ENV PATH="/metacpan-api-v0-shim/local/bin:${PATH}"

COPY app.psgi ./
COPY lib lib

STOPSIGNAL SIGKILL

CMD [ \
    "/uwsgi.sh", \
    "--http-socket", ":5001" \
]

EXPOSE 5001

################### Test Runner
FROM server AS test
SHELL [ "/bin/bash", "-euo", "pipefail", "-c" ]

ENV PLACK_ENV=

USER root

RUN \
    --mount=type=cache,target=/root/.perl-cpm \
<<EOT /bin/bash -euo pipefail
    cpm install --show-build-log-on-failure --with-test
EOT

COPY t t

USER metacpan
CMD [ "prove", "-l", "-r", "-j", "2", "t" ]

################### Production Server
FROM server AS production

USER metacpan
