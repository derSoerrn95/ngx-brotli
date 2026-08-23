# alpine-slim drops njs, xslt, image-filter and geoip along with their
# dependency trees (libgd, freetype, fontconfig, libjpeg, libpng, libxml2,
# libxslt) — ~20 MB compressed, none of which this image uses. Same nginx
# build, same entrypoint chain, same envsubst template support.
ARG NGINX_VERSION=alpine-slim

FROM nginx:${NGINX_VERSION} AS builder

RUN apk add --no-cache \
    build-base \
    cmake \
    git \
    linux-headers \
    pcre2-dev \
    openssl-dev \
    zlib-dev

# Get nginx version and download matching source
RUN NGINX_VER=$(nginx -v 2>&1 | sed 's/.*nginx\///' ) && \
    wget -O /tmp/nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz" && \
    tar -xzf /tmp/nginx.tar.gz -C /tmp

# Clone and build brotli module
RUN git clone --recurse-submodules https://github.com/google/ngx_brotli.git /tmp/ngx_brotli && \
    cd /tmp/ngx_brotli/deps/brotli && \
    mkdir out && cd out && \
    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
          -DENABLE_TESTING=OFF -DENABLE_INSTALL=OFF .. && \
    cmake --build . --config Release -j$(nproc)

# Build dynamic modules against the exact nginx version
RUN NGINX_VER=$(nginx -v 2>&1 | sed 's/.*nginx\///') && \
    cd /tmp/nginx-${NGINX_VER} && \
    CONFARGS=$(nginx -V 2>&1 | sed -n 's/.*configure arguments: //p') && \
    eval ./configure ${CONFARGS} --with-compat --add-dynamic-module=/tmp/ngx_brotli && \
    make modules -j$(nproc)

FROM nginx:${NGINX_VERSION}

# Install the watcher's only runtime dependency, then strip what a running
# nginx never touches. These files come from the base image's layers, so a
# whiteout here shrinks the attack surface of the *container*, not the
# download size of the image — parent-layer bytes can't be reclaimed.
RUN apk add --no-cache inotify-tools && \
    apk add --no-cache --virtual .setcap libcap-setcap && \
    setcap cap_net_bind_service=+ep /usr/sbin/nginx && \
    apk del .setcap && \
    rm -f /usr/sbin/nginx-debug /usr/bin/scanelf && \
    rm -f /sbin/apk /usr/lib/libapk.so.* && \
    mkdir -p /etc/nginx/modules

# On removing apk: it stops an attacker with RCE from installing tooling.
# /lib/apk/db/installed is deliberately kept so image scanners (trivy, grype)
# can still enumerate packages — without it they report zero findings, which
# reads as "clean" rather than "unknown".
# Caveat: docker-entrypoint.d/10-listen-on-ipv6-by-default.sh shells out to
# `apk manifest` to checksum the stock conf.d/default.conf. It now no-ops
# (exits 0), so a *stock* default.conf no longer gets `listen [::]:80;`
# added. Irrelevant if you mount your own config, which this image expects.
COPY --from=builder /tmp/nginx-*/objs/ngx_http_brotli_filter_module.so /etc/nginx/modules/
COPY --from=builder /tmp/nginx-*/objs/ngx_http_brotli_static_module.so /etc/nginx/modules/

# Add module loading to nginx config
RUN sed -i '1i load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;\nload_module /etc/nginx/modules/ngx_http_brotli_static_module.so;' /etc/nginx/nginx.conf

# Auto-reload nginx when SSL files change on disk. Hooks into the official
# /docker-entrypoint.d/ chain so ENTRYPOINT/CMD stay drop-in compatible.
COPY cert-watch.sh    /usr/local/bin/cert-watch.sh
COPY 40-cert-watch.sh /docker-entrypoint.d/40-cert-watch.sh
RUN chmod +x /usr/local/bin/cert-watch.sh /docker-entrypoint.d/40-cert-watch.sh

# Run unprivileged. Root was only needed for two things: binding :80/:443,
# now covered by the file capability set above, and owning the runtime dirs,
# handled here. The pid file moves to /tmp because /run is root-owned, and a
# tmpfs mounted over it would be too unless the caller passes uid=101.
#
# `user nginx;` is deliberately left in nginx.conf. It is inert while the
# master is unprivileged (nginx logs one warning at startup), but it means
# `--user 0:0` restores the original root-master/nginx-worker behaviour
# exactly, which is the escape hatch if a mount can't be made readable.
#
# Certificates must be readable by uid 101. This is the one breaking change
# for existing deployments: a root-owned key with mode 600 was readable by
# the old root master and is not readable now.
RUN sed -i 's#/run/nginx\.pid#/tmp/nginx.pid#' /etc/nginx/nginx.conf && \
    grep -q '/tmp/nginx.pid' /etc/nginx/nginx.conf && \
    chown -R nginx:nginx /var/cache/nginx /etc/nginx/conf.d

USER nginx

LABEL org.opencontainers.image.source="https://github.com/derSoerrn95/ngx-brotli"
LABEL org.opencontainers.image.description="Hardened nginx:alpine-slim with Brotli compression and SSL cert auto-reload"
