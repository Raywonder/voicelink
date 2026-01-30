/**
 * VoiceLink Unified Admin Interface
 * Seamless local and remote server administration
 */

class UnifiedAdminInterface {
    constructor(serverAccessManager, audioEngine, multiChannelEngine, vstEngine) {
        this.serverAccessManager = serverAccessManager;
        this.audioEngine = audioEngine;
        this.multiChannelEngine = multiChannelEngine;
        this.vstEngine = vstEngine;

        // Admin context
        this.currentContext = null; // local or remote server context
        this.adminSessions = new Map(); // serverId -> AdminSession
        this.syncedSettings = new Map(); // settingKey -> syncData

        // Admin capabilities
        this.capabilities = {
            local: new Set(),
            remote: new Map() // serverId -> Set of capabilities
        };

        // Real-time synchronization
        this.syncQueue = [];
        this.lastSync = new Map(); // serverId -> timestamp

        this.init();
    }

    async init() {
        console.log('Initializing Unified Admin Interface...');

        // Detect local admin capabilities
        await this.detectLocalCapabilities();

        // Setup admin interface
        this.setupAdminInterface();

        // Setup real-time sync
        this.setupRealtimeSync();

        // Listen for server connections
        this.setupServerConnectionHandlers();

        console.log('Unified Admin Interface initialized');
    }

    async detectLocalCapabilities() {
        // Detect what admin functions are available locally
        const localCaps = new Set();

        // Audio system capabilities
        if (this.audioEngine) {
            localCaps.add('audio_routing');
            localCaps.add('audio_devices');
            localCaps.add('audio_settings');
        }

        if (this.multiChannelEngine) {
            localCaps.add('multi_channel_control');
            localCaps.add('channel_matrix');
            localCaps.add('advanced_routing');
        }

        if (this.vstEngine) {
            localCaps.add('vst_management');
            localCaps.add('vst_streaming');
            localCaps.add('plugin_control');
        }

        // System capabilities
        localCaps.add('user_management');
        localCaps.add('room_management');
        localCaps.add('server_monitoring');
        localCaps.add('settings_management');

        this.capabilities.local = localCaps;
        console.log('Local admin capabilities:', Array.from(localCaps));
    }

    setupAdminInterface() {
        // Create unified admin panel
        this.createAdminPanel();

        // Setup context switching
        this.setupContextSwitching();

        // Setup admin commands
        this.setupAdminCommands();

        // Setup real-time monitoring
        this.setupRealtimeMonitoring();
    }

