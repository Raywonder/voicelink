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
                                    <div class="server-actions" style="display: flex; gap: 10px; margin-bottom: 15px;">
                                        <button class="discover-btn" id="discover-jellyfin-servers" aria-label="Search for Jellyfin servers on network">Search Network</button>
                                        <button class="add-btn" id="add-jellyfin-server" aria-label="Manually add a Jellyfin server">+ Add Manually</button>
                                    </div>
                                    <div id="discovery-status" class="discovery-status" style="display: none;"></div>
                                    <div class="server-list" id="jellyfin-server-list">
                                        <p class="no-servers">No servers configured</p>
                                    </div>
                                    <div id="discovered-servers" class="discovered-servers" style="display: none;">
                                        <h4>Discovered Servers</h4>
                                        <div id="discovered-server-list"></div>
                                    </div>
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
                            <label for="server-name">Server Name</label>
                            <input type="text" id="server-name" placeholder="My Jellyfin Server" required aria-describedby="server-name-hint">
                            <small id="server-name-hint" style="color: #888;">A friendly name for this server</small>
                        </div>
                        <div class="input-group">
                            <label for="server-url">Server URL</label>
                            <input type="text" id="server-url" placeholder="http://192.168.1.100:8096" required aria-describedby="server-url-hint">
                            <small id="server-url-hint" style="color: #888;">The full URL to your Jellyfin server</small>
                        </div>
                        <div class="input-group">
                            <label for="server-api-key">API Key</label>
                            <input type="password" id="server-api-key" placeholder="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" required aria-describedby="api-key-hint">
                            <small id="api-key-hint" style="color: #888;">Generate in Jellyfin: Dashboard > API Keys > New</small>
                        </div>
                        <div id="server-validation-status" class="validation-status"></div>
                        <div class="button-group">
                            <button type="button" id="test-server-connection">Test Connection</button>
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
        this.container.querySelector('#discover-jellyfin-servers').addEventListener('click', () => {
            this.discoverJellyfinServers();
        });

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

        // Test connection button
        const testConnectionBtn = document.getElementById('test-server-connection');
        if (testConnectionBtn) {
            testConnectionBtn.addEventListener('click', () => {
                this.testServerConnection();
            });
        }

        cancelAddServer.addEventListener('click', () => {
            addServerModal.classList.add('hidden');
            document.getElementById('server-validation-status').textContent = '';
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
    async refreshJellyfinTab() {
        const serverList = this.container.querySelector('#jellyfin-server-list');

        // Load servers from server-side API
        const servers = await this.loadServersFromAPI();

        if (servers.length === 0) {
            serverList.textContent = '';
            const noServers = document.createElement('p');
            noServers.className = 'no-servers';
            noServers.textContent = 'No servers configured. Search network or add manually.';
            serverList.appendChild(noServers);
        } else {
            serverList.textContent = ''; // Clear existing content

            servers.forEach(server => {
                const item = document.createElement('div');
                item.className = 'server-item';
                item.dataset.serverId = server.id;

                const info = document.createElement('div');
                info.className = 'server-info';

                const h4 = document.createElement('h4');
                h4.textContent = server.name;

                const p = document.createElement('p');
                p.textContent = server.url;

                const status = document.createElement('span');
                status.className = 'status connected';
                status.textContent = 'Ready';

                info.appendChild(h4);
                info.appendChild(p);
                info.appendChild(status);

                const controls = document.createElement('div');
                controls.className = 'server-controls';

                const browseBtn = document.createElement('button');
                browseBtn.className = 'browse-btn';
                browseBtn.textContent = 'Browse';
                browseBtn.setAttribute('aria-label', `Browse ${server.name} library`);
                browseBtn.addEventListener('click', () => {
                    this.browseServerLibrary(server.id);
                });

                const removeBtn = document.createElement('button');
                removeBtn.className = 'remove-btn';
                removeBtn.textContent = 'Remove';
                removeBtn.setAttribute('aria-label', `Remove ${server.name}`);
                removeBtn.addEventListener('click', () => {
                    this.removeServer(server.id);
                });

                controls.appendChild(browseBtn);
                controls.appendChild(removeBtn);

                item.appendChild(info);
                item.appendChild(controls);
                serverList.appendChild(item);
            });
        }
    }

    async browseServerLibrary(serverId) {
        // Show the library browser and load content
        const browser = this.container.querySelector('#jellyfin-browser');
        browser.style.display = 'block';
        this.selectedServer = serverId;

        try {
            const response = await fetch(`/api/jellyfin/${serverId}/library?limit=50`);
            const data = await response.json();

            const grid = this.container.querySelector('#jellyfin-media-grid');
            grid.textContent = '';

            if (data.items && data.items.length > 0) {
                data.items.forEach(item => {
                    const card = document.createElement('div');
                    card.className = 'media-card';
                    card.dataset.itemId = item.id;

                    const img = document.createElement('div');
                    img.className = 'media-thumb';
                    if (item.imageUrl) {
                        const imgEl = document.createElement('img');
                        imgEl.src = item.imageUrl;
                        imgEl.alt = item.name;
                        img.appendChild(imgEl);
                    } else {
                        img.textContent = item.type === 'Audio' ? 'Music' : 'Media';
                    }

                    const info = document.createElement('div');
                    info.className = 'media-info';

                    const title = document.createElement('h5');
                    title.textContent = item.name;

                    const artist = document.createElement('p');
                    artist.textContent = item.artist || item.album || item.type;

                    info.appendChild(title);
                    info.appendChild(artist);

                    const playBtn = document.createElement('button');
                    playBtn.className = 'play-media-btn';
                    playBtn.textContent = 'Play';
                    playBtn.setAttribute('aria-label', `Play ${item.name}`);
                    playBtn.addEventListener('click', () => {
                        this.playMedia(serverId, item.id, item.name);
                    });

                    card.appendChild(img);
                    card.appendChild(info);
                    card.appendChild(playBtn);
                    grid.appendChild(card);
                });
            } else {
                const empty = document.createElement('p');
                empty.textContent = 'No media found in library';
                grid.appendChild(empty);
            }
        } catch (error) {
            console.error('Failed to browse library:', error);
        }
    }

    async playMedia(serverId, itemId, itemName) {
        try {
            const response = await fetch('/api/jellyfin/stream-url', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ serverId, itemId, type: 'audio' })
            });
            const data = await response.json();

            if (data.success && data.streamUrl) {
                // Play through room jukebox if in a room
                if (window.jukeboxManager && window.jukeboxManager.currentRoom) {
                    window.jukeboxManager.playForRoom(data.streamUrl, itemName);
                } else {
                    // Local playback
                    const audio = new Audio(data.streamUrl);
                    audio.play();
                }
                this.showSuccess(`Now playing: ${itemName}`);
            }
        } catch (error) {
            this.showError(`Failed to play: ${error.message}`);
        }
    }

    async removeServer(serverId) {
        try {
            const response = await fetch(`/api/jellyfin/servers/${serverId}`, {
                method: 'DELETE'
            });
            const data = await response.json();

            if (data.success) {
                this.refreshJellyfinTab();
                this.showSuccess('Server removed');
            }
        } catch (error) {
            this.showError(`Failed to remove server: ${error.message}`);
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

    // Discover Jellyfin servers on the network
    async discoverJellyfinServers() {
        const discoverBtn = this.container.querySelector('#discover-jellyfin-servers');
        const statusDiv = this.container.querySelector('#discovery-status');
        const discoveredDiv = this.container.querySelector('#discovered-servers');
        const discoveredList = this.container.querySelector('#discovered-server-list');

        // Show loading state
        discoverBtn.disabled = true;
        discoverBtn.textContent = 'Searching...';
        statusDiv.style.display = 'block';
        statusDiv.textContent = 'Scanning network for Jellyfin servers...';
        statusDiv.className = 'discovery-status searching';

        try {
            // Call the server API to discover Jellyfin servers
            const response = await fetch('/api/jellyfin/discover?timeout=3000');
            const data = await response.json();

            if (data.servers && data.servers.length > 0) {
                statusDiv.textContent = `Found ${data.servers.length} server(s)`;
                statusDiv.className = 'discovery-status success';

                // Show discovered servers using safe DOM methods
                discoveredDiv.style.display = 'block';
                discoveredList.textContent = ''; // Clear existing content

                data.servers.forEach(server => {
                    const item = document.createElement('div');
                    item.className = 'discovered-server-item';
                    item.dataset.url = server.url;
                    item.dataset.name = server.name;

                    const info = document.createElement('div');
                    info.className = 'server-info';

                    const h5 = document.createElement('h5');
                    h5.textContent = server.name;

                    const p = document.createElement('p');
                    p.textContent = server.url;

                    const version = document.createElement('span');
                    version.className = 'version';
                    version.textContent = `Jellyfin ${server.version}`;

                    info.appendChild(h5);
                    info.appendChild(p);
                    info.appendChild(version);

                    const btn = document.createElement('button');
                    btn.className = 'configure-btn';
                    btn.setAttribute('aria-label', `Configure ${server.name}`);
                    btn.textContent = 'Configure';
                    btn.addEventListener('click', () => {
                        this.showConfigureServerModal(server.url, server.name);
                    });

                    item.appendChild(info);
                    item.appendChild(btn);
                    discoveredList.appendChild(item);
                });
            } else {
                statusDiv.textContent = 'No Jellyfin servers found on network';
                statusDiv.className = 'discovery-status empty';
                discoveredDiv.style.display = 'none';
            }
        } catch (error) {
            statusDiv.textContent = `Discovery failed: ${error.message}`;
            statusDiv.className = 'discovery-status error';
            discoveredDiv.style.display = 'none';
        }

        // Reset button
        discoverBtn.disabled = false;
        discoverBtn.textContent = 'Search Network';
    }

    // Show modal to configure a discovered server with API key
    showConfigureServerModal(url, name) {
        document.getElementById('server-name').value = name;
        document.getElementById('server-url').value = url;
        document.getElementById('server-username').value = '';
        document.getElementById('server-password').value = '';
        document.getElementById('add-server-modal').classList.remove('hidden');
    }

    // Add server using server-side API
    async addServerViaAPI(config) {
        try {
            // First validate the server
            const validateResponse = await fetch('/api/jellyfin/validate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url: config.url, apiKey: config.apiKey })
            });
            const validateData = await validateResponse.json();

            if (!validateData.valid) {
                throw new Error(validateData.error || 'Invalid server');
            }

            if (config.apiKey && !validateData.authenticated) {
                throw new Error(validateData.error || 'Authentication failed');
            }

            // Add server to the server-side config
            const addResponse = await fetch('/api/jellyfin/servers', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    name: config.name || validateData.serverName,
                    url: config.url,
                    apiKey: config.apiKey
                })
            });

            const addData = await addResponse.json();

            if (!addData.success) {
                throw new Error(addData.error || 'Failed to add server');
            }

            return addData;
        } catch (error) {
            throw error;
        }
    }

    // Load servers from server-side API
    async loadServersFromAPI() {
        try {
            const response = await fetch('/api/jellyfin/servers');
            const data = await response.json();
            return data.servers || [];
        } catch (error) {
            console.error('Failed to load servers from API:', error);
            return [];
        }
    }

    async handleAddServer() {
        const form = document.getElementById('add-server-form');
        const statusDiv = document.getElementById('server-validation-status');

        const config = {
            name: document.getElementById('server-name').value,
            url: document.getElementById('server-url').value,
            apiKey: document.getElementById('server-api-key').value
        };

        statusDiv.textContent = 'Adding server...';
        statusDiv.className = 'validation-status pending';

        try {
            // Use server-side API to add the server
            await this.addServerViaAPI(config);
            document.getElementById('add-server-modal').classList.add('hidden');
            form.reset();
            statusDiv.textContent = '';
            this.refreshJellyfinTab();
            this.showSuccess('Jellyfin server added successfully');
        } catch (error) {
            statusDiv.textContent = error.message;
            statusDiv.className = 'validation-status error';
        }
    }

    async testServerConnection() {
        const url = document.getElementById('server-url').value;
        const apiKey = document.getElementById('server-api-key').value;
        const statusDiv = document.getElementById('server-validation-status');

        if (!url) {
            statusDiv.textContent = 'Please enter a server URL';
            statusDiv.className = 'validation-status error';
            return;
        }

        statusDiv.textContent = 'Testing connection...';
        statusDiv.className = 'validation-status pending';

        try {
            const response = await fetch('/api/jellyfin/validate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url, apiKey })
            });
            const data = await response.json();

            if (data.valid) {
                if (data.authenticated) {
                    statusDiv.textContent = `Connected to ${data.serverName} (v${data.version})`;
                    statusDiv.className = 'validation-status success';
                    // Auto-fill server name if empty
                    if (!document.getElementById('server-name').value) {
                        document.getElementById('server-name').value = data.serverName;
                    }
                } else {
                    statusDiv.textContent = `Server found: ${data.serverName}. ${data.message || 'Add API key for full access.'}`;
                    statusDiv.className = 'validation-status warning';
                }
            } else {
                statusDiv.textContent = data.error || 'Invalid server';
                statusDiv.className = 'validation-status error';
            }
        } catch (error) {
            statusDiv.textContent = `Connection failed: ${error.message}`;
            statusDiv.className = 'validation-status error';
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