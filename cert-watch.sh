#!/bin/sh
# Reload nginx when SSL files it has loaded change on disk.
# Discovers paths from `nginx -T` and watches their parent dirs.
#
# Env vars:
#   CERT_WATCH_EXTRA_DIRS    Extra dirs to watch, ":"-separated. Useful for
#                            paths nginx doesn't load directly (symlink
#                            targets, dirs populated after reload, etc.).
#   CERT_WATCH_DEBOUNCE_SEC  Wait this long after the first event before
#                            reloading, so multi-file renewals (fullchain +
#                            privkey arriving back-to-back) settle before
#                            nginx re-reads them. Default 2.
set -eu

DEBOUNCE="${CERT_WATCH_DEBOUNCE_SEC:-2}"

# Wait for the config to be parseable. `nginx -T` only parses, it does not
# require the master to be running, so this mainly guards against a config
# volume that mounts slightly after the container starts.
i=0
until nginx -T >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 30 ] || { echo "[cert-watch] config never became valid; exiting" >&2; exit 1; }
    sleep 1
done

AUTO=$(nginx -T 2>/dev/null \
    | awk '$1 ~ /^ssl_(certificate|certificate_key|trusted_certificate|client_certificate|dhparam|stapling_file|crl)$/ {
               gsub(";", "", $2); print $2
           }' \
    | xargs -rn1 dirname)

EXTRA=""
[ -n "${CERT_WATCH_EXTRA_DIRS:-}" ] && EXTRA=$(echo "$CERT_WATCH_EXTRA_DIRS" | tr ':' '\n')

DIRS=$(printf '%s\n%s\n' "$AUTO" "$EXTRA" \
    | grep -v '^$' \
    | sort -u \
    | while read d; do [ -d "$d" ] && echo "$d"; done)

if [ -z "$DIRS" ]; then
    echo "[cert-watch] no SSL paths discovered and no CERT_WATCH_EXTRA_DIRS set — exiting"
    exit 0
fi

echo "[cert-watch] watching: $(echo $DIRS | tr '\n' ' ')"

while true; do
    inotifywait -q -e moved_to,close_write $DIRS >/dev/null || true
    # Sleep BEFORE reloading so companion files (e.g. fullchain + privkey
    # written back-to-back) land first. Reloading on the very first event
    # risks loading a new fullchain alongside an old privkey, which nginx
    # rejects, leaving us on the old config with no further events queued.
    sleep "$DEBOUNCE"
    # `nginx -t` runs SSL_CTX_check_private_key(), so a mid-renewal state
    # (new cert + old key, or vice versa) is caught here. Skipping the
    # reload in that case avoids noisy errors in nginx's log; the next
    # event (the late companion file) will drive the eventual reload.
    if nginx -t >/dev/null 2>&1; then
        echo "[cert-watch] reloading nginx"
        nginx -s reload || true
    else
        echo "[cert-watch] config invalid (likely cert/key mismatch mid-renewal); waiting for next event"
    fi
done
