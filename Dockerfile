ARG erlang_version=27.3
ARG elixir_version=1.19.4
ARG alpine_version=3.22.4

FROM hexpm/elixir:${elixir_version}-erlang-${erlang_version}-alpine-${alpine_version} AS builder

RUN apk update && apk add --no-cache build-base git
RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY config config
RUN mix release

# ==============================================

FROM alpine:${alpine_version}

ARG PUID=1000
ARG PGID=1000

ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8

RUN apk update --no-cache && \
    apk add --no-cache bash libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app

RUN addgroup -g ${PGID} -S llmgateway && \
    adduser -u ${PUID} -S llmgateway -G llmgateway -h /app
RUN mkdir -p /config && chown llmgateway:llmgateway /config

USER llmgateway

COPY --chown=llmgateway:llmgateway --from=builder /app/_build/prod/rel/llmgateway .

ENV LLMGATEWAY_CONFIG_PATH=/config/config.yaml
ENV LLMGATEWAY_DATA_DIR=/config

VOLUME /config
EXPOSE 4000

CMD ["./bin/llmgateway", "start"]
