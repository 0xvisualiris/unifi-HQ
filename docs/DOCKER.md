# Docker tutorial: Lagezentrum in one container

The main [README](../README.md) installs Lagezentrum into a Proxmox LXC. If you'd rather run it on a
host that already has Docker (a Linux server, Synology, Unraid, TrueNAS SCALE, a Raspberry Pi 4/5),
use the **all-in-one image**. It packs everything into one container:

| Inside the container | Job | Listens on |
|---|---|---|
| GoFlow2 2.2.7 | receives NetFlow/IPFIX from the gateway | UDP 2055 |
| Vector 0.58 | syslog, direction detection, GeoIP/ASN, device names | UDP 5514, 127.0.0.1:8090 |
| VictoriaLogs 1.53 | history | 127.0.0.1:9428 |
| API | login, device names | 127.0.0.1:8092 |
| Caddy 2.11 | dashboard, LAN-only access | TCP 8080 |

Everything that has to persist lives in **one volume at `/data`**:

```
/data/config/hosts.csv   device names (edited from the dashboard or by hand)
/data/geoip/             DB-IP Lite databases (~140 MB, downloaded on first start, refreshed monthly)
/data/vlogs/             history (VictoriaLogs)
/data/auth/              session key and password hash (mode 700)
```

Images for `linux/amd64` and `linux/arm64` are published to `ghcr.io/0xvisualiris/unifi-hq`.

## Contents

