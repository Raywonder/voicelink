/**
 * VoiceLink Local - Encryption Status Display UI
 * Shows encryption status indicators on main page and room lists
 */

class EncryptionStatusDisplay {
    constructor() {
        this.serverEncryptionManager = window.serverEncryptionManager;
        this.statusElements = new Map();
        this.currentServerId = null;

        this.init();
    }

    init() {
        this.setupEventListeners();
        this.createStatusStyles();
    }

    setupEventListeners() {
        // Listen for server connection changes
        window.addEventListener('serverConnected', (event) => {
            this.currentServerId = event.detail.serverId;
            this.updateServerStatus();
        });

        window.addEventListener('serverDisconnected', () => {
            this.currentServerId = null;
            this.clearAllStatus();
        });

        // Listen for encryption setting changes
        window.addEventListener('serverEncryptionChanged', (event) => {
            this.updateServerStatus();
            this.updateAllRoomStatus();
        });

        // Listen for room list updates
        window.addEventListener('roomListUpdated', (event) => {
            this.updateRoomListStatus(event.detail.rooms);
        });
    }

    createStatusStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .encryption-status {
                display: inline-flex;
                align-items: center;
                gap: 0.25rem;
                font-size: 0.875rem;
                padding: 0.25rem 0.5rem;
                border-radius: 4px;
                font-weight: 500;
            }

            .encryption-status-icon {
                font-size: 1rem;
            }

            .encryption-enabled {
                background: #d4edda;
                color: #155724;
                border: 1px solid #c3e6cb;
            }

            .encryption-disabled {
                background: #f8d7da;
                color: #721c24;
                border: 1px solid #f5c6cb;
            }

            .encryption-partial {
                background: #fff3cd;
                color: #856404;
                border: 1px solid #ffeaa7;
            }

            .room-status {
                display: inline-flex;
                align-items: center;
                gap: 0.25rem;
                font-size: 0.75rem;
                padding: 0.125rem 0.375rem;
                border-radius: 3px;
                margin-left: 0.5rem;
            }

            .room-public {
                background: #e3f2fd;
                color: #1565c0;
                border: 1px solid #bbdefb;
            }

            .room-unlisted {
                background: #f3e5f5;
                color: #7b1fa2;
                border: 1px solid #e1bee7;
            }

            .room-private {
                background: #fff8e1;
                color: #f57f17;
                border: 1px solid #fff59d;
            }

            .room-encrypted {
                background: #e8f5e8;
                color: #2e7d32;
                border: 1px solid #c8e6c9;
            }

            .room-secure {
                background: #fce4ec;
                color: #c2185b;
                border: 1px solid #f8bbd9;
            }

            .server-encryption-banner {
                display: flex;
                align-items: center;
                justify-content: space-between;
                background: #667eea;
                color: white;
                padding: 0.75rem 1rem;
                margin-bottom: 1rem;
                border-radius: 8px;
                font-weight: 500;
            }

            .server-encryption-banner.disabled {
                background: #9e9e9e;
            }

            .server-encryption-banner .status-text {
                display: flex;
                align-items: center;
                gap: 0.5rem;
            }

            .server-encryption-banner .manage-btn {
                background: rgba(255, 255, 255, 0.2);
                border: 1px solid rgba(255, 255, 255, 0.3);
                color: white;
                padding: 0.25rem 0.5rem;
                border-radius: 4px;
                cursor: pointer;
                font-size: 0.875rem;
                transition: background-color 0.2s;
            }

            .server-encryption-banner .manage-btn:hover,
            .server-encryption-banner .manage-btn:focus {
                background: rgba(255, 255, 255, 0.3);
            }

            .room-list-item .encryption-indicators {
                display: flex;
                gap: 0.5rem;
                align-items: center;
                margin-left: auto;
            }

            .tooltip {
                position: relative;
                cursor: help;
            }

            .tooltip::after {
                content: attr(data-tooltip);
                position: absolute;
                bottom: 100%;
                left: 50%;
                transform: translateX(-50%);
                background: #333;
                color: white;
                padding: 0.5rem;
                border-radius: 4px;
                font-size: 0.75rem;
                white-space: nowrap;
                opacity: 0;
                pointer-events: none;
                transition: opacity 0.3s;
                z-index: 1000;
            }

