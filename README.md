# AWG Proxy (Portable Alpine)

Russian version: [README.ru.md](README.ru.md)

Containerized VPN gateway that establishes an AmneziaWG tunnel and provides two modes of operation:

1. **SOCKS5 proxy** — applications connect through a local SOCKS5 port.
2. **Network gateway (router)** — the container acts as a default gateway for other devices on your LAN, routing all their traffic through the VPN tunnel.

Traffic flow (SOCKS5 mode):
- Client -> SOCKS5 proxy (`microsocks`)
- Proxy process -> container network stack
- Container routing policy -> AWG tunnel (`awg-quick` + `amneziawg-go` userspace fallback)

Traffic flow (gateway mode):
- LAN device (default gateway = container IP) -> container network stack
- iptables NAT/MASQUERADE -> AWG tunnel

This project is designed to work on Windows Docker Desktop and Linux.

## What is included

- Base image: Alpine (portable variant)
- AWG userspace backend: `amneziawg-go`
- AWG tooling: `awg`, `awg-quick`
- Proxy: `microsocks`
- Entrypoint orchestration: `entrypoint.sh`

## Requirements

- Docker Engine / Docker Desktop
- Docker Compose v2
- `NET_ADMIN` capability
- `/dev/net/tun` device mapping
- AWG client config mounted to `/config/amnezia.conf`

## Quick start

1. Copy the example compose file and AWG config:

```bash
cp docker-compose.example.yml docker-compose.yml
cp /path/to/your/amnezia.conf amnezia.conf
```

   Edit `docker-compose.yml` if you need to change ports, add macvlan network, etc.

2. Start service:

```powershell
docker compose up --build -d
```

3. Check status:

```powershell
docker compose ps
docker compose logs --tail=120 awg-proxy
```

4. Use SOCKS5 proxy on host:

- Address: `127.0.0.1`
- Port: `1080` (default)

Example:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

## Configuration

Compose publishes a configurable port:

- `PROXY_PORT` (default `1080`)

Supported environment variables:

- `AWG_CONFIG_FILE` (default `/config/amnezia.conf`)
- `WG_QUICK_USERSPACE_IMPLEMENTATION` (default `amneziawg-go`)
- `LOG_LEVEL` (default `info`)
- `PROXY_LISTEN_HOST` (default `0.0.0.0`)
- `PROXY_PORT` (default `1080`)
- `PROXY_USER`, `PROXY_PASSWORD` (optional auth, must be set together)
- `MICROSOCKS_BIND_ADDRESS` (optional)
- `MICROSOCKS_WHITELIST` (optional)
- `MICROSOCKS_AUTH_ONCE` (`0` or `1`)
- `MICROSOCKS_QUIET` (`0` or `1`)
- `MICROSOCKS_OPTS` (extra flags)

DNS behavior:

- `DNS = ...` from AWG config is applied to container resolver.
- Runtime uses two layers for portability:
  - `resolvconf` shim for `awg-quick` DNS hook.
  - Explicit DNS apply step in `entrypoint.sh` after `awg-quick up`.
- On Docker Desktop, AWG startup may take time (endpoint retries are normal), so check resolver state after startup logs finish.

## Notes about AWG config

- File name must end with `.conf`.
- `AllowedIPs` should include default routes if you want all proxy traffic to go through VPN:
  - `0.0.0.0/0`
  - `::/0`
- Empty assignments like `I2 =` are sanitized at runtime by `entrypoint.sh` into a temporary config.

## Using as a VPN gateway (router mode)

The container can serve as a default gateway for devices on your local network, routing all their traffic through the VPN tunnel. This is useful when you want to route traffic from devices that do not support SOCKS5 (smart TVs, consoles, IoT, etc.).

### How it works

At startup `entrypoint.sh` automatically:
- Sets MTU 1400 on `eth0` and `amnezia` interfaces.
- Clamps TCP MSS to 1200 to prevent fragmentation.
- Enables iptables NAT (`MASQUERADE`) on the tunnel interface.

No extra flags needed — these rules are applied on every start.

### Network setup

To make the container reachable as a gateway, use a macvlan network so the container gets its own IP address on your LAN.