    createAdminPanel() {
        const adminPanel = document.createElement('div');
        adminPanel.id = 'unified-admin-panel';
        adminPanel.className = 'admin-panel hidden';

        adminPanel.innerHTML = `
            <div class="admin-header">
                <div class="admin-title">
                    <h2>🎛️ VoiceLink Administration</h2>
                    <div class="admin-context">
                        <select id="admin-context-selector">
                            <option value="local">Local Server</option>
                        </select>
                        <button id="admin-sync-status" class="sync-status">🔄 Synced</button>
                    </div>
                </div>
                <div class="admin-controls">
                    <button id="admin-settings" class="admin-btn">⚙️ Settings</button>
                    <button id="admin-logs" class="admin-btn">📋 Logs</button>
                    <button id="admin-close" class="admin-btn close">✕</button>
                </div>
            </div>

            <div class="admin-content">
                <div class="admin-sidebar">
                    <nav class="admin-nav">
                        <button class="nav-item active" data-section="dashboard">📊 Dashboard</button>
                        <button class="nav-item" data-section="users">👥 Users</button>
                        <button class="nav-item" data-section="rooms">🏠 Rooms</button>
                        <button class="nav-item" data-section="audio">🎵 Audio System</button>
                        <button class="nav-item" data-section="channels">📡 Channel Matrix</button>
                        <button class="nav-item" data-section="vst">🎛️ VST Plugins</button>
                        <button class="nav-item" data-section="network">🌐 Network</button>
                        <button class="nav-item" data-section="permissions">🔑 Permissions</button>
                        <button class="nav-item" data-section="integrations">🔗 Integrations</button>
                        <button class="nav-item" data-section="security">🔒 Security</button>
                        <button class="nav-item" data-section="system">💻 System</button>
                    </nav>
                </div>

                <div class="admin-main">
                    <!-- Dashboard Section -->
                    <div class="admin-section active" id="admin-dashboard">
                        <h3>Server Dashboard</h3>
                        <div class="dashboard-grid">
                            <div class="dashboard-card">
                                <h4>Server Status</h4>
                                <div id="server-status" class="status-indicator">
                                    <span class="status-dot online"></span>
                                    <span>Online</span>
                                </div>
                                <div class="server-info">
                                    <div>Uptime: <span id="server-uptime">--</span></div>
                                    <div>CPU: <span id="server-cpu">--</span></div>
                                    <div>Memory: <span id="server-memory">--</span></div>
                                </div>
                            </div>

                            <div class="dashboard-card">
                                <h4>Connected Users</h4>
                                <div class="user-stats">
                                    <div class="stat-number" id="total-users">0</div>
                                    <div class="stat-label">Total Users</div>
                                </div>
                                <div class="user-activity" id="user-activity-chart"></div>
                            </div>

                            <div class="dashboard-card">
                                <h4>Audio Performance</h4>
                                <div class="audio-stats">
                                    <div>Latency: <span id="audio-latency">--</span></div>
                                    <div>CPU Load: <span id="audio-cpu">--</span></div>
                                    <div>Active Channels: <span id="active-channels">--</span></div>
                                </div>
                            </div>

                            <div class="dashboard-card">
                                <h4>VST Activity</h4>
                                <div class="vst-stats">
                                    <div>Active Plugins: <span id="active-vsts">0</span></div>
                                    <div>Streaming: <span id="vst-streams">0</span></div>
                                    <div>CPU Usage: <span id="vst-cpu">--</span></div>
                                </div>
                            </div>
                        </div>

                        <div class="recent-activity">
                            <h4>Recent Activity</h4>
                            <div id="activity-log" class="activity-log"></div>
                        </div>
                    </div>

                    <!-- Users Section -->
                    <div class="admin-section" id="admin-users">
                        <div class="section-header">
                            <h3>User Management</h3>
                            <div class="section-controls">
                                <button id="add-user-btn" class="primary-btn">➕ Add User</button>
                                <button id="bulk-actions-btn" class="secondary-btn">📋 Bulk Actions</button>
                            </div>
                        </div>

                        <div class="user-filters">
                            <input type="text" id="user-search" placeholder="Search users...">
                            <select id="user-filter-role">
                                <option value="">All Roles</option>
                                <option value="admin">Admin</option>
                                <option value="moderator">Moderator</option>
                                <option value="user">User</option>
                                <option value="guest">Guest</option>
                            </select>
                            <select id="user-filter-status">
                                <option value="">All Status</option>
                                <option value="online">Online</option>
                                <option value="offline">Offline</option>
                                <option value="away">Away</option>
                            </select>
                        </div>

                        <div class="user-list" id="admin-user-list">
                            <!-- Users will be populated dynamically -->
                        </div>
                    </div>

                    <!-- Rooms Section -->
                    <div class="admin-section" id="admin-rooms">
                        <div class="section-header">
                            <h3>Room Management</h3>
                            <div class="section-controls">
                                <button id="room-templates-btn" class="secondary-btn">📄 Templates</button>
                                <button id="refresh-rooms-btn" class="secondary-btn">🔄 Refresh</button>
                            </div>
                        </div>
                        <div class="room-note">
                            <p>💡 Use the main "Create New Room" button in the Quick Start section to create rooms</p>
                        </div>

                        <div class="room-list" id="admin-room-list">
                            <!-- Rooms will be populated dynamically -->
                        </div>
                    </div>

                    <!-- Audio System Section -->
                    <div class="admin-section" id="admin-audio">
                        <div class="section-header">
                            <h3>Audio System Control</h3>
                            <div class="section-controls">
                                <button id="audio-test-btn" class="primary-btn">🔊 Test Audio</button>
                                <button id="audio-reset-btn" class="secondary-btn">🔄 Reset</button>
                            </div>
                        </div>

                        <div class="audio-controls-grid">
                            <div class="audio-control-panel">
                                <h4>Master Controls</h4>
                                <div class="control-group">
                                    <label>Master Volume:</label>
                                    <input type="range" id="master-volume" min="0" max="200" value="100">
                                    <span id="master-volume-value">100%</span>
                                </div>
                                <div class="control-group">
                                    <label>Sample Rate:</label>
                                    <select id="sample-rate">
                                        <option value="44100">44.1 kHz</option>
                                        <option value="48000" selected>48 kHz</option>
                                        <option value="96000">96 kHz</option>
                                        <option value="192000">192 kHz</option>
                                    </select>
                                </div>
                                <div class="control-group">
                                    <label>Buffer Size:</label>
                                    <select id="buffer-size">
                                        <option value="64">64 samples</option>
                                        <option value="128">128 samples</option>
                                        <option value="256" selected>256 samples</option>
                                        <option value="512">512 samples</option>
                                    </select>
                                </div>
                            </div>

                            <div class="audio-device-panel">
                                <h4>Audio Devices</h4>
                                <div id="audio-devices-list"></div>
                            </div>

                            <div class="audio-routing-panel">
                                <h4>User Audio Routing</h4>
                                <div id="user-audio-routing"></div>
                            </div>
                        </div>
                    </div>

                    <!-- Channel Matrix Section -->
                    <div class="admin-section" id="admin-channels">
                        <div class="section-header">
                            <h3>64-Channel Matrix Control</h3>
                            <div class="section-controls">
                                <button id="channel-preset-btn" class="primary-btn">💾 Presets</button>
                                <button id="channel-reset-btn" class="secondary-btn">🔄 Reset Matrix</button>
                            </div>
                        </div>

                        <div class="channel-matrix-container">
                            <div class="channel-matrix" id="channel-matrix">
                                <!-- 64x64 channel matrix will be generated -->
                            </div>
                        </div>

                        <div class="channel-controls">
                            <div class="channel-info">
                                <h4>Channel Information</h4>
                                <div id="selected-channel-info">Select a channel to view details</div>
                            </div>

                            <div class="channel-types">
                                <h4>Channel Types</h4>
                                <div class="channel-type-legend">
                                    <div class="legend-item"><span class="color-mono"></span> Mono</div>
                                    <div class="legend-item"><span class="color-stereo"></span> Stereo</div>
                                    <div class="legend-item"><span class="color-binaural"></span> 3D Binaural</div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- VST Plugins Section -->
                    <div class="admin-section" id="admin-vst">
                        <div class="section-header">
                            <h3>VST Plugin Management</h3>
                            <div class="section-controls">
                                <button id="vst-scan-btn" class="primary-btn">🔍 Scan Plugins</button>
                                <button id="vst-stream-manager-btn" class="secondary-btn">📡 Stream Manager</button>
                            </div>
                        </div>

                        <div class="vst-management-grid">
                            <div class="vst-library">
                                <h4>Plugin Library</h4>
                                <div id="vst-plugin-library"></div>
                            </div>

                            <div class="vst-instances">
                                <h4>Active Instances</h4>
                                <div id="vst-active-instances"></div>
                            </div>

                            <div class="vst-streaming">
                                <h4>Streaming Sessions</h4>
                                <div id="vst-streaming-sessions"></div>
                            </div>
                        </div>
                    </div>

                    <!-- Network Section -->
                    <div class="admin-section" id="admin-network">
                        <div class="section-header">
                            <h3>Network Management</h3>
                            <div class="section-controls">
                                <button id="network-test-btn" class="primary-btn">🌐 Test Network</button>
                                <button id="port-scanner-btn" class="secondary-btn">🔍 Port Scanner</button>
                            </div>
                        </div>

                        <div class="network-info-grid">
                            <div class="connection-info">
                                <h4>Connection Information</h4>
                                <div id="network-connection-info"></div>
                            </div>

                            <div class="port-configuration">
                                <h4>Port Configuration</h4>
                                <div class="port-settings">
                                    <div class="setting-group">
                                        <label>Local Server Port:</label>
                                        <input type="number" id="local-server-port" min="1024" max="65535" value="4004">
                                        <button id="test-port-btn" class="test-btn">Test</button>
                                    </div>
                                    <div class="setting-group">
                                        <label>Remote Server Port:</label>
                                        <input type="number" id="remote-server-port" min="1024" max="65535" value="4005">
                                    </div>
                                    <div class="setting-group">
                                        <label>WebSocket Port:</label>
                                        <input type="number" id="websocket-port" min="1024" max="65535" value="4006">
                                    </div>
                                    <div class="setting-group">
                                        <label>
                                            <input type="checkbox" id="auto-detect-ports" checked>
                                            Auto-detect available ports
                                        </label>
                                    </div>
                                    <div class="port-status" id="port-status">
                                        <!-- Port availability status -->
                                    </div>
                                    <button id="scan-ports-btn" class="secondary-btn">🔍 Scan Available Ports</button>
                                </div>
                            </div>

                            <div class="bandwidth-monitor">
                                <h4>Bandwidth Usage</h4>
                                <div id="bandwidth-chart"></div>
                            </div>

                            <div class="connected-clients">
                                <h4>Connected Clients</h4>
                                <div id="network-clients-list"></div>
                            </div>
                        </div>
                    </div>

                    <!-- Permissions Section -->
                    <div class="admin-section" id="admin-permissions">
                        <div class="section-header">
                            <h3>Feature Permissions Management</h3>
                            <div class="section-controls">
                                <button id="permission-presets-btn" class="primary-btn">📄 Presets</button>
                                <button id="export-permissions-btn" class="secondary-btn">💾 Export</button>
                                <button id="import-permissions-btn" class="secondary-btn">📁 Import</button>
                            </div>
                        </div>

                        <div class="permissions-container">
                            <div class="permission-tabs">
                                <button class="permission-tab active" data-tab="global">Global</button>
                                <button class="permission-tab" data-tab="channels">Channels</button>
                                <button class="permission-tab" data-tab="users">Users</button>
                                <button class="permission-tab" data-tab="groups">Groups</button>
                            </div>

                            <!-- Global Permissions -->
                            <div class="permission-content active" data-tab="global">
                                <div class="permission-categories">
                                    <div class="permission-category">
                                        <h4>🎧 Audio Features</h4>
                                        <div class="permission-toggles">
                                            <label><input type="checkbox" data-permission="audio.spatialAudio" checked> 3D Spatial Audio</label>
                                            <label><input type="checkbox" data-permission="audio.multiChannel" checked> Multi-Channel Audio</label>
                                            <label><input type="checkbox" data-permission="audio.audioEffects" checked> Audio Effects</label>
                                            <label><input type="checkbox" data-permission="audio.noiseSuppression" checked> Noise Suppression</label>
                                        </div>
                                    </div>

                                    <div class="permission-category">
                                        <h4>📹 Streaming & Recording</h4>
                                        <div class="permission-toggles">
                                            <label><input type="checkbox" data-permission="streaming.liveStreaming" checked> Live Streaming</label>
                                            <label><input type="checkbox" data-permission="streaming.rtmpStreaming" checked> RTMP Streaming</label>
                                            <label><input type="checkbox" data-permission="streaming.multiPlatformStreaming" checked> Multi-Platform Streaming</label>
                                            <label><input type="checkbox" data-permission="recording.localRecording" checked> Local Recording</label>
                                            <label><input type="checkbox" data-permission="recording.cloudRecording"> Cloud Recording</label>
                                            <label><input type="checkbox" data-permission="recording.autoRecording"> Auto Recording</label>
                                        </div>
                                    </div>

                                    <div class="permission-category">
                                        <h4>🎹 VST Plugins</h4>
                                        <div class="permission-toggles">
                                            <label><input type="checkbox" data-permission="vst.vstPlugins" checked> VST Plugins</label>
                                            <label><input type="checkbox" data-permission="vst.vstStreaming" checked> VST Streaming</label>
                                            <label><input type="checkbox" data-permission="vst.customVSTs" checked> Custom VSTs</label>
                                            <label><input type="checkbox" data-permission="vst.realtimeProcessing" checked> Real-time Processing</label>
                                        </div>
                                    </div>

                                    <div class="permission-category">
                                        <h4>🗣️ Channels</h4>
                                        <div class="permission-toggles">
                                            <label><input type="checkbox" data-permission="channels.createChannels" checked> Create Channels</label>
                                            <label><input type="checkbox" data-permission="channels.deleteChannels"> Delete Channels</label>
                                            <label><input type="checkbox" data-permission="channels.privateChannels" checked> Private Channels</label>
                                            <label><input type="checkbox" data-permission="channels.channelModerators" checked> Channel Moderators</label>
                                        </div>
                                    </div>

                                    <div class="permission-category">
                                        <h4>👥 Users & Groups</h4>
                                        <div class="permission-toggles">
                                            <label><input type="checkbox" data-permission="users.userRegistration" checked> User Registration</label>
                                            <label><input type="checkbox" data-permission="users.guestAccess" checked> Guest Access</label>
                                            <label><input type="checkbox" data-permission="users.createGroups" checked> Create Groups</label>
                                            <label><input type="checkbox" data-permission="users.manageGroups" checked> Manage Groups</label>
                                            <label><input type="checkbox" data-permission="users.banUsers" checked> Ban Users</label>
                                            <label><input type="checkbox" data-permission="users.kickUsers" checked> Kick Users</label>
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <!-- Channel Permissions -->
                            <div class="permission-content" data-tab="channels">
                                <div class="channel-selector">
                                    <label>Select Channel:</label>
                                    <select id="channel-permission-selector">
                                        <option value="">Select a channel...</option>
                                    </select>
                                    <button id="create-channel-btn" class="secondary-btn">+ New Channel</button>
                                </div>
                                <div id="channel-permission-settings">
                                    <p>Select a channel to configure permissions</p>
                                </div>
                            </div>

                            <!-- User Permissions -->
                            <div class="permission-content" data-tab="users">
                                <div class="user-selector">
                                    <label>Select User:</label>
                                    <select id="user-permission-selector">
                                        <option value="">Select a user...</option>
                                    </select>
                                    <input type="text" id="user-search" placeholder="Search users...">
                                </div>
                                <div id="user-permission-settings">
                                    <p>Select a user to configure permissions</p>
                                </div>
                            </div>

                            <!-- Group Permissions -->
                            <div class="permission-content" data-tab="groups">
                                <div class="group-management">
                                    <div class="group-selector">
                                        <label>Select Group:</label>
                                        <select id="group-permission-selector">
                                            <option value="">Select a group...</option>
                                        </select>
                                        <button id="create-group-btn" class="secondary-btn">+ New Group</button>
                                    </div>
                                    <div class="role-templates">
                                        <label>Apply Role Template:</label>
                                        <select id="role-template-selector">
                                            <option value="">Select template...</option>
                                            <option value="Admin">Admin</option>
                                            <option value="Moderator">Moderator</option>
                                            <option value="DJ">DJ</option>
                                            <option value="Listener">Listener</option>
                                            <option value="Muted">Muted</option>
                                        </select>
                                        <button id="apply-template-btn" class="secondary-btn">Apply</button>
                                    </div>
                                </div>
                                <div id="group-permission-settings">
                                    <p>Select a group to configure permissions</p>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Integrations Section -->
                    <div class="admin-section" id="admin-integrations">
                        <div class="section-header">
                            <h3>External Integrations</h3>
                            <div class="section-controls">
                                <button id="test-integrations-btn" class="primary-btn">🧪 Test Connections</button>
                                <button id="integration-logs-btn" class="secondary-btn">📄 Logs</button>
                            </div>
                        </div>

                        <div class="integration-tabs">
                            <button class="integration-tab active" data-tab="wordpress">WordPress</button>
                            <button class="integration-tab" data-tab="discord">Discord</button>
                            <button class="integration-tab" data-tab="api">API Keys</button>
                            <button class="integration-tab" data-tab="webhooks">Webhooks</button>
                        </div>

                        <!-- WordPress Integration -->
                        <div class="integration-content active" data-tab="wordpress">
                            <div class="wordpress-integration">
                                <div class="integration-header">
                                    <h4>🎨 WordPress Integration</h4>
                                    <div class="connection-status" id="wp-connection-status">
                                        <span class="status-dot offline"></span>
                                        <span>Not Connected</span>
                                    </div>
                                </div>

                                <div class="wp-connection-form">
                                    <div class="form-group">
                                        <label>WordPress Site URL:</label>
                                        <input type="url" id="wp-site-url" placeholder="https://yoursite.com">
                                    </div>
                                    <div class="form-group">
                                        <label>Username:</label>
                                        <input type="text" id="wp-username" placeholder="WordPress username">
                                    </div>
                                    <div class="form-group">
                                        <label>Application Password:</label>
                                        <input type="password" id="wp-app-password" placeholder="WordPress application password">
                                        <small>Generate an application password in your WordPress admin under Users > Profile</small>
                                    </div>
                                    <div class="form-group">
                                        <label>
                                            <input type="checkbox" id="wp-auto-sync" checked>
                                            Auto-sync users every hour
                                        </label>
                                    </div>
                                    <div class="form-actions">
                                        <button id="wp-test-connection" class="secondary-btn">Test Connection</button>
                                        <button id="wp-connect" class="primary-btn">Connect</button>
                                        <button id="wp-disconnect" class="danger-btn" style="display:none">Disconnect</button>
                                    </div>
                                </div>

                                <div class="wp-role-mapping" id="wp-role-mapping" style="display:none">
                                    <h4>WordPress Role Mapping</h4>
                                    <div class="role-mapping-grid">
                                        <div class="role-mapping-item">
                                            <div class="wp-role">
                                                <strong>Administrator</strong>
                                                <span class="role-desc">Full admin access</span>
                                            </div>
                                            <div class="mapping-arrow">→</div>
                                            <div class="voicelink-permissions">
                                                <span class="permission-summary">Full Access + Admin Panel</span>
                                                <button class="edit-mapping-btn" data-role="administrator">Edit</button>
                                            </div>
                                        </div>
                                        <div class="role-mapping-item">
                                            <div class="wp-role">
                                                <strong>Editor</strong>
                                                <span class="role-desc">Content management</span>
                                            </div>
                                            <div class="mapping-arrow">→</div>
                                            <div class="voicelink-permissions">
                                                <span class="permission-summary">Streaming + Moderation</span>
                                                <button class="edit-mapping-btn" data-role="editor">Edit</button>
                                            </div>
                                        </div>
                                        <div class="role-mapping-item">
                                            <div class="wp-role">
                                                <strong>Author</strong>
                                                <span class="role-desc">Content creation</span>
                                            </div>
                                            <div class="mapping-arrow">→</div>
                                            <div class="voicelink-permissions">
                                                <span class="permission-summary">Basic Streaming</span>
                                                <button class="edit-mapping-btn" data-role="author">Edit</button>
                                            </div>
                                        </div>
                                        <div class="role-mapping-item">
                                            <div class="wp-role">
                                                <strong>Subscriber</strong>
                                                <span class="role-desc">Basic access</span>
                                            </div>
                                            <div class="mapping-arrow">→</div>
                                            <div class="voicelink-permissions">
                                                <span class="permission-summary">Listen Only</span>
                                                <button class="edit-mapping-btn" data-role="subscriber">Edit</button>
                                            </div>
                                        </div>
                                    </div>
                                    <div class="sync-controls">
                                        <button id="wp-sync-users" class="primary-btn">🔄 Sync All Users</button>
                                        <button id="wp-export-mappings" class="secondary-btn">💾 Export Mappings</button>
                                        <button id="wp-import-mappings" class="secondary-btn">📁 Import Mappings</button>
                                    </div>
                                </div>

                                <div class="wp-sync-status" id="wp-sync-status" style="display:none">
                                    <h4>Last Sync Results</h4>
                                    <div class="sync-summary">
                                        <div class="sync-stat">
                                            <span class="stat-label">Users Processed:</span>
                                            <span class="stat-value" id="sync-processed">0</span>
                                        </div>
                                        <div class="sync-stat">
                                            <span class="stat-label">Users Created:</span>
                                            <span class="stat-value" id="sync-created">0</span>
                                        </div>
                                        <div class="sync-stat">
                                            <span class="stat-label">Users Updated:</span>
                                            <span class="stat-value" id="sync-updated">0</span>
                                        </div>
                                        <div class="sync-stat">
                                            <span class="stat-label">Errors:</span>
                                            <span class="stat-value" id="sync-errors">0</span>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Discord Integration -->
                        <div class="integration-content" data-tab="discord">
                            <div class="discord-integration">
                                <h4>🗨 Discord Bot Integration</h4>
                                <p>Connect VoiceLink to Discord for user role synchronization and bot commands.</p>
                                <div class="form-group">
                                    <label>Discord Bot Token:</label>
                                    <input type="password" id="discord-bot-token" placeholder="Bot token from Discord Developer Portal">
                                </div>
                                <div class="form-group">
                                    <label>Discord Server ID:</label>
                                    <input type="text" id="discord-server-id" placeholder="Discord server (guild) ID">
                                </div>
                                <button id="discord-connect" class="primary-btn">Connect Discord</button>
                            </div>
                        </div>

                        <!-- API Keys -->
                        <div class="integration-content" data-tab="api">
                            <div class="api-keys">
                                <h4>🔑 API Keys & External Services</h4>
                                <div class="api-key-list">
                                    <div class="api-key-item">
                                        <label>Twitch API Key:</label>
                                        <input type="password" placeholder="For Twitch integration">
                                        <button class="test-btn">Test</button>
                                    </div>
                                    <div class="api-key-item">
                                        <label>YouTube API Key:</label>
                                        <input type="password" placeholder="For YouTube integration">
                                        <button class="test-btn">Test</button>
                                    </div>
                                    <div class="api-key-item">
                                        <label>Facebook API Key:</label>
                                        <input type="password" placeholder="For Facebook Live integration">
                                        <button class="test-btn">Test</button>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Webhooks -->
                        <div class="integration-content" data-tab="webhooks">
                            <div class="webhooks">
                                <h4>🔗 Webhook Endpoints</h4>
                                <p>Configure webhooks for real-time integration updates.</p>
                                <div class="webhook-list">
                                    <div class="webhook-item">
                                        <label>User Role Change Webhook:</label>
                                        <input type="url" placeholder="https://yoursite.com/webhook/role-change">
                                        <button class="test-btn">Test</button>
                                    </div>
                                    <div class="webhook-item">
                                        <label>New User Registration Webhook:</label>
                                        <input type="url" placeholder="https://yoursite.com/webhook/new-user">
                                        <button class="test-btn">Test</button>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Security Section -->
                    <div class="admin-section" id="admin-security">
                        <div class="section-header">
                            <h3>Security Management</h3>
                            <div class="section-controls">
                                <button id="security-audit-btn" class="primary-btn">🔒 Audit</button>
                                <button id="ban-manager-btn" class="secondary-btn">🚫 Ban Manager</button>
                            </div>
                        </div>

                        <div class="security-grid">
                            <div class="access-control">
                                <h4>Access Control</h4>
                                <div id="access-control-settings"></div>
                            </div>

                            <div class="security-logs">
                                <h4>Security Logs</h4>
                                <div id="security-logs-list"></div>
                            </div>

                            <div class="banned-users">
                                <h4>Banned Users</h4>
                                <div id="banned-users-list"></div>
                            </div>
                        </div>
                    </div>

                    <!-- System Section -->
                    <div class="admin-section" id="admin-system">
                        <div class="section-header">
                            <h3>System Management</h3>
                            <div class="section-controls">
                                <button id="system-backup-btn" class="primary-btn">💾 Backup</button>
                                <button id="system-restart-btn" class="secondary-btn">🔄 Restart</button>
                            </div>
                        </div>

                        <div class="system-info-grid">
                            <div class="system-status">
                                <h4>System Status</h4>
                                <div id="system-status-info"></div>
                            </div>

                            <div class="system-logs">
                                <h4>System Logs</h4>
                                <div id="system-logs-list"></div>
                            </div>

                            <div class="system-settings">
                                <h4>System Settings</h4>
                                <div id="system-settings-panel"></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;

        document.body.appendChild(adminPanel);
        this.adminPanel = adminPanel;

        // Setup admin panel event handlers
        this.setupAdminPanelHandlers();
    }

    setupAdminPanelHandlers() {
        // Navigation
        const navItems = this.adminPanel.querySelectorAll('.nav-item');
        navItems.forEach(item => {
            item.addEventListener('click', () => {
                const section = item.dataset.section;
                this.switchAdminSection(section);

                navItems.forEach(nav => nav.classList.remove('active'));
                item.classList.add('active');
            });
        });

        // Context switching
        const contextSelector = document.getElementById('admin-context-selector');
        contextSelector.addEventListener('change', (e) => {
            this.switchAdminContext(e.target.value);
        });

        // Close admin panel
        document.getElementById('admin-close').addEventListener('click', () => {
            this.hideAdminPanel();
        });

        // Admin hotkey (Ctrl+Shift+A)
        document.addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.shiftKey && e.code === 'KeyA') {
                e.preventDefault();
                this.toggleAdminPanel();
            }
        });
    }

    setupContextSwitching() {
        // Handle switching between local and remote server contexts
        this.contextSwitchHandlers = new Map();

        // Local context handler
        this.contextSwitchHandlers.set('local', () => {
            this.currentContext = {
                type: 'local',
                capabilities: this.capabilities.local,
                adminSession: this.createLocalAdminSession()
            };
        });

        // Remote context handlers (added when servers connect)
        this.serverAccessManager.connectedServers.forEach((connection, serverId) => {
            this.addRemoteContext(serverId, connection);
        });
    }

    addRemoteContext(serverId, connection) {
        const serverInfo = connection.serverInfo;

        // Add to context selector
        const contextSelector = document.getElementById('admin-context-selector');
        const option = document.createElement('option');
        option.value = serverId;
        option.textContent = `${serverInfo.name} (Remote)`;
        contextSelector.appendChild(option);

        // Create context switch handler
        this.contextSwitchHandlers.set(serverId, () => {
            this.currentContext = {
                type: 'remote',
                serverId,
                serverInfo,
                connection,
                capabilities: this.capabilities.remote.get(serverId) || new Set(),
                adminSession: this.createRemoteAdminSession(serverId, connection)
            };
        });

        // Request remote capabilities
        this.requestRemoteCapabilities(serverId, connection);
    }

    createLocalAdminSession() {
        return {
            type: 'local',

            // User management
            getUsers: () => this.getLocalUsers(),
            createUser: (userData) => this.createLocalUser(userData),
            updateUser: (userId, updates) => this.updateLocalUser(userId, updates),
            deleteUser: (userId) => this.deleteLocalUser(userId),

            // Room management
            getRooms: () => this.getLocalRooms(),
            createRoom: (roomData) => this.createLocalRoom(roomData),
            updateRoom: (roomId, updates) => this.updateLocalRoom(roomId, updates),
            deleteRoom: (roomId) => this.deleteLocalRoom(roomId),

            // Audio system
            getAudioDevices: () => this.audioEngine.getDevices(),
            setAudioSettings: (settings) => this.audioEngine.updateSettings(settings),
            getChannelMatrix: () => this.multiChannelEngine.getAllChannelStates(),
            setChannelRouting: (input, output, gain) => this.multiChannelEngine.routeInputToOutput(input, output, gain),

            // VST management
            getVSTPlugins: () => this.vstEngine.getAvailablePlugins(),
            getVSTInstances: () => this.vstEngine.getUserVSTInstances('local'),
            createVSTInstance: (pluginName, channelId) => this.vstEngine.createVSTInstance(pluginName, 'local', channelId),

            // System info
            getSystemInfo: () => this.getLocalSystemInfo(),
            getSystemLogs: () => this.getLocalSystemLogs()
        };
    }

    createRemoteAdminSession(serverId, connection) {
        return {
            type: 'remote',
            serverId,
            socket: connection.socket,

            // Remote admin commands
            executeCommand: (command, params) => this.executeRemoteCommand(serverId, command, params),

            // User management
            getUsers: () => this.executeRemoteCommand(serverId, 'admin:get_users'),
            createUser: (userData) => this.executeRemoteCommand(serverId, 'admin:create_user', userData),
            updateUser: (userId, updates) => this.executeRemoteCommand(serverId, 'admin:update_user', { userId, updates }),
            deleteUser: (userId) => this.executeRemoteCommand(serverId, 'admin:delete_user', { userId }),

            // Room management
            getRooms: () => this.executeRemoteCommand(serverId, 'admin:get_rooms'),
            createRoom: (roomData) => this.executeRemoteCommand(serverId, 'admin:create_room', roomData),
            updateRoom: (roomId, updates) => this.executeRemoteCommand(serverId, 'admin:update_room', { roomId, updates }),
            deleteRoom: (roomId) => this.executeRemoteCommand(serverId, 'admin:delete_room', { roomId }),

            // Audio system
            getAudioDevices: () => this.executeRemoteCommand(serverId, 'admin:get_audio_devices'),
            setAudioSettings: (settings) => this.executeRemoteCommand(serverId, 'admin:set_audio_settings', settings),
            getChannelMatrix: () => this.executeRemoteCommand(serverId, 'admin:get_channel_matrix'),
            setChannelRouting: (input, output, gain) => this.executeRemoteCommand(serverId, 'admin:set_channel_routing', { input, output, gain }),

            // VST management
            getVSTPlugins: () => this.executeRemoteCommand(serverId, 'admin:get_vst_plugins'),
            getVSTInstances: () => this.executeRemoteCommand(serverId, 'admin:get_vst_instances'),
            createVSTInstance: (pluginName, channelId) => this.executeRemoteCommand(serverId, 'admin:create_vst_instance', { pluginName, channelId }),

            // System info
            getSystemInfo: () => this.executeRemoteCommand(serverId, 'admin:get_system_info'),
            getSystemLogs: () => this.executeRemoteCommand(serverId, 'admin:get_system_logs')
        };
    }

    async executeRemoteCommand(serverId, command, params = {}) {
        const connection = this.serverAccessManager.connectedServers.get(serverId);
        if (!connection) {
            throw new Error('Server not connected');
        }

        return new Promise((resolve, reject) => {
            const commandId = `admin_${Date.now()}_${Math.random().toString(36).slice(2)}`;

            const timeout = setTimeout(() => {
                connection.socket.off(`admin_response_${commandId}`);
                reject(new Error('Command timeout'));
            }, 10000);

            connection.socket.once(`admin_response_${commandId}`, (response) => {
                clearTimeout(timeout);
                if (response.success) {
                    resolve(response.data);
                } else {
                    reject(new Error(response.error));
                }
            });

            connection.socket.emit('admin_command', {
                commandId,
                command,
                params
            });
        });
    }

    async switchAdminContext(contextId) {
        const handler = this.contextSwitchHandlers.get(contextId);
        if (handler) {
            await handler();

            // Update UI to reflect context
            this.updateAdminContextUI();

            // Refresh admin data for new context
            this.refreshAdminData();

            console.log(`Switched admin context to: ${contextId}`);
        }
    }

    updateAdminContextUI() {
        if (!this.currentContext) return;

        // Update context indicator
        const syncStatus = document.getElementById('admin-sync-status');
        if (this.currentContext.type === 'local') {
            syncStatus.textContent = '🏠 Local';
            syncStatus.className = 'sync-status local';
        } else {
            syncStatus.textContent = '🌐 Remote';
            syncStatus.className = 'sync-status remote';
        }

        // Show/hide features based on capabilities
        this.updateCapabilityUI();
    }

    updateCapabilityUI() {
        const capabilities = this.currentContext.capabilities;

        // Show/hide admin sections based on capabilities
        const sections = {
            'audio': capabilities.has('audio_routing'),
            'channels': capabilities.has('multi_channel_control'),
            'vst': capabilities.has('vst_management'),
            'network': capabilities.has('network_management'),
            'security': capabilities.has('security_management'),
            'system': capabilities.has('system_management')
        };

        Object.entries(sections).forEach(([section, enabled]) => {
            const navItem = document.querySelector(`[data-section="${section}"]`);
            const sectionElement = document.getElementById(`admin-${section}`);

            if (navItem && sectionElement) {
                navItem.style.display = enabled ? 'block' : 'none';
                if (!enabled && sectionElement.classList.contains('active')) {
                    // Switch to dashboard if current section is disabled
                    this.switchAdminSection('dashboard');
                }
            }
        });
    }

    setupRealtimeSync() {
        // Setup real-time synchronization between local and remote admin interfaces
        setInterval(() => {
            this.syncAdminData();
        }, 5000);

        // Setup bidirectional sync handlers
        this.setupSyncHandlers();
    }

    setupSyncHandlers() {
        // Listen for remote admin changes
        document.addEventListener('voicelink-remote-admin-change', (event) => {
            const { serverId, type, data } = event.detail;
            this.handleRemoteAdminChange(serverId, type, data);
        });

        // Listen for local admin changes
        document.addEventListener('voicelink-local-admin-change', (event) => {
            const { type, data } = event.detail;
            this.handleLocalAdminChange(type, data);
        });
    }

    async syncAdminData() {
        if (!this.currentContext || this.currentContext.type === 'local') return;

        const serverId = this.currentContext.serverId;
        const lastSyncTime = this.lastSync.get(serverId) || 0;

        try {
            // Get incremental changes since last sync
            const changes = await this.executeRemoteCommand(serverId, 'admin:get_changes', {
                since: lastSyncTime
            });

            if (changes && changes.length > 0) {
                this.applyRemoteChanges(serverId, changes);
                this.lastSync.set(serverId, Date.now());
            }

            // Update sync status UI
            this.updateSyncStatus('synced');

        } catch (error) {
            console.error('Failed to sync admin data:', error);
            this.updateSyncStatus('error');
        }
    }

    applyRemoteChanges(serverId, changes) {
        changes.forEach(change => {
            switch (change.type) {
                case 'user_update':
                    this.updateUserInUI(change.data);
                    break;
                case 'room_update':
                    this.updateRoomInUI(change.data);
                    break;
                case 'audio_setting_change':
                    this.updateAudioSettingInUI(change.data);
                    break;
                case 'vst_instance_change':
                    this.updateVSTInstanceInUI(change.data);
                    break;
                default:
                    console.log('Unknown change type:', change.type);
            }
        });
    }

    // Admin Panel Display Methods

    showAdminPanel() {
        this.adminPanel.classList.remove('hidden');
        document.body.classList.add('admin-open');

        // Initialize with dashboard if no context
        if (!this.currentContext) {
            this.switchAdminContext('local');
        }

        this.refreshAdminData();
    }

    hideAdminPanel() {
        this.adminPanel.classList.add('hidden');
        document.body.classList.remove('admin-open');
    }

    toggleAdminPanel() {
        if (this.adminPanel.classList.contains('hidden')) {
            this.showAdminPanel();
        } else {
            this.hideAdminPanel();
        }
    }

    switchAdminSection(sectionName) {
        // Hide all sections
        const sections = this.adminPanel.querySelectorAll('.admin-section');
        sections.forEach(section => section.classList.remove('active'));

        // Show target section
        const targetSection = document.getElementById(`admin-${sectionName}`);
        if (targetSection) {
            targetSection.classList.add('active');

            // Load section data
            this.loadAdminSectionData(sectionName);
        }
    }

    async loadAdminSectionData(sectionName) {
        if (!this.currentContext) return;

        const session = this.currentContext.adminSession;

        try {
            switch (sectionName) {
                case 'dashboard':
                    await this.loadDashboardData(session);
                    break;
                case 'users':
                    await this.loadUsersData(session);
                    break;
                case 'rooms':
                    await this.loadRoomsData(session);
                    break;
                case 'audio':
                    await this.loadAudioData(session);
                    break;
                case 'channels':
                    await this.loadChannelMatrixData(session);
                    break;
                case 'vst':
                    await this.loadVSTData(session);
                    break;
                case 'network':
                    await this.loadNetworkData(session);
                    break;
                case 'security':
                    await this.loadSecurityData(session);
                    break;
                case 'system':
                    await this.loadSystemData(session);
                    break;
            }
        } catch (error) {
            console.error(`Failed to load ${sectionName} data:`, error);
            this.showAdminError(`Failed to load ${sectionName} data: ${error.message}`);
        }
    }

    async loadDashboardData(session) {
        // Load dashboard overview data
        const [systemInfo, users, rooms] = await Promise.all([
            session.getSystemInfo(),
            session.getUsers(),
            session.getRooms()
        ]);

        // Update dashboard UI
        document.getElementById('total-users').textContent = users.length;
        document.getElementById('server-uptime').textContent = this.formatUptime(systemInfo.uptime);
        document.getElementById('server-cpu').textContent = `${systemInfo.cpu}%`;
        document.getElementById('server-memory').textContent = `${systemInfo.memory}%`;

        if (this.vstEngine) {
            const vstInstances = await session.getVSTInstances();
            document.getElementById('active-vsts').textContent = vstInstances.length;
        }

        // Update activity log
        this.updateActivityLog();
    }

    async loadUsersData(session) {
        const users = await session.getUsers();
        this.renderUsersList(users);
    }

    async loadRoomsData(session) {
        const rooms = await session.getRooms();
        this.renderRoomsList(rooms);
    }

    async loadAudioData(session) {
        const devices = await session.getAudioDevices();
        this.renderAudioDevices(devices);
    }

    async loadChannelMatrixData(session) {
        const channelStates = await session.getChannelMatrix();
        this.renderChannelMatrix(channelStates);
    }

    async loadVSTData(session) {
        const [plugins, instances] = await Promise.all([
            session.getVSTPlugins(),
            session.getVSTInstances()
        ]);
        this.renderVSTManagement(plugins, instances);
    }

    // Utility methods for local admin operations
    getLocalUsers() {
        // Return local users (from current session)
        return Array.from(window.voiceLinkApp?.users?.values() || []);
    }

    getLocalRooms() {
        // Return local rooms
        return window.voiceLinkApp?.currentRoom ? [window.voiceLinkApp.currentRoom] : [];
    }

    getLocalSystemInfo() {
        return {
            uptime: Date.now() - (window.voiceLinkApp?.startTime || Date.now()),
            cpu: Math.random() * 20 + 10, // Mock CPU usage
            memory: Math.random() * 30 + 20, // Mock memory usage
            version: '1.0.0',
            platform: navigator.platform
        };
    }

    // UI Helper Methods
    formatUptime(uptimeMs) {
        const seconds = Math.floor(uptimeMs / 1000);
        const minutes = Math.floor(seconds / 60);
        const hours = Math.floor(minutes / 60);
        const days = Math.floor(hours / 24);

        if (days > 0) return `${days}d ${hours % 24}h`;
        if (hours > 0) return `${hours}h ${minutes % 60}m`;
        return `${minutes}m ${seconds % 60}s`;
    }

    updateSyncStatus(status) {
        const syncButton = document.getElementById('admin-sync-status');
        if (syncButton) {
            switch (status) {
                case 'synced':
                    syncButton.innerHTML = '🔄 Synced';
                    syncButton.className = 'sync-status synced';
                    break;
                case 'syncing':
                    syncButton.innerHTML = '⏳ Syncing...';
                    syncButton.className = 'sync-status syncing';
                    break;
                case 'error':
                    syncButton.innerHTML = '❌ Sync Error';
                    syncButton.className = 'sync-status error';
                    break;
            }
        }
    }

    showAdminError(message) {
        // Show error notification in admin panel
        console.error('Admin Error:', message);
    }

    async refreshAdminData() {
        // Refresh all data in current admin section
        const activeSection = this.adminPanel.querySelector('.admin-section.active');
        if (activeSection) {
            const sectionName = activeSection.id.replace('admin-', '');
            await this.loadAdminSectionData(sectionName);
        }
    }

    // Server connection handlers
    setupServerConnectionHandlers() {
        document.addEventListener('voicelink-connection-status', (event) => {
            const { serverId, status } = event.detail;

            if (status === 'connected') {
                const connection = this.serverAccessManager.connectedServers.get(serverId);
                if (connection) {
                    this.addRemoteContext(serverId, connection);
                }
            } else if (status === 'disconnected') {
                this.removeRemoteContext(serverId);
            }
        });
    }

    removeRemoteContext(serverId) {
        // Remove from context selector
        const contextSelector = document.getElementById('admin-context-selector');
        const option = contextSelector.querySelector(`option[value="${serverId}"]`);
        if (option) {
            option.remove();
        }

        // Remove context handler
        this.contextSwitchHandlers.delete(serverId);

        // Switch to local if currently on this server
        if (this.currentContext && this.currentContext.serverId === serverId) {
            this.switchAdminContext('local');
        }
    }

    async requestRemoteCapabilities(serverId, connection) {
        try {
            const capabilities = await this.executeRemoteCommand(serverId, 'admin:get_capabilities');
            this.capabilities.remote.set(serverId, new Set(capabilities));

            console.log(`Remote capabilities for ${serverId}:`, capabilities);
        } catch (error) {
            console.error(`Failed to get remote capabilities for ${serverId}:`, error);
        }
    }
}

// Export for use in other modules
window.UnifiedAdminInterface = UnifiedAdminInterface;