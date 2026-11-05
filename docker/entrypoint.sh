#!/bin/sh
# Lagezentrum all-in-one: prepares /data, then runs VictoriaLogs, Vector (+ GoFlow2),
# the API and Caddy side by side. If one of them dies, all are stopped and the
# container exits, so Docker's restart policy brings everything back in a clean state.
set -eu

DATA=${DATA_DIR:-/data}
SHARE=/usr/local/share/unifi-hq

log() { echo "[unifi-hq] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# "docker run --rm -i <image> hash-password" and other one-off commands
case "${1:-}" in
  "") ;;
  hash-password) exec lz-api hash-password ;;
  *) exec "$@" ;;
esac

# --- User ---------------------------------------------------------------
# Started as root (default): fix ownership of /data, then drop to PUID:PGID.
# Started with --user: run everything as that user, /data must be writable for it.
if [ "$(id -u)" = 0 ]; then
  RUN="su-exec ${PUID}:${PGID}"
else
  RUN=""
  PUID=$(id -u) PGID=$(id -g)
fi

mkdir -p "$DATA/config" "$DATA/geoip" "$DATA/vlogs" "$DATA/auth" /tmp/vector /tmp/caddy 2>/dev/null \
  || die "$DATA is not writable for uid $(id -u) (set PUID/PGID or fix the volume permissions)"
[ -f "$DATA/config/hosts.csv" ] || { cp "$SHARE/hosts.example.csv" "$DATA/config/hosts.csv"; log "created config/hosts.csv (IP,name per line)"; }
if [ -n "$RUN" ]; then
  find "$DATA" /tmp/vector /tmp/caddy \( ! -user "$PUID" -o ! -group "$PGID" \) -exec chown "$PUID:$PGID" {} + 2>/dev/null || true
fi
chmod 700 "$DATA/auth"

# --- Login --------------------------------------------------------------
# AUTH_SECRET signs the session cookies. Unset = generated once and kept in /data/auth.
if [ -z "${AUTH_SECRET:-}" ]; then
  if [ ! -s "$DATA/auth/secret" ]; then
    (umask 077; head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' > "$DATA/auth/secret")
    log "generated session key ($DATA/auth/secret)"
  fi
  AUTH_SECRET=$(cat "$DATA/auth/secret")
fi
export AUTH_SECRET

# Either AUTH_PASSWORD_HASH (from "docker run --rm -i <image> hash-password") or a plain
# AUTH_PASSWORD / AUTH_PASSWORD_FILE. A plain password is hashed once and the hash is reused
# while the password stays the same, otherwise every restart would sign out all browsers.
if [ -n "${AUTH_PASSWORD_FILE:-}" ]; then
  [ -r "$AUTH_PASSWORD_FILE" ] || die "AUTH_PASSWORD_FILE $AUTH_PASSWORD_FILE is not readable"
  AUTH_PASSWORD=$(head -n1 "$AUTH_PASSWORD_FILE" | tr -d '\r')
fi
if [ -z "${AUTH_PASSWORD_HASH:-}" ] && [ -n "${AUTH_PASSWORD:-}" ]; then
  [ "${#AUTH_PASSWORD}" -ge 10 ] || die "AUTH_PASSWORD must have at least 10 characters"
  fp=$(printf '%s\n%s' "$AUTH_SECRET" "$AUTH_PASSWORD" | sha256sum | cut -d' ' -f1)
  if [ -s "$DATA/auth/password.hash" ] && [ "$(cat "$DATA/auth/password.fp" 2>/dev/null)" = "$fp" ]; then
    AUTH_PASSWORD_HASH=$(cat "$DATA/auth/password.hash")
  else
    AUTH_PASSWORD_HASH=$(printf '%s\n' "$AUTH_PASSWORD" | lz-api hash-password | tail -1)
    case "$AUTH_PASSWORD_HASH" in pbkdf2-sha256:*) ;; *) die "could not hash AUTH_PASSWORD" ;; esac
    (umask 077; printf '%s\n' "$AUTH_PASSWORD_HASH" > "$DATA/auth/password.hash"; printf '%s\n' "$fp" > "$DATA/auth/password.fp")
    log "login password set (all browsers have to sign in again)"
  fi
