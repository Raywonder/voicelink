/**
 * User Settings Interface
 * UI for managing persistent user settings with global/per-server/per-room configurations
 */

class UserSettingsInterface {
    constructor(userSettingsManager) {
        this.userSettingsManager = userSettingsManager;
        this.isVisible = false;
        this.currentTab = 'profile';

        this.init();
    }

    init() {
        this.createInterface();
        this.setupEventListeners();
    }

    createInterface() {
        // Create main container
        this.container = document.createElement('div');
        this.container.id = 'user-settings-interface';
        this.container.className = 'overlay-panel large-panel';
        this.container.style.display = 'none';

        this.container.innerHTML = `
            <div class="panel-header">
                <h3>👤 User Settings</h3>
                <div class="context-selector">
                    <label>Settings for:</label>
                    <select id="settings-context">
                        <option value="global">Global (All Servers)</option>
                        <option value="server">This Server Only</option>
                        <option value="room">This Room Only</option>
                    </select>
                </div>
                <button class="close-btn" onclick="userSettingsInterface.hide()">&times;</button>
            </div>

            <div class="panel-body">
                <div class="settings-tabs">
                    <button class="tab-btn active" data-tab="profile">👤 Profile</button>
                    <button class="tab-btn" data-tab="status">📡 Status</button>
                    <button class="tab-btn" data-tab="audio">🎵 Audio</button>
                    <button class="tab-btn" data-tab="appearance">🎨 Appearance</button>
                    <button class="tab-btn" data-tab="notifications">🔔 Notifications</button>
                    <button class="tab-btn" data-tab="privacy">🔒 Privacy</button>
                    <button class="tab-btn" data-tab="advanced">⚙️ Advanced</button>
                </div>

                <div class="settings-content">
                    <!-- Profile Tab -->
                    <div class="tab-content active" data-tab="profile">
                        <h4>User Profile</h4>

                        <div class="setting-group">
                            <label>Nickname:</label>
                            <input type="text" id="setting-nickname" placeholder="Your display name">
                            <small>This is how others see you in chat</small>
                        </div>

                        <div class="setting-group">
                            <label>Display Name:</label>
                            <input type="text" id="setting-displayName" placeholder="Full name (optional)">
                            <small>Optional full name shown in your profile</small>
                        </div>

                        <div class="setting-group">
                            <label>Avatar URL:</label>
                            <input type="url" id="setting-avatar" placeholder="https://example.com/avatar.jpg">
                            <small>Link to your profile picture</small>
                        </div>

                        <div class="setting-group">
                            <label>Signature:</label>
                            <textarea id="setting-signature" rows="3" placeholder="Your signature... (HTML/links supported)"></textarea>
                            <small>Supports HTML formatting and links. Example: Visit &lt;a href="https://example.com"&gt;my site&lt;/a&gt;</small>
                            <div class="signature-preview">
                                <strong>Preview:</strong>
                                <div id="signature-preview-content"></div>
                            </div>
                        </div>
                    </div>

                    <!-- Status Tab -->
                    <div class="tab-content" data-tab="status">
                        <h4>Status & Presence</h4>

                        <div class="setting-group">
                            <label>Current Status:</label>
                            <div class="status-selector">
                                <select id="setting-status"></select>
                                <div class="status-preview">
                                    <span class="status-icon"></span>
                                    <span class="status-label"></span>
                                </div>
                            </div>
                        </div>

                        <div class="setting-group">
                            <label>Custom Status Message:</label>
                            <input type="text" id="setting-customStatus" placeholder="What are you doing?">
                            <small>Custom message shown with your status</small>
                        </div>

                        <div class="setting-group">
                            <label>Status Message:</label>
                            <input type="text" id="setting-statusMessage" placeholder="Additional status info">
                            <small>Additional information about your current status</small>
                        </div>

                        <div class="setting-group">
                            <h5>Privacy Options</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-showOnlineStatus">
                                Show online status to others
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-showLastSeen">
                                Show "last seen" information
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-showTypingIndicator">
                                Show typing indicator
                            </label>
                        </div>
                    </div>

                    <!-- Audio Tab -->
                    <div class="tab-content" data-tab="audio">
                        <h4>Audio Preferences</h4>

                        <div class="setting-group">
                            <label>Default Volume:</label>
                            <div class="slider-group">
                                <input type="range" id="setting-defaultVolume" min="0" max="100" value="100">
                                <span class="slider-value">100%</span>
                            </div>
                        </div>

                        <div class="setting-group">
                            <label>Microphone Gain:</label>
                            <div class="slider-group">
                                <input type="range" id="setting-microphoneGain" min="0" max="200" value="100">
                                <span class="slider-value">100%</span>
                            </div>
                        </div>

                        <div class="setting-group">
                            <label>Push-to-Talk Key:</label>
                            <input type="text" id="setting-pushToTalkKey" readonly placeholder="Click to set key">
                            <button id="set-ptk-key">Set Key</button>
                        </div>

                        <div class="setting-group">
                            <h5>Audio Processing</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-voiceActivation">
                                Voice Activation (hands-free)
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-noiseSuppression">
                                Noise Suppression
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-echoCancellation">
                                Echo Cancellation
                            </label>
                        </div>
                    </div>

                    <!-- Appearance Tab -->
                    <div class="tab-content" data-tab="appearance">
                        <h4>Appearance</h4>

                        <div class="setting-group">
                            <label>Theme:</label>
                            <select id="setting-theme">
                                <option value="dark">Dark</option>
                                <option value="light">Light</option>
                                <option value="auto">Auto (system)</option>
                            </select>
                        </div>

                        <div class="setting-group">
                            <label>Font Size:</label>
                            <select id="setting-fontSize">
                                <option value="small">Small</option>
                                <option value="medium">Medium</option>
                                <option value="large">Large</option>
                            </select>
                        </div>

                        <div class="setting-group">
                            <h5>Interface Options</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-compactMode">
                                Compact Mode
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-showAvatars">
                                Show User Avatars
                            </label>
                        </div>
                    </div>

                    <!-- Notifications Tab -->
                    <div class="tab-content" data-tab="notifications">
                        <h4>Notifications</h4>

                        <div class="setting-group">
                            <h5>Sound Notifications</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-soundNotifications">
                                Enable sound notifications
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-mentionSound">
                                Play sound when mentioned
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-joinLeaveNotifications">
                                Play sound for user join/leave
                            </label>
                        </div>

                        <div class="setting-group">
                            <h5>Desktop Notifications</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-desktopNotifications">
                                Enable desktop notifications
                            </label>
                        </div>
                    </div>

                    <!-- Privacy Tab -->
                    <div class="tab-content" data-tab="privacy">
                        <h4>Privacy Settings</h4>

                        <div class="setting-group">
                            <h5>Message Privacy</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-allowDirectMessages">
                                Allow direct messages from other users
                            </label>
                        </div>

                        <div class="setting-group">
                            <h5>Data & Storage</h5>
                            <button id="export-settings" class="secondary-btn">Export Settings</button>
                            <button id="import-settings" class="secondary-btn">Import Settings</button>
                            <input type="file" id="import-file" style="display: none" accept=".json">
                        </div>
                    </div>

                    <!-- Advanced Tab -->
                    <div class="tab-content" data-tab="advanced">
                        <h4>Advanced Settings</h4>

                        <div class="setting-group">
                            <h5>Behavior</h5>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-autoJoinLastRoom">
                                Auto-join last room on startup
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-rememberWindowSize">
                                Remember window size and position
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-minimizeToTray">
                                Minimize to system tray
                            </label>
                            <label class="checkbox-label">
                                <input type="checkbox" id="setting-startMinimized">
                                Start minimized
                            </label>
                        </div>

                        <div class="setting-group">
                            <h5>Reset Options</h5>
                            <button id="reset-current-context" class="warning-btn">Reset Current Context</button>
                            <button id="reset-all-settings" class="danger-btn">Reset All Settings</button>
                        </div>
                    </div>
                </div>
            </div>

            <div class="panel-footer">
                <button id="save-settings" class="primary-btn">Save Settings</button>
                <button id="cancel-settings" class="secondary-btn">Cancel</button>
            </div>
        `;

        document.body.appendChild(this.container);
        this.addStyles();
    }

