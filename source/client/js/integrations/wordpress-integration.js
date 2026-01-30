/**
 * WordPress Integration Manager
 * Handles user role import and synchronization with WordPress sites
 */

class WordPressIntegration {
    constructor(featurePermissionsManager) {
        this.permissionsManager = featurePermissionsManager;
        this.wpConnections = new Map(); // siteId -> connection info
        this.roleMappings = new Map(); // wpRole -> voiceLinkPermissions
        this.userSyncSettings = this.getDefaultSyncSettings();

        this.setupDefaultRoleMappings();
        this.loadStoredConnections();
    }

    getDefaultSyncSettings() {
        return {
            autoSync: false,
            syncInterval: 3600000, // 1 hour
            syncOnLogin: true,
            createMissingUsers: true,
            updateExistingUsers: true,
            respectWordPressCapabilities: true,
            fallbackRole: 'subscriber',
            enableWebhooks: false,
            logSyncActivity: true
        };
    }

    setupDefaultRoleMappings() {
        // Default WordPress to VoiceLink role mappings
        this.roleMappings.set('administrator', {
            description: 'WordPress Administrator',
            voiceLinkPermissions: {
                // Full admin access
                audio: { spatialAudio: true, multiChannel: true, audioEffects: true, noiseSuppression: true },
                streaming: { liveStreaming: true, rtmpStreaming: true, multiPlatformStreaming: true },
                recording: { localRecording: true, cloudRecording: true, autoRecording: true },
                vst: { vstPlugins: true, vstStreaming: true, customVSTs: true },
                channels: { createChannels: true, deleteChannels: true, manageChannels: true },
                users: { manageGroups: true, banUsers: true, kickUsers: true, moderatorTools: true },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true, fileUpload: true,
                    useVST: true, streaming: true, recording: true,
                    moderateChannel: true, kickUsers: true, muteUsers: true, managePermissions: true
                }
            }
        });

