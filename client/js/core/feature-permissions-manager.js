/**
 * Feature Permissions Manager
 * Controls which features are enabled/disabled on servers
 */

class FeaturePermissionsManager {
    constructor() {
        this.permissions = new Map(); // serverId -> permissions object
        this.globalPermissions = this.getDefaultPermissions();
        this.featureCategories = this.getFeatureCategories();

        // Per-channel and per-user permissions
        this.channelPermissions = new Map(); // channelId -> permissions
        this.userGroupPermissions = new Map(); // groupId -> permissions
        this.userPermissions = new Map(); // userId -> permissions
        this.userGroups = new Map(); // userId -> Set of groupIds

        // Channel-specific user permissions
        this.channelUserPermissions = new Map(); // channelId -> Map(userId -> permissions)
        this.channelGroupPermissions = new Map(); // channelId -> Map(groupId -> permissions)

        this.loadPermissions();
        this.setupEventListeners();
    }

    getDefaultPermissions() {
        return {
            // Audio Features
            audio: {
                spatialAudio: true,
                multiChannel: true,
                audioRouting: true,
                audioEffects: true,
                noiseSuppression: true,
                echoCancellation: true
            },

            // Streaming & Recording
            streaming: {
                liveStreaming: true,
                rtmpStreaming: true,
                webrtcStreaming: true,
                multiPlatformStreaming: true,
                customStreamTargets: true,
                streamingPresets: true
            },

            recording: {
                localRecording: true,
                cloudRecording: false,
                autoRecording: false,
                splitRecordings: true,
                recordingFormats: true,
                recordingScheduling: false
            },

            // VST & Plugins
            vst: {
                vstPlugins: true,
                vstStreaming: true,
                pluginChaining: true,
                customVSTs: true,
                vstPresets: true,
                realtimeProcessing: true
            },

            // Network & Communication
            network: {
                p2pConnections: true,
                externalConnections: true,
                portConfiguration: true,
                customPorts: true,
                networkDiagnostics: true,
                bandwidth: {
                    unlimited: false,
                    maxMbps: 100
                }
            },

            // Room Features
            rooms: {
                roomCreation: true,
                privateRooms: true,
                passwordProtection: true,
                roomTemplates: true,
                persistentRooms: false,
                maxRooms: 50,
                maxUsersPerRoom: 100
            },

            // User Management
            users: {
                userRegistration: true,
                guestAccess: true,
                userProfiles: true,
                userRoles: true,
                banUsers: true,
                kickUsers: true,
                moderatorTools: true,
                createGroups: true,
                manageGroups: true,
                assignGroupRoles: true
            },

            // Channel Permissions
            channels: {
                createChannels: true,
                deleteChannels: false,
                manageChannels: true,
                joinAnyChannel: true,
                privateChannels: true,
                channelModerators: true,
                channelPermissions: true,
                voiceActivation: true,
                pushToTalk: true,
                textChat: true,
                fileSharing: true,
                screenSharing: true
            },

            // Per-User Channel Permissions
            userChannelPermissions: {
                speak: true,
                listen: true,
                textChat: true,
                fileUpload: true,
                useVST: true,
                streaming: true,
                recording: true,
                moderateChannel: false,
                kickUsers: false,
                muteUsers: false,
                managePermissions: false
            },

            // Security Features
            security: {
                endToEndEncryption: true,
                requireEncryption: false,
                ssl: true,
                anonymousMode: true,
                auditLogs: true,
                rateLimiting: true,
                ipWhitelist: false
            },

            // System Features
            system: {
                adminInterface: true,
                systemMonitoring: true,
                performanceMetrics: true,
                automaticUpdates: true,
                backupRestore: true,
                customization: true,
                theming: true
            },

            // Advanced Features
            advanced: {
                apiAccess: false,
                webhooks: false,
                integrations: true,
                customPlugins: false,
                developmentMode: false,
                debugging: false
            }
        };
    }

