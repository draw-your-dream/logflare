FROM gcr.io/logflare-232118/logflare_base:latest

COPY ./ /logflare
WORKDIR /logflare

ENV MIX_ENV prod

RUN mix deps.get
RUN mix compile --force

RUN cd /logflare/assets \
    && yarn \
    && ./node_modules/webpack/bin/webpack.js --mode production --silent

WORKDIR /logflare

RUN mix phx.digest
RUN mix release --force --overwrite

WORKDIR /logflare

ENTRYPOINT [ "/logflare/run.bash" ]