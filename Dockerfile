# Memos + Litestream on Cloudflare Containers.
# State lives in SQLite on the (ephemeral) container disk and is continuously
# replicated to R2 by Litestream; on every cold start it is restored from R2.

# Pinned so a redeploy never silently jumps versions and runs schema migrations
# you didn't plan. To upgrade, bump this to a newer tag from
# https://hub.docker.com/r/neosmemo/memos/tags after reading the release notes.
ARG MEMOS_VERSION=0.31.0
FROM neosmemo/memos:${MEMOS_VERSION}

# Litestream ships a static binary, so it runs on the Alpine-based Memos image.
# Copied from the official image on Docker Hub rather than ADDed from GitHub
# releases: the GitHub asset download can exceed BuildKit's 60s fetch deadline.
# Cloudflare Containers run linux/amd64, and wrangler builds for that platform.
COPY --from=litestream/litestream:0.5.10 /usr/local/bin/litestream /usr/local/bin/litestream
RUN litestream version

COPY litestream.yml /etc/litestream.yml
COPY --chmod=755 run.sh /usr/local/bin/run.sh

EXPOSE 5230

# Replaces the upstream entrypoint; run.sh does the same privilege drop itself.
ENTRYPOINT ["/usr/local/bin/run.sh"]