        this.roleMappings.set('editor', {
            description: 'WordPress Editor',
            voiceLinkPermissions: {
                audio: { spatialAudio: true, multiChannel: true, audioEffects: true },
                streaming: { liveStreaming: true, rtmpStreaming: true },
                recording: { localRecording: true, cloudRecording: false },
                vst: { vstPlugins: true, vstStreaming: true },
                channels: { createChannels: true, manageChannels: true },
                users: { moderatorTools: true },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true, fileUpload: true,
                    useVST: true, streaming: true, recording: true,
                    moderateChannel: true, kickUsers: true, muteUsers: true
                }
            }
        });

        this.roleMappings.set('author', {
            description: 'WordPress Author',
            voiceLinkPermissions: {
                audio: { spatialAudio: true, multiChannel: false, audioEffects: true },
                streaming: { liveStreaming: true, rtmpStreaming: false },
                recording: { localRecording: true, cloudRecording: false },
                vst: { vstPlugins: true, vstStreaming: false },
                channels: { createChannels: false, manageChannels: false },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true, fileUpload: true,
                    useVST: true, streaming: true, recording: true
                }
            }
        });

        this.roleMappings.set('contributor', {
            description: 'WordPress Contributor',
            voiceLinkPermissions: {
                audio: { spatialAudio: true, multiChannel: false },
                streaming: { liveStreaming: false },
                recording: { localRecording: false },
                vst: { vstPlugins: false },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true, fileUpload: false
                }
            }
        });

        this.roleMappings.set('subscriber', {
            description: 'WordPress Subscriber',
            voiceLinkPermissions: {
                audio: { spatialAudio: true },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true
                }
            }
        });

        // Custom WordPress roles (common plugins)
        this.roleMappings.set('shop_manager', {
            description: 'WooCommerce Shop Manager',
            voiceLinkPermissions: {
                audio: { spatialAudio: true, multiChannel: true },
                streaming: { liveStreaming: true },
                recording: { localRecording: true },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true, fileUpload: true,
                    moderateChannel: true
                }
            }
        });

        this.roleMappings.set('customer', {
            description: 'WooCommerce Customer',
            voiceLinkPermissions: {
                audio: { spatialAudio: true },
                userChannelPermissions: {
                    speak: true, listen: true, textChat: true
                }
            }
        });
    }

    async connectToWordPress(siteConfig) {
        const { siteUrl, username, password, appPassword, useAppPassword = true } = siteConfig;

        try {
            // Validate WordPress site
            const validationResult = await this.validateWordPressSite(siteUrl);
            if (!validationResult.valid) {
                throw new Error(`Invalid WordPress site: ${validationResult.error}`);
            }

            // Test authentication
            const authResult = await this.testWordPressAuth(siteUrl, username, password, useAppPassword);
            if (!authResult.success) {
                throw new Error(`Authentication failed: ${authResult.error}`);
            }

            // Store connection
            const connectionId = this.generateConnectionId(siteUrl);
            const connection = {
                id: connectionId,
                siteUrl,
                username,
                password: useAppPassword ? password : null, // Only store app passwords
                appPassword: useAppPassword ? password : null,
                useAppPassword,
                connected: true,
                lastSync: null,
                userCount: 0,
                availableRoles: [],
                capabilities: authResult.capabilities
            };

            this.wpConnections.set(connectionId, connection);
            this.saveConnections();

            // Fetch initial data
            await this.fetchWordPressData(connectionId);

            return { success: true, connectionId, connection };

        } catch (error) {
            console.error('WordPress connection failed:', error);
            return { success: false, error: error.message };
        }
    }

    async validateWordPressSite(siteUrl) {
        try {
            // Check if site is WordPress
            const restUrl = `${siteUrl.replace(/\/$/, '')}/wp-json/wp/v2/`;
            const response = await fetch(restUrl, { method: 'HEAD' });

            return {
                valid: response.ok,
                version: response.headers.get('X-WP-Version'),
                error: response.ok ? null : 'Not a valid WordPress site or REST API disabled'
            };
        } catch (error) {
            return { valid: false, error: error.message };
        }
    }

    async testWordPressAuth(siteUrl, username, password, useAppPassword) {
        try {
            const baseUrl = siteUrl.replace(/\/$/, '');
            const authHeader = 'Basic ' + btoa(`${username}:${password}`);

            // Test with current user endpoint
            const response = await fetch(`${baseUrl}/wp-json/wp/v2/users/me`, {
                headers: {
                    'Authorization': authHeader,
                    'Content-Type': 'application/json'
                }
            });

            if (response.ok) {
                const userData = await response.json();
                return {
                    success: true,
                    user: userData,
                    capabilities: userData.capabilities || []
                };
            } else {
                return {
                    success: false,
                    error: `Authentication failed: ${response.statusText}`
                };
            }
        } catch (error) {
            return { success: false, error: error.message };
        }
    }

    async fetchWordPressUsers(connectionId, page = 1, perPage = 100) {
        const connection = this.wpConnections.get(connectionId);
        if (!connection) throw new Error('Connection not found');

        const authHeader = 'Basic ' + btoa(`${connection.username}:${connection.appPassword}`);
        const baseUrl = connection.siteUrl.replace(/\/$/, '');

        try {
            const response = await fetch(`${baseUrl}/wp-json/wp/v2/users?page=${page}&per_page=${perPage}`, {
                headers: {
                    'Authorization': authHeader,
                    'Content-Type': 'application/json'
                }
            });

            if (!response.ok) {
                throw new Error(`Failed to fetch users: ${response.statusText}`);
            }

            const users = await response.json();
            const totalPages = parseInt(response.headers.get('X-WP-TotalPages')) || 1;

            return {
                users: users.map(user => this.parseWordPressUser(user)),
                totalPages,
                hasMore: page < totalPages
            };
        } catch (error) {
            console.error('Error fetching WordPress users:', error);
            throw error;
        }
    }

    parseWordPressUser(wpUser) {
        return {
            id: wpUser.id,
            username: wpUser.slug,
            displayName: wpUser.name,
            email: wpUser.email,
            roles: wpUser.roles || [],
            capabilities: wpUser.capabilities || {},
            registeredDate: wpUser.registered_date,
            avatarUrl: wpUser.avatar_urls ? wpUser.avatar_urls['96'] : null,
            profileUrl: wpUser.link,
            lastLogin: wpUser.meta ? wpUser.meta.last_login : null,
            isActive: true
        };
    }

    async syncWordPressUsers(connectionId, options = {}) {
        const connection = this.wpConnections.get(connectionId);
        if (!connection) throw new Error('Connection not found');

        const syncLog = {
            startTime: Date.now(),
            connectionId,
            usersProcessed: 0,
            usersCreated: 0,
            usersUpdated: 0,
            errors: []
        };

        try {
            let page = 1;
            let hasMore = true;
            const processedUsers = new Set();

            while (hasMore) {
                const result = await this.fetchWordPressUsers(connectionId, page);

                for (const wpUser of result.users) {
                    try {
                        await this.syncWordPressUser(wpUser, connectionId);
                        processedUsers.add(wpUser.id);
                        syncLog.usersProcessed++;

                        // Check if user was created or updated
                        const existingUser = this.permissionsManager.userPermissions.has(`wp_${wpUser.id}`);
                        if (existingUser) {
                            syncLog.usersUpdated++;
                        } else {
                            syncLog.usersCreated++;
                        }
                    } catch (error) {
                        syncLog.errors.push({
                            userId: wpUser.id,
                            username: wpUser.username,
                            error: error.message
                        });
                    }
                }

                hasMore = result.hasMore;
                page++;
            }

            // Update connection stats
            connection.lastSync = Date.now();
            connection.userCount = processedUsers.size;
            this.saveConnections();

            syncLog.endTime = Date.now();
            syncLog.duration = syncLog.endTime - syncLog.startTime;

            this.logSyncActivity(syncLog);

            return syncLog;

        } catch (error) {
            syncLog.errors.push({ general: error.message });
            syncLog.endTime = Date.now();
            return syncLog;
        }
    }

    async syncWordPressUser(wpUser, connectionId) {
        const userId = `wp_${wpUser.id}`;

        // Determine user's highest role
        const primaryRole = this.getPrimaryWordPressRole(wpUser.roles);
        const roleMapping = this.roleMappings.get(primaryRole);

        if (!roleMapping) {
            console.warn(`No role mapping found for WordPress role: ${primaryRole}`);
            return;
        }

        // Apply role permissions
        const permissions = JSON.parse(JSON.stringify(roleMapping.voiceLinkPermissions));

        // Store user metadata
        const userMetadata = {
            source: 'wordpress',
            connectionId,
            wpUserId: wpUser.id,
            wpUsername: wpUser.username,
            wpRoles: wpUser.roles,
            wpCapabilities: wpUser.capabilities,
            displayName: wpUser.displayName,
            email: wpUser.email,
            avatarUrl: wpUser.avatarUrl,
            lastSynced: Date.now()
        };

        // Set permissions in the permission manager
        Object.entries(permissions).forEach(([category, categoryPerms]) => {
            if (typeof categoryPerms === 'object') {
                Object.entries(categoryPerms).forEach(([feature, enabled]) => {
                    this.permissionsManager.setUserPermission(userId, `${category}.${feature}`, enabled);
                });
            }
        });

        // Store user metadata separately
        const existingUserData = this.permissionsManager.userPermissions.get(userId) || {};
        existingUserData.metadata = userMetadata;
        this.permissionsManager.userPermissions.set(userId, existingUserData);

        // Add user to appropriate groups based on WordPress role
        await this.assignUserToWordPressGroups(userId, wpUser.roles);
    }

    getPrimaryWordPressRole(roles) {
        // WordPress role hierarchy (highest to lowest)
        const roleHierarchy = ['administrator', 'editor', 'author', 'contributor', 'subscriber'];

        for (const role of roleHierarchy) {
            if (roles.includes(role)) {
                return role;
            }
        }

        // Check for custom roles
        if (roles.length > 0) {
            return roles[0];
        }

        return this.userSyncSettings.fallbackRole;
    }

    async assignUserToWordPressGroups(userId, wpRoles) {
        for (const role of wpRoles) {
            const groupId = `wp_role_${role}`;

            // Create group if it doesn't exist
            if (!this.permissionsManager.userGroupPermissions.has(groupId)) {
                const roleMapping = this.roleMappings.get(role);
                if (roleMapping) {
                    this.permissionsManager.createUserGroup(
                        groupId,
                        `WordPress ${role.charAt(0).toUpperCase() + role.slice(1)}`,
                        roleMapping.voiceLinkPermissions.userChannelPermissions || {}
                    );
                }
            }

            // Add user to group
            this.permissionsManager.addUserToGroup(userId, groupId);
        }
    }

    // Role mapping management
    setRoleMapping(wpRole, voiceLinkPermissions, description = '') {
        this.roleMappings.set(wpRole, {
            description,
            voiceLinkPermissions
        });
        this.saveRoleMappings();
    }

    getRoleMapping(wpRole) {
        return this.roleMappings.get(wpRole);
    }

    getAllRoleMappings() {
        return Object.fromEntries(this.roleMappings);
    }

    // Webhook handling for real-time sync
    setupWordPressWebhooks(connectionId) {
        const connection = this.wpConnections.get(connectionId);
        if (!connection || !this.userSyncSettings.enableWebhooks) return;

        // This would typically register webhook endpoints with WordPress
        // For now, we'll set up a polling mechanism
        this.setupUserSyncPolling(connectionId);
    }

    setupUserSyncPolling(connectionId) {
        if (this.userSyncSettings.autoSync && this.userSyncSettings.syncInterval > 0) {
            const intervalId = setInterval(async () => {
                try {
                    await this.syncWordPressUsers(connectionId);
                } catch (error) {
                    console.error('Auto-sync failed:', error);
                }
            }, this.userSyncSettings.syncInterval);

            // Store interval ID for cleanup
            const connection = this.wpConnections.get(connectionId);
            if (connection) {
                connection.syncIntervalId = intervalId;
            }
        }
    }

    // Utility methods
    generateConnectionId(siteUrl) {
        return btoa(siteUrl).replace(/[^a-zA-Z0-9]/g, '').substring(0, 16);
    }

    loadStoredConnections() {
        try {
            const stored = localStorage.getItem('voicelink-wordpress-connections');
            if (stored) {
                const data = JSON.parse(stored);
                Object.entries(data.connections || {}).forEach(([id, conn]) => {
                    this.wpConnections.set(id, conn);
                });

                if (data.roleMappings) {
                    Object.entries(data.roleMappings).forEach(([role, mapping]) => {
                        this.roleMappings.set(role, mapping);
                    });
                }

                if (data.syncSettings) {
                    this.userSyncSettings = { ...this.userSyncSettings, ...data.syncSettings };
                }
            }
        } catch (error) {
            console.error('Error loading WordPress connections:', error);
        }
    }

    saveConnections() {
        try {
            const data = {
                connections: Object.fromEntries(this.wpConnections),
                roleMappings: Object.fromEntries(this.roleMappings),
                syncSettings: this.userSyncSettings
            };
            localStorage.setItem('voicelink-wordpress-connections', JSON.stringify(data));
        } catch (error) {
            console.error('Error saving WordPress connections:', error);
        }
    }

    saveRoleMappings() {
        this.saveConnections();
    }

    logSyncActivity(syncLog) {
        if (this.userSyncSettings.logSyncActivity) {
            console.log('WordPress sync completed:', syncLog);

            // Store sync history
            const syncHistory = JSON.parse(localStorage.getItem('voicelink-wp-sync-history') || '[]');
            syncHistory.push(syncLog);

            // Keep only last 50 sync logs
            if (syncHistory.length > 50) {
                syncHistory.splice(0, syncHistory.length - 50);
            }

            localStorage.setItem('voicelink-wp-sync-history', JSON.stringify(syncHistory));
        }
    }

    getSyncHistory() {
        return JSON.parse(localStorage.getItem('voicelink-wp-sync-history') || '[]');
    }

    // Disconnect and cleanup
    disconnectWordPress(connectionId) {
        const connection = this.wpConnections.get(connectionId);
        if (connection && connection.syncIntervalId) {
            clearInterval(connection.syncIntervalId);
        }

        this.wpConnections.delete(connectionId);
        this.saveConnections();
    }

    // Export/Import functionality
    exportRoleMappings() {
        return {
            mappings: Object.fromEntries(this.roleMappings),
            exportDate: new Date().toISOString(),
            version: '1.0'
        };
    }

    importRoleMappings(mappingData) {
        if (mappingData.mappings) {
            Object.entries(mappingData.mappings).forEach(([role, mapping]) => {
                this.roleMappings.set(role, mapping);
            });
            this.saveRoleMappings();
            return true;
        }
        return false;
    }
}

// Make available globally
window.WordPressIntegration = WordPressIntegration;