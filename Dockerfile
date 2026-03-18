# syntax=docker/dockerfile:1.7

ARG ALPINE_VERSION=3.20
ARG GO_IMAGE=golang:1.24-alpine
ARG AMNEZIAWG_GO_REF=master
ARG AMNEZIAWG_TOOLS_REF=v1.0.20260223
ARG MICROSOCKS_REF=v1.0.5

FROM ${GO_IMAGE} AS build-amneziawg-go
ARG AMNEZIAWG_GO_REF

RUN apk add --no-cache git make build-base linux-headers

WORKDIR /src
RUN git clone --depth 1 --branch "${AMNEZIAWG_GO_REF}" https://github.com/amnezia-vpn/amneziawg-go.git .
RUN make

FROM alpine:${ALPINE_VERSION} AS build-amneziawg-tools
ARG AMNEZIAWG_TOOLS_REF

RUN apk add --no-cache bash build-base git make linux-headers

WORKDIR /src
RUN git clone --depth 1 --branch "${AMNEZIAWG_TOOLS_REF}" https://github.com/amnezia-vpn/amneziawg-tools.git .
RUN make -C src WITH_WGQUICK=yes WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no
RUN make -C src install \
    DESTDIR=/out \
    PREFIX=/usr \
    WITH_WGQUICK=yes \
    WITH_BASHCOMPLETION=no \
    WITH_SYSTEMDUNITS=no

FROM alpine:${ALPINE_VERSION} AS build-microsocks
ARG MICROSOCKS_REF

RUN apk add --no-cache build-base git make

WORKDIR /src
RUN git clone --depth 1 --branch "${MICROSOCKS_REF}" https://github.com/rofl0r/microsocks.git .
RUN make

FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache bash ca-certificates iproute2 iptables procps tini \
    && update-ca-certificates \
    && mkdir -p /config /etc/amnezia/amneziawg /var/run/amneziawg /dev/net

RUN printf '#!/usr/bin/env sh\nfor arg in "$@"; do\n  case "$arg" in\n    -a) cat > /etc/resolv.conf; exit 0 ;;\n    -d) exit 0 ;;\n  esac\ndone\ncat >/dev/null 2>/dev/null\nexit 0\n' > /usr/local/bin/resolvconf \
    && chmod 0755 /usr/local/bin/resolvconf

COPY --from=build-amneziawg-go /src/amneziawg-go /usr/local/bin/amneziawg-go
COPY --from=build-amneziawg-tools /out/usr/bin/awg /usr/local/bin/awg
COPY --from=build-amneziawg-tools /out/usr/bin/awg-quick /usr/local/bin/awg-quick
COPY --from=build-amneziawg-tools /out/etc/amnezia/amneziawg /etc/amnezia/amneziawg
COPY --from=build-microsocks /src/microsocks /usr/local/bin/microsocks
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN sed -i 's/cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1/cmd sysctl -q net.ipv4.conf.all.src_valid_mark=1 || true/' /usr/local/bin/awg-quick \
    && chmod 0755 /usr/local/bin/amneziawg-go \
    /usr/local/bin/awg \
    /usr/local/bin/awg-quick \
    /usr/local/bin/microsocks \
    /usr/local/bin/resolvconf \
    /usr/local/bin/entrypoint.sh

ENV AWG_CONFIG_FILE=/config/amnezia.conf \
    WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go \
    LOG_LEVEL=info \
    PROXY_LISTEN_HOST=0.0.0.0 \
    PROXY_PORT=1080

VOLUME ["/config"]

EXPOSE 1080/tcp

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]