# ngx-brotli

`nginx:alpine-slim` with the [Brotli](https://github.com/google/ngx_brotli) modules
and automatic reload when TLS certificates change on disk.

Rebuilt daily against the upstream base image and published to
`ghcr.io/dersoerrn95/ngx-brotli`.

## Tags

| tag | meaning |
| --- | --- |
| `latest` | most recent build |
| `1.31.4` | the nginx version in the image |
| `nginx-<digest>` | the base image digest the build came from |
| `sha-<commit>` | the commit that produced the image |

## Quick start

```sh
docker run -d -p 80:80 -p 443:443 \
  -v ./conf.d:/etc/nginx/conf.d:ro \
  -v ./certs:/etc/nginx/certs:ro \
  ghcr.io/dersoerrn95/ngx-brotli:latest
```

Enable Brotli in a server block. The modules are already loaded by
`nginx.conf`, so no `load_module` line is needed:

```nginx
brotli            on;
brotli_comp_level 5;
brotli_min_length 256;
brotli_types      text/plain text/css application/json application/javascript
                  text/xml application/xml image/svg+xml;
```

## Certificate auto-reload

`cert-watch.sh` runs from the entrypoint chain. It reads `nginx -T`, collects
the directories behind every `ssl_certificate`, `ssl_certificate_key`,
`ssl_trusted_certificate`, `ssl_client_certificate`, `ssl_dhparam`,
`ssl_stapling_file` and `ssl_crl` path, and watches them with `inotifywait`.
On a change it waits out a debounce, runs `nginx -t`, and reloads only if the
config still validates — so a half-finished renewal (new cert, old key) is
skipped rather than reloaded into a broken state.

| variable | default | purpose |
| --- | --- | --- |
| `CERT_WATCH_DISABLE` | unset | set to `1` to skip the watcher |
| `CERT_WATCH_DEBOUNCE_SEC` | `2` | seconds to wait before reloading |
| `CERT_WATCH_EXTRA_DIRS` | unset | extra `:`-separated dirs to watch |
| `CERT_WATCH_SCRIPT` | `/usr/local/bin/cert-watch.sh` | override the script |

`CERT_WATCH_EXTRA_DIRS` matters when certificates arrive through a symlink
(certbot's `live/` layout) or land in a directory that doesn't exist yet at
startup — inotify watches the directory, not the link target.

## Running hardened

The image runs as **uid 101** and needs no writable filesystem beyond two
tmpfs mounts. `read_only` and capability limits are runtime settings, so they
have to be applied by whoever starts the container:

```yaml
services:
  nginx:
    image: ghcr.io/dersoerrn95/ngx-brotli:latest
    ports: ["80:80", "443:443"]
    read_only: true
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    tmpfs:
      - /tmp:mode=1777
      - /var/cache/nginx:uid=101,gid=101
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./certs:/etc/nginx/certs:ro
```

CI starts the published image with exactly these flags on every build and
fails if it can't serve a Brotli-encoded response.

### Things that will bite you

**Certificates must be readable by uid 101.** This is the one behaviour change
from a stock `nginx` image. There the master process was root and could read a
`0600` root-owned key before dropping workers to `nginx`. Here it cannot.
Use `chown 101:101` on the key, or `--user 0:0` to restore the old
root-master behaviour — `user nginx;` is still in `nginx.conf`, so workers stay
unprivileged either way.

**Do not add `no-new-privileges:true` with this compose file.** Binding
`:80`/`:443` as a non-root user works because `/usr/sbin/nginx` carries the
`cap_net_bind_service` file capability. `no_new_privs` makes the kernel ignore
file capabilities across `execve`, so nginx would fail to bind. If you want
that flag, serve on unprivileged ports instead — `listen 8080;` in your config,
`ports: ["80:8080"]`, then `cap_drop: [ALL]` with no `cap_add` at all, which is
strictly the stronger setup.

**Templates need a writable `conf.d`.** `/etc/nginx/templates/*.template` is
rendered by the entrypoint into `/etc/nginx/conf.d/`, which a read-only rootfs
blocks. Add a tmpfs on `/etc/nginx/conf.d` if you use them.

**One startup warning is expected**: `the "user" directive makes sense only if
the master process runs with super-user privileges`. It is inert and kept
deliberately so `--user 0:0` still works.

## What was removed

`alpine-slim` drops njs, xslt, image-filter and geoip along with libgd,
freetype, fontconfig, libjpeg, libpng, libxml2 and libxslt — about 20 MB of
code this image never calls. The build additionally removes `nginx-debug`,
`scanelf` and the `apk` binary, leaving `/lib/apk/db/installed` in place so
vulnerability scanners can still enumerate packages.

Because `apk` is gone, `docker-entrypoint.d/10-listen-on-ipv6-by-default.sh`
no longer adds `listen [::]:80;` to a *stock* `conf.d/default.conf`. Set it
yourself if you rely on the packaged default config over IPv6.
