ARG NGINX_VERSION=alpine

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

# Copy compiled brotli modules
RUN NGINX_VER=$(nginx -v 2>&1 | sed 's/.*nginx\///') && \
    mkdir -p /etc/nginx/modules
COPY --from=builder /tmp/nginx-*/objs/ngx_http_brotli_filter_module.so /etc/nginx/modules/
COPY --from=builder /tmp/nginx-*/objs/ngx_http_brotli_static_module.so /etc/nginx/modules/

# Add module loading to nginx config
RUN sed -i '1i load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;\nload_module /etc/nginx/modules/ngx_http_brotli_static_module.so;' /etc/nginx/nginx.conf

LABEL org.opencontainers.image.source="https://github.com/derSoerrn95/ngx-brotli"
LABEL org.opencontainers.image.description="nginx:alpine with Brotli compression module"
