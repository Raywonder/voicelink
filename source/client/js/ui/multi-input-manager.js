/**
 * Multi-Input Management Interface
 * Manages separate microphone, media streaming, virtual, and system audio inputs
 */

class MultiInputManager {
    constructor(audioEngine) {
        this.audioEngine = audioEngine;
        this.isVisible = false;
        this.inputLevelMeters = new Map();
        this.animationFrames = new Map();

        this.init();
    }

    init() {
        this.createInterface();
        this.setupEventListeners();
        this.loadSettings();
    }

    createInterface() {
        // Create main container
        this.container = document.createElement('div');
        this.container.id = 'multi-input-manager';
        this.container.className = 'overlay-panel';
        this.container.style.display = 'none';

        this.container.innerHTML = `
            <div class="panel-header">
                <h3>🎛️ Multi-Input Audio Management</h3>
                <button class="close-btn" onclick="multiInputManager.hide()">&times;</button>
            </div>

            <div class="panel-content">
                <div class="input-section">
                    <h4>🎙️ Microphone Input</h4>
                    <div class="input-controls" data-input-type="microphone">
                        <div class="device-selection">
                            <label>Device:</label>
                            <select class="input-device-select" data-type="microphone">
                                <option value="">Select Microphone...</option>
                            </select>
                        </div>
                        <div class="volume-controls">
                            <label>Volume:</label>
                            <input type="range" class="volume-slider" min="0" max="100" value="100" data-type="microphone">
                            <span class="volume-value">100%</span>
                        </div>
                        <div class="control-buttons">
                            <button class="enable-btn" data-type="microphone">Enable</button>
                            <button class="mute-btn" data-type="microphone">Mute</button>
                            <button class="test-btn" data-type="microphone">Test</button>
                        </div>
                        <div class="level-meter">
                            <div class="level-bar" data-type="microphone"></div>
                        </div>
                        <div class="processing-options">
                            <label><input type="checkbox" class="echo-cancellation" data-type="microphone" checked> Echo Cancellation</label>
                            <label><input type="checkbox" class="noise-suppression" data-type="microphone" checked> Noise Suppression</label>
                            <label><input type="checkbox" class="auto-gain" data-type="microphone" checked> Auto Gain Control</label>
                        </div>
                        <div class="ducking-controls">
                            <h5>🎛️ Audio Ducking</h5>
                            <div class="ducking-row">
                                <label><input type="checkbox" class="ducking-enabled" data-type="microphone"> Enable Ducking</label>
                            </div>
                            <div class="ducking-row">
                                <label>Level:</label>
                                <select class="ducking-level" data-type="microphone">
                                    <option value="-5">-5dB</option>
                                    <option value="-10">-10dB</option>
                                    <option value="-15">-15dB</option>
                                    <option value="-20" selected>-20dB</option>
                                    <option value="-25">-25dB</option>
                                    <option value="-30">-30dB</option>
                                    <option value="-40">-40dB</option>
                                    <option value="-50">-50dB</option>
                                    <option value="-60">-60dB</option>
                                    <option value="-70">-70dB</option>
                                    <option value="-80">-80dB</option>
                                    <option value="-90">-90dB</option>
                                    <option value="-100">-100dB</option>
                                </select>
                            </div>
                            <div class="ducking-row">
                                <label>Speed:</label>
                                <select class="ducking-speed" data-type="microphone">
                                    <option value="instant">Instant (10ms)</option>
                                    <option value="fastest">Fastest (20ms)</option>
                                    <option value="fast">Fast (50ms)</option>
                                    <option value="medium">Medium (100ms)</option>
                                    <option value="default_half_second" selected>Default (0.5s)</option>
                                    <option value="slow">Slow (300ms)</option>
                                    <option value="very_slow">Very Slow (800ms)</option>
                                    <option value="extended">Extended (1.5s)</option>
                                    <option value="ultra_long">Ultra Long (3s)</option>
                                </select>
                            </div>
                            <div class="ducking-buttons">
                                <button class="duck-now-btn" data-type="microphone">Duck Now</button>
                                <button class="release-duck-btn" data-type="microphone">Release</button>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="input-section">
                    <h4>📡 Media Streaming Input</h4>
                    <div class="input-controls" data-input-type="media_streaming">
                        <div class="device-selection">
                            <label>Device:</label>
                            <select class="input-device-select" data-type="media_streaming">
                                <option value="">Select Media Source...</option>
                            </select>
                        </div>
                        <div class="volume-controls">
                            <label>Volume:</label>
                            <input type="range" class="volume-slider" min="0" max="100" value="100" data-type="media_streaming">
                            <span class="volume-value">100%</span>
                        </div>
                        <div class="control-buttons">
                            <button class="enable-btn" data-type="media_streaming">Enable</button>
                            <button class="mute-btn" data-type="media_streaming">Mute</button>
                            <button class="test-btn" data-type="media_streaming">Test</button>
                        </div>
                        <div class="level-meter">
                            <div class="level-bar" data-type="media_streaming"></div>
                        </div>
                        <div class="processing-options">
                            <label><input type="checkbox" class="echo-cancellation" data-type="media_streaming"> Echo Cancellation</label>
                            <label><input type="checkbox" class="noise-suppression" data-type="media_streaming"> Noise Suppression</label>
                            <span class="note">Media streaming typically uses raw audio</span>
                        </div>
                    </div>
                </div>

                <div class="input-section">
                    <h4>🔌 Virtual Audio Input</h4>
                    <div class="input-controls" data-input-type="virtual_input">
                        <div class="device-selection">
                            <label>Device:</label>
                            <select class="input-device-select" data-type="virtual_input">
                                <option value="">Select Virtual Device...</option>
                            </select>
                        </div>
                        <div class="volume-controls">
                            <label>Volume:</label>
                            <input type="range" class="volume-slider" min="0" max="100" value="100" data-type="virtual_input">
                            <span class="volume-value">100%</span>
                        </div>
                        <div class="control-buttons">
                            <button class="enable-btn" data-type="virtual_input">Enable</button>
                            <button class="mute-btn" data-type="virtual_input">Mute</button>
                            <button class="test-btn" data-type="virtual_input">Test</button>
                        </div>
                        <div class="level-meter">
                            <div class="level-bar" data-type="virtual_input"></div>
                        </div>
                        <div class="virtual-devices-info">
                            <p class="help-text">
                                Virtual devices like Loopback, VB-Cable, BlackHole, or Soundflower allow routing
                                audio from other applications into VoiceLink.
                            </p>
                        </div>
                    </div>
                </div>

                <div class="input-section">
                    <h4>🖥️ System Audio Input</h4>
                    <div class="input-controls" data-input-type="system_audio">
                        <div class="device-selection">
                            <label>Device:</label>
                            <select class="input-device-select" data-type="system_audio">
                                <option value="">Select System Audio...</option>
                            </select>
                        </div>
                        <div class="volume-controls">
                            <label>Volume:</label>
                            <input type="range" class="volume-slider" min="0" max="100" value="100" data-type="system_audio">
                            <span class="volume-value">100%</span>
                        </div>
                        <div class="control-buttons">
                            <button class="enable-btn" data-type="system_audio">Enable</button>
                            <button class="mute-btn" data-type="system_audio">Mute</button>
                            <button class="test-btn" data-type="system_audio">Test</button>
                        </div>
                        <div class="level-meter">
                            <div class="level-bar" data-type="system_audio"></div>
                        </div>
                    </div>
                </div>

                <div class="master-controls">
                    <h4>🎛️ Master Mix Controls</h4>
                    <div class="master-volume">
                        <label>Master Input Volume:</label>
                        <input type="range" id="master-input-volume" min="0" max="100" value="100">
                        <span id="master-volume-value">100%</span>
                    </div>
                    <div class="preset-controls">
                        <button id="save-preset">Save Preset</button>
                        <button id="load-preset">Load Preset</button>
                        <button id="reset-all">Reset All</button>
                    </div>
                </div>

                <div class="status-display">
                    <h4>📊 Input Status</h4>
                    <div id="input-status-grid">
                        <!-- Status indicators will be populated here -->
                    </div>
                </div>
            </div>
        `;

        document.body.appendChild(this.container);
        this.addStyles();
    }