            .tooltip:hover::after,
            .tooltip:focus::after {
                opacity: 1;
            }

            @media (max-width: 768px) {
                .server-encryption-banner {
                    flex-direction: column;
                    gap: 0.5rem;
                    text-align: center;
                }

                .room-list-item .encryption-indicators {
                    flex-direction: column;
                    gap: 0.25rem;
                }
            }
        `;
        document.head.appendChild(style);
    }

    // Main page server status display
    updateServerStatus() {
        if (!this.currentServerId) return;

        const status = this.serverEncryptionManager.getEncryptionStatusDisplay(this.currentServerId);
        this.displayServerBanner(status.server);
    }

    displayServerBanner(serverStatus) {
        // Find or create server status banner
        let banner = document.querySelector('.server-encryption-banner');
        if (!banner) {
            banner = this.createServerBanner();
        }

        banner.className = `server-encryption-banner ${serverStatus.class}`;

        const statusText = banner.querySelector('.status-text');
        statusText.innerHTML = `
            <span class="encryption-status-icon">${serverStatus.icon}</span>
            <span>${serverStatus.text}</span>
        `;

        // Show/hide manage button based on user permissions
        const manageBtn = banner.querySelector('.manage-btn');
        if (window.serverEncryptionManager.isServerOwner) {
            manageBtn.style.display = 'block';
            manageBtn.textContent = 'Manage Encryption';
            manageBtn.onclick = () => this.openEncryptionSettings();
        } else {
            manageBtn.style.display = 'none';
        }
    }

    createServerBanner() {
        const banner = document.createElement('div');
        banner.className = 'server-encryption-banner';
        banner.innerHTML = `
            <div class="status-text">
                <span class="encryption-status-icon"></span>
                <span></span>
            </div>
            <button class="manage-btn" style="display: none;">Manage Encryption</button>
        `;

        // Insert at the top of main content area
        const mainContent = document.querySelector('.main-content, .content, main');
        if (mainContent) {
            mainContent.insertBefore(banner, mainContent.firstChild);
        }

        return banner;
    }

    // Room list status indicators
    updateRoomListStatus(rooms) {
        if (!rooms || !this.currentServerId) return;

        rooms.forEach(room => {
            this.updateRoomStatus(room.id, room.element);
        });
    }

    updateRoomStatus(roomId, roomElement) {
        if (!roomElement) return;

        const status = this.serverEncryptionManager.getEncryptionStatusDisplay(
            this.currentServerId,
            roomId
        );

        this.displayRoomStatus(roomElement, status);
    }

    displayRoomStatus(roomElement, status) {
        // Remove existing indicators
        const existingIndicators = roomElement.querySelector('.encryption-indicators');
        if (existingIndicators) {
            existingIndicators.remove();
        }

        // Create new indicators container
        const indicators = document.createElement('div');
        indicators.className = 'encryption-indicators';

        // Add server encryption indicator if enabled
        if (status.server.enabled) {
            const serverIndicator = document.createElement('span');
            serverIndicator.className = `encryption-status ${status.server.class} tooltip`;
            serverIndicator.setAttribute('data-tooltip', status.server.text);
            serverIndicator.innerHTML = `
                <span class="encryption-status-icon">${status.server.icon}</span>
            `;
            indicators.appendChild(serverIndicator);
        }

        // Add room privacy indicator
        if (status.room) {
            const roomIndicator = document.createElement('span');
            roomIndicator.className = `room-status ${status.room.class} tooltip`;
            roomIndicator.setAttribute('data-tooltip', status.room.text);
            roomIndicator.innerHTML = `
                <span class="encryption-status-icon">${status.room.icon}</span>
                <span>${status.room.privacy}</span>
            `;
            indicators.appendChild(roomIndicator);
        }

        // Add indicators to room element
        roomElement.appendChild(indicators);
    }

    // Individual room status updates
    updateSingleRoomStatus(roomId) {
        const roomElement = document.querySelector(`[data-room-id="${roomId}"]`);
        if (roomElement) {
            this.updateRoomStatus(roomId, roomElement);
        }
    }

    updateAllRoomStatus() {
        const roomElements = document.querySelectorAll('[data-room-id]');
        roomElements.forEach(element => {
            const roomId = element.getAttribute('data-room-id');
            if (roomId) {
                this.updateRoomStatus(roomId, element);
            }
        });
    }

    // Room creation/settings modal integration
    addRoomPrivacyControls(modal) {
        const privacySection = document.createElement('div');
        privacySection.className = 'room-privacy-section';

        const availableLevels = this.serverEncryptionManager.getAvailablePrivacyLevels();

        privacySection.innerHTML = `
            <h3>Room Privacy Settings</h3>
            <div class="privacy-level-selector">
                ${availableLevels.map(level => this.createPrivacyOption(level)).join('')}
            </div>
            <div class="privacy-description" id="privacy-description">
                Select a privacy level to see details
            </div>
        `;

        // Add event listeners for privacy level selection
        privacySection.addEventListener('change', (event) => {
            if (event.target.name === 'privacy-level') {
                this.updatePrivacyDescription(event.target.value);
            }
        });

        return privacySection;
    }

    createPrivacyOption(level) {
        const descriptions = {
            'public': 'Visible to all users, no encryption',
            'unlisted': 'Not listed publicly, joinable with link',
            'private': 'Invitation only, encrypted communication',
            'encrypted': 'End-to-end encrypted, publicly visible',
            'secure': 'Private and encrypted for maximum security'
        };

        const icons = {
            'public': '🌐',
            'unlisted': '🔗',
            'private': '👥',
            'encrypted': '🔐',
            'secure': '🛡️'
        };

        return `
            <label class="privacy-option">
                <input type="radio" name="privacy-level" value="${level}">
                <span class="privacy-icon">${icons[level]}</span>
                <span class="privacy-label">${level.charAt(0).toUpperCase() + level.slice(1)}</span>
                <span class="privacy-desc">${descriptions[level]}</span>
            </label>
        `;
    }

    updatePrivacyDescription(level) {
        const descriptions = {
            'public': 'Anyone can find and join this room. Communication is not encrypted unless server-wide encryption is enabled.',
            'unlisted': 'Room won\'t appear in public lists but can be joined with a direct link. Communication follows server encryption settings.',
            'private': 'Users must be invited to join. All communication is encrypted regardless of server settings.',
            'encrypted': 'Room is publicly visible but all communication uses end-to-end encryption.',
            'secure': 'Maximum security: invitation-only access with end-to-end encryption for all communication.'
        };

        const descElement = document.getElementById('privacy-description');
        if (descElement) {
            descElement.textContent = descriptions[level] || 'Select a privacy level';
        }
    }

    // Server owner encryption management
    openEncryptionSettings() {
        const modal = this.createEncryptionSettingsModal();
        document.body.appendChild(modal);
        modal.showModal();
    }

    createEncryptionSettingsModal() {
        const modal = document.createElement('dialog');
        modal.className = 'encryption-settings-modal';

        const currentSettings = this.serverEncryptionManager.getServerEncryptionStatus();

        modal.innerHTML = `
            <div class="modal-content">
                <div class="modal-header">
                    <h2>Server Encryption Settings</h2>
                    <button class="close-btn" onclick="this.closest('dialog').close()">&times;</button>
                </div>
                <div class="modal-body">
                    <div class="setting-group">
                        <label class="setting-toggle">
                            <input type="checkbox" id="encryption-enabled" ${currentSettings.enabled ? 'checked' : ''}>
                            <span class="toggle-slider"></span>
                            <span class="toggle-label">Enable Server Encryption</span>
                        </label>
                        <p class="setting-description">
                            When enabled, encryption will be enforced based on the settings below.
                        </p>
                    </div>

