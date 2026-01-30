/**
 * Media Streaming Interface
 * Unified interface for Jellyfin and live streaming management
 */

class MediaStreamingInterface {
    constructor() {
        this.isVisible = false;
        this.currentTab = 'jellyfin';
        this.jellyfinManager = null;
        this.liveStreamingManager = null;

        // UI state
        this.selectedServer = null;
        this.selectedLibrary = null;
        this.currentPlaylist = [];
        this.searchResults = [];

        this.init();
    }

    init() {
        // Initialize managers
        this.jellyfinManager = new JellyfinManager();
        this.liveStreamingManager = new LiveStreamingManager();

        // Create interface
        this.createInterface();
        this.setupEventListeners();

        console.log('Media Streaming Interface initialized');
    }

    createInterface() {
        // Create main container
        const container = document.createElement('div');
        container.id = 'media-streaming-interface';
        container.className = 'streaming-interface hidden';
        container.innerHTML = this.getInterfaceHTML();

        document.body.appendChild(container);
        this.container = container;
    }

    getInterfaceHTML() {
        return `
            <div class="streaming-overlay">
                <div class="streaming-modal">
                    <div class="streaming-header">
                        <h2>🎵 Media Streaming</h2>
                        <button class="close-btn" id="close-streaming-interface">✕</button>
                    </div>

                    <div class="streaming-tabs">
                        <button class="tab-btn active" data-tab="jellyfin">📚 Jellyfin</button>
                        <button class="tab-btn" data-tab="live-streams">📡 Live Streams</button>
                        <button class="tab-btn" data-tab="now-playing">🎵 Now Playing</button>
                        <button class="tab-btn" data-tab="settings">⚙️ Settings</button>
                    </div>

                    <div class="streaming-content">
                        <!-- Jellyfin Tab -->
                        <div class="tab-content active" id="jellyfin-tab">
                            <div class="jellyfin-section">
                                <div class="server-controls">
                                    <h3>Jellyfin Servers</h3>
                                    <div class="server-list" id="jellyfin-server-list">
                                        <p class="no-servers">No servers configured</p>
                                    </div>
                                    <button class="add-btn" id="add-jellyfin-server">+ Add Server</button>
                                </div>

                                <div class="library-browser" id="jellyfin-browser" style="display: none;">
                                    <div class="browser-header">
                                        <select id="library-selector">
                                            <option value="">Select Library</option>
                                        </select>
                                        <input type="text" id="jellyfin-search" placeholder="Search media...">
                                        <button id="jellyfin-search-btn">🔍</button>
                                    </div>

                                    <div class="media-grid" id="jellyfin-media-grid">
                                        <!-- Media items will be populated here -->
                                    </div>

                                    <div class="pagination" id="jellyfin-pagination">
                                        <!-- Pagination controls -->
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Live Streams Tab -->
                        <div class="tab-content" id="live-streams-tab">
                            <div class="streams-section">
                                <div class="stream-controls">
                                    <h3>Live Streams</h3>
                                    <div class="stream-list" id="live-stream-list">
                                        <p class="no-streams">No streams configured</p>
                                    </div>
                                    <button class="add-btn" id="add-live-stream">+ Add Stream</button>
                                </div>

                                <div class="stream-categories">
                                    <h4>Popular Streams</h4>
                                    <div class="category-grid" id="popular-streams">
                                        <!-- Popular stream templates -->
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Now Playing Tab -->
                        <div class="tab-content" id="now-playing-tab">
                            <div class="now-playing-section">
                                <div class="current-track" id="current-track-info">
                                    <div class="track-artwork">
                                        <div class="artwork-placeholder">🎵</div>
                                    </div>
                                    <div class="track-details">
                                        <h3 class="track-title">No media playing</h3>
                                        <p class="track-artist">Select something to play</p>
                                        <p class="track-album"></p>
                                    </div>
                                </div>

                                <div class="playback-controls">
                                    <button id="prev-btn">⏮️</button>
                                    <button id="play-pause-btn">▶️</button>
                                    <button id="next-btn">⏭️</button>
                                    <button id="stop-btn">⏹️</button>
                                </div>

                                <div class="volume-control">
                                    <span>🔊</span>
                                    <input type="range" id="media-volume" min="0" max="100" value="80">
                                    <span id="volume-display">80%</span>
                                </div>

                                <div class="progress-control">
                                    <span id="current-time">0:00</span>
                                    <input type="range" id="progress-bar" min="0" max="100" value="0">
                                    <span id="total-time">0:00</span>
                                </div>

                                <div class="visualization" id="audio-visualization">
                                    <canvas id="visualizer-canvas" width="400" height="100"></canvas>
                                </div>

                                <div class="playlist" id="current-playlist">
                                    <h4>Queue</h4>
                                    <div class="playlist-items">
                                        <p class="empty-playlist">Queue is empty</p>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <!-- Settings Tab -->
                        <div class="tab-content" id="settings-tab">
                            <div class="settings-section">
                                <h3>Streaming Settings</h3>

                                <div class="setting-group">
                                    <h4>Audio Quality</h4>
                                    <select id="default-quality">
                                        <option value="low">Low (64kbps)</option>
                                        <option value="medium" selected>Medium (128kbps)</option>
                                        <option value="high">High (192kbps)</option>
                                        <option value="ultra">Ultra (320kbps)</option>
                                    </select>
                                </div>

                                <div class="setting-group">
                                    <h4>Playback</h4>
                                    <label>
                                        <input type="checkbox" id="crossfade-enabled">
                                        Enable crossfading between tracks
                                    </label>
                                    <label>
                                        <input type="checkbox" id="auto-play-next" checked>
                                        Auto-play next track in queue
                                    </label>
                                    <label>
                                        <input type="checkbox" id="save-queue" checked>
                                        Remember queue between sessions
                                    </label>
                                </div>

                                <div class="setting-group">
                                    <h4>Integration</h4>
                                    <label>
                                        <input type="checkbox" id="spatial-audio-media" checked>
                                        Apply 3D spatial audio to media
                                    </label>
                                    <label>
                                        <input type="checkbox" id="ducking-media">
                                        Auto-duck media during voice chat
                                    </label>
                                </div>

                                <div class="setting-group">
                                    <h4>Cache & Storage</h4>
                                    <label>Cache Size: <span id="cache-size-display">100MB</span></label>
                                    <input type="range" id="cache-size" min="50" max="1000" value="100">
                                    <button id="clear-cache">Clear Cache</button>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Add Server Modal -->
            <div class="modal-overlay hidden" id="add-server-modal">
                <div class="modal-content">
                    <h3>Add Jellyfin Server</h3>
                    <form id="add-server-form">
                        <div class="input-group">
                            <label>Server Name</label>
                            <input type="text" id="server-name" placeholder="My Jellyfin Server" required>
                        </div>
                        <div class="input-group">
                            <label>Server URL</label>
                            <input type="url" id="server-url" placeholder="http://localhost:8096" required>
                        </div>
                        <div class="input-group">
                            <label>Username</label>
                            <input type="text" id="server-username" required>
                        </div>
                        <div class="input-group">
                            <label>Password</label>
                            <input type="password" id="server-password" required>
                        </div>
                        <div class="button-group">
                            <button type="submit">Add Server</button>
                            <button type="button" id="cancel-add-server">Cancel</button>
                        </div>
                    </form>
                </div>
            </div>

            <!-- Add Stream Modal -->
            <div class="modal-overlay hidden" id="add-stream-modal">
                <div class="modal-content">
                    <h3>Add Live Stream</h3>
                    <form id="add-stream-form">
                        <div class="input-group">
                            <label>Stream Name</label>
                            <input type="text" id="stream-name" placeholder="My Radio Station" required>
                        </div>
                        <div class="input-group">
                            <label>Stream URL</label>
                            <input type="url" id="stream-url" placeholder="http://example.com:8000/stream" required>
                        </div>
                        <div class="input-group">
                            <label>Stream Type</label>
                            <select id="stream-type">
                                <option value="auto">Auto-detect</option>
                                <option value="icecast">Icecast</option>
                                <option value="shoutcast">Shoutcast</option>
                                <option value="generic">Generic</option>
                            </select>
                        </div>
                        <div class="input-group">
                            <label>Genre</label>
                            <input type="text" id="stream-genre" placeholder="Music, Talk, News...">
                        </div>
                        <div class="input-group">
                            <label>Description</label>
                            <textarea id="stream-description" placeholder="Optional description"></textarea>
                        </div>
                        <div class="button-group">
                            <button type="submit">Add Stream</button>
                            <button type="button" id="cancel-add-stream">Cancel</button>
                        </div>
                    </form>
                </div>
            </div>
        `;
    }

