#!/bin/sh
# Boot sequence for an ephemeral-disk container:
#   1. drop root -> nonroot (same UID the upstream Memos image uses)
#   2. restore the SQLite DB from R2
#   3. run Memos as a child of `litestream replicate`, which streams every WAL
#      change back to R2 and does a final sync when SIGTERM arrives.
set -eu

DATA_DIR=/var/opt/memos
DB="$DATA_DIR/memos_prod.db"
MEMOS_UID=${MEMOS_UID:-10001}
MEMOS_GID=${MEMOS_GID:-10001}

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DATA_DIR"
  chown -R "$MEMOS_UID:$MEMOS_GID" "$DATA_DIR"
  # su-exec keeps the environment, so R2 credentials survive the switch.
  exec su-exec "$MEMOS_UID:$MEMOS_GID" "$0" "$@"
fi

for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  eval "val=\${$v:-}"
  if [ -z "$val" ]; then
    echo "run.sh: $v is not set; refusing to start (data would not be persisted)" >&2
    exit 1
  fi
done

# Safety latch. On the very first deploy there is no replica yet, so restore must
# be allowed to find nothing. After that, "no replica found" almost always means a
# misconfiguration (wrong bucket/path/credentials). Starting anyway would boot an
# EMPTY Memos and start replicating that over your history, so we fail instead.
RESTORE_FLAGS="-if-db-not-exists"
if [ "${LITESTREAM_ALLOW_EMPTY:-false}" = "true" ]; then
  RESTORE_FLAGS="$RESTORE_FLAGS -if-replica-exists"
  echo "run.sh: LITESTREAM_ALLOW_EMPTY=true, an empty replica is allowed (first boot only!)"
fi

echo "run.sh: restoring $DB from r2://$R2_BUCKET/memos"
# shellcheck disable=SC2086
litestream restore $RESTORE_FLAGS "$DB"

export MEMOS_DRIVER=sqlite
export MEMOS_DSN="$DB"
export MEMOS_DATA="$DATA_DIR"

echo "run.sh: starting memos under litestream replicate"
exec litestream replicate -exec "/usr/local/memos/memos"