fi
unset AUTH_PASSWORD AUTH_PASSWORD_FILE
export AUTH_PASSWORD_HASH="${AUTH_PASSWORD_HASH:-}"
[ -n "$RUN" ] && chown -R "$PUID:$PGID" "$DATA/auth"

# --- GeoIP ----------------------------------------------------------------
geoip() { $RUN sh "$SHARE/geoip-update.sh"; }
geoip || die "GeoIP databases missing and download failed – the container needs internet access on first start"

# --- Services ---------------------------------------------------------------
PIDS=""
start() {  # start NAME CMD... -> runs CMD as PUID:PGID in the background
  name=$1; shift
  $RUN "$@" &
  PIDS="$PIDS $!"
  eval "PID_$name=$!"
}
alive() {  # a child that exited stays a zombie until reaped, so check its state too
  s=$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null) || return 1
  [ -n "$s" ] && [ "$s" != Z ]
}
stop() {
  # front to back: Caddy/API/Vector first so Vector can flush, VictoriaLogs last
  for p in ${PID_caddy:-} ${PID_api:-} ${PID_vector:-} ${PID_geoip:-}; do kill -TERM "$p" 2>/dev/null || true; done
  for p in ${PID_caddy:-} ${PID_api:-} ${PID_vector:-}; do wait "$p" 2>/dev/null || true; done
  [ -n "${PID_vlogs:-}" ] && { kill -TERM "$PID_vlogs" 2>/dev/null || true; wait "$PID_vlogs" 2>/dev/null || true; }
}
trap 'log "stopping"; stop; exit 0' TERM INT

start vlogs victoria-logs \
  -httpListenAddr=127.0.0.1:9428 \
  -storageDataPath="$DATA/vlogs" \
  -retentionPeriod="${RETENTION:-90d}" \
  -retention.maxDiskSpaceUsageBytes="${MAX_DISK:-20GiB}" \
  -inmemoryDataFlushInterval=30s \
  -loggerLevel=WARN \
  -search.maxQueryDuration=60s
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://127.0.0.1:9428/health 2>/dev/null && break
  alive "$PID_vlogs" || die "VictoriaLogs did not start"
  sleep 0.5
done

start vector vector --config /etc/vector/vector.yaml
start api env HOSTS_FILE="$DATA/config/hosts.csv" LISTEN=127.0.0.1:8092 lz-api
start caddy caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

# GeoIP refresh: daily check, downloads only when the files are older than GEOIP_MAX_AGE_DAYS
# (default 32). New databases are picked up by reloading Vector (SIGHUP).
(
  trap 'exit 0' TERM
  while :; do
    sleep 86400 & wait $!
    before=$(stat -c %Y /geoip/*.mmdb 2>/dev/null | tr '\n' ' ')
    geoip || log "GeoIP refresh failed, keeping the current databases"
    [ "$before" = "$(stat -c %Y /geoip/*.mmdb 2>/dev/null | tr '\n' ' ')" ] || { kill -HUP "$PID_vector" 2>/dev/null || true; log "GeoIP updated"; }
  done
) &
PID_geoip=$!

log "running – dashboard on port ${HTTP_PORT:-8080}, NetFlow/IPFIX udp/2055, syslog udp/5514"
[ -n "$AUTH_PASSWORD_HASH" ] || log "WARNING: no login password set – anyone on the LAN can open the dashboard (set AUTH_PASSWORD)"

while :; do
  for p in $PIDS; do
    if ! alive "$p"; then
      log "process $p exited, stopping the container"
      stop
      exit 1
    fi
  done
  sleep 5 & wait $!
done