    getFeatureCategories() {
        return {
            essential: ['audio.spatialAudio', 'network.p2pConnections', 'rooms.roomCreation', 'channels.joinAnyChannel'],
            streaming: ['streaming.liveStreaming', 'streaming.rtmpStreaming', 'recording.localRecording', 'userChannelPermissions.streaming'],
            professional: ['vst.vstPlugins', 'streaming.multiPlatformStreaming', 'advanced.apiAccess', 'userChannelPermissions.useVST'],
            security: ['security.endToEndEncryption', 'security.ssl', 'security.auditLogs'],
            management: ['users.userRoles', 'system.adminInterface', 'system.systemMonitoring', 'users.manageGroups'],
            channel: ['channels.createChannels', 'channels.manageChannels', 'channels.channelPermissions'],
            userGroups: ['users.createGroups', 'users.assignGroupRoles', 'userChannelPermissions.moderateChannel']
        };
    }

    loadPermissions() {
        try {
            const stored = localStorage.getItem('voicelink-feature-permissions');
            if (stored) {
                const data = JSON.parse(stored);
                this.globalPermissions = { ...this.globalPermissions, ...data.global };

                if (data.servers) {
                    Object.entries(data.servers).forEach(([serverId, perms]) => {
                        this.permissions.set(serverId, perms);
                    });
                }

                if (data.channels) {
                    Object.entries(data.channels).forEach(([channelId, perms]) => {
                        this.channelPermissions.set(channelId, perms);
                    });
                }

                if (data.userGroups) {
                    Object.entries(data.userGroups).forEach(([groupId, perms]) => {
                        this.userGroupPermissions.set(groupId, perms);
                    });
                }

                if (data.users) {
                    Object.entries(data.users).forEach(([userId, perms]) => {
                        this.userPermissions.set(userId, perms);
                    });
                }

                if (data.userGroupMembership) {
                    Object.entries(data.userGroupMembership).forEach(([userId, groups]) => {
                        this.userGroups.set(userId, new Set(groups));
                    });
                }

                if (data.channelUsers) {
                    Object.entries(data.channelUsers).forEach(([channelId, userPerms]) => {
                        const channelUserMap = new Map();
                        Object.entries(userPerms).forEach(([userId, perms]) => {
                            channelUserMap.set(userId, perms);
                        });
                        this.channelUserPermissions.set(channelId, channelUserMap);
                    });
                }

                if (data.channelGroups) {
                    Object.entries(data.channelGroups).forEach(([channelId, groupPerms]) => {
                        const channelGroupMap = new Map();
                        Object.entries(groupPerms).forEach(([groupId, perms]) => {
                            channelGroupMap.set(groupId, perms);
                        });
                        this.channelGroupPermissions.set(channelId, channelGroupMap);
                    });
                }
            }
        } catch (error) {
            console.error('Error loading feature permissions:', error);
        }
    }

    savePermissions() {
        try {
            const data = {
                global: this.globalPermissions,
                servers: Object.fromEntries(this.permissions),
                channels: Object.fromEntries(this.channelPermissions),
                userGroups: Object.fromEntries(this.userGroupPermissions),
                users: Object.fromEntries(this.userPermissions),
                userGroupMembership: Object.fromEntries(
                    Array.from(this.userGroups.entries()).map(([userId, groups]) => [
                        userId,
                        Array.from(groups)
                    ])
                ),
                channelUsers: Object.fromEntries(
                    Array.from(this.channelUserPermissions.entries()).map(([channelId, userMap]) => [
                        channelId,
                        Object.fromEntries(userMap)
                    ])
                ),
                channelGroups: Object.fromEntries(
                    Array.from(this.channelGroupPermissions.entries()).map(([channelId, groupMap]) => [
                        channelId,
                        Object.fromEntries(groupMap)
                    ])
                )
            };
            localStorage.setItem('voicelink-feature-permissions', JSON.stringify(data));

            // Notify about permission changes
            this.dispatchPermissionChange();
        } catch (error) {
            console.error('Error saving feature permissions:', error);
        }
    }

    getPermissions(serverId = null) {
        if (serverId && this.permissions.has(serverId)) {
            // Merge server-specific with global permissions
            return this.mergePermissions(this.globalPermissions, this.permissions.get(serverId));
        }
        return this.globalPermissions;
    }

