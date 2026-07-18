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
COPY config config 2>/dev/null || true
RUN mix release

# ==============================================

FROM alpine:${alpine_version}

ENV LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 LANGUAGE=en_US.UTF-8

RUN apk update --no-cache && \
    apk add --no-cache bash libstdc++ ncurses-libs openssl

WORKDIR /app

RUN addgroup -S llmgateway && adduser -S llmgateway -G llmgateway -h /app
USER llmgateway

COPY --chown=llmgateway:llmgateway --from=builder /app/_build/prod/rel/llmgateway .

EXPOSE 4000

CMD ["./bin/llmgateway", "start"]