An example compose file is provided in `docker-compose.example.yml`:

```yaml
services:
  awg-proxy:
    image: ghcr.io/snarknn/awg-proxy:latest
    container_name: awg-proxy
    cap_add:
      - NET_ADMIN
    sysctls:
      net.ipv4.conf.all.src_valid_mark: "1"
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "127.0.0.1:${PROXY_PORT:-1080}:${PROXY_PORT:-1080}/tcp"
    volumes:
      - ./amnezia.conf:/config/amnezia.conf:ro
    environment:
      WG_QUICK_USERSPACE_IMPLEMENTATION: amneziawg-go
      LOG_LEVEL: info
      PROXY_LISTEN_HOST: 0.0.0.0
      PROXY_PORT: ${PROXY_PORT:-1080}
    restart: unless-stopped
    networks:
      macnet:
        ipv4_address: 192.168.7.2

networks:
  macnet:
    driver: macvlan
    driver_opts:
      parent: ens18        # host interface connected to your LAN
    ipam:
      config:
        - subnet: 192.168.7.0/24
          gateway: 192.168.7.1
```

Adjust `parent`, `subnet`, `gateway`, and `ipv4_address` to match your network.

### Client configuration

On any device you want to route through VPN, set:

- **Default gateway**: the container's macvlan IP (e.g. `192.168.7.2`)
- **DNS server**: the container's macvlan IP or the DNS from your AWG config

After that all traffic from the device will flow through the AWG tunnel.

> **Note:** Gateway mode requires Linux with Docker Engine. macvlan networks are not supported on Docker Desktop (Windows/macOS).

## Platform behavior

- Windows Docker Desktop: expected to use userspace fallback (`amneziawg-go`). SOCKS5 mode only.
- Linux with kernel module installed: `awg-quick` may use kernel path first. Both SOCKS5 and gateway modes are available.

## How to verify the container works

1. Check that the service is running:

```powershell
docker compose ps
```

Expected: service `awg-proxy` is `Up` and the proxy port is published.

2. Check startup logs:

```powershell
docker compose logs --tail=120 awg-proxy
```

Expected: lines about bringing up AWG and starting `microsocks`.

3. Test proxy egress with curl:

```powershell
curl.exe --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

If your proxy port is custom, replace `1080` with `PROXY_PORT` value.

4. Optional tunnel evidence from inside container:

```powershell
docker exec awg-proxy awg show
```

5. Verify DNS from AWG config is active inside container:

```powershell
docker exec awg-proxy cat /etc/resolv.conf
docker exec awg-proxy nslookup google.com
```

Expected: `resolv.conf` contains `nameserver` entries from your AWG config (for example `1.1.1.1`) and `nslookup` reports one of those servers.

If direct and proxied public IP are identical, your host may already use the same upstream route. In this case, rely on `awg show` counters and container logs to confirm traffic through the tunnel.

## Troubleshooting

- `/dev/net/tun is missing`
  - Ensure `devices: - /dev/net/tun:/dev/net/tun` is present in compose.

- `Line unrecognized: I2=`
  - Fixed by runtime sanitization in `entrypoint.sh`. Use the current image.

- `sysctl: permission denied on key net.ipv4.conf.all.src_valid_mark`
  - Expected in some Docker Desktop environments.
  - Current image tolerates this and continues startup.

- Proxy port busy
  - Override host/container port via `PROXY_PORT`.

- Container still shows `nameserver 127.0.0.11`
  - Wait until AWG startup completes (`docker compose logs --tail=120 awg-proxy`).
  - Re-check `docker exec awg-proxy cat /etc/resolv.conf`.
  - If needed, restart and wait longer (AWG may retry endpoint before finishing setup).

## Files

- `Dockerfile` - multi-stage Alpine portable build
- `entrypoint.sh` - AWG startup, NAT/routing setup, and proxy orchestration
- `docker-compose.example.yml` - example compose file (copy to `docker-compose.yml` before use)
- `amnezia.conf.example` - example AWG config

`docker-compose.yml` and `amnezia.conf` are in `.gitignore` — they contain local settings and are not tracked by git.