    setPermission(feature, enabled, serverId = null) {
        const permissions = serverId ?
            (this.permissions.get(serverId) || {}) :
            this.globalPermissions;

        this.setNestedProperty(permissions, feature, enabled);

        if (serverId) {
            this.permissions.set(serverId, permissions);
        } else {
            this.globalPermissions = permissions;
        }

        this.savePermissions();
        return true;
    }

    isFeatureEnabled(feature, serverId = null, channelId = null, userId = null) {
        // Check user-specific channel permissions first (most specific)
        if (channelId && userId) {
            const userChannelPerms = this.getUserChannelPermissions(userId, channelId);
            const userFeatureValue = this.getNestedProperty(userChannelPerms, feature);
            if (userFeatureValue !== undefined) {
                return userFeatureValue === true;
            }
        }

        // Check user group permissions in channel
        if (channelId && userId) {
            const userGroups = this.getUserGroups(userId);
            for (const groupId of userGroups) {
                const groupChannelPerms = this.getGroupChannelPermissions(groupId, channelId);
                const groupFeatureValue = this.getNestedProperty(groupChannelPerms, feature);
                if (groupFeatureValue !== undefined) {
                    return groupFeatureValue === true;
                }
            }
        }

        // Check channel-wide permissions
        if (channelId) {
            const channelPerms = this.getChannelPermissions(channelId);
            const channelFeatureValue = this.getNestedProperty(channelPerms, feature);
            if (channelFeatureValue !== undefined) {
                return channelFeatureValue === true;
            }
        }

        // Check user-specific permissions (global)
        if (userId) {
            const userPerms = this.getUserPermissions(userId);
            const userFeatureValue = this.getNestedProperty(userPerms, feature);
            if (userFeatureValue !== undefined) {
                return userFeatureValue === true;
            }
        }

        // Check user group permissions (global)
        if (userId) {
            const userGroups = this.getUserGroups(userId);
            for (const groupId of userGroups) {
                const groupPerms = this.getUserGroupPermissions(groupId);
                const groupFeatureValue = this.getNestedProperty(groupPerms, feature);
                if (groupFeatureValue !== undefined) {
                    return groupFeatureValue === true;
                }
            }
        }

        // Fall back to server/global permissions
        const permissions = this.getPermissions(serverId);
        return this.getNestedProperty(permissions, feature) === true;
    }

    setFeatureCategory(category, enabled, serverId = null) {
        const features = this.featureCategories[category] || [];
        features.forEach(feature => {
            this.setPermission(feature, enabled, serverId);
        });
    }

    validatePermission(feature, serverId = null) {
        // Check if feature is enabled and validate dependencies
        if (!this.isFeatureEnabled(feature, serverId)) {
            return { allowed: false, reason: 'Feature disabled by administrator' };
        }

        // Check feature dependencies
        const dependencies = this.getFeatureDependencies(feature);
        for (const dep of dependencies) {
            if (!this.isFeatureEnabled(dep, serverId)) {
                return {
                    allowed: false,
                    reason: `Required feature '${dep}' is disabled`
                };
            }
        }

        return { allowed: true };
    }

    getFeatureDependencies(feature) {
        const dependencies = {
            'streaming.liveStreaming': ['audio.spatialAudio', 'network.p2pConnections'],
            'recording.cloudRecording': ['recording.localRecording', 'network.externalConnections'],
            'vst.vstStreaming': ['vst.vstPlugins', 'streaming.liveStreaming'],
            'security.requireEncryption': ['security.endToEndEncryption'],
            'advanced.webhooks': ['advanced.apiAccess'],
            'rooms.persistentRooms': ['rooms.roomCreation']
        };

        return dependencies[feature] || [];
    }

    getServerPermissionProfile(serverId) {
        const permissions = this.getPermissions(serverId);
        const profile = {
            essential: [],
            enabled: [],
            disabled: [],
            restricted: []
        };

        this.flattenPermissions(permissions).forEach(({ feature, enabled }) => {
            if (this.featureCategories.essential.includes(feature)) {
                profile.essential.push({ feature, enabled });
            } else if (enabled) {
                profile.enabled.push(feature);
            } else {
                profile.disabled.push(feature);
            }
        });

        return profile;
    }