                    <div class="setting-group" ${currentSettings.enabled ? '' : 'style="opacity: 0.5;"'}>
                        <label class="setting-toggle">
                            <input type="checkbox" id="enforce-all-rooms" ${currentSettings.enforceForAllRooms ? 'checked' : ''}>
                            <span class="toggle-slider"></span>
                            <span class="toggle-label">Enforce Encryption for All Rooms</span>
                        </label>
                        <p class="setting-description">
                            All rooms will be encrypted regardless of user preferences.
                        </p>
                    </div>

                    <div class="setting-group" ${currentSettings.enabled ? '' : 'style="opacity: 0.5;"'}>
                        <label class="setting-toggle">
                            <input type="checkbox" id="allow-user-override" ${currentSettings.allowUserOverride ? 'checked' : ''}>
                            <span class="toggle-slider"></span>
                            <span class="toggle-label">Allow User Privacy Overrides</span>
                        </label>
                        <p class="setting-description">
                            Users can choose their own room privacy levels within encryption constraints.
                        </p>
                    </div>

                    <div class="setting-group" ${currentSettings.enabled ? '' : 'style="opacity: 0.5;"'}>
                        <label for="encryption-algorithm">Encryption Algorithm:</label>
                        <select id="encryption-algorithm">
                            <option value="AES-256-GCM" ${currentSettings.algorithm === 'AES-256-GCM' ? 'selected' : ''}>AES-256-GCM (Recommended)</option>
                            <option value="ChaCha20-Poly1305" ${currentSettings.algorithm === 'ChaCha20-Poly1305' ? 'selected' : ''}>ChaCha20-Poly1305</option>
                            <option value="AES-128-GCM" ${currentSettings.algorithm === 'AES-128-GCM' ? 'selected' : ''}>AES-128-GCM</option>
                        </select>
                    </div>

                    <div class="setting-group" ${currentSettings.enabled ? '' : 'style="opacity: 0.5;"'}>
                        <label for="key-rotation">Key Rotation Interval:</label>
                        <select id="key-rotation">
                            <option value="3600000" ${currentSettings.keyRotationInterval === 3600000 ? 'selected' : ''}>1 Hour</option>
                            <option value="21600000" ${currentSettings.keyRotationInterval === 21600000 ? 'selected' : ''}>6 Hours</option>
                            <option value="86400000" ${currentSettings.keyRotationInterval === 86400000 ? 'selected' : ''}>24 Hours (Recommended)</option>
                            <option value="604800000" ${currentSettings.keyRotationInterval === 604800000 ? 'selected' : ''}>1 Week</option>
                        </select>
                    </div>
                </div>
                <div class="modal-footer">
                    <button class="btn-secondary" onclick="this.closest('dialog').close()">Cancel</button>
                    <button class="btn-primary" onclick="window.encryptionStatusDisplay.saveEncryptionSettings(this.closest('dialog'))">Save Settings</button>
                </div>
            </div>
        `;

        // Add event listener to toggle dependent settings
        const enabledCheckbox = modal.querySelector('#encryption-enabled');
        enabledCheckbox.addEventListener('change', (e) => {
            const dependentGroups = modal.querySelectorAll('.setting-group:not(:first-child)');
            dependentGroups.forEach(group => {
                group.style.opacity = e.target.checked ? '1' : '0.5';
            });
        });

        return modal;
    }

    saveEncryptionSettings(modal) {
        const enabled = modal.querySelector('#encryption-enabled').checked;
        const enforceAll = modal.querySelector('#enforce-all-rooms').checked;
        const allowOverride = modal.querySelector('#allow-user-override').checked;
        const algorithm = modal.querySelector('#encryption-algorithm').value;
        const keyRotation = parseInt(modal.querySelector('#key-rotation').value);

        try {
            if (enabled) {
                this.serverEncryptionManager.enableServerEncryption(this.currentServerId, {
                    algorithm,
                    keyRotationInterval: keyRotation,
                    enforceForAllRooms: enforceAll,
                    allowUserOverride: allowOverride
                });
            } else {
                this.serverEncryptionManager.disableServerEncryption(this.currentServerId);
            }

            modal.close();
            this.updateServerStatus();
            this.updateAllRoomStatus();
        } catch (error) {
            console.error('Failed to save encryption settings:', error);
            alert('Failed to save encryption settings: ' + error.message);
        }
    }

    // Cleanup methods
    clearAllStatus() {
        const banner = document.querySelector('.server-encryption-banner');
        if (banner) {
            banner.remove();
        }

        const indicators = document.querySelectorAll('.encryption-indicators');
        indicators.forEach(indicator => indicator.remove());
    }

    clearRoomStatus(roomId) {
        const roomElement = document.querySelector(`[data-room-id="${roomId}"]`);
        if (roomElement) {
            const indicators = roomElement.querySelector('.encryption-indicators');
            if (indicators) {
                indicators.remove();
            }
        }
    }
}

// Initialize global instance
window.encryptionStatusDisplay = new EncryptionStatusDisplay();

// Export for module usage
if (typeof module !== 'undefined' && module.exports) {
    module.exports = EncryptionStatusDisplay;
}