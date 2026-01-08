class SettingsInterfaceManager {
    constructor() {
        this.currentTab = 'audio-devices';
        this.currentSubTab = {};
        this.settingsData = {
            audioDevices: {
                inputDevice: 'default',
                outputDevice: 'default',
                sampleRate: 48000,
                bufferSize: 256,
                inputGain: 1.0,
                outputGain: 1.0,
                monitoring: false
            },
            channelMatrix: {
                inputChannels: [],
                outputChannels: [],
                binauralChannels: [],
                channelAssignments: new Map()
            },
            vstPlugins: {
                enabledPlugins: [],
                streamingSettings: {},
                pluginChain: []
            },
            security: {
                encryptionLevel: 'medium',
                twoFactorEnabled: false,
                keychainAuth: false,
                biometricAuth: false
            },
            server: {
                connectionMethod: 'direct',
                serverAddress: '',
                port: 3001,
                autoConnect: false,
                proxySettings: {}
            },
            audioTesting: {
                testVolume: 0.7,
                spatialTesting: true,
                microphoneTesting: true
            }
        };
        this.init();
    }

    init() {
        this.createSettingsInterface();
        this.loadSettings();
        this.bindEvents();
    }

    createSettingsInterface() {
        const settingsHTML = `
            <div id="settings-interface" class="settings-interface hidden">
                <div class="settings-header">
                    <h2>VoiceLink Settings</h2>
                    <button id="close-settings" class="close-button">×</button>
                </div>

                <div class="settings-container">
                    <div class="settings-tabs">
                        <button class="tab-button active" data-tab="audio-devices">
                            <i class="icon-microphone"></i>
                            Audio Devices
                        </button>
                        <button class="tab-button" data-tab="channel-matrix">
                            <i class="icon-grid"></i>
                            Channel Matrix
                        </button>
                        <button class="tab-button" data-tab="vst-plugins">
                            <i class="icon-equalizer"></i>
                            VST Plugins
                        </button>
                        <button class="tab-button" data-tab="security">
                            <i class="icon-shield"></i>
                            Security
                        </button>
                        <button class="tab-button" data-tab="server">
                            <i class="icon-server"></i>
                            Server
                        </button>
                        <button class="tab-button" data-tab="audio-testing">
                            <i class="icon-test"></i>
                            Audio Testing
                        </button>
                    </div>

                    <div class="settings-content">
                        ${this.createAudioDevicesTab()}
                        ${this.createChannelMatrixTab()}
                        ${this.createVSTPluginsTab()}
                        ${this.createSecurityTab()}
                        ${this.createServerTab()}
                        ${this.createAudioTestingTab()}
                    </div>
                </div>

                <!-- Settings controls now integrated into each tab -->
            </div>
        `;

        document.body.insertAdjacentHTML('beforeend', settingsHTML);
        this.addSettingsStyles();
    }

    createAudioDevicesTab() {
        return `
            <div class="tab-content active" data-tab="audio-devices">
                <div class="sub-tabs">
                    <button class="sub-tab-button active" data-subtab="devices">Input/Output Devices</button>
                    <button class="sub-tab-button" data-subtab="advanced">Advanced Audio</button>
                    <button class="sub-tab-button" data-subtab="monitoring">Monitoring</button>
                </div>

                <div class="sub-tab-content active" data-subtab="devices">
                    <h3>Audio Device Configuration</h3>
                    <div class="setting-group">
                        <label>Input Device:</label>
                        <select id="input-device-select" class="setting-control">
                            <option value="default">Default System Input</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Output Device:</label>
                        <select id="output-device-select" class="setting-control">
                            <option value="default">Default System Output</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Input Gain:</label>
                        <input type="range" id="input-gain" class="setting-control" min="0" max="2" step="0.1" value="1.0">
                        <span class="range-value">1.0</span>
                    </div>
                    <div class="setting-group">
                        <label>Output Gain:</label>
                        <input type="range" id="output-gain" class="setting-control" min="0" max="2" step="0.1" value="1.0">
                        <span class="range-value">1.0</span>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="advanced">
                    <h3>Advanced Audio Settings</h3>
                    <div class="setting-group">
                        <label>Sample Rate:</label>
                        <select id="sample-rate-select" class="setting-control">
                            <option value="44100">44.1 kHz</option>
                            <option value="48000" selected>48 kHz</option>
                            <option value="88200">88.2 kHz</option>
                            <option value="96000">96 kHz</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Buffer Size:</label>
                        <select id="buffer-size-select" class="setting-control">
                            <option value="64">64 samples</option>
                            <option value="128">128 samples</option>
                            <option value="256" selected>256 samples</option>
                            <option value="512">512 samples</option>
                            <option value="1024">1024 samples</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Audio Quality:</label>
                        <select id="audio-quality-select" class="setting-control">
                            <option value="low">Low (32 kbps)</option>
                            <option value="medium" selected>Medium (128 kbps)</option>
                            <option value="high">High (320 kbps)</option>
                            <option value="lossless">Lossless</option>
                        </select>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="monitoring">
                    <h3>Audio Monitoring</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-monitoring" class="setting-control">
                            Enable Input Monitoring
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>Monitor Volume:</label>
                        <input type="range" id="monitor-volume" class="setting-control" min="0" max="1" step="0.1" value="0.5">
                        <span class="range-value">0.5</span>
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-echo-cancellation" class="setting-control">
                            Enable Echo Cancellation
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-noise-suppression" class="setting-control">
                            Enable Noise Suppression
                        </label>
                    </div>
                </div>

                <div class="tab-controls">
                    <button id="apply-audio-settings" class="button primary">Apply Audio Settings</button>
                    <button id="reset-audio-settings" class="button secondary">Reset Audio</button>
                </div>
            </div>
        `;
    }

    createChannelMatrixTab() {
        return `
            <div class="tab-content" data-tab="channel-matrix">
                <div class="sub-tabs">
                    <button class="sub-tab-button active" data-subtab="input-channels">Input Channels</button>
                    <button class="sub-tab-button" data-subtab="output-channels">Output Channels</button>
                    <button class="sub-tab-button" data-subtab="binaural">3D Binaural</button>
                    <button class="sub-tab-button" data-subtab="routing">Channel Routing</button>
                </div>

                <div class="sub-tab-content active" data-subtab="input-channels">
                    <h3>Input Channel Configuration (64 Channels Max)</h3>
                    <div class="channel-grid" id="input-channel-grid">
                        <!-- Dynamic channel grid will be generated here -->
                    </div>
                    <button id="add-input-channel" class="button secondary">Add Input Channel</button>
                </div>

                <div class="sub-tab-content" data-subtab="output-channels">
                    <h3>Output Channel Configuration (64 Channels Max)</h3>
                    <div class="channel-grid" id="output-channel-grid">
                        <!-- Dynamic channel grid will be generated here -->
                    </div>
                    <button id="add-output-channel" class="button secondary">Add Output Channel</button>
                </div>

                <div class="sub-tab-content" data-subtab="binaural">
                    <h3>3D Binaural Audio Settings</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-binaural" class="setting-control">
                            Enable 3D Binaural Processing
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>HRTF Profile:</label>
                        <select id="hrtf-profile-select" class="setting-control">
                            <option value="default">Default HRTF</option>
                            <option value="kemar">KEMAR Dummy Head</option>
                            <option value="cipic">CIPIC Database</option>
                            <option value="custom">Custom Profile</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Room Model:</label>
                        <select id="room-model-select" class="setting-control">
                            <option value="anechoic">Anechoic Chamber</option>
                            <option value="small-room">Small Room</option>
                            <option value="large-room" selected>Large Room</option>
                            <option value="concert-hall">Concert Hall</option>
                            <option value="outdoor">Outdoor Space</option>
                        </select>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="routing">
                    <h3>Channel Routing Matrix</h3>
                    <div class="routing-matrix" id="routing-matrix">
                        <!-- Dynamic routing matrix will be generated here -->
                    </div>
                </div>
            </div>
        `;
    }

    createVSTPluginsTab() {
        return `
            <div class="tab-content" data-tab="vst-plugins">
                <div class="sub-tabs">
                    <button class="sub-tab-button active" data-subtab="plugins">Available Plugins</button>
                    <button class="sub-tab-button" data-subtab="chain">Plugin Chain</button>
                    <button class="sub-tab-button" data-subtab="streaming">VST Streaming</button>
                </div>

                <div class="sub-tab-content active" data-subtab="plugins">
                    <h3>VST Plugin Library</h3>
                    <div class="plugin-grid" id="plugin-grid">
                        <div class="plugin-card">
                            <h4>Reverb</h4>
                            <div class="plugin-controls">
                                <label>Room Size: <input type="range" min="0" max="1" step="0.1" value="0.5"></label>
                                <label>Wet Mix: <input type="range" min="0" max="1" step="0.1" value="0.3"></label>
                            </div>
                            <button class="toggle-plugin" data-plugin="reverb">Enable</button>
                        </div>
                        <div class="plugin-card">
                            <h4>Compressor</h4>
                            <div class="plugin-controls">
                                <label>Threshold: <input type="range" min="-60" max="0" step="1" value="-20"></label>
                                <label>Ratio: <input type="range" min="1" max="20" step="0.5" value="4"></label>
                            </div>
                            <button class="toggle-plugin" data-plugin="compressor">Enable</button>
                        </div>
                        <div class="plugin-card">
                            <h4>EQ</h4>
                            <div class="plugin-controls">
                                <label>Low: <input type="range" min="-15" max="15" step="0.5" value="0"></label>
                                <label>Mid: <input type="range" min="-15" max="15" step="0.5" value="0"></label>
                                <label>High: <input type="range" min="-15" max="15" step="0.5" value="0"></label>
                            </div>
                            <button class="toggle-plugin" data-plugin="eq">Enable</button>
                        </div>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="chain">
                    <h3>Plugin Processing Chain</h3>
                    <div class="plugin-chain" id="plugin-chain">
                        <div class="chain-slot empty" data-slot="0">
                            <span>Drop Plugin Here</span>
                        </div>
                        <div class="chain-slot empty" data-slot="1">
                            <span>Drop Plugin Here</span>
                        </div>
                        <div class="chain-slot empty" data-slot="2">
                            <span>Drop Plugin Here</span>
                        </div>
                        <div class="chain-slot empty" data-slot="3">
                            <span>Drop Plugin Here</span>
                        </div>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="streaming">
                    <h3>VST Streaming Configuration</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-vst-streaming" class="setting-control">
                            Enable VST Plugin Streaming
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>Streaming Quality:</label>
                        <select id="vst-streaming-quality" class="setting-control">
                            <option value="low">Low Latency</option>
                            <option value="medium" selected>Balanced</option>
                            <option value="high">High Quality</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Max Concurrent Streams:</label>
                        <input type="number" id="max-vst-streams" class="setting-control" min="1" max="16" value="4">
                    </div>
                </div>
            </div>
        `;
    }

    createSecurityTab() {
        return `
            <div class="tab-content" data-tab="security">
                <div class="sub-tabs">
                    <button class="sub-tab-button active" data-subtab="encryption">Encryption</button>
                    <button class="sub-tab-button" data-subtab="authentication">Authentication</button>
                    <button class="sub-tab-button" data-subtab="keychain">Keychain</button>
                </div>

                <div class="sub-tab-content active" data-subtab="encryption">
                    <h3>End-to-End Encryption</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-encryption" class="setting-control">
                            Enable End-to-End Encryption
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>Encryption Level:</label>
                        <select id="encryption-level" class="setting-control">
                            <option value="basic">Basic (AES-128)</option>
                            <option value="medium" selected>Medium (AES-256)</option>
                            <option value="high">High (AES-256 + RSA-4096)</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-perfect-forward-secrecy" class="setting-control">
                            Perfect Forward Secrecy
                        </label>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="authentication">
                    <h3>Two-Factor Authentication</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-2fa" class="setting-control">
                            Enable Two-Factor Authentication
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>2FA Method:</label>
                        <select id="2fa-method" class="setting-control">
                            <option value="totp">TOTP (Authenticator App)</option>
                            <option value="sms">SMS</option>
                            <option value="email">Email</option>
                            <option value="hardware">Hardware Key</option>
                            <option value="biometric">Biometric</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-biometric" class="setting-control">
                            Enable Biometric Authentication
                        </label>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="keychain">
                    <h3>Keychain Integration</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-keychain" class="setting-control">
                            Enable Keychain Authentication
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>Keychain Provider:</label>
                        <select id="keychain-provider" class="setting-control">
                            <option value="icloud">iCloud Keychain</option>
                            <option value="windows">Windows Credential Manager</option>
                            <option value="linux">Linux Secret Service</option>
                            <option value="custom">Custom Provider</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="sync-across-devices" class="setting-control">
                            Sync Credentials Across Devices
                        </label>
                    </div>
                </div>
            </div>
        `;
    }

    createServerTab() {
        return `
            <div class="tab-content" data-tab="server">
                <div class="sub-tabs">
                    <button class="sub-tab-button active" data-subtab="connection">Connection</button>
                    <button class="sub-tab-button" data-subtab="discovery">Server Discovery</button>
                    <button class="sub-tab-button" data-subtab="proxy">Proxy & VPN</button>
                </div>

                <div class="sub-tab-content active" data-subtab="connection">
                    <h3>Server Connection Settings</h3>
                    <div class="setting-group">
                        <label>Connection Method:</label>
                        <select id="connection-method" class="setting-control">
                            <option value="direct" selected>Direct IP</option>
                            <option value="domain">Domain Name</option>
                            <option value="invite">Invite Link</option>
                            <option value="qr">QR Code</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Server Address:</label>
                        <input type="text" id="server-address" class="setting-control" placeholder="Enter server address">
                    </div>
                    <div class="setting-group">
                        <label>Port:</label>
                        <input type="number" id="server-port" class="setting-control" min="1" max="65535" value="3001">
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="auto-connect" class="setting-control">
                            Auto-connect on startup
                        </label>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="discovery">
                    <h3>Server Discovery</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-local-discovery" class="setting-control">
                            Enable Local Network Discovery
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-public-browser" class="setting-control">
                            Enable Public Server Browser
                        </label>
                    </div>
                    <div class="server-list" id="discovered-servers">
                        <h4>Discovered Servers:</h4>
                        <div class="server-item">
                            <span>Local Server (192.168.1.100:3001)</span>
                            <button class="button small">Connect</button>
                        </div>
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="proxy">
                    <h3>Proxy & VPN Settings</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-proxy" class="setting-control">
                            Enable Proxy Connection
                        </label>
                    </div>
                    <div class="setting-group">
                        <label>Proxy Type:</label>
                        <select id="proxy-type" class="setting-control">
                            <option value="http">HTTP</option>
                            <option value="socks4">SOCKS4</option>
                            <option value="socks5">SOCKS5</option>
                        </select>
                    </div>
                    <div class="setting-group">
                        <label>Proxy Address:</label>
                        <input type="text" id="proxy-address" class="setting-control" placeholder="proxy.example.com">
                    </div>
                    <div class="setting-group">
                        <label>Proxy Port:</label>
                        <input type="number" id="proxy-port" class="setting-control" min="1" max="65535" value="8080">
                    </div>
                </div>
            </div>
        `;
    }

    createAudioTestingTab() {
        return `
            <div class="tab-content" data-tab="audio-testing">
                <div class="sub-tabs">
                    <button class="sub-tab-button active" data-subtab="playback">Playback Tests</button>
                    <button class="sub-tab-button" data-subtab="recording">Recording Tests</button>
                    <button class="sub-tab-button" data-subtab="spatial">3D Spatial Tests</button>
                </div>

                <div class="sub-tab-content active" data-subtab="playback">
                    <h3>Audio Playback Testing</h3>
                    <div class="setting-group">
                        <label>Test Volume:</label>
                        <input type="range" id="test-volume" class="setting-control" min="0" max="1" step="0.1" value="0.7">
                        <span class="range-value">0.7</span>
                    </div>
                    <div class="audio-test-grid" id="audio-test-grid">
                        <!-- Audio test controls will be populated here -->
                    </div>
                </div>

                <div class="sub-tab-content" data-subtab="recording">
                    <h3>Microphone Testing</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-mic-testing" class="setting-control">
                            Enable Microphone Testing
                        </label>
                    </div>
                    <div class="mic-test-controls">
                        <button id="start-mic-test" class="button">Start Recording Test</button>
                        <button id="stop-mic-test" class="button" disabled>Stop Recording</button>
                        <button id="play-recording" class="button" disabled>Play Recording</button>
                    </div>
                    <canvas id="mic-level-meter" width="300" height="100"></canvas>
                </div>

                <div class="sub-tab-content" data-subtab="spatial">
                    <h3>3D Spatial Audio Testing</h3>
                    <div class="setting-group">
                        <label>
                            <input type="checkbox" id="enable-spatial-testing" class="setting-control">
                            Enable 3D Spatial Testing
                        </label>
                    </div>
                    <div class="spatial-test-area">
                        <canvas id="spatial-test-canvas" width="400" height="400"></canvas>
                        <div class="spatial-controls">
                            <button id="play-spatial-left" class="button">Test Left</button>
                            <button id="play-spatial-right" class="button">Test Right</button>
                            <button id="play-spatial-front" class="button">Test Front</button>
                            <button id="play-spatial-back" class="button">Test Back</button>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }

    addSettingsStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .settings-interface {
                position: fixed;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                background: rgba(0, 0, 0, 0.8);
                backdrop-filter: blur(10px);
                z-index: 1000;
                display: flex;
                flex-direction: column;
            }

            .settings-interface.hidden {
                display: none;
            }

            .settings-header {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                padding: 20px;
                display: flex;
                justify-content: space-between;
                align-items: center;
            }

            .settings-header h2 {
                margin: 0;
                font-size: 24px;
            }

            .close-button {
                background: none;
                border: none;
                color: white;
                font-size: 24px;
                cursor: pointer;
                width: 40px;
                height: 40px;
                border-radius: 50%;
                transition: background 0.3s ease;
            }

            .close-button:hover {
                background: rgba(255, 255, 255, 0.2);
            }

            .settings-container {
                flex: 1;
                display: flex;
                overflow: hidden;
            }

            .settings-tabs {
                width: 250px;
                background: rgba(255, 255, 255, 0.1);
                backdrop-filter: blur(10px);
                border-right: 1px solid rgba(255, 255, 255, 0.2);
                padding: 20px 0;
            }

            .tab-button {
                width: 100%;
                padding: 15px 20px;
                background: none;
                border: none;
                color: white;
                text-align: left;
                cursor: pointer;
                transition: all 0.3s ease;
                display: flex;
                align-items: center;
                gap: 10px;
            }

            .tab-button:hover {
                background: rgba(255, 255, 255, 0.1);
            }

            .tab-button.active {
                background: rgba(255, 255, 255, 0.2);
                border-right: 3px solid #667eea;
            }

            .settings-content {
                flex: 1;
                padding: 20px;
                overflow-y: auto;
                color: white;
            }

            .tab-content {
                display: none;
            }

            .tab-content.active {
                display: block;
            }

            .sub-tabs {
                display: flex;
                gap: 10px;
                margin-bottom: 20px;
                border-bottom: 1px solid rgba(255, 255, 255, 0.2);
            }

            .sub-tab-button {
                padding: 10px 15px;
                background: none;
                border: none;
                color: rgba(255, 255, 255, 0.7);
                cursor: pointer;
                border-bottom: 2px solid transparent;
                transition: all 0.3s ease;
            }

            .sub-tab-button:hover {
                color: white;
            }

            .sub-tab-button.active {
                color: white;
                border-bottom-color: #667eea;
            }

            .sub-tab-content {
                display: none;
            }

            .sub-tab-content.active {
                display: block;
            }

            .setting-group {
                margin-bottom: 20px;
                display: flex;
                flex-direction: column;
                gap: 5px;
            }

            .setting-group label {
                font-weight: 500;
                display: flex;
                align-items: center;
                gap: 10px;
            }

            .setting-control {
                padding: 8px 12px;
                border: 1px solid rgba(255, 255, 255, 0.3);
                border-radius: 5px;
                background: rgba(255, 255, 255, 0.1);
                color: white;
                font-size: 14px;
            }

            .setting-control:focus {
                outline: none;
                border-color: #667eea;
                box-shadow: 0 0 0 2px rgba(102, 126, 234, 0.3);
            }

            .range-value {
                margin-left: 10px;
                min-width: 40px;
                text-align: center;
                background: rgba(255, 255, 255, 0.1);
                padding: 2px 8px;
                border-radius: 3px;
                font-size: 12px;
            }

            .channel-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
                gap: 15px;
                margin-bottom: 20px;
            }

            .channel-item {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 8px;
                padding: 15px;
                border: 1px solid rgba(255, 255, 255, 0.2);
            }

            .plugin-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
                gap: 15px;
            }

            .plugin-card {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 8px;
                padding: 15px;
                border: 1px solid rgba(255, 255, 255, 0.2);
            }

            .plugin-controls {
                margin: 10px 0;
                display: flex;
                flex-direction: column;
                gap: 8px;
            }

            .plugin-controls label {
                font-size: 12px;
                display: flex;
                justify-content: space-between;
                align-items: center;
            }

            .plugin-controls input {
                width: 100px;
            }

            .toggle-plugin {
                width: 100%;
                padding: 8px;
                background: #667eea;
                color: white;
                border: none;
                border-radius: 5px;
                cursor: pointer;
                transition: background 0.3s ease;
            }

            .toggle-plugin:hover {
                background: #5a6fd8;
            }

            .toggle-plugin.active {
                background: #28a745;
            }

            .plugin-chain {
                display: flex;
                gap: 15px;
                padding: 20px;
                background: rgba(255, 255, 255, 0.05);
                border-radius: 8px;
                min-height: 80px;
                align-items: center;
            }

            .chain-slot {
                flex: 1;
                height: 60px;
                border: 2px dashed rgba(255, 255, 255, 0.3);
                border-radius: 8px;
                display: flex;
                align-items: center;
                justify-content: center;
                background: rgba(255, 255, 255, 0.05);
                transition: all 0.3s ease;
            }

            .chain-slot.empty {
                color: rgba(255, 255, 255, 0.5);
            }

            .chain-slot:hover {
                border-color: #667eea;
                background: rgba(102, 126, 234, 0.1);
            }

            .audio-test-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
                gap: 15px;
                margin-top: 20px;
            }

            .mic-test-controls {
                display: flex;
                gap: 10px;
                margin: 20px 0;
            }

            #mic-level-meter {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 5px;
                margin-top: 10px;
            }

            .spatial-test-area {
                display: flex;
                flex-direction: column;
                align-items: center;
                gap: 20px;
            }

            #spatial-test-canvas {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 8px;
                border: 1px solid rgba(255, 255, 255, 0.2);
            }

            .spatial-controls {
                display: grid;
                grid-template-columns: repeat(2, 1fr);
                gap: 10px;
            }

            .server-list {
                margin-top: 20px;
            }

            .server-item {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 10px;
                background: rgba(255, 255, 255, 0.1);
                border-radius: 5px;
                margin-bottom: 10px;
            }

            .settings-footer {
                background: rgba(255, 255, 255, 0.1);
                padding: 20px;
                display: flex;
                gap: 10px;
                justify-content: flex-end;
                border-top: 1px solid rgba(255, 255, 255, 0.2);
            }

            .button {
                padding: 10px 20px;
                border: none;
                border-radius: 5px;
                cursor: pointer;
                font-size: 14px;
                transition: all 0.3s ease;
            }

            .button.primary {
                background: #667eea;
                color: white;
            }

            .button.primary:hover {
                background: #5a6fd8;
            }

            .button.secondary {
                background: rgba(255, 255, 255, 0.1);
                color: white;
                border: 1px solid rgba(255, 255, 255, 0.3);
            }

            .button.secondary:hover {
                background: rgba(255, 255, 255, 0.2);
            }

            .button.small {
                padding: 5px 10px;
                font-size: 12px;
            }

            .tab-controls {
                margin-top: 20px;
                padding-top: 20px;
                border-top: 1px solid rgba(255, 255, 255, 0.2);
                display: flex;
                gap: 10px;
                justify-content: flex-end;
            }

            .routing-matrix {
                background: rgba(255, 255, 255, 0.05);
                padding: 20px;
                border-radius: 8px;
                margin-top: 20px;
            }
        `;
        document.head.appendChild(style);
    }

    bindEvents() {
        // Main tab switching
        document.querySelectorAll('.tab-button').forEach(button => {
            button.addEventListener('click', (e) => {
                const tabName = e.target.dataset.tab;
                this.switchTab(tabName);
            });
        });

        // Sub-tab switching
        document.querySelectorAll('.sub-tab-button').forEach(button => {
            button.addEventListener('click', (e) => {
                const subTabName = e.target.dataset.subtab;
                const parentTab = e.target.closest('.tab-content').dataset.tab;
                this.switchSubTab(parentTab, subTabName);
            });
        });

        // Close settings
        document.getElementById('close-settings').addEventListener('click', () => {
            this.hideSettings();
        });

        // Range value updates
        document.querySelectorAll('input[type="range"]').forEach(range => {
            range.addEventListener('input', (e) => {
                const valueSpan = e.target.parentNode.querySelector('.range-value');
                if (valueSpan) {
                    valueSpan.textContent = e.target.value;
                }
            });
        });

        // Settings buttons
        document.getElementById('apply-settings').addEventListener('click', () => {
            this.applySettings();
        });

        document.getElementById('reset-settings').addEventListener('click', () => {
            this.resetSettings();
        });

        document.getElementById('export-settings').addEventListener('click', () => {
            this.exportSettings();
        });

        document.getElementById('import-settings').addEventListener('click', () => {
            this.importSettings();
        });

        // Plugin toggles
        document.querySelectorAll('.toggle-plugin').forEach(button => {
            button.addEventListener('click', (e) => {
                const pluginName = e.target.dataset.plugin;
                this.togglePlugin(pluginName, e.target);
            });
        });

        // Initialize audio testing
        this.initializeAudioTesting();
    }

    switchTab(tabName) {
        // Update tab buttons
        document.querySelectorAll('.tab-button').forEach(button => {
            button.classList.remove('active');
        });
        document.querySelector(`[data-tab="${tabName}"]`).classList.add('active');

        // Update tab content
        document.querySelectorAll('.tab-content').forEach(content => {
            content.classList.remove('active');
        });
        document.querySelector(`.tab-content[data-tab="${tabName}"]`).classList.add('active');

        this.currentTab = tabName;
    }

    switchSubTab(parentTab, subTabName) {
        const parentContent = document.querySelector(`.tab-content[data-tab="${parentTab}"]`);

        // Update sub-tab buttons
        parentContent.querySelectorAll('.sub-tab-button').forEach(button => {
            button.classList.remove('active');
        });
        parentContent.querySelector(`[data-subtab="${subTabName}"]`).classList.add('active');

        // Update sub-tab content
        parentContent.querySelectorAll('.sub-tab-content').forEach(content => {
            content.classList.remove('active');
        });
        parentContent.querySelector(`.sub-tab-content[data-subtab="${subTabName}"]`).classList.add('active');

        if (!this.currentSubTab[parentTab]) {
            this.currentSubTab[parentTab] = {};
        }
        this.currentSubTab[parentTab] = subTabName;
    }

    showSettings() {
        document.getElementById('settings-interface').classList.remove('hidden');
        this.populateAudioDevices();
        this.populateChannelMatrix();
    }

    hideSettings() {
        document.getElementById('settings-interface').classList.add('hidden');
    }

    async populateAudioDevices() {
        try {
            const devices = await navigator.mediaDevices.enumerateDevices();
            const inputSelect = document.getElementById('input-device-select');
            const outputSelect = document.getElementById('output-device-select');

            // Clear existing options except default
            inputSelect.innerHTML = '<option value="default">Default System Input</option>';
            outputSelect.innerHTML = '<option value="default">Default System Output</option>';

            devices.forEach(device => {
                const option = document.createElement('option');
                option.value = device.deviceId;
                option.textContent = device.label || `${device.kind} - ${device.deviceId.substr(0, 8)}`;

                if (device.kind === 'audioinput') {
                    inputSelect.appendChild(option);
                } else if (device.kind === 'audiooutput') {
                    outputSelect.appendChild(option);
                }
            });
        } catch (error) {
            console.error('Error enumerating audio devices:', error);
        }
    }

    populateChannelMatrix() {
        this.populateInputChannels();
        this.populateOutputChannels();
        this.generateRoutingMatrix();
    }

    populateInputChannels() {
        const grid = document.getElementById('input-channel-grid');
        grid.innerHTML = '';

        for (let i = 1; i <= 8; i++) {
            const channelItem = document.createElement('div');
            channelItem.className = 'channel-item';
            channelItem.innerHTML = `
                <h4>Input Channel ${i}</h4>
                <label>Type:
                    <select class="setting-control">
                        <option value="mono">Mono</option>
                        <option value="stereo">Stereo</option>
                        <option value="binaural">3D Binaural</option>
                    </select>
                </label>
                <label>Gain:
                    <input type="range" class="setting-control" min="0" max="2" step="0.1" value="1.0">
                    <span class="range-value">1.0</span>
                </label>
                <label>
                    <input type="checkbox" class="setting-control">
                    Enabled
                </label>
            `;
            grid.appendChild(channelItem);
        }
    }

    populateOutputChannels() {
        const grid = document.getElementById('output-channel-grid');
        grid.innerHTML = '';

        for (let i = 1; i <= 8; i++) {
            const channelItem = document.createElement('div');
            channelItem.className = 'channel-item';
            channelItem.innerHTML = `
                <h4>Output Channel ${i}</h4>
                <label>Type:
                    <select class="setting-control">
                        <option value="mono">Mono</option>
                        <option value="stereo">Stereo</option>
                        <option value="binaural">3D Binaural</option>
                    </select>
                </label>
                <label>Volume:
                    <input type="range" class="setting-control" min="0" max="2" step="0.1" value="1.0">
                    <span class="range-value">1.0</span>
                </label>
                <label>
                    <input type="checkbox" class="setting-control">
                    Enabled
                </label>
            `;
            grid.appendChild(channelItem);
        }
    }

    generateRoutingMatrix() {
        const matrix = document.getElementById('routing-matrix');
        matrix.innerHTML = '<h4>Input to Output Routing</h4>';

        const table = document.createElement('table');
        table.style.width = '100%';
        table.style.borderCollapse = 'collapse';

        // Header row
        const headerRow = document.createElement('tr');
        headerRow.innerHTML = '<th></th>';
        for (let i = 1; i <= 8; i++) {
            headerRow.innerHTML += `<th>Out ${i}</th>`;
        }
        table.appendChild(headerRow);

        // Input rows
        for (let i = 1; i <= 8; i++) {
            const row = document.createElement('tr');
            row.innerHTML = `<td><strong>In ${i}</strong></td>`;
            for (let j = 1; j <= 8; j++) {
                row.innerHTML += `<td><input type="checkbox" ${i === j ? 'checked' : ''}></td>`;
            }
            table.appendChild(row);
        }

        table.style.color = 'white';
        table.querySelectorAll('th, td').forEach(cell => {
            cell.style.padding = '8px';
            cell.style.border = '1px solid rgba(255, 255, 255, 0.2)';
            cell.style.textAlign = 'center';
        });

        matrix.appendChild(table);
    }

    initializeAudioTesting() {
        const testGrid = document.getElementById('audio-test-grid');
        if (!testGrid) return;

        // Initialize with audio test manager if available
        if (window.audioTestManager) {
            const testFiles = window.audioTestManager.testFiles;
            testGrid.innerHTML = '';

            Object.entries(testFiles).forEach(([fileId, fileData]) => {
                const testItem = document.createElement('div');
                testItem.className = 'channel-item';
                testItem.innerHTML = `
                    <h4>${fileData.name}</h4>
                    <button class="toggle-plugin" data-file-id="${fileId}">Play</button>
                    <div class="test-info">
                        <small>Size: ${(fileData.size / 1024 / 1024).toFixed(1)} MB</small>
                    </div>
                `;

                const button = testItem.querySelector('.toggle-plugin');
                button.addEventListener('click', () => {
                    window.audioTestManager.toggleAudioPlayback(fileId, button);
                });

                testGrid.appendChild(testItem);
            });
        }
    }

    togglePlugin(pluginName, buttonElement) {
        const isActive = buttonElement.classList.contains('active');

        if (isActive) {
            buttonElement.classList.remove('active');
            buttonElement.textContent = 'Enable';
        } else {
            buttonElement.classList.add('active');
            buttonElement.textContent = 'Disable';
        }

        // Trigger plugin state change
        if (window.vstStreamingEngine) {
            if (isActive) {
                window.vstStreamingEngine.disablePlugin(pluginName);
            } else {
                window.vstStreamingEngine.enablePlugin(pluginName);
            }
        }
    }

    applySettings() {
        console.log('Applying settings...');
        // Collect all settings and apply them
        this.collectAllSettings();
        this.hideSettings();
    }

    resetSettings() {
        if (confirm('Are you sure you want to reset all settings to defaults?')) {
            this.settingsData = {
                audioDevices: {
                    inputDevice: 'default',
                    outputDevice: 'default',
                    sampleRate: 48000,
                    bufferSize: 256,
                    inputGain: 1.0,
                    outputGain: 1.0,
                    monitoring: false
                },
                channelMatrix: {
                    inputChannels: [],
                    outputChannels: [],
                    binauralChannels: [],
                    channelAssignments: new Map()
                },
                vstPlugins: {
                    enabledPlugins: [],
                    streamingSettings: {},
                    pluginChain: []
                },
                security: {
                    encryptionLevel: 'medium',
                    twoFactorEnabled: false,
                    keychainAuth: false,
                    biometricAuth: false
                },
                server: {
                    connectionMethod: 'direct',
                    serverAddress: '',
                    port: 3001,
                    autoConnect: false,
                    proxySettings: {}
                },
                audioTesting: {
                    testVolume: 0.7,
                    spatialTesting: true,
                    microphoneTesting: true
                }
            };
            this.loadSettings();
        }
    }

    exportSettings() {
        const settings = JSON.stringify(this.settingsData, null, 2);
        const blob = new Blob([settings], { type: 'application/json' });
        const url = URL.createObjectURL(blob);

        const a = document.createElement('a');
        a.href = url;
        a.download = 'voicelink-settings.json';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    importSettings() {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = '.json';

        input.onchange = (event) => {
            const file = event.target.files[0];
            if (file) {
                const reader = new FileReader();
                reader.onload = (e) => {
                    try {
                        const settings = JSON.parse(e.target.result);
                        this.settingsData = { ...this.settingsData, ...settings };
                        this.loadSettings();
                        alert('Settings imported successfully!');
                    } catch (error) {
                        alert('Error importing settings: Invalid file format');
                    }
                };
                reader.readAsText(file);
            }
        };

        input.click();
    }

    collectAllSettings() {
        // Collect settings from all form elements
        const formElements = document.querySelectorAll('#settings-interface .setting-control');

        formElements.forEach(element => {
            const id = element.id;
            if (id) {
                let value;
                if (element.type === 'checkbox') {
                    value = element.checked;
                } else if (element.type === 'range' || element.type === 'number') {
                    value = parseFloat(element.value);
                } else {
                    value = element.value;
                }

                // Store setting based on ID
                this.updateSettingValue(id, value);
            }
        });

        // Save to localStorage
        localStorage.setItem('voicelink-settings', JSON.stringify(this.settingsData));
    }

    updateSettingValue(id, value) {
        // Map form IDs to settings structure
        const settingsMap = {
            'input-device-select': ['audioDevices', 'inputDevice'],
            'output-device-select': ['audioDevices', 'outputDevice'],
            'sample-rate-select': ['audioDevices', 'sampleRate'],
            'buffer-size-select': ['audioDevices', 'bufferSize'],
            'input-gain': ['audioDevices', 'inputGain'],
            'output-gain': ['audioDevices', 'outputGain'],
            'enable-monitoring': ['audioDevices', 'monitoring'],
            'encryption-level': ['security', 'encryptionLevel'],
            'enable-2fa': ['security', 'twoFactorEnabled'],
            'enable-keychain': ['security', 'keychainAuth'],
            'enable-biometric': ['security', 'biometricAuth'],
            'connection-method': ['server', 'connectionMethod'],
            'server-address': ['server', 'serverAddress'],
            'server-port': ['server', 'port'],
            'auto-connect': ['server', 'autoConnect'],
            'test-volume': ['audioTesting', 'testVolume']
        };

        const path = settingsMap[id];
        if (path) {
            const [category, setting] = path;
            this.settingsData[category][setting] = value;
        }
    }

    loadSettings() {
        // Load settings from localStorage
        const saved = localStorage.getItem('voicelink-settings');
        if (saved) {
            try {
                this.settingsData = { ...this.settingsData, ...JSON.parse(saved) };
            } catch (error) {
                console.error('Error loading settings:', error);
            }
        }

        // Apply settings to form elements
        this.applySettingsToForm();
    }

    applySettingsToForm() {
        // Apply settings to form elements
        Object.entries(this.settingsData).forEach(([category, settings]) => {
            Object.entries(settings).forEach(([key, value]) => {
                const element = this.findElementForSetting(category, key);
                if (element) {
                    if (element.type === 'checkbox') {
                        element.checked = value;
                    } else {
                        element.value = value;
                    }

                    // Update range value display
                    if (element.type === 'range') {
                        const valueSpan = element.parentNode.querySelector('.range-value');
                        if (valueSpan) {
                            valueSpan.textContent = value;
                        }
                    }
                }
            });
        });
    }

    findElementForSetting(category, key) {
        const settingsMap = {
            audioDevices: {
                inputDevice: 'input-device-select',
                outputDevice: 'output-device-select',
                sampleRate: 'sample-rate-select',
                bufferSize: 'buffer-size-select',
                inputGain: 'input-gain',
                outputGain: 'output-gain',
                monitoring: 'enable-monitoring'
            },
            security: {
                encryptionLevel: 'encryption-level',
                twoFactorEnabled: 'enable-2fa',
                keychainAuth: 'enable-keychain',
                biometricAuth: 'enable-biometric'
            },
            server: {
                connectionMethod: 'connection-method',
                serverAddress: 'server-address',
                port: 'server-port',
                autoConnect: 'auto-connect'
            },
            audioTesting: {
                testVolume: 'test-volume'
            }
        };

        const elementId = settingsMap[category]?.[key];
        return elementId ? document.getElementById(elementId) : null;
    }
}

// Initialize settings interface manager
window.settingsInterfaceManager = new SettingsInterfaceManager();