    createPermissionPreset(name, permissions) {
        const presets = this.getPermissionPresets();
        presets[name] = permissions;
        localStorage.setItem('voicelink-permission-presets', JSON.stringify(presets));
    }

    getPermissionPresets() {
        try {
            const stored = localStorage.getItem('voicelink-permission-presets');
            return stored ? JSON.parse(stored) : this.getDefaultPresets();
        } catch (error) {
            return this.getDefaultPresets();
        }
    }

    getDefaultPresets() {
        return {
            'Basic Server': {
                audio: { spatialAudio: true, multiChannel: false },
                streaming: { liveStreaming: false },
                recording: { localRecording: true },
                vst: { vstPlugins: false },
                rooms: { maxRooms: 10, maxUsersPerRoom: 20 }
            },
            'Streaming Server': {
                audio: { spatialAudio: true, multiChannel: true },
                streaming: { liveStreaming: true, rtmpStreaming: true },
                recording: { localRecording: true, cloudRecording: true },
                vst: { vstPlugins: true, vstStreaming: true }
            },
            'Production Server': {
                ...this.getDefaultPermissions(),
                security: { ...this.getDefaultPermissions().security, requireEncryption: true },
                advanced: { apiAccess: true, webhooks: true }
            },
            'Locked Down': {
                audio: { spatialAudio: true },
                streaming: { liveStreaming: false },
                recording: { localRecording: false },
                vst: { vstPlugins: false },
                security: { requireEncryption: true, anonymousMode: false }
            }
        };
    }

    // Utility methods
    mergePermissions(global, serverSpecific) {
        const merged = JSON.parse(JSON.stringify(global));

        function merge(target, source) {
            for (const key in source) {
                if (typeof source[key] === 'object' && !Array.isArray(source[key])) {
                    if (!target[key]) target[key] = {};
                    merge(target[key], source[key]);
                } else {
                    target[key] = source[key];
                }
            }
        }

        merge(merged, serverSpecific);
        return merged;
    }

    setNestedProperty(obj, path, value) {
        const keys = path.split('.');
        let current = obj;

        for (let i = 0; i < keys.length - 1; i++) {
            if (!current[keys[i]]) current[keys[i]] = {};
            current = current[keys[i]];
        }

        current[keys[keys.length - 1]] = value;
    }

    getNestedProperty(obj, path) {
        const keys = path.split('.');
        let current = obj;

        for (const key of keys) {
            if (current && typeof current === 'object') {
                current = current[key];
            } else {
                return undefined;
            }
        }

        return current;
    }

    flattenPermissions(permissions, prefix = '') {
        const result = [];

        for (const [key, value] of Object.entries(permissions)) {
            const fullKey = prefix ? `${prefix}.${key}` : key;

            if (typeof value === 'object' && !Array.isArray(value) && value !== null) {
                result.push(...this.flattenPermissions(value, fullKey));
            } else {
                result.push({ feature: fullKey, enabled: value });
            }
        }

        return result;
    }

    setupEventListeners() {
        // Listen for server connections to apply permissions
        window.addEventListener('serverConnected', (event) => {
            const { serverId } = event.detail;
            this.applyPermissionsToServer(serverId);
        });

        // Listen for feature usage attempts
        window.addEventListener('featureRequest', (event) => {
            const { feature, serverId } = event.detail;
            const validation = this.validatePermission(feature, serverId);

            event.detail.allowed = validation.allowed;
            event.detail.reason = validation.reason;
        });
    }

    applyPermissionsToServer(serverId) {
        const permissions = this.getPermissions(serverId);

        // Send permissions to server
        const event = new CustomEvent('permissionsApplied', {
            detail: { serverId, permissions }
        });
        window.dispatchEvent(event);
    }

    // Channel Permission Methods
    setChannelPermission(channelId, feature, enabled) {
        const permissions = this.channelPermissions.get(channelId) || {};
        this.setNestedProperty(permissions, feature, enabled);
        this.channelPermissions.set(channelId, permissions);
        this.savePermissions();
    }

