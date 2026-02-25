class JellyfinPluginManager {
  constructor(options = {}) {
    this.getConnection = options.getConnection || (() => null);
    this.logger = options.logger || console;
    this.defaultPluginNames = [
      'Playback Reporting',
      'Intro Skipper',
      'Reports',
      'TMDb Box Sets',
      'Merge Versions',
      'AudioDB'
    ];
  }

  getResolvedConnection(overrides = {}) {
    const base = this.getConnection() || {};
    return {
      serverUrl: String(overrides.serverUrl || base.serverUrl || '').replace(/\/+$/, ''),
      apiKey: overrides.apiKey || base.apiKey || null
    };
  }

  async jellyfinRequest(connection, endpoint, options = {}) {
    const url = `${connection.serverUrl}${endpoint}`;
    const headers = {
      'Content-Type': 'application/json',
      'X-Emby-Token': connection.apiKey,
      ...(options.headers || {})
    };
    const response = await fetch(url, { ...options, headers });
    if (!response.ok) {
      const body = await response.text().catch(() => '');
      throw new Error(`Jellyfin ${response.status} ${response.statusText}: ${body}`.slice(0, 400));
    }
    if (response.status === 204) return null;
    const contentType = response.headers.get('content-type') || '';
    if (contentType.includes('application/json')) return response.json();
    return response.text();
  }

  async listInstalled(connection) {
    const result = await this.jellyfinRequest(connection, '/Plugins');
    return Array.isArray(result) ? result : [];
  }

  async listCatalog(connection) {
    const result = await this.jellyfinRequest(connection, '/Packages?PackageType=UserInstalled&EnableIncompatible=false');
    if (Array.isArray(result)) return result;
    if (result?.Items && Array.isArray(result.Items)) return result.Items;
    return [];
  }

  async installCatalogItem(connection, catalogItem) {
    const name = catalogItem.Name || catalogItem.name;
    const guid = catalogItem.Guid || catalogItem.guid;
    const version = catalogItem.Version || catalogItem.version;
    if (!name || !guid || !version) {
      throw new Error(`Catalog item missing install metadata: ${JSON.stringify({ name, guid, version })}`);
    }
    const endpoint = `/Packages/Installed/${encodeURIComponent(name)}?AssemblyGuid=${encodeURIComponent(guid)}&version=${encodeURIComponent(version)}`;
    await this.jellyfinRequest(connection, endpoint, { method: 'POST' });
    return { name, guid, version };
  }

  async installPlugins(options = {}) {
    const connection = this.getResolvedConnection(options);
    if (!connection.serverUrl || !connection.apiKey) {
      throw new Error('Jellyfin connection is not configured (serverUrl/apiKey)');
    }

    const mode = options.mode || 'voicelink';
    const installed = await this.listInstalled(connection);
    const installedNames = new Set(installed.map((p) => String(p.Name || p.name || '').toLowerCase()));
    const catalog = await this.listCatalog(connection);

    let desiredNames;
    if (mode === 'all') {
      desiredNames = catalog.map((p) => p.Name || p.name).filter(Boolean);
    } else if (Array.isArray(options.pluginNames) && options.pluginNames.length) {
      desiredNames = options.pluginNames;
    } else {
      desiredNames = this.defaultPluginNames;
    }

    const catalogByLowerName = new Map(
      catalog
        .filter((p) => p && (p.Name || p.name))
        .map((p) => [String(p.Name || p.name).toLowerCase(), p])
    );

    const toInstall = [];
    const missingFromCatalog = [];
    desiredNames.forEach((name) => {
      const key = String(name).toLowerCase();
      if (installedNames.has(key)) return;
      const item = catalogByLowerName.get(key);
      if (!item) {
        missingFromCatalog.push(name);
        return;
      }
      toInstall.push(item);
    });

    const installedNow = [];
    const failed = [];
    for (const item of toInstall) {
      try {
        const installedItem = await this.installCatalogItem(connection, item);
        installedNow.push(installedItem);
      } catch (error) {
        failed.push({ name: item.Name || item.name, error: error.message });
      }
    }

    return {
      mode,
      serverUrl: connection.serverUrl,
      requestedCount: desiredNames.length,
      alreadyInstalledCount: desiredNames.length - toInstall.length - missingFromCatalog.length,
      installedCount: installedNow.length,
      failedCount: failed.length,
      missingFromCatalog,
      installed: installedNow,
      failed
    };
  }

  setupRoutes(app, options = {}) {
    if (!app) return;
    const isAdminRequest = options.isAdminRequest || (() => false);
    const deny = (res) => res.status(403).json({ success: false, error: 'Admin access required' });

    app.get('/api/jellyfin/plugins/status', async (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      try {
        const connection = this.getResolvedConnection(req.query || {});
        if (!connection.serverUrl || !connection.apiKey) {
          return res.json({ success: true, connected: false, installed: [], catalogCount: 0 });
        }
        const [installed, catalog] = await Promise.all([
          this.listInstalled(connection),
          this.listCatalog(connection)
        ]);
        res.json({
          success: true,
          connected: true,
          serverUrl: connection.serverUrl,
          installed,
          catalogCount: catalog.length
        });
      } catch (error) {
        res.status(500).json({ success: false, error: error.message });
      }
    });

    app.post('/api/jellyfin/plugins/install', async (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      try {
        const result = await this.installPlugins(req.body || {});
        res.json({ success: true, ...result });
      } catch (error) {
        this.logger.error('[JellyfinPlugins] Install error:', error.message);
        res.status(500).json({ success: false, error: error.message });
      }
    });

    app.post('/api/jellyfin/plugins/install-all', async (req, res) => {
      if (!isAdminRequest(req)) return deny(res);
      try {
        const result = await this.installPlugins({ ...(req.body || {}), mode: 'all' });
        res.json({ success: true, ...result });
      } catch (error) {
        this.logger.error('[JellyfinPlugins] Install-all error:', error.message);
        res.status(500).json({ success: false, error: error.message });
      }
    });
  }
}

module.exports = JellyfinPluginManager;
