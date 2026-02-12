class JellyfinAutoManager {
  constructor(federatedManager = null) {
    this.federatedManager = federatedManager;
    this.started = false;
  }

  startAutoConnect() {
    this.started = true;
  }

  setupRoutes(app) {
    if (!app) return;

    app.get('/api/jellyfin/auto/status', (req, res) => {
      res.json({
        ok: true,
        started: this.started,
        message: 'Jellyfin auto-manager is running in compatibility mode.'
      });
    });
  }
}

module.exports = JellyfinAutoManager;
