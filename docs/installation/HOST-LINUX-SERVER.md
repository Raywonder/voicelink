# Host VoiceLink on Linux (Server Guide)

This guide covers Ubuntu/Debian style installs first, then Docker.

## 1) Install Server (Native)

```bash
git clone https://github.com/Raywonder/voicelink.git voicelink-local
cd voicelink-local
bash installer/install.sh
```

The installer configures server identity, federation mode, and PM2 runtime.

## 2) Start / Restart Server

```bash
cd ~/voicelink
pm2 start server/routes/local-server.js --name voicelink-local-api
pm2 save
pm2 startup
```

## 3) Open Network Access

```bash
sudo ufw allow 3010/tcp
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
```

Use your reverse proxy (nginx/caddy) for TLS.

## 4) Verify API + Rooms

```bash
curl -fsSL http://127.0.0.1:3010/api/info
curl -fsSL http://127.0.0.1:3010/api/rooms
curl -fsSL http://127.0.0.1:3010/api/federation/status
```

## 5) Register as Public Server

```bash
bash scripts/linux/register-public-server.sh \
  --api-base "https://your-domain.example" \
  --title "My VoiceLink Server" \
  --public-url "https://your-domain.example" \
  --announce true
```

Expected behavior in desktop clients:
- Users see only your server title and hosted rooms.
- Users do not need to see your internal host/IP details.

## 6) Docker / Compose Option

```bash
docker compose -f installer/docker-compose.server.yml up -d
```

Then verify:

```bash
docker compose -f installer/docker-compose.server.yml ps
curl -fsSL http://127.0.0.1:3010/api/info
```

## 7) Supported Endpoint Identity

The server can be announced by:
- IP
- Domain
- Web3 domain string (stored as metadata label)

Clients still resolve to standard HTTPS endpoint(s).

## 8) Admin Update Workflow

Server operators can receive/pull updates through:
- git-based update flow
- PM2 restart
- optional control-plane APIs (HubNode/VoiceLink admin endpoints)

After updates:

```bash
pm2 restart voicelink-local-api
pm2 logs voicelink-local-api --lines 100
```