    setupEventListeners() {
        // Tab switching
        this.container.querySelectorAll('.tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                this.switchTab(e.target.dataset.tab);
            });
        });

        // Close interface
        this.container.querySelector('#close-streaming-interface').addEventListener('click', () => {
            this.hide();
        });

        // Jellyfin controls
        this.container.querySelector('#add-jellyfin-server').addEventListener('click', () => {
            this.showAddServerModal();
        });

        // Live stream controls
        this.container.querySelector('#add-live-stream').addEventListener('click', () => {
            this.showAddStreamModal();
        });

        // Modal handlers
        this.setupModalHandlers();

        // Playback controls
        this.setupPlaybackControls();

        // Settings handlers
        this.setupSettingsHandlers();

        // Listen for external events
        this.setupExternalEventListeners();
    }

    setupModalHandlers() {
        // Add server modal
        const addServerModal = document.getElementById('add-server-modal');
        const addServerForm = document.getElementById('add-server-form');
        const cancelAddServer = document.getElementById('cancel-add-server');

        addServerForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            await this.handleAddServer();
        });

        cancelAddServer.addEventListener('click', () => {
            addServerModal.classList.add('hidden');
        });

        // Add stream modal
        const addStreamModal = document.getElementById('add-stream-modal');
        const addStreamForm = document.getElementById('add-stream-form');
        const cancelAddStream = document.getElementById('cancel-add-stream');

        addStreamForm.addEventListener('submit', async (e) => {
            e.preventDefault();
            await this.handleAddStream();
        });

        cancelAddStream.addEventListener('click', () => {
            addStreamModal.classList.add('hidden');
        });
    }

    setupPlaybackControls() {
        const playPauseBtn = this.container.querySelector('#play-pause-btn');
        const stopBtn = this.container.querySelector('#stop-btn');
        const volumeSlider = this.container.querySelector('#media-volume');

        playPauseBtn.addEventListener('click', () => {
            this.togglePlayPause();
        });

        stopBtn.addEventListener('click', () => {
            this.stopPlayback();
        });

        volumeSlider.addEventListener('input', (e) => {
            this.setVolume(e.target.value / 100);
        });
    }

    setupSettingsHandlers() {
        // Quality setting
        this.container.querySelector('#default-quality').addEventListener('change', (e) => {
            this.saveSettings();
        });

        // Checkboxes
        this.container.querySelectorAll('#settings-tab input[type="checkbox"]').forEach(checkbox => {
            checkbox.addEventListener('change', () => {
                this.saveSettings();
            });
        });

        // Cache controls
        this.container.querySelector('#clear-cache').addEventListener('click', () => {
            this.clearCache();
        });
    }

    setupExternalEventListeners() {
        // Listen for Jellyfin events
        window.addEventListener('jellyfinConnectionChanged', (e) => {
            this.handleJellyfinConnection(e.detail);
        });

        // Listen for live stream events
        window.addEventListener('liveStreamEvent', (e) => {
            this.handleLiveStreamEvent(e.detail);
        });

        // Listen for visualization data
        window.addEventListener('streamVisualization', (e) => {
            this.updateVisualization(e.detail);
        });
    }

    // Interface methods
    show() {
        this.container.classList.remove('hidden');
        this.isVisible = true;
        this.refreshContent();
    }

    hide() {
        this.container.classList.add('hidden');
        this.isVisible = false;
    }

    switchTab(tabName) {
        // Update tab buttons
        this.container.querySelectorAll('.tab-btn').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.tab === tabName);
        });

        // Update tab content
        this.container.querySelectorAll('.tab-content').forEach(content => {
            content.classList.toggle('active', content.id === `${tabName}-tab`);
        });

        this.currentTab = tabName;
        this.refreshTabContent(tabName);
    }

    refreshContent() {
        this.refreshTabContent(this.currentTab);
    }

    refreshTabContent(tabName) {
        switch (tabName) {
            case 'jellyfin':
                this.refreshJellyfinTab();
                break;
            case 'live-streams':
                this.refreshLiveStreamsTab();
                break;
            case 'now-playing':
                this.refreshNowPlayingTab();
                break;
            case 'settings':
                this.refreshSettingsTab();
                break;
        }
    }

    // Jellyfin tab methods
    refreshJellyfinTab() {
        const serverList = this.container.querySelector('#jellyfin-server-list');
        const servers = this.jellyfinManager.getConnectedServers();

        if (servers.length === 0) {
            serverList.innerHTML = '<p class="no-servers">No servers configured</p>';
        } else {
            serverList.innerHTML = servers.map(server => `
                <div class="server-item" data-server-id="${server.id}">
                    <div class="server-info">
                        <h4>${server.name}</h4>
                        <p>${server.url}</p>
                        <span class="status ${server.isActive ? 'connected' : 'disconnected'}">
                            ${server.isActive ? '🟢 Connected' : '🔴 Disconnected'}
                        </span>
                    </div>
                    <div class="server-controls">
                        <button class="connect-btn" ${server.isActive ? 'disabled' : ''}>
                            ${server.isActive ? 'Connected' : 'Connect'}
                        </button>
                        <button class="remove-btn">Remove</button>
                    </div>
                </div>
            `).join('');
        }
    }

    // Live streams tab methods
    refreshLiveStreamsTab() {
        const streamList = this.container.querySelector('#live-stream-list');
        const streams = this.liveStreamingManager.getStreams();

        if (streams.length === 0) {
            streamList.innerHTML = '<p class="no-streams">No streams configured</p>';
        } else {
            streamList.innerHTML = streams.map(stream => `
                <div class="stream-item" data-stream-id="${stream.id}">
                    <div class="stream-info">
                        <h4>${stream.name}</h4>
                        <p>${stream.url}</p>
                        <span class="type">${stream.type}</span>
                        <span class="status ${stream.isActive ? 'playing' : 'stopped'}">
                            ${stream.isActive ? '🎵 Playing' : '⏸️ Stopped'}
                        </span>
                    </div>
                    <div class="stream-controls">
                        <button class="play-btn">
                            ${stream.isActive ? '⏸️ Pause' : '▶️ Play'}
                        </button>
                        <button class="remove-btn">Remove</button>
                    </div>
                </div>
            `).join('');
        }

        this.populatePopularStreams();
    }

    populatePopularStreams() {
        const popularContainer = this.container.querySelector('#popular-streams');
        const popularStreams = [
            { name: 'BBC Radio 1', url: 'http://bbcmedia.ic.llnwd.net/stream/bbcmedia_radio1_mf_p', type: 'bbc' },
            { name: 'NPR News', url: 'https://npr-ice.streamguys1.com/live.mp3', type: 'news' },
            { name: 'Classical KUSC', url: 'https://kusc-ice.streamguys1.com/kusc-128-mp3', type: 'classical' },
            { name: 'Jazz24', url: 'https://live.wostreaming.net/direct/ppm-jazz24mp3-ibc3', type: 'jazz' }
        ];

        popularContainer.innerHTML = popularStreams.map(stream => `
            <div class="popular-stream" data-url="${stream.url}">
                <h5>${stream.name}</h5>
                <button class="quick-add-btn">+ Add</button>
            </div>
        `).join('');
    }

    // Modal handlers
    showAddServerModal() {
        document.getElementById('add-server-modal').classList.remove('hidden');
    }

    showAddStreamModal() {
        document.getElementById('add-stream-modal').classList.remove('hidden');
    }

    async handleAddServer() {
        const form = document.getElementById('add-server-form');
        const formData = new FormData(form);

        const config = {
            name: document.getElementById('server-name').value,
            url: document.getElementById('server-url').value,
            username: document.getElementById('server-username').value,
            password: document.getElementById('server-password').value
        };

        try {
            await this.jellyfinManager.addServer(config);
            document.getElementById('add-server-modal').classList.add('hidden');
            form.reset();
            this.refreshJellyfinTab();
            this.showSuccess('Jellyfin server added successfully');
        } catch (error) {
            this.showError(`Failed to add server: ${error.message}`);
        }
    }

    async handleAddStream() {
        const form = document.getElementById('add-stream-form');

        const config = {
            name: document.getElementById('stream-name').value,
            url: document.getElementById('stream-url').value,
            type: document.getElementById('stream-type').value === 'auto' ? undefined : document.getElementById('stream-type').value,
            genre: document.getElementById('stream-genre').value,
            description: document.getElementById('stream-description').value
        };

        try {
            await this.liveStreamingManager.addStream(config);
            document.getElementById('add-stream-modal').classList.add('hidden');
            form.reset();
            this.refreshLiveStreamsTab();
            this.showSuccess('Live stream added successfully');
        } catch (error) {
            this.showError(`Failed to add stream: ${error.message}`);
        }
    }

    // Utility methods
    showSuccess(message) {
        console.log('Success:', message);
        // In a real implementation, show a toast notification
    }

    showError(message) {
        console.error('Error:', message);
        // In a real implementation, show an error notification
    }

    saveSettings() {
        const settings = {
            defaultQuality: this.container.querySelector('#default-quality').value,
            crossfadeEnabled: this.container.querySelector('#crossfade-enabled').checked,
            autoPlayNext: this.container.querySelector('#auto-play-next').checked,
            saveQueue: this.container.querySelector('#save-queue').checked,
            spatialAudioMedia: this.container.querySelector('#spatial-audio-media').checked,
            duckingMedia: this.container.querySelector('#ducking-media').checked,
            cacheSize: this.container.querySelector('#cache-size').value
        };

        localStorage.setItem('voicelink_media_settings', JSON.stringify(settings));
        console.log('Media settings saved');
    }

    loadSettings() {
        try {
            const saved = localStorage.getItem('voicelink_media_settings');
            if (saved) {
                const settings = JSON.parse(saved);

                // Apply saved settings to UI
                Object.entries(settings).forEach(([key, value]) => {
                    const element = this.container.querySelector(`#${key.replace(/([A-Z])/g, '-$1').toLowerCase()}`);
                    if (element) {
                        if (element.type === 'checkbox') {
                            element.checked = value;
                        } else {
                            element.value = value;
                        }
                    }
                });
            }
        } catch (error) {
            console.error('Failed to load media settings:', error);
        }
    }

    // Cleanup
    destroy() {
        if (this.jellyfinManager) {
            this.jellyfinManager.destroy();
        }
        if (this.liveStreamingManager) {
            this.liveStreamingManager.destroy();
        }
        if (this.container) {
            this.container.remove();
        }
    }
}

// Export for use in other modules
window.MediaStreamingInterface = MediaStreamingInterface;