    addStyles() {
        const styles = `
            <style id="user-settings-styles">
                .large-panel {
                    width: 95%;
                    max-width: 900px;
                    max-height: 95vh;
                }

                .panel-body {
                    padding: 0;
                    display: flex;
                    height: calc(100% - 120px);
                }

                .settings-tabs {
                    width: 200px;
                    background: rgba(0, 0, 0, 0.3);
                    padding: 10px 0;
                    border-right: 1px solid rgba(100, 200, 255, 0.2);
                }

                .tab-btn {
                    display: block;
                    width: 100%;
                    padding: 12px 20px;
                    background: none;
                    border: none;
                    color: rgba(255, 255, 255, 0.7);
                    text-align: left;
                    cursor: pointer;
                    transition: all 0.3s ease;
                    font-size: 0.9em;
                }

                .tab-btn:hover, .tab-btn.active {
                    background: rgba(100, 200, 255, 0.2);
                    color: white;
                }

                .settings-content {
                    flex: 1;
                    padding: 20px;
                    overflow-y: auto;
                }

                .tab-content {
                    display: none;
                }

                .tab-content.active {
                    display: block;
                }

                .setting-group {
                    margin-bottom: 25px;
                }

                .setting-group label {
                    display: block;
                    margin-bottom: 8px;
                    font-weight: bold;
                    color: #64c8ff;
                }

                .setting-group input, .setting-group select, .setting-group textarea {
                    width: 100%;
                    padding: 10px;
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(100, 200, 255, 0.3);
                    border-radius: 4px;
                    color: white;
                    font-size: 0.9em;
                }

                .setting-group textarea {
                    resize: vertical;
                    min-height: 80px;
                }

                .setting-group small {
                    display: block;
                    margin-top: 5px;
                    color: rgba(255, 255, 255, 0.6);
                    font-size: 0.8em;
                }

                .checkbox-label {
                    display: flex !important;
                    align-items: center;
                    margin-bottom: 10px !important;
                    font-weight: normal !important;
                    cursor: pointer;
                }

                .checkbox-label input[type="checkbox"] {
                    width: auto !important;
                    margin-right: 10px;
                }

                .slider-group {
                    display: flex;
                    align-items: center;
                    gap: 15px;
                }

                .slider-group input[type="range"] {
                    flex: 1;
                }

                .slider-value {
                    min-width: 50px;
                    text-align: right;
                    font-weight: bold;
                    color: #64c8ff;
                }

                .status-selector {
                    display: flex;
                    align-items: center;
                    gap: 15px;
                }

                .status-preview {
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    padding: 8px 12px;
                    background: rgba(255, 255, 255, 0.1);
                    border-radius: 4px;
                    min-width: 150px;
                }

                .status-icon {
                    font-size: 1.2em;
                }

                .signature-preview {
                    margin-top: 10px;
                    padding: 10px;
                    background: rgba(255, 255, 255, 0.05);
                    border-radius: 4px;
                    border: 1px solid rgba(100, 200, 255, 0.2);
                }

                #signature-preview-content {
                    margin-top: 5px;
                    min-height: 20px;
                }

                #signature-preview-content a {
                    color: #64c8ff;
                }

                .context-selector {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                }

                .context-selector label {
                    font-size: 0.9em;
                    color: rgba(255, 255, 255, 0.8);
                }

                .context-selector select {
                    padding: 5px 10px;
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(100, 200, 255, 0.3);
                    border-radius: 4px;
                    color: white;
                    font-size: 0.85em;
                }

                .panel-footer {
                    padding: 15px 20px;
                    border-top: 1px solid rgba(100, 200, 255, 0.2);
                    display: flex;
                    gap: 10px;
                    justify-content: flex-end;
                }

                .warning-btn {
                    background: rgba(255, 165, 0, 0.2);
                    border: 1px solid rgba(255, 165, 0, 0.5);
                    color: white;
                    padding: 8px 16px;
                    border-radius: 4px;
                    cursor: pointer;
                }

                .danger-btn {
                    background: rgba(255, 100, 100, 0.2);
                    border: 1px solid rgba(255, 100, 100, 0.5);
                    color: white;
                    padding: 8px 16px;
                    border-radius: 4px;
                    cursor: pointer;
                }

                .warning-btn:hover, .danger-btn:hover {
                    opacity: 0.8;
                }
            </style>
        `;

        if (!document.getElementById('user-settings-styles')) {
            document.head.insertAdjacentHTML('beforeend', styles);
        }
    }

