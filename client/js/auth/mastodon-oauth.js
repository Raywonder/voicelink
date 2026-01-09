/**
 * VoiceLink Mastodon OAuth Manager
 * Handles authentication with any Mastodon-compatible instance
 */

class MastodonOAuthManager {
    constructor() {
        this.currentUser = null;
        this.accessToken = null;
        this.instanceUrl = null;
        this.clientId = null;
        this.clientSecret = null;

        // Suggested instances
        this.suggestedInstances = [
            { url: 'https://md.tappedin.fm', name: 'TappedIn' },
            { url: 'https://mastodon.devinecreations.net', name: 'DevineCreations' }
        ];

        // OAuth scopes needed
        this.scopes = 'read:accounts read:statuses';

        // Determine the correct redirect URI for current environment
        const pageHost = window.location.hostname || 'localhost';
        const pageProtocol = window.location.protocol;
        const isProduction = pageHost.includes('voicelink.devinecreations.net') ||
                            pageHost.includes('voicelink.tappedin.fm');
        this.productionRedirectUri = isProduction
            ? `${pageProtocol}//${pageHost}/oauth/callback`
            : null;

        // Load saved session
        this.loadSession();

        console.log('Mastodon OAuth Manager initialized', {
            isProduction,
            redirectUri: this.productionRedirectUri
        });
    }

    /**
     * Load saved session from localStorage
     */
    loadSession() {
        try {
            const saved = localStorage.getItem('voicelink_mastodon_session');
            if (saved) {
                const session = JSON.parse(saved);
                this.accessToken = session.accessToken;
                this.instanceUrl = session.instanceUrl;
                this.currentUser = session.user;
                this.clientId = session.clientId;
                this.clientSecret = session.clientSecret;

                // Verify token is still valid
                this.verifyToken();
            }
        } catch (err) {
            console.error('Failed to load Mastodon session:', err);
        }
    }

    /**
     * Save session to localStorage
     */
    saveSession() {
        try {
            const session = {
                accessToken: this.accessToken,
                instanceUrl: this.instanceUrl,
                user: this.currentUser,
                clientId: this.clientId,
                clientSecret: this.clientSecret
            };
            localStorage.setItem('voicelink_mastodon_session', JSON.stringify(session));
        } catch (err) {
            console.error('Failed to save Mastodon session:', err);
        }
    }

    /**
     * Clear session
     */
    clearSession() {
        this.accessToken = null;
        this.instanceUrl = null;
        this.currentUser = null;
        this.clientId = null;
        this.clientSecret = null;
        localStorage.removeItem('voicelink_mastodon_session');
    }

    /**
     * Get the redirect URI for OAuth
     */
    getRedirectUri() {
        const isElectron = typeof process !== 'undefined' && process.versions?.electron;
        if (isElectron) {
            return 'urn:ietf:wg:oauth:2.0:oob';  // Out-of-band for Electron
        }
        // Use production redirect URI if available, otherwise use current origin
        return this.productionRedirectUri || `${window.location.origin}/oauth/callback`;
    }

