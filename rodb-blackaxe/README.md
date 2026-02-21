# BlackAxe v1.2.2 — Mining Device Manager for UmbrelOS

Professional web-based management dashboard for Bitcoin solo miners.

---

## Requirements

| Tool | Version | Install |
|------|---------|---------|
| Docker | 20 or higher | https://docs.docker.com/get-docker/ |
| Docker Compose | v2 or higher | Included with Docker Desktop |

---

## Quick Start

```bash
# 1. Open a terminal in this folder
# 2. Build and start the container
docker compose up -d
```

Once running, open your browser and go to:

```
http://127.0.0.1:30211
```

---

## Default Login

| Field | Value |
|-------|-------|
| Username | `blackaxe` |
| Password | `blackaxe` |

> **Important:** Change the default password immediately after your first login via **Settings**.

---

## Docker Commands

| Action | Command |
|--------|---------|
| Start (background) | `docker compose up -d` |
| Start (with logs) | `docker compose up` |
| Stop | `docker compose down` |
| View logs | `docker compose logs -f` |
| Rebuild image | `docker compose up -d --build` |
| Remove everything | `docker compose down -v` |

---

## Configuration

Edit `docker-compose.yml` to change port or environment variables:

```yaml
ports:
  - "30211:30211"   # Change left side to use a different host port
environment:
  - PORT=30211
  - HOST=0.0.0.0
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `30211` | Port inside the container |
| `HOST` | `0.0.0.0` | Binds to all interfaces inside container |

---

## Data Persistence

The SQLite database is stored in a named Docker volume `blackaxe_data`.  
Your data survives container restarts and upgrades.

```bash
# Backup the database
docker cp blackaxe:/app/data/blackaxe.db ./blackaxe_backup.db

# Restore from backup
docker cp ./blackaxe_backup.db blackaxe:/app/data/blackaxe.db
```

---

## Supported Mining Devices

| Device | API Type | Port |
|--------|----------|------|
| Bitaxe (Ultra, Supra, Gamma, Hex) | HTTP REST | 80 |
| NerdQAxe++ | HTTP REST | 80 |
| Avalon Nano (all versions) | CGMiner TCP | 4028 / 4029 |
| Avalon Nano 3S | CGMiner TCP | 4028 / 4029 |
| Avalon Q | CGMiner TCP | 4028 / 4029 |
| AvalonMiner (1246, 1166, 1066, all) | CGMiner TCP | 4028 / 4029 |
| Antminer (S19, S17, all series) | CGMiner TCP | 4028 / 4029 |
| Whatsminer (M30, M20, all models) | CGMiner TCP | 4028 / 4029 |
| Canaan (all devices) | CGMiner TCP | 4028 / 4029 |

> **Network Access:** The Docker container must be on the same network as your miners.  
> If miners are on a different subnet, use `network_mode: host` in `docker-compose.yml`.

---

## Features

- Real-time hashrate, temperature, fan speed, and power monitoring
- Automatic device discovery via network scan
- 24-hour history charts
- Pool audit and verification
- Solo block detection and tracking
- Alert system for offline miners
- Multi-group miner organization
- Dark / light theme

---

## Troubleshooting

**Port already in use:**
```bash
# Edit docker-compose.yml, change the host port:
ports:
  - "30212:30211"
```

**Cannot reach miners from container:**
```yaml
# Add to docker-compose.yml under the service:
network_mode: host
# Then remove the ports section (not needed with host networking)
```

**View container logs:**
```bash
docker compose logs -f blackaxe
```

**Rebuild after code changes:**
```bash
docker compose up -d --build
```

---

*BlackAxe v12.0 — Built for solo Bitcoin miners.*
