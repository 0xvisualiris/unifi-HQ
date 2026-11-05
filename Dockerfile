# Lagezentrum – all-in-one image
#
# One container with everything docker-compose.yml otherwise spreads over five:
# Vector + GoFlow2 (collector), VictoriaLogs (history), Caddy (dashboard), the
# login/names API and the GeoIP download. Meant for plain Docker hosts (Synology,
# Unraid, TrueNAS, a Pi, any Linux box) where the Proxmox/LXC install doesn't fit.
#
#   docker build -t unifi-hq .
#   docker run -d --name unifi-hq --network host -v unifi-hq:/data unifi-hq
#
# Tutorial: docs/DOCKER.md. Versions are kept in sync with docker-compose.yml
# and collector/Dockerfile.
ARG GOFLOW2_VERSION=v2.2.7
ARG VECTOR_VERSION=0.58.0
ARG VICTORIALOGS_VERSION=v1.53.0
ARG CADDY_VERSION=2.11

# Cross-compiled on the build machine, so multi-arch builds don't run Go under QEMU
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS api
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY api/go.mod api/*.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /lz-api .

FROM netsampler/goflow2:${GOFLOW2_VERSION} AS goflow2
FROM victoriametrics/victoria-logs:${VICTORIALOGS_VERSION} AS victorialogs
FROM caddy:${CADDY_VERSION}-alpine AS caddy

# Vector's Alpine image as the base: Vector itself is the only binary that isn't static
FROM timberio/vector:${VECTOR_VERSION}-alpine

# tini reaps zombies and forwards signals, su-exec drops root, bash/curl for "lz test"
RUN apk add --no-cache tini su-exec bash curl ca-certificates ssl_client tzdata

COPY --from=goflow2 /goflow2 /usr/local/bin/goflow2
COPY --from=victorialogs /victoria-logs-prod /usr/local/bin/victoria-logs
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=api /lz-api /usr/local/bin/lz-api

# Same paths as in the compose setup, so vector.yaml and the Caddyfile stay unchanged.
# Everything that has to persist lives in /data, the paths below point there.
COPY collector/vector.yaml /etc/vector/vector.yaml
COPY caddy/Caddyfile /etc/caddy/Caddyfile
COPY caddy/auth/README.md /etc/caddy/auth/README.md
COPY web/ /srv/
COPY scripts/geoip-update.sh /usr/local/share/unifi-hq/geoip-update.sh
COPY config/hosts.example.csv /usr/local/share/unifi-hq/hosts.example.csv
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/lz /usr/local/bin/lz
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/lz \
 && rm -rf /etc/vector/config /var/lib/vector \
 && ln -s /data/config /etc/vector/config \
 && ln -s /data/geoip /geoip \
 && ln -s /tmp/vector /var/lib/vector

ENV DATA_DIR=/data \
    PUID=65534 \
    PGID=65534 \
    HTTP_PORT=8080 \
    LOCAL_SERVER_PORTS=51820 \
    RETENTION=90d \
    MAX_DISK=20GiB \
    VECTOR_LOG=warn \
    VECTOR_THREADS=1 \
    HOME=/tmp \
    XDG_CONFIG_HOME=/tmp/caddy \
    XDG_DATA_HOME=/tmp/caddy

VOLUME /data
# 2055/udp NetFlow/IPFIX, 5514/udp syslog, 8080/tcp dashboard
EXPOSE 2055/udp 5514/udp 8080/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:9428/health \
   && curl -fsS -o /dev/null http://127.0.0.1:8092/api/health \
   && curl -s -o /dev/null "http://127.0.0.1:${HTTP_PORT}/login.html" || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
