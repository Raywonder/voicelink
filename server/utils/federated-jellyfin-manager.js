class FederatedJellyfinManager {
  constructor(options = {}) {
    this.options = options;
  }

  setupRoutes(app) {
    if (!app) return;

    app.get('/api/jellyfin/federation/status', (req, res) => {
      res.json({
        ok: true,
        enabled: false,
        mode: 'standalone',
        message: 'Federated Jellyfin manager is running in compatibility mode.'
      });
    });
  }
}

module.exports = FederatedJellyfinManager;
