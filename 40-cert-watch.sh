#!/bin/sh
# Hook for the official nginx entrypoint chain. Backgrounds the cert
# watcher and returns immediately so the entrypoint can exec nginx.
#
# Env vars:
#   CERT_WATCH_DISABLE=1   Skip the watcher entirely.
#   CERT_WATCH_SCRIPT      Path to the watcher script. Defaults to the
#                          bundled /usr/local/bin/cert-watch.sh; override
#                          to use a custom script bind-mounted into the
#                          container.
set -eu

if [ "${CERT_WATCH_DISABLE:-}" = "1" ]; then
    echo "[cert-watch] disabled by CERT_WATCH_DISABLE"
    exit 0
fi

SCRIPT="${CERT_WATCH_SCRIPT:-/usr/local/bin/cert-watch.sh}"
if [ -x "$SCRIPT" ]; then
    echo "[cert-watch] launching: $SCRIPT"
    "$SCRIPT" &
else
    echo "[cert-watch] WARNING: $SCRIPT not found or not executable; skipping" >&2
fi