    /**
     * Register VoiceLink as an OAuth app on the instance
     */
    async registerApp(instanceUrl) {
        // Normalize instance URL
        instanceUrl = instanceUrl.replace(/\/$/, '');
        if (!instanceUrl.startsWith('http')) {
            instanceUrl = 'https://' + instanceUrl;
        }

        const redirectUri = this.getRedirectUri();
        console.log('OAuth registerApp:', { instanceUrl, redirectUri });

        // Check if we already have credentials for this instance + redirect combo
        const storageKey = `voicelink_mastodon_apps_${redirectUri.replace(/[^a-z0-9]/gi, '_')}`;
        const savedApps = JSON.parse(localStorage.getItem(storageKey) || '{}');
        if (savedApps[instanceUrl]) {
            this.clientId = savedApps[instanceUrl].clientId;
            this.clientSecret = savedApps[instanceUrl].clientSecret;
            this.instanceUrl = instanceUrl;
            console.log('Using saved OAuth app credentials');
            return { clientId: this.clientId, clientSecret: this.clientSecret };
        }

        try {
            console.log('Registering new OAuth app on', instanceUrl);
            const response = await fetch(`${instanceUrl}/api/v1/apps`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    client_name: 'VoiceLink',
                    redirect_uris: redirectUri,
                    scopes: this.scopes,
                    website: 'https://voicelink.devinecreations.net'
                })
            });

            if (!response.ok) {
                const errorText = await response.text();
                console.error('OAuth app registration failed:', response.status, errorText);
                throw new Error(`Failed to register app: ${response.status} - ${errorText}`);
            }

            const app = await response.json();
            console.log('OAuth app registered successfully:', app.client_id);

            // Save app credentials
            savedApps[instanceUrl] = {
                clientId: app.client_id,
                clientSecret: app.client_secret
            };
            localStorage.setItem(storageKey, JSON.stringify(savedApps));

            this.clientId = app.client_id;
            this.clientSecret = app.client_secret;
            this.instanceUrl = instanceUrl;

            return { clientId: app.client_id, clientSecret: app.client_secret };
        } catch (err) {
            console.error('Failed to register OAuth app:', err);
            throw new Error(`Could not connect to ${instanceUrl}. Please check the instance URL and try again.`);
        }
    }

    /**
     * Start OAuth flow - returns authorization URL
     */
    async startAuth(instanceUrl) {
        await this.registerApp(instanceUrl);

        const redirectUri = this.getRedirectUri();
        console.log('Starting OAuth flow:', { instanceUrl: this.instanceUrl, redirectUri });

        // Generate state for CSRF protection
        const state = this.generateState();
        sessionStorage.setItem('voicelink_oauth_state', state);
        sessionStorage.setItem('voicelink_oauth_instance', this.instanceUrl);
        // Also store in localStorage as backup (sessionStorage can be lost on redirect)
        localStorage.setItem('voicelink_oauth_state_backup', state);
        localStorage.setItem('voicelink_oauth_instance_backup', this.instanceUrl);

        const authUrl = `${this.instanceUrl}/oauth/authorize?` + new URLSearchParams({
            client_id: this.clientId,
            redirect_uri: redirectUri,
            response_type: 'code',
            scope: this.scopes,
            state: state
        });

        return authUrl;
    }

    /**
     * Handle OAuth callback with authorization code
     */
    async handleCallback(code, state) {
        console.log('Handling OAuth callback:', { code: code?.substring(0, 10) + '...', state });

        // Try sessionStorage first, fall back to localStorage backup
        let savedState = sessionStorage.getItem('voicelink_oauth_state');
        let savedInstance = sessionStorage.getItem('voicelink_oauth_instance');

        // If sessionStorage is empty, try localStorage backup
        if (!savedState) {
            savedState = localStorage.getItem('voicelink_oauth_state_backup');
            savedInstance = localStorage.getItem('voicelink_oauth_instance_backup');
            console.log('Using localStorage backup for OAuth state');
        }

        console.log('Saved OAuth state:', { savedState, savedInstance, providedState: state });

        // Only verify state if we have a provided state (some flows may not include it)
        if (state && savedState && state !== savedState) {
            throw new Error('Invalid OAuth state - possible CSRF attack');
        }

        if (savedInstance) {
            this.instanceUrl = savedInstance;
        }

        if (!this.instanceUrl) {
            throw new Error('No instance URL found. Please try logging in again.');
        }

        const redirectUri = this.getRedirectUri();

        // Load app credentials if needed
        if (!this.clientId || !this.clientSecret) {
            const storageKey = `voicelink_mastodon_apps_${redirectUri.replace(/[^a-z0-9]/gi, '_')}`;
            const savedApps = JSON.parse(localStorage.getItem(storageKey) || '{}');
            if (savedApps[this.instanceUrl]) {
                this.clientId = savedApps[this.instanceUrl].clientId;
                this.clientSecret = savedApps[this.instanceUrl].clientSecret;
                console.log('Loaded app credentials from storage');
            }
        }

        if (!this.clientId || !this.clientSecret) {
            throw new Error('OAuth app credentials not found. Please try logging in again.');
        }

        console.log('Exchanging code for token:', { instanceUrl: this.instanceUrl, redirectUri });

        // Exchange code for token
        const response = await fetch(`${this.instanceUrl}/oauth/token`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                client_id: this.clientId,
                client_secret: this.clientSecret,
                redirect_uri: redirectUri,
                grant_type: 'authorization_code',
                code: code,
                scope: this.scopes
            })
        });

        if (!response.ok) {
            const error = await response.text();
            throw new Error(`Token exchange failed: ${error}`);
        }

        const token = await response.json();
        this.accessToken = token.access_token;

        // Get user info
        await this.fetchUserInfo();

        // Save session
        this.saveSession();

        // Clean up
        sessionStorage.removeItem('voicelink_oauth_state');
        sessionStorage.removeItem('voicelink_oauth_instance');

        // Dispatch login event
        window.dispatchEvent(new CustomEvent('mastodon-login', {
            detail: { user: this.currentUser }
        }));

        return this.currentUser;
    }

    /**
     * Handle manual code entry (for Electron OOB flow)
     */
    async handleManualCode(code) {
        return this.handleCallback(code, null);
    }

    /**
     * Fetch current user info from Mastodon
     */
    async fetchUserInfo() {
        if (!this.accessToken || !this.instanceUrl) {
            throw new Error('Not authenticated');
        }

        const response = await fetch(`${this.instanceUrl}/api/v1/accounts/verify_credentials`, {
            headers: {
                'Authorization': `Bearer ${this.accessToken}`
            }
        });

        if (!response.ok) {
            if (response.status === 401) {
                this.clearSession();
                throw new Error('Token expired or invalid');
            }
            throw new Error(`Failed to fetch user info: ${response.status}`);
        }

        const user = await response.json();

        // Parse user data
        this.currentUser = {
            id: user.id,
            username: user.username,
            displayName: user.display_name || user.username,
            avatar: user.avatar,
            avatarStatic: user.avatar_static,
            instance: new URL(this.instanceUrl).hostname,
            fullHandle: `@${user.username}@${new URL(this.instanceUrl).hostname}`,
            url: user.url,
            isAdmin: this.checkAdminRole(user),
            isModerator: this.checkModeratorRole(user),
            createdAt: user.created_at,
            note: user.note,
            followersCount: user.followers_count,
            followingCount: user.following_count
        };

        return this.currentUser;
    }

    /**
     * Check if user has admin role
     */
    checkAdminRole(user) {
        // Check various ways Mastodon indicates admin status
        if (user.role) {
            // Mastodon 4.0+ uses role object
            if (typeof user.role === 'object') {
                return user.role.name === 'Admin' ||
                       user.role.name === 'Owner' ||
                       (user.role.permissions && user.role.permissions > 0);
            }
            // Older versions use string
            return user.role === 'admin' || user.role === 'owner';
        }

        // Check is_admin field (older Mastodon)
        if (user.is_admin === true) return true;

        // Check pleroma/akkoma admin field
        if (user.pleroma?.is_admin === true) return true;

        return false;
    }

    /**
     * Check if user has moderator role
     */
    checkModeratorRole(user) {
        if (user.role) {
            if (typeof user.role === 'object') {
                return user.role.name === 'Moderator';
            }
            return user.role === 'moderator';
        }

        if (user.is_moderator === true) return true;
        if (user.pleroma?.is_moderator === true) return true;

        return false;
    }

    /**
     * Verify current token is still valid
     */
    async verifyToken() {
        if (!this.accessToken || !this.instanceUrl) return false;

        try {
            await this.fetchUserInfo();

            // Dispatch login event
            window.dispatchEvent(new CustomEvent('mastodon-login', {
                detail: { user: this.currentUser }
            }));

            return true;
        } catch (err) {
            console.error('Token verification failed:', err);
            this.clearSession();
            return false;
        }
    }

    /**
     * Logout
     */
    async logout() {
        // Revoke token if possible
        if (this.accessToken && this.instanceUrl && this.clientId && this.clientSecret) {
            try {
                await fetch(`${this.instanceUrl}/oauth/revoke`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        client_id: this.clientId,
                        client_secret: this.clientSecret,
                        token: this.accessToken
                    })
                });
            } catch (err) {
                console.error('Failed to revoke token:', err);
            }
        }

        const user = this.currentUser;
        this.clearSession();

        // Dispatch logout event
        window.dispatchEvent(new CustomEvent('mastodon-logout', {
            detail: { user }
        }));
    }

    /**
     * Generate random state for CSRF protection
     */
    generateState() {
        const array = new Uint8Array(32);
        crypto.getRandomValues(array);
        return Array.from(array, byte => byte.toString(16).padStart(2, '0')).join('');
    }

    /**
     * Check if user is authenticated
     */
    isAuthenticated() {
        return !!this.accessToken && !!this.currentUser;
    }

    /**
     * Check if current user is admin
     */
    isAdmin() {
        return this.currentUser?.isAdmin === true;
    }

    /**
     * Check if current user is moderator
     */
    isModerator() {
        return this.currentUser?.isModerator === true || this.isAdmin();
    }

    /**
     * Get current user
     */
    getUser() {
        return this.currentUser;
    }

    /**
     * Get suggested instances
     */
    getSuggestedInstances() {
        return this.suggestedInstances;
    }
}

// Create global instance
window.mastodonAuth = new MastodonOAuthManager();