    getChannelPermissions(channelId) {
        return this.channelPermissions.get(channelId) || {};
    }

    createChannel(channelId, name, type = 'voice', parentChannelId = null) {
        const channelData = {
            id: channelId,
            name,
            type, // 'voice', 'text', 'category'
            parentChannelId,
            permissions: this.getDefaultPermissions().userChannelPermissions,
            createdAt: Date.now()
        };

        this.channelPermissions.set(channelId, channelData.permissions);
        this.savePermissions();
        return channelData;
    }

    deleteChannel(channelId) {
        this.channelPermissions.delete(channelId);
        this.channelUserPermissions.delete(channelId);
        this.channelGroupPermissions.delete(channelId);
        this.savePermissions();
    }

    // User Group Methods
    createUserGroup(groupId, name, permissions = {}) {
        const groupData = {
            id: groupId,
            name,
            permissions: { ...this.getDefaultPermissions().userChannelPermissions, ...permissions },
            createdAt: Date.now(),
            members: new Set()
        };

        this.userGroupPermissions.set(groupId, groupData.permissions);
        this.savePermissions();
        return groupData;
    }

    deleteUserGroup(groupId) {
        this.userGroupPermissions.delete(groupId);

        // Remove users from this group
        this.userGroups.forEach((groups, userId) => {
            if (groups.has(groupId)) {
                groups.delete(groupId);
            }
        });

        this.savePermissions();
    }

    addUserToGroup(userId, groupId) {
        if (!this.userGroups.has(userId)) {
            this.userGroups.set(userId, new Set());
        }
        this.userGroups.get(userId).add(groupId);
        this.savePermissions();
    }

    removeUserFromGroup(userId, groupId) {
        if (this.userGroups.has(userId)) {
            this.userGroups.get(userId).delete(groupId);
        }
        this.savePermissions();
    }

    getUserGroups(userId) {
        return this.userGroups.get(userId) || new Set();
    }

    getGroupMembers(groupId) {
        const members = new Set();
        this.userGroups.forEach((groups, userId) => {
            if (groups.has(groupId)) {
                members.add(userId);
            }
        });
        return members;
    }

    // User Permission Methods
    setUserPermission(userId, feature, enabled) {
        const permissions = this.userPermissions.get(userId) || {};
        this.setNestedProperty(permissions, feature, enabled);
        this.userPermissions.set(userId, permissions);
        this.savePermissions();
    }

    getUserPermissions(userId) {
        return this.userPermissions.get(userId) || {};
    }

    setUserGroupPermission(groupId, feature, enabled) {
        const permissions = this.userGroupPermissions.get(groupId) || {};
        this.setNestedProperty(permissions, feature, enabled);
        this.userGroupPermissions.set(groupId, permissions);
        this.savePermissions();
    }

    getUserGroupPermissions(groupId) {
        return this.userGroupPermissions.get(groupId) || {};
    }

    // Channel-User Specific Methods
    setUserChannelPermission(userId, channelId, feature, enabled) {
        if (!this.channelUserPermissions.has(channelId)) {
            this.channelUserPermissions.set(channelId, new Map());
        }

        const channelUsers = this.channelUserPermissions.get(channelId);
        const userPerms = channelUsers.get(userId) || {};
        this.setNestedProperty(userPerms, feature, enabled);
        channelUsers.set(userId, userPerms);
        this.savePermissions();
    }

    getUserChannelPermissions(userId, channelId) {
        const channelUsers = this.channelUserPermissions.get(channelId);
        return channelUsers ? (channelUsers.get(userId) || {}) : {};
    }

    setGroupChannelPermission(groupId, channelId, feature, enabled) {
        if (!this.channelGroupPermissions.has(channelId)) {
            this.channelGroupPermissions.set(channelId, new Map());
        }

        const channelGroups = this.channelGroupPermissions.get(channelId);
        const groupPerms = channelGroups.get(groupId) || {};
        this.setNestedProperty(groupPerms, feature, enabled);
        channelGroups.set(groupId, groupPerms);
        this.savePermissions();
    }