    setupEventListeners() {
        // Tab switching
        this.container.querySelectorAll('.tab-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                this.switchTab(e.target.dataset.tab);
            });
        });

        // Settings context change
        document.getElementById('settings-context')?.addEventListener('change', (e) => {
            this.updateContextDisplay(e.target.value);
        });

        // Status change
        document.getElementById('setting-status')?.addEventListener('change', (e) => {
            this.updateStatusPreview(e.target.value);
        });

        // Signature preview
        document.getElementById('setting-signature')?.addEventListener('input', (e) => {
            this.updateSignaturePreview(e.target.value);
        });

        // Slider updates
        this.container.querySelectorAll('input[type="range"]').forEach(slider => {
            slider.addEventListener('input', (e) => {
                const valueSpan = e.target.parentNode.querySelector('.slider-value');
                if (valueSpan) {
                    valueSpan.textContent = e.target.value + '%';
                }
            });
        });

        // Save/Cancel buttons
        document.getElementById('save-settings')?.addEventListener('click', () => {
            this.saveSettings();
        });

        document.getElementById('cancel-settings')?.addEventListener('click', () => {
            this.hide();
        });

        // Export/Import settings
        document.getElementById('export-settings')?.addEventListener('click', () => {
            this.exportSettings();
        });

        document.getElementById('import-settings')?.addEventListener('click', () => {
            document.getElementById('import-file').click();
        });

        document.getElementById('import-file')?.addEventListener('change', (e) => {
            this.importSettings(e.target.files[0]);
        });

        // Reset buttons
        document.getElementById('reset-current-context')?.addEventListener('click', () => {
            this.resetCurrentContext();
        });

        document.getElementById('reset-all-settings')?.addEventListener('click', () => {
            this.resetAllSettings();
        });
    }

    switchTab(tabName) {
        // Update tab buttons
        this.container.querySelectorAll('.tab-btn').forEach(btn => {
            btn.classList.remove('active');
        });
        this.container.querySelector(`[data-tab="${tabName}"]`).classList.add('active');

        // Update tab content
        this.container.querySelectorAll('.tab-content').forEach(content => {
            content.classList.remove('active');
        });
        this.container.querySelector(`.tab-content[data-tab="${tabName}"]`).classList.add('active');

        this.currentTab = tabName;
    }

    show() {
        this.container.style.display = 'block';
        this.isVisible = true;
        this.populateStatusOptions();
        this.loadCurrentSettings();
    }

    hide() {
        this.container.style.display = 'none';
        this.isVisible = false;
    }

    populateStatusOptions() {
        const statusSelect = document.getElementById('setting-status');
        if (!statusSelect) return;

        statusSelect.innerHTML = '';
        const statusTypes = this.userSettingsManager.getAvailableStatusTypes();

        Object.entries(statusTypes).forEach(([key, status]) => {
            const option = document.createElement('option');
            option.value = key;
            option.textContent = `${status.icon} ${status.label}`;
            statusSelect.appendChild(option);
        });
    }

    updateStatusPreview(statusKey) {
        const statusTypes = this.userSettingsManager.getAvailableStatusTypes();
        const status = statusTypes[statusKey];

        if (status) {
            const icon = this.container.querySelector('.status-icon');
            const label = this.container.querySelector('.status-label');

            if (icon) icon.textContent = status.icon;
            if (label) {
                label.textContent = status.label;
                label.style.color = status.color;
            }
        }
    }

    updateSignaturePreview(signature) {
        const preview = document.getElementById('signature-preview-content');
        if (preview) {
            preview.innerHTML = this.userSettingsManager.parseSignatureForDisplay(signature);
        }
    }

    loadCurrentSettings() {
        // Load all settings into the form
        const settingInputs = this.container.querySelectorAll('[id^="setting-"]');

        settingInputs.forEach(input => {
            const settingKey = input.id.replace('setting-', '');
            const value = this.userSettingsManager.getSetting(settingKey);

            if (input.type === 'checkbox') {
                input.checked = Boolean(value);
            } else if (input.type === 'range') {
                input.value = value || 100;
                const valueSpan = input.parentNode.querySelector('.slider-value');
                if (valueSpan) {
                    valueSpan.textContent = (value || 100) + '%';
                }
            } else {
                input.value = value || '';
            }
        });

        // Update status preview
        const currentStatus = this.userSettingsManager.getSetting('status');
        this.updateStatusPreview(currentStatus);

        // Update signature preview
        const currentSignature = this.userSettingsManager.getSetting('signature');
        this.updateSignaturePreview(currentSignature);
    }

    saveSettings() {
        const context = document.getElementById('settings-context').value;
        const settingInputs = this.container.querySelectorAll('[id^="setting-"]');

        settingInputs.forEach(input => {
            const settingKey = input.id.replace('setting-', '');
            let value;

            if (input.type === 'checkbox') {
                value = input.checked;
            } else if (input.type === 'range') {
                value = parseInt(input.value);
            } else {
                value = input.value;
            }

            // Save based on context
            if (context === 'global') {
                this.userSettingsManager.setGlobalSetting(settingKey, value);
            } else if (context === 'server') {
                const serverId = this.userSettingsManager.currentServerId || 'local';
                this.userSettingsManager.setServerSetting(serverId, settingKey, value);
            } else if (context === 'room') {
                const roomId = this.userSettingsManager.currentRoomId || 'default';
                this.userSettingsManager.setRoomSetting(roomId, settingKey, value);
            }
        });

        this.showNotification('Settings saved successfully!', 'success');
        this.hide();
    }

    exportSettings() {
        const settings = this.userSettingsManager.exportAllSettings();
        const blob = new Blob([JSON.stringify(settings, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);

        const a = document.createElement('a');
        a.href = url;
        a.download = `voicelink-settings-${new Date().toISOString().split('T')[0]}.json`;
        a.click();

        URL.revokeObjectURL(url);
        this.showNotification('Settings exported successfully!', 'success');
    }

    importSettings(file) {
        if (!file) return;

        const reader = new FileReader();
        reader.onload = (e) => {
            try {
                const settings = JSON.parse(e.target.result);
                if (this.userSettingsManager.importAllSettings(settings)) {
                    this.loadCurrentSettings();
                    this.showNotification('Settings imported successfully!', 'success');
                } else {
                    this.showNotification('Failed to import settings', 'error');
                }
            } catch (error) {
                this.showNotification('Invalid settings file', 'error');
            }
        };
        reader.readAsText(file);
    }

    resetCurrentContext() {
        const context = document.getElementById('settings-context').value;
        if (confirm(`Reset all ${context} settings to defaults?`)) {
            const contextId = context === 'server' ?
                (this.userSettingsManager.currentServerId || 'local') :
                (this.userSettingsManager.currentRoomId || 'default');

            this.userSettingsManager.resetToDefaults(context, contextId);
            this.loadCurrentSettings();
            this.showNotification(`${context} settings reset to defaults`, 'info');
        }
    }

    resetAllSettings() {
        if (confirm('Reset ALL settings to defaults? This cannot be undone!')) {
            this.userSettingsManager.resetToDefaults('global');
            this.loadCurrentSettings();
            this.showNotification('All settings reset to defaults', 'info');
        }
    }

    showNotification(message, type = 'info') {
        if (window.app && window.app.showNotification) {
            window.app.showNotification(message, type);
        } else {
            console.log(`[${type.toUpperCase()}] ${message}`);
        }
    }

    updateContextDisplay(context) {
        // Update UI to show which context is being edited
        const contextLabel = {
            'global': 'Global (All Servers)',
            'server': 'This Server Only',
            'room': 'This Room Only'
        }[context];

        console.log(`Editing ${contextLabel} settings`);
        this.loadCurrentSettings();
    }
}

// Export for use in other modules
window.UserSettingsInterface = UserSettingsInterface;