const fs = require('fs');
const path = require('path');

class FederatedJellyfinManager {
  constructor(options = {}) {
    this.dataDir = options.dataDir || path.join(process.cwd(), 'data');
    this.filePath = path.join(this.dataDir, 'jellyfin-federation.json');
    this.config = {
      enabled: Boolean(options.config?.enabled),
      relayEnabled: options.config?.relayEnabled !== false,
      peers: Array.isArray(options.config?.peers) ? options.config.peers : []
    };
    this.loadFromDisk();
  }

  loadFromDisk() {
    try {
      if (!fs.existsSync(this.filePath)) return;
      const parsed = JSON.parse(fs.readFileSync(this.filePath, 'utf8'));
      if (!parsed || typeof parsed !== 'object') return;
      this.config.enabled = parsed.enabled === true;
      this.config.relayEnabled = parsed.relayEnabled !== false;
      this.config.peers = Array.isArray(parsed.peers) ? parsed.peers : [];
    } catch (_) {
      // Keep in-memory defaults if load fails.
    }
  }

  saveToDisk() {
    fs.mkdirSync(this.dataDir, { recursive: true });
    fs.writeFileSync(this.filePath, JSON.stringify(this.config, null, 2), 'utf8');
  }

  normalizePeer(input = {}) {
    const id = String(input.id || `peer_${Date.now().toString(36)}`);
    const baseUrl = String(input.baseUrl || '').trim().replace(/\/+$/, '');
    const serverName = input.serverName || id;
    const apiKey = input.apiKey || null;
    return { id, serverName, baseUrl, apiKey, enabled: input.enabled !== false };
  }

  listPeers() {
    return this.config.peers.filter((peer) => peer && peer.baseUrl);
  }

  isAllowedRelayTarget(targetUrl) {
    let parsedTarget;
    try {
      parsedTarget = new URL(targetUrl);
    } catch (_) {
      return false;
    }
    const allowedHosts = new Set();
    this.listPeers().forEach((peer) => {
      try {
        const parsed = new URL(peer.baseUrl);
        allowedHosts.add(parsed.host.toLowerCase());
      } catch (_) {
        // Ignore invalid peer entries.
      }
    });
    return allowedHosts.has(parsedTarget.host.toLowerCase());
  }

  async proxyRelayRequest(req, res) {
    if (!this.config.enabled || !this.config.relayEnabled) {
      return res.status(403).json({ error: 'Federated relay is disabled' });
    }
    const upstreamUrl = String(req.query.url || '').trim();
    if (!upstreamUrl) {
      return res.status(400).json({ error: 'Missing relay target url' });
    }
    if (!this.isAllowedRelayTarget(upstreamUrl)) {
      return res.status(403).json({ error: 'Relay target is not in federated peer list' });
    }

    const headers = {};
    if (req.headers.range) headers.Range = req.headers.range;
    if (req.headers['user-agent']) headers['User-Agent'] = req.headers['user-agent'];

    const upstream = await fetch(upstreamUrl, { method: 'GET', headers });
    if (!upstream.ok && upstream.status !== 206) {
      const text = await upstream.text().catch(() => '');
      return res.status(upstream.status).json({ error: text || `Upstream returned ${upstream.status}` });
    }

    const passthroughHeaders = ['content-type', 'content-length', 'accept-ranges', 'content-range', 'cache-control'];
    passthroughHeaders.forEach((header) => {
      const value = upstream.headers.get(header);
      if (value) res.setHeader(header, value);
    });
    res.status(upstream.status);

    if (!upstream.body) {
      res.end();
      return;
    }

    const reader = upstream.body.getReader();
    const pump = async () => {
      const { done, value } = await reader.read();
      if (done) {
        res.end();
        return;
      }
      res.write(Buffer.from(value));
      await pump();
    };

    try {
      await pump();
    } catch (error) {
      if (!res.headersSent) {
        res.status(500).json({ error: error.message });
      } else {
        res.end();
      }
    }
  }

  setupRoutes(app, options = {}) {
    if (!app) return;
    const isAdminRequest = options.isAdminRequest || (() => false);
    const deny = (res) => res.status(403).json({ success: false, error: 'Admin access required' });

    app.get('/api/jellyfin/federation/status', (req, res) => {
      res.json({
        ok: true,
        enabled: this.config.enabled,
        relayEnabled: this.config.relayEnabled,
        peers: this.listPeers().map((peer) => ({
          id: peer.id,
          serverName: peer.serverName,
          baseUrl: peer.baseUrl,
          enabled: peer.enabled !== false
        })),
        message: this.config.enabled
          ? 'Federated Jellyfin is enabled.'
          : 'Federated Jellyfin is disabled.'
      });
    });

    app.get('/api/jellyfin/federation/peers', (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      res.json({ success: true, peers: this.listPeers() });
    });

    app.post('/api/jellyfin/federation/peers', (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      const peer = this.normalizePeer(req.body || {});
      if (!peer.baseUrl) {
        return res.status(400).json({ success: false, error: 'baseUrl is required' });
      }
      this.config.peers = this.listPeers().filter((p) => p.id !== peer.id);
      this.config.peers.push(peer);
      this.config.enabled = true;
      this.saveToDisk();
      res.json({ success: true, peer, enabled: this.config.enabled });
    });

    app.delete('/api/jellyfin/federation/peers/:peerId', (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      const peerId = String(req.params.peerId || '');
      this.config.peers = this.listPeers().filter((p) => p.id !== peerId);
      this.saveToDisk();
      res.json({ success: true, peerId, peers: this.listPeers() });
    });

    app.post('/api/jellyfin/federation/relay/toggle', (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      this.config.enabled = req.body?.enabled !== false;
      this.config.relayEnabled = req.body?.relayEnabled !== false;
      this.saveToDisk();
      res.json({ success: true, enabled: this.config.enabled, relayEnabled: this.config.relayEnabled });
    });

    app.get('/api/jellyfin/relay/proxy', async (req, res) => {
      try {
        await this.proxyRelayRequest(req, res);
      } catch (error) {
        res.status(500).json({ error: error.message });
      }
    });
  }
}

module.exports = FederatedJellyfinManager;