    addStyles() {
        const styles = `
            <style id="multi-input-styles">
                .overlay-panel {
                    position: fixed;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    background: rgba(20, 20, 30, 0.95);
                    backdrop-filter: blur(10px);
                    border: 1px solid rgba(100, 200, 255, 0.3);
                    border-radius: 12px;
                    color: white;
                    width: 90%;
                    max-width: 800px;
                    max-height: 90vh;
                    overflow-y: auto;
                    z-index: 1000;
                    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
                }

                .panel-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    padding: 15px 20px;
                    border-bottom: 1px solid rgba(100, 200, 255, 0.2);
                    background: rgba(0, 50, 100, 0.3);
                }

                .panel-header h3 {
                    margin: 0;
                    color: #64c8ff;
                    font-size: 1.2em;
                }

                .close-btn {
                    background: none;
                    border: none;
                    color: #ff6b6b;
                    font-size: 24px;
                    cursor: pointer;
                    padding: 0;
                    width: 30px;
                    height: 30px;
                }

                .close-btn:hover {
                    background: rgba(255, 107, 107, 0.2);
                    border-radius: 50%;
                }

                .panel-content {
                    padding: 20px;
                }

                .input-section {
                    margin-bottom: 25px;
                    padding: 15px;
                    background: rgba(255, 255, 255, 0.05);
                    border-radius: 8px;
                    border: 1px solid rgba(100, 200, 255, 0.2);
                }

                .input-section h4 {
                    margin: 0 0 15px 0;
                    color: #64c8ff;
                    border-bottom: 1px solid rgba(100, 200, 255, 0.3);
                    padding-bottom: 5px;
                }

                .input-controls {
                    display: grid;
                    gap: 15px;
                }

                .device-selection, .volume-controls {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                }

                .device-selection label, .volume-controls label {
                    min-width: 80px;
                    font-weight: bold;
                }

                .input-device-select {
                    flex: 1;
                    padding: 8px;
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(100, 200, 255, 0.3);
                    border-radius: 4px;
                    color: white;
                }

                .volume-slider {
                    flex: 1;
                    margin: 0 10px;
                }

                .volume-value {
                    min-width: 40px;
                    text-align: right;
                    font-weight: bold;
                    color: #64c8ff;
                }

                .control-buttons {
                    display: flex;
                    gap: 10px;
                }

                .control-buttons button {
                    padding: 8px 16px;
                    background: rgba(100, 200, 255, 0.2);
                    border: 1px solid rgba(100, 200, 255, 0.5);
                    border-radius: 4px;
                    color: white;
                    cursor: pointer;
                    transition: all 0.3s ease;
                }

                .control-buttons button:hover {
                    background: rgba(100, 200, 255, 0.4);
                }

                .control-buttons button.active {
                    background: rgba(100, 255, 100, 0.3);
                    border-color: rgba(100, 255, 100, 0.7);
                }

                .control-buttons button.muted {
                    background: rgba(255, 100, 100, 0.3);
                    border-color: rgba(255, 100, 100, 0.7);
                }

                .level-meter {
                    height: 20px;
                    background: rgba(0, 0, 0, 0.5);
                    border-radius: 10px;
                    overflow: hidden;
                    border: 1px solid rgba(100, 200, 255, 0.3);
                }

                .level-bar {
                    height: 100%;
                    background: linear-gradient(90deg, #00ff00, #ffff00, #ff0000);
                    width: 0%;
                    transition: width 0.1s ease;
                }

                .processing-options {
                    display: flex;
                    gap: 20px;
                    flex-wrap: wrap;
                }

                .processing-options label {
                    display: flex;
                    align-items: center;
                    gap: 5px;
                    cursor: pointer;
                }

                .help-text, .note {
                    font-size: 0.9em;
                    color: rgba(255, 255, 255, 0.7);
                    font-style: italic;
                }

                .master-controls {
                    background: rgba(100, 200, 255, 0.1);
                    padding: 15px;
                    border-radius: 8px;
                    margin-bottom: 20px;
                }

                .master-controls h4 {
                    margin: 0 0 15px 0;
                    color: #64c8ff;
                }

                .master-volume {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                    margin-bottom: 15px;
                }

                .preset-controls {
                    display: flex;
                    gap: 10px;
                }

                .preset-controls button {
                    padding: 8px 16px;
                    background: rgba(255, 165, 0, 0.2);
                    border: 1px solid rgba(255, 165, 0, 0.5);
                    border-radius: 4px;
                    color: white;
                    cursor: pointer;
                }

                .preset-controls button:hover {
                    background: rgba(255, 165, 0, 0.4);
                }

                .status-display {
                    background: rgba(0, 0, 0, 0.3);
                    padding: 15px;
                    border-radius: 8px;
                }

                .status-display h4 {
                    margin: 0 0 15px 0;
                    color: #64c8ff;
                }

                #input-status-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                    gap: 10px;
                }

                .status-item {
                    padding: 10px;
                    background: rgba(255, 255, 255, 0.05);
                    border-radius: 4px;
                    border: 1px solid rgba(100, 200, 255, 0.2);
                }

                .status-item .status-label {
                    font-weight: bold;
                    color: #64c8ff;
                    margin-bottom: 5px;
                }

                .status-item .status-value {
                    font-size: 0.9em;
                }

                .status-enabled {
                    border-color: rgba(100, 255, 100, 0.5);
                }

                .status-disabled {
                    border-color: rgba(255, 100, 100, 0.5);
                    opacity: 0.6;
                }

                .ducking-controls {
                    margin-top: 15px;
                    padding: 12px;
                    background: rgba(255, 165, 0, 0.1);
                    border-radius: 6px;
                    border: 1px solid rgba(255, 165, 0, 0.3);
                }

                .ducking-controls h5 {
                    margin: 0 0 10px 0;
                    color: #ffa500;
                    font-size: 0.9em;
                    font-weight: bold;
                }

                .ducking-row {
                    display: flex;
                    align-items: center;
                    margin-bottom: 8px;
                    gap: 10px;
                }

                .ducking-row label {
                    min-width: 60px;
                    font-size: 0.85em;
                }

                .ducking-row select {
                    flex: 1;
                    padding: 4px;
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(255, 165, 0, 0.3);
                    border-radius: 3px;
                    color: white;
                    font-size: 0.85em;
                }

                .ducking-buttons {
                    display: flex;
                    gap: 8px;
                    margin-top: 10px;
                }

                .ducking-buttons button {
                    flex: 1;
                    padding: 6px 12px;
                    background: rgba(255, 165, 0, 0.2);
                    border: 1px solid rgba(255, 165, 0, 0.5);
                    border-radius: 4px;
                    color: white;
                    cursor: pointer;
                    font-size: 0.8em;
                    transition: all 0.3s ease;
                }

                .ducking-buttons button:hover {
                    background: rgba(255, 165, 0, 0.4);
                }

                .ducking-buttons .duck-now-btn {
                    background: rgba(255, 100, 100, 0.2);
                    border-color: rgba(255, 100, 100, 0.5);
                }

                .ducking-buttons .duck-now-btn:hover {
                    background: rgba(255, 100, 100, 0.4);
                }

                .ducking-buttons .release-duck-btn {
                    background: rgba(100, 255, 100, 0.2);
                    border-color: rgba(100, 255, 100, 0.5);
                }

                .ducking-buttons .release-duck-btn:hover {
                    background: rgba(100, 255, 100, 0.4);
                }
            </style>
        `;

        if (!document.getElementById('multi-input-styles')) {
            document.head.insertAdjacentHTML('beforeend', styles);
        }
    }