    getGroupChannelPermissions(groupId, channelId) {
        const channelGroups = this.channelGroupPermissions.get(channelId);
        return channelGroups ? (channelGroups.get(groupId) || {}) : {};
    }

    // Permission Analysis Methods
    getUserEffectivePermissions(userId, channelId = null, serverId = null) {
        const effective = {};
        const allFeatures = this.flattenPermissions(this.getDefaultPermissions());

        allFeatures.forEach(({ feature }) => {
            effective[feature] = this.isFeatureEnabled(feature, serverId, channelId, userId);
        });

        return effective;
    }

    getChannelUserList(channelId, includePermissions = false) {
        const users = [];
        const channelUsers = this.channelUserPermissions.get(channelId) || new Map();

        channelUsers.forEach((permissions, userId) => {
            const userData = { userId };
            if (includePermissions) {
                userData.permissions = permissions;
                userData.effectivePermissions = this.getUserEffectivePermissions(userId, channelId);
            }
            users.push(userData);
        });

        return users;
    }

    getPermissionConflicts(userId, channelId) {
        const conflicts = [];
        const userChannelPerms = this.getUserChannelPermissions(userId, channelId);
        const userGlobalPerms = this.getUserPermissions(userId);
        const userGroups = this.getUserGroups(userId);

        // Check for conflicts between different permission levels
        Object.keys(userChannelPerms).forEach(feature => {
            const channelValue = userChannelPerms[feature];
            const globalValue = userGlobalPerms[feature];

            if (channelValue !== undefined && globalValue !== undefined && channelValue !== globalValue) {
                conflicts.push({
                    feature,
                    channelValue,
                    globalValue,
                    type: 'user-channel-vs-global'
                });
            }

            // Check group conflicts
            userGroups.forEach(groupId => {
                const groupChannelPerms = this.getGroupChannelPermissions(groupId, channelId);
                const groupGlobalPerms = this.getUserGroupPermissions(groupId);

                if (groupChannelPerms[feature] !== undefined &&
                    channelValue !== undefined &&
                    groupChannelPerms[feature] !== channelValue) {
                    conflicts.push({
                        feature,
                        userValue: channelValue,
                        groupValue: groupChannelPerms[feature],
                        groupId,
                        type: 'user-vs-group-channel'
                    });
                }
            });
        });

        return conflicts;
    }

    // Role Templates
    getDefaultRoleTemplates() {
        return {
            'Admin': {
                ...this.getDefaultPermissions().userChannelPermissions,
                moderateChannel: true,
                kickUsers: true,
                muteUsers: true,
                managePermissions: true
            },
            'Moderator': {
                ...this.getDefaultPermissions().userChannelPermissions,
                moderateChannel: true,
                kickUsers: true,
                muteUsers: true,
                managePermissions: false
            },
            'DJ': {
                ...this.getDefaultPermissions().userChannelPermissions,
                useVST: true,
                streaming: true,
                recording: true
            },
            'Listener': {
                speak: false,
                listen: true,
                textChat: true,
                fileUpload: false,
                useVST: false,
                streaming: false,
                recording: false
            },
            'Muted': {
                speak: false,
                listen: true,
                textChat: false,
                fileUpload: false,
                useVST: false,
                streaming: false,
                recording: false
            }
        };
    }

    applyRoleTemplate(userId, channelId, templateName) {
        const templates = this.getDefaultRoleTemplates();
        const template = templates[templateName];

        if (template) {
            Object.entries(template).forEach(([feature, enabled]) => {
                this.setUserChannelPermission(userId, channelId, feature, enabled);
            });
        }
    }

    dispatchPermissionChange() {
        const event = new CustomEvent('permissionsChanged', {
            detail: {
                global: this.globalPermissions,
                servers: Object.fromEntries(this.permissions),
                channels: Object.fromEntries(this.channelPermissions),
                userGroups: Object.fromEntries(this.userGroupPermissions),
                users: Object.fromEntries(this.userPermissions)
            }
        });
        window.dispatchEvent(event);
    }
}

// Make available globally
window.FeaturePermissionsManager = FeaturePermissionsManager;