1. [Requirements](#1-requirements)
2. [Quick start with `docker run`](#2-quick-start-with-docker-run)
3. [Docker Compose (recommended)](#3-docker-compose-recommended)
4. [Settings](#4-settings)
5. [Setting the login password](#5-setting-the-login-password)
6. [Pointing UniFi at the container](#6-pointing-unifi-at-the-container)
7. [Testing](#7-testing)
8. [Day-to-day operation](#8-day-to-day-operation)
9. [Building the image yourself](#9-building-the-image-yourself)
10. [NAS notes (Synology, Unraid, TrueNAS)](#10-nas-notes)
11. [Bridge networking instead of host networking](#11-bridge-networking-instead-of-host-networking)
12. [Troubleshooting](#12-troubleshooting)

## 1. Requirements

- **Linux Docker host** with Docker Engine 24+ and the compose plugin (`docker compose version`).
  Docker Desktop on Windows/macOS works for trying out the demo, but it hides the real sender IPs, so
  see [section 11](#11-bridge-networking-instead-of-host-networking).
- The host must be **reachable from your gateway** (UDP 2055 and 5514) and from your clients (TCP 8080).
- **Internet access on first start** for the GeoIP download (download.db-ip.com).
- About **300 MB RAM** and a few GB of disk (history is capped at 20 GiB / 90 days by default).
- Free ports on the host: UDP 2055, UDP 5514, TCP 8080, plus 127.0.0.1:8090–8092 and 127.0.0.1:9428.

## 2. Quick start with `docker run`

```bash
docker run -d --name unifi-hq \
  --network host \
  --restart unless-stopped \
  -e TZ=Europe/Berlin \
  -e AUTH_PASSWORD='choose-a-long-password' \
  -e ALLOWED_SENDERS=192.168.1.1 \
  -e HOME_LABEL=Frankfurt -e HOME_LAT=50.11 -e HOME_LON=8.68 \
  -v unifi-hq-data:/data \
  ghcr.io/0xvisualiris/unifi-hq:latest
```

Follow the start-up (the first start downloads ~140 MB of GeoIP data):

```bash
docker logs -f unifi-hq
```

Once you see `running – dashboard on port 8080 …`, open `http://<docker-host-ip>:8080/?demo`. That's
the globe with sample data, no UniFi needed yet.

## 3. Docker Compose (recommended)

Compose keeps the settings in a file and adds the hardening (read-only filesystem, no extra
capabilities). Grab the example file:

```bash
mkdir -p ~/unifi-hq && cd ~/unifi-hq
curl -fsSLo compose.yml https://raw.githubusercontent.com/0xvisualiris/unifi-HQ/main/docker/compose.yml
```

Edit the `environment:` block in `compose.yml` (at least `WAN_IP`, `ALLOWED_SENDERS`, `HOME_*` and
`AUTH_PASSWORD`, see [Settings](#4-settings)), then:

```bash
docker compose up -d
docker compose logs -f
```

Change a value later? Edit `compose.yml` and run `docker compose up -d` again. The container is
recreated, the data in the volume stays.

To keep secrets out of `compose.yml`, put them in a `.env` file next to it and reference them:

```yaml
    environment:
      AUTH_PASSWORD: ${AUTH_PASSWORD}
```

```bash
echo "AUTH_PASSWORD=choose-a-long-password" > .env && chmod 600 .env
```

## 4. Settings

All settings are environment variables. They match the `.env` of the LXC install.

| Variable | Default | Meaning |
|---|---|---|
| `WAN_IP` | *(empty)* | public IPv4 of your gateway, comma-separated if several (`curl -4 ifconfig.me`) |
| `ALLOWED_SENDERS` | *(empty = any private IP)* | IP(s)/CIDRs allowed to send NetFlow and syslog, usually the gateway's LAN IP |
| `LOCAL_EXTRA_NETS` | *(empty)* | your own extra networks, e.g. your IPv6 prefix `2003:ab:cd00::/56` |
| `LOCAL_SERVER_PORTS` | `51820` | ports reachable from outside (port forwards, VPN server) |
| `IGNORE_IPS` | *(empty)* | ignore flows from/to these IPs (e.g. the Docker host itself) |
| `HTTP_PORT` | `8080` | dashboard port |
| `ALLOWED_CLIENTS` | `private_ranges` | who may open the dashboard (Caddy syntax, space-separated CIDRs) |
| `HOME_LAT`, `HOME_LON`, `HOME_LABEL` | `50.11`, `8.68`, `Home` | your location on the globe |
| `GATEWAY_NAME` | `Gateway` | name of the gateway in the dashboard |
| `AUTH_PASSWORD` | *(empty = no login)* | dashboard password, min. 10 characters |
| `AUTH_PASSWORD_FILE` | | read the password from a file (Docker secrets) |
| `AUTH_PASSWORD_HASH` | | pre-computed hash instead of a plain password ([section 5](#5-setting-the-login-password)) |
| `AUTH_SECRET` | *(generated, kept in `/data/auth`)* | key for the session cookies |
| `RETENTION` | `90d` | how long history is kept |
| `MAX_DISK` | `20GiB` | max. disk space for history (whichever limit is hit first) |
| `TZ` | UTC | time zone |
| `PUID`, `PGID` | `65534` | owner of the files in `/data` |
| `VECTOR_THREADS` | `1` | Vector worker threads, only raise with very many flows |
| `GEOIP_MAX_AGE_DAYS` | `32` | GeoIP databases older than this are downloaded again |

Don't put quotes inside `HOME_LABEL` or `GATEWAY_NAME`.

Device names: rename devices directly in the dashboard (✎ in the ticker or the *Devices* tab).
To edit by hand: `/data/config/hosts.csv`, one `IP,name` per line, then `docker exec unifi-hq lz reload`.

## 5. Setting the login password

Pick **one** of three options:

**a) Plain password (simplest).** `AUTH_PASSWORD=...`. The container hashes it once on start
(PBKDF2-SHA256, 600,000 rounds) and keeps the hash in `/data/auth`. Browsers stay signed in across
restarts. Changing the password signs out every browser.

**b) Docker secret / file.** `AUTH_PASSWORD_FILE=/run/secrets/unifi_hq_password`:

```yaml
services:
  unifi-hq:
    environment:
      AUTH_PASSWORD_FILE: /run/secrets/unifi_hq_password
    secrets: [unifi_hq_password]
secrets:
  unifi_hq_password:
    file: ./password.txt
```

**c) Pre-computed hash.** The plain password then appears nowhere in your config:

```bash
docker run --rm -i ghcr.io/0xvisualiris/unifi-hq:latest hash-password
# type the password, press Enter -> prints pbkdf2-sha256:600000:…
```

Set the output as `AUTH_PASSWORD_HASH`. The hash contains no `$`, so it can go into compose
files unescaped.

**Sign out all browsers:** delete `/data/auth/secret` and restart
(`docker exec unifi-hq rm /data/auth/secret && docker restart unifi-hq`).
**Turn the login off:** remove the password variables and recreate the container.

## 6. Pointing UniFi at the container

This works the same as [README section 3](../README.md#3-unifi-setup). Use the **Docker host's IP**
wherever it says `<LXC-IP>`:

- *Settings → CyberSecure → Traffic Logging → NetFlow (IPFIX)*: collector `<docker-host-ip>`, port
  `2055`, version 10, all networks, *All traffic*, sampling off.
- *Activity Logging / SIEM Server* (optional, for blocked traffic): `<docker-host-ip>`, port `5514`.
- Optional firewall rule *Log scanners* for the red arcs, see README 3C.

If the Docker host runs a firewall (ufw, firewalld, Synology firewall), open UDP 2055 and 5514 for the
gateway and TCP 8080 for your LAN.

## 7. Testing

```bash
docker exec unifi-hq lz test
```

This sends a test flow and a test syslog line through the whole chain. It checks that they arrive
in the history with GeoIP data and that the dashboard and login answer:

```
✔ NetFlow path: GoFlow2 -> Vector -> VictoriaLogs works
✔ Syslog path: Vector -> VictoriaLogs works
✔ GeoIP works (45.33.32.156 -> US)
✔ Dashboard answers, login active (HTTP 401 without session)
```

Then:

1. `http://<docker-host-ip>:8080/?demo` shows the login page, then the globe with sample data.
2. `http://<docker-host-ip>:8080` shows **Live** with a green dot.
3. Real flows show up about a minute after enabling NetFlow in UniFi.

## 8. Day-to-day operation

```bash
docker exec unifi-hq lz status     # events in the last hour, last event per source, disk usage
docker exec unifi-hq lz geoip      # refresh GeoIP now (otherwise checked daily, refreshed after 32 days)
docker exec unifi-hq lz reload     # reload Vector after editing hosts.csv by hand
docker logs -f unifi-hq            # logs of all services
docker stats unifi-hq              # RAM / CPU
```

**Updating:**

```bash
docker compose pull && docker compose up -d       # compose
# or with docker run: docker pull …, docker rm -f unifi-hq, then the same docker run again
```

Pin a version instead of `latest` if you prefer (`ghcr.io/0xvisualiris/unifi-hq:sha-abc1234`, or
`:1.2` once releases are tagged).

**Backup:** back up the volume, or at least `/data/config/hosts.csv` and `/data/auth`. The history
(`/data/vlogs`) can be rebuilt, so it's optional to back up:

```bash
docker run --rm -v unifi-hq-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/unifi-hq-config.tgz -C /data config auth
```

**Health:** the image has a built-in healthcheck (`docker ps` shows `healthy`). It checks VictoriaLogs,
the API and Caddy. If any internal service dies, the container exits and the restart policy starts it
again cleanly.

## 9. Building the image yourself

```bash
git clone https://github.com/0xvisualiris/unifi-HQ.git && cd unifi-HQ
docker build -t unifi-hq .
```

In `docker/compose.yml`, swap `image:` for `build: ..` (the path is relative to the compose file).
Multi-arch build for a registry:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/unifi-hq:latest --push .
```

Pinned versions are build arguments: `--build-arg VECTOR_VERSION=0.58.0`, `GOFLOW2_VERSION`,
`VICTORIALOGS_VERSION`, `CADDY_VERSION`. Keep GoFlow2 on 2.x, because `netsampler/goflow2:latest`
is the old 1.x with a different JSON format.

CI (`.github/workflows/docker.yml`) builds the image on every pull request, starts it read-only,
runs `lz test`, logs in, restarts and checks the session survives. On `main` it publishes
`latest` + `sha-…` for amd64 and arm64 to GHCR.

## 10. NAS notes

**File ownership (`PUID`/`PGID`).** The container starts as root, fixes ownership of `/data` and then
runs all services as `PUID:PGID`. With a bind mount (`- /mnt/pool/unifi-hq:/data`) set these to the
user who should own the files. Alternatively start the container directly as that user (`user: "568:568"`).
`/data` must then already be writable for that user, and you can drop all capabilities.

- **TrueNAS SCALE** (*Apps → Discover → ⋮ → Install via YAML*): paste `docker/compose.yml`, set
  `PUID`/`PGID` to `568` (the *apps* user) and use a host path on your pool for `/data`. Host networking
  is supported.
- **Synology** (*Container Manager → Project → Create*): paste `docker/compose.yml`, use a folder under
  `/volume1/docker/unifi-hq` for `/data`, and set `PUID`/`PGID` to your user (`id` over SSH). Port 5514
  is usually free. If *Log Center* already listens on 514, that doesn't matter.
- **Unraid**: add a container with *Network type: Host*, repository `ghcr.io/0xvisualiris/unifi-hq:latest`,
  path `/data` → `/mnt/user/appdata/unifi-hq`, `PUID=99`, `PGID=100`, plus the variables from
  [Settings](#4-settings).
- **Raspberry Pi**: the `arm64` image runs on Pi 4/5 with a 64-bit OS. Open the dashboard on a
  Pi kiosk with `?lite`.

## 11. Bridge networking instead of host networking

Host networking is the default because Lagezentrum checks **source IPs**. `ALLOWED_SENDERS` checks the
gateway's IP, and `ALLOWED_CLIENTS` checks the browser's IP. On a normal Linux host with bridge
networking, Docker's iptables rules usually keep those IPs, so this works too:

```yaml
    # instead of network_mode: host
    ports:
      - "2055:2055/udp"
      - "5514:5514/udp"
      - "8080:8080/tcp"
```

The internal services then stay on the container's own loopback interface, which is not reachable
from the host. Check with `docker exec unifi-hq lz test` and look at the first real flows. If nothing
arrives although tcpdump on the host sees the packets, the sender IP is being rewritten: switch back to
host networking or clear `ALLOWED_SENDERS`.

Docker Desktop (Windows/macOS) always rewrites source IPs. It's fine for `?demo`, but not for
real UniFi data.

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Container exits right after start, log says *GeoIP … download failed* | no internet / DNS on first start | fix DNS/proxy on the host, then `docker start unifi-hq` |
| *`/data` is not writable* | wrong owner of a bind mount while running with `user:` | `chown -R 568:568 /mnt/…` or drop `user:` and use `PUID`/`PGID` |
| *address already in use* | port 8080/2055/5514 or 127.0.0.1:8090–8092/9428 taken on the host | free it or change `HTTP_PORT`; for the internal ports use bridge networking ([section 11](#11-bridge-networking-instead-of-host-networking)) |
| Dashboard unreachable | client IP not in `ALLOWED_CLIENTS`, or host firewall | add the range (e.g. `private_ranges 100.64.0.0/10` for Tailscale), open TCP 8080 |
| *Live · no data for 2 min* | NetFlow doesn't arrive | collector IP/port in UniFi, `tcpdump -ni any udp port 2055` on the host |
| Flows arrive (tcpdump) but nothing shows | sender not allowed or rewritten | `ALLOWED_SENDERS` must match the source IP from tcpdump; see section 11 |
| Login says *Too many failed attempts* | 5 wrong passwords | wait (max 15 min) or `docker restart unifi-hq` |
| Forgot password | | set a new `AUTH_PASSWORD`, `docker compose up -d` |
| Container is `unhealthy` | an internal service hangs | `docker logs unifi-hq`, then `docker restart unifi-hq` |

Everything else (what UniFi exports, search syntax, dashboard features, security model) is the same
as in the [README](../README.md).
