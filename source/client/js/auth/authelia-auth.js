(function() {
    class AutheliaAuthBridge {
        constructor() {
            this.user = null;
            this.mastodonOriginal = null;
            this.init();
        }

        async init() {
            await this.refresh();
            this.attachUiHandlers();
            this.syncUi();
            this.attachMastodonCompatibility();
        }

        async refresh() {
            try {
                const response = await fetch('/api/auth/authelia/user', {
                    credentials: 'include'
                });
                if (!response.ok) {
                    this.user = null;
                    return;
                }

                const payload = await response.json();
                if (!payload || !payload.authenticated) {
                    this.user = null;
                    return;
                }

                this.user = this.normalizeUser(payload);
                window.dispatchEvent(new CustomEvent('mastodon-login', { detail: { user: this.user } }));
            } catch (error) {
                console.warn('Authelia session check failed:', error);
                this.user = null;
            }
        }

        normalizeUser(payload) {
            const host = window.location.hostname || 'local';
            const username = payload.user || 'user';
            const displayName = payload.name || username;
            const groups = Array.isArray(payload.groups) ? payload.groups : [];

            return {
                id: username,
                username,
                displayName,
                fullHandle: '@' + username + '@' + host,
                avatar: '',
                avatarStatic: '',
                email: payload.email || '',
                groups,
                isAdmin: !!payload.isAdmin,
                isModerator: groups.includes('moderators') || !!payload.isAdmin,
                authProvider: 'authelia'
            };
        }

        attachUiHandlers() {
            document.getElementById('authelia-login-btn')?.addEventListener('click', async () => {
                const rd = encodeURIComponent(window.location.href);
                window.location.href = '/api/auth/authelia/login?rd=' + rd;
            });

            document.getElementById('authelia-logout-btn')?.addEventListener('click', async () => {
                const rd = encodeURIComponent(window.location.origin + window.location.pathname);
                window.location.href = '/api/auth/authelia/logout?rd=' + rd;
            });
        }

        attachMastodonCompatibility() {
            if (!window.mastodonAuth) {
                window.mastodonAuth = {
                    isAuthenticated: () => !!this.user,
                    getUser: () => this.user,
                    logout: async () => {
                        const rd = encodeURIComponent(window.location.origin + window.location.pathname);
                        window.location.href = '/api/auth/authelia/logout?rd=' + rd;
                    }
                };
                return;
            }

            if (this.mastodonOriginal) {
                return;
            }

            this.mastodonOriginal = window.mastodonAuth;
            const bridge = this;
            window.mastodonAuth = {
                ...this.mastodonOriginal,
                isAuthenticated() {
                    const mastodonLoggedIn = typeof bridge.mastodonOriginal.isAuthenticated === 'function'
                        ? bridge.mastodonOriginal.isAuthenticated()
                        : false;
                    return mastodonLoggedIn || !!bridge.user;
                },
                getUser() {
                    const mastodonLoggedIn = typeof bridge.mastodonOriginal.isAuthenticated === 'function'
                        ? bridge.mastodonOriginal.isAuthenticated()
                        : false;
                    if (mastodonLoggedIn && typeof bridge.mastodonOriginal.getUser === 'function') {
                        return bridge.mastodonOriginal.getUser();
                    }
                    return bridge.user;
                }
            };
        }

        syncUi() {
            const prompt = document.getElementById('authelia-login-prompt');
            const info = document.getElementById('authelia-user-info');
            const name = document.getElementById('authelia-user-name');
            const role = document.getElementById('authelia-user-role');

            if (!prompt && !info) {
                return;
            }

            if (this.user) {
                if (prompt) prompt.style.display = 'none';
                if (info) info.style.display = 'flex';
                if (name) name.textContent = this.user.displayName;
                if (role) role.textContent = this.user.isAdmin ? 'Admin (SSO)' : 'User (SSO)';
                return;
            }

            if (prompt) prompt.style.display = 'block';
            if (info) info.style.display = 'none';
        }
    }

    window.autheliaAuth = new AutheliaAuthBridge();
})();