    setupEventListeners() {
        // Device selection handlers
        this.container.querySelectorAll('.input-device-select').forEach(select => {
            select.addEventListener('change', (e) => {
                const inputType = e.target.dataset.type;
                const deviceId = e.target.value;
                if (deviceId) {
                    this.setupInputSource(inputType, deviceId);
                }
            });
        });

        // Volume control handlers
        this.container.querySelectorAll('.volume-slider').forEach(slider => {
            slider.addEventListener('input', (e) => {
                const inputType = e.target.dataset.type;
                const volume = e.target.value / 100;
                this.audioEngine.setInputVolume(inputType, volume);

                const valueSpan = e.target.parentNode.querySelector('.volume-value');
                if (valueSpan) {
                    valueSpan.textContent = `${e.target.value}%`;
                }
            });
        });

        // Enable/disable buttons
        this.container.querySelectorAll('.enable-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const inputType = e.target.dataset.type;
                const deviceSelect = this.container.querySelector(`select[data-type="${inputType}"]`);
                const deviceId = deviceSelect.value;

                if (deviceId) {
                    this.setupInputSource(inputType, deviceId);
                    e.target.classList.add('active');
                } else {
                    alert('Please select a device first');
                }
            });
        });

        // Mute buttons
        this.container.querySelectorAll('.mute-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const inputType = e.target.dataset.type;
                const currentlyMuted = e.target.classList.contains('muted');
                this.audioEngine.setInputMute(inputType, !currentlyMuted);

                if (currentlyMuted) {
                    e.target.classList.remove('muted');
                    e.target.textContent = 'Mute';
                } else {
                    e.target.classList.add('muted');
                    e.target.textContent = 'Unmute';
                }
            });
        });

        // Test buttons
        this.container.querySelectorAll('.test-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const inputType = e.target.dataset.type;
                this.testInputSource(inputType);
            });
        });

        // Processing option checkboxes
        this.container.querySelectorAll('.processing-options input[type="checkbox"]').forEach(checkbox => {
            checkbox.addEventListener('change', (e) => {
                const inputType = e.target.dataset.type;
                const settingType = e.target.className;
                const settings = this.audioEngine.inputSettings.get(inputType);

                if (settings && settings.processing) {
                    if (settingType === 'echo-cancellation') {
                        settings.processing.echoCancellation = e.target.checked;
                    } else if (settingType === 'noise-suppression') {
                        settings.processing.noiseSuppression = e.target.checked;
                    } else if (settingType === 'auto-gain') {
                        settings.processing.autoGainControl = e.target.checked;
                    }
                    this.audioEngine.inputSettings.set(inputType, settings);
                }
            });
        });

        // Master volume control
        const masterVolumeSlider = this.container.querySelector('#master-input-volume');
        if (masterVolumeSlider) {
            masterVolumeSlider.addEventListener('input', (e) => {
                const volume = e.target.value / 100;
                if (this.audioEngine.inputMixerNode) {
                    this.audioEngine.inputMixerNode.gain.value = volume;
                }
                document.getElementById('master-volume-value').textContent = `${e.target.value}%`;
            });
        }

        // Preset controls
        document.getElementById('save-preset')?.addEventListener('click', () => {
            this.audioEngine.saveMultiInputSettings();
            this.showNotification('Preset saved successfully', 'success');
        });

        document.getElementById('load-preset')?.addEventListener('click', () => {
            this.audioEngine.loadMultiInputSettings();
            this.updateUI();
            this.showNotification('Preset loaded successfully', 'success');
        });

        document.getElementById('reset-all')?.addEventListener('click', () => {
            if (confirm('Reset all input settings to default?')) {
                this.resetAllInputs();
                this.showNotification('All inputs reset', 'info');
            }
        });

        // Ducking control event listeners
        this.setupDuckingEventListeners();
    }

    setupDuckingEventListeners() {
        // Ducking enabled checkboxes
        this.container.querySelectorAll('.ducking-enabled').forEach(checkbox => {
            checkbox.addEventListener('change', (e) => {
                const inputType = e.target.dataset.type;
                const enabled = e.target.checked;

                if (this.audioEngine.duckingProcessor) {
                    this.audioEngine.duckingProcessor.setDuckingEnabled(inputType, enabled);
                    this.showNotification(`Ducking ${enabled ? 'enabled' : 'disabled'} for ${inputType}`, 'info');
                }
            });
        });

        // Ducking level selects
        this.container.querySelectorAll('.ducking-level').forEach(select => {
            select.addEventListener('change', (e) => {
                const inputType = e.target.dataset.type;
                const level = parseFloat(e.target.value);

                if (this.audioEngine.duckingProcessor) {
                    this.audioEngine.duckingProcessor.setDuckingLevel(inputType, level);
                    this.showNotification(`Ducking level set to ${level}dB for ${inputType}`, 'info');
                }
            });
        });

        // Ducking speed selects
        this.container.querySelectorAll('.ducking-speed').forEach(select => {
            select.addEventListener('change', (e) => {
                const inputType = e.target.dataset.type;
                const speedPreset = e.target.value;

                if (this.audioEngine.duckingProcessor) {
                    this.audioEngine.duckingProcessor.setDuckingSpeedPreset(inputType, speedPreset);
                    const presetDetails = this.audioEngine.duckingProcessor.getDuckingSpeedPresetDetails(speedPreset);
                    this.showNotification(`Ducking speed: ${presetDetails?.description || speedPreset}`, 'info');
                }
            });
        });

        // Duck now buttons
        this.container.querySelectorAll('.duck-now-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const inputType = e.target.dataset.type;

                if (this.audioEngine.duckingProcessor) {
                    this.audioEngine.duckingProcessor.triggerDucking(inputType);
                    this.showNotification(`Manual ducking triggered for ${inputType}`, 'info');
                }
            });
        });

        // Release duck buttons
        this.container.querySelectorAll('.release-duck-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                const inputType = e.target.dataset.type;

                if (this.audioEngine.duckingProcessor) {
                    this.audioEngine.duckingProcessor.releaseDucking(inputType);
                    this.showNotification(`Ducking released for ${inputType}`, 'info');
                }
            });
        });

        console.log('Ducking event listeners set up');
    }

    async setupInputSource(inputType, deviceId) {
        try {
            await this.audioEngine.setupInputSource(inputType, deviceId);
            this.startLevelMeter(inputType);
            this.updateStatus();
            this.showNotification(`${inputType} input enabled`, 'success');
        } catch (error) {
            console.error(`Failed to setup ${inputType}:`, error);
            this.showNotification(`Failed to setup ${inputType}: ${error.message}`, 'error');
        }
    }

    testInputSource(inputType) {
        const stream = this.audioEngine.inputStreams.get(inputType);
        if (stream) {
            this.showNotification(`Testing ${inputType} - speak or play audio`, 'info');
            // The level meter will show the activity
        } else {
            this.showNotification(`Please enable ${inputType} first`, 'warning');
        }
    }

    startLevelMeter(inputType) {
        const stream = this.audioEngine.inputStreams.get(inputType);
        const levelBar = this.container.querySelector(`.level-bar[data-type="${inputType}"]`);

        if (!stream || !levelBar || !this.audioEngine.audioContext) return;

        // Stop existing meter for this input
        this.stopLevelMeter(inputType);

        try {
            const source = this.audioEngine.audioContext.createMediaStreamSource(stream);
            const analyser = this.audioEngine.audioContext.createAnalyser();
            analyser.fftSize = 256;
            source.connect(analyser);

            const dataArray = new Uint8Array(analyser.frequencyBinCount);
            this.inputLevelMeters.set(inputType, { analyser, dataArray });

            const updateLevel = () => {
                if (!this.inputLevelMeters.has(inputType)) return;

                analyser.getByteFrequencyData(dataArray);
                const average = dataArray.reduce((a, b) => a + b) / dataArray.length;
                const level = average / 255;

                levelBar.style.width = `${level * 100}%`;

                const animationId = requestAnimationFrame(updateLevel);
                this.animationFrames.set(inputType, animationId);
            };

            updateLevel();
        } catch (error) {
            console.error(`Failed to create level meter for ${inputType}:`, error);
        }
    }

    stopLevelMeter(inputType) {
        const animationId = this.animationFrames.get(inputType);
        if (animationId) {
            cancelAnimationFrame(animationId);
            this.animationFrames.delete(inputType);
        }
        this.inputLevelMeters.delete(inputType);
    }

    updateDeviceSelects() {
        // Update all device select dropdowns
        const selects = this.container.querySelectorAll('.input-device-select');

        selects.forEach(select => {
            const inputType = select.dataset.type;
            select.innerHTML = '<option value="">Select Device...</option>';

            let devices = this.audioEngine.audioDevices.inputs;

            // Filter devices based on input type
            if (inputType === 'virtual_input') {
                devices = this.audioEngine.getVirtualAudioDevices();
            }

            devices.forEach(device => {
                const option = document.createElement('option');
                option.value = device.id;
                option.textContent = `${device.label} (${device.type})`;
                select.appendChild(option);
            });
        });
    }

    updateStatus() {
        const statusGrid = this.container.querySelector('#input-status-grid');
        if (!statusGrid) return;

        const status = this.audioEngine.getInputSourcesStatus();
        statusGrid.innerHTML = '';

        Object.entries(status).forEach(([inputType, info]) => {
            const statusItem = document.createElement('div');
            statusItem.className = `status-item ${info.enabled ? 'status-enabled' : 'status-disabled'}`;

            statusItem.innerHTML = `
                <div class="status-label">${this.getInputTypeDisplayName(inputType)}</div>
                <div class="status-value">
                    Device: ${info.deviceName}<br>
                    Volume: ${Math.round(info.volume * 100)}%<br>
                    Status: ${info.enabled ? (info.muted ? 'Muted' : 'Active') : 'Disabled'}
                </div>
            `;

            statusGrid.appendChild(statusItem);
        });
    }

    getInputTypeDisplayName(inputType) {
        const names = {
            'microphone': '🎙️ Microphone',
            'media_streaming': '📡 Media Streaming',
            'virtual_input': '🔌 Virtual Input',
            'system_audio': '🖥️ System Audio'
        };
        return names[inputType] || inputType;
    }

    updateUI() {
        this.updateDeviceSelects();
        this.updateStatus();

        // Update volume sliders and checkboxes from saved settings
        Object.values(this.audioEngine.inputTypes).forEach(inputType => {
            const settings = this.audioEngine.inputSettings.get(inputType);
            const deviceId = this.audioEngine.selectedInputDevices.get(inputType);

            if (settings) {
                // Update volume slider
                const volumeSlider = this.container.querySelector(`.volume-slider[data-type="${inputType}"]`);
                const volumeValue = this.container.querySelector(`.volume-controls[data-type="${inputType}"] .volume-value`);
                if (volumeSlider) {
                    volumeSlider.value = settings.volume * 100;
                    if (volumeValue) {
                        volumeValue.textContent = `${Math.round(settings.volume * 100)}%`;
                    }
                }

                // Update device selection
                const deviceSelect = this.container.querySelector(`.input-device-select[data-type="${inputType}"]`);
                if (deviceSelect && deviceId) {
                    deviceSelect.value = deviceId;
                }

                // Update processing checkboxes
                if (settings.processing) {
                    const echoCheckbox = this.container.querySelector(`.echo-cancellation[data-type="${inputType}"]`);
                    const noiseCheckbox = this.container.querySelector(`.noise-suppression[data-type="${inputType}"]`);
                    const gainCheckbox = this.container.querySelector(`.auto-gain[data-type="${inputType}"]`);

                    if (echoCheckbox) echoCheckbox.checked = settings.processing.echoCancellation;
                    if (noiseCheckbox) noiseCheckbox.checked = settings.processing.noiseSuppression;
                    if (gainCheckbox) gainCheckbox.checked = settings.processing.autoGainControl;
                }
            }
        });
    }

    resetAllInputs() {
        // Stop all input sources
        Object.values(this.audioEngine.inputTypes).forEach(inputType => {
            this.audioEngine.stopInputSource(inputType);
            this.stopLevelMeter(inputType);
        });

        // Reset UI controls
        this.container.querySelectorAll('.enable-btn').forEach(btn => btn.classList.remove('active'));
        this.container.querySelectorAll('.mute-btn').forEach(btn => {
            btn.classList.remove('muted');
            btn.textContent = 'Mute';
        });
        this.container.querySelectorAll('.volume-slider').forEach(slider => slider.value = 100);
        this.container.querySelectorAll('.volume-value').forEach(span => span.textContent = '100%');

        this.updateStatus();
    }

    loadSettings() {
        this.audioEngine.loadMultiInputSettings();
    }

    showNotification(message, type = 'info') {
        // Reuse the existing notification system from the main app
        if (window.app && window.app.showNotification) {
            window.app.showNotification(message, type);
        } else {
            console.log(`[${type.toUpperCase()}] ${message}`);
        }
    }

    show() {
        this.container.style.display = 'block';
        this.isVisible = true;
        this.updateDeviceSelects();
        this.updateUI();
        this.updateStatus();
    }

    hide() {
        this.container.style.display = 'none';
        this.isVisible = false;

        // Stop all level meters
        Object.keys(this.audioEngine.inputTypes).forEach(inputType => {
            this.stopLevelMeter(inputType);
        });
    }

    toggle() {
        if (this.isVisible) {
            this.hide();
        } else {
            this.show();
        }
    }
}

// Export for use in other modules
window.MultiInputManager = MultiInputManager;