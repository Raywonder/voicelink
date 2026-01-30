class TTSAnnouncementManager {
    constructor(paSystemManager, builtinEffectsProcessor, audioEngine) {
        this.paSystemManager = paSystemManager;
        this.effectsProcessor = builtinEffectsProcessor;
        this.audioEngine = audioEngine;

        // TTS Configuration
        this.ttsConfig = {
            voice: 'default',
            rate: 1.0,
            pitch: 1.0,
            volume: 1.0,
            language: 'en-US',
            enableEffects: true,
            announcementPrefix: 'Attention all users',
            adminPrefix: 'Administrator announcement',
            emergencyPrefix: 'Emergency alert',
            systemPrefix: 'System notification'
        };

        // Available TTS voices
        this.availableVoices = [];
        this.systemVoices = new Map();

        // Announcement queue
        this.announcementQueue = [];
        this.isAnnouncing = false;

        // Predefined announcements
        this.predefinedAnnouncements = new Map();

        this.init();
    }

    init() {
        this.loadAvailableVoices();
        this.createPredefinedAnnouncements();
        this.createAnnouncementInterface();
        this.loadTTSConfiguration();
    }

    // Load available TTS voices
    loadAvailableVoices() {
        if ('speechSynthesis' in window) {
            const updateVoices = () => {
                this.availableVoices = speechSynthesis.getVoices();
                this.categorizeVoices();
            };

            updateVoices();
            speechSynthesis.onvoiceschanged = updateVoices;
        }
    }

    // Categorize voices by language and gender
    categorizeVoices() {
        this.systemVoices.clear();

        this.availableVoices.forEach(voice => {
            const category = {
                name: voice.name,
                lang: voice.lang,
                gender: this.detectGender(voice.name),
                quality: this.detectQuality(voice.name),
                voice: voice
            };

            const key = `${voice.lang}_${category.gender}`;
            if (!this.systemVoices.has(key)) {
                this.systemVoices.set(key, []);
            }
            this.systemVoices.get(key).push(category);
        });
    }

    // Detect gender from voice name
    detectGender(voiceName) {
        const name = voiceName.toLowerCase();
        const femaleNames = ['female', 'woman', 'girl', 'sara', 'samantha', 'alex', 'alice', 'emma', 'victoria', 'zoe'];
        const maleNames = ['male', 'man', 'boy', 'daniel', 'thomas', 'fred', 'george', 'nathan', 'arthur'];

        for (const femaleName of femaleNames) {
            if (name.includes(femaleName)) return 'female';
        }
        for (const maleName of maleNames) {
            if (name.includes(maleName)) return 'male';
        }

        return 'neutral';
    }

    // Detect voice quality
    detectQuality(voiceName) {
        const name = voiceName.toLowerCase();
        if (name.includes('premium') || name.includes('enhanced') || name.includes('neural')) {
            return 'high';
        } else if (name.includes('compact') || name.includes('basic')) {
            return 'low';
        }
        return 'medium';
    }

    // Create predefined announcements
    createPredefinedAnnouncements() {
        // System announcements
        this.predefinedAnnouncements.set('server_maintenance', {
            type: 'system',
            text: 'Server maintenance will begin in 5 minutes. Please save your work and prepare to disconnect.',
            voice: 'system',
            effects: 'radio_voice'
        });

        this.predefinedAnnouncements.set('server_restart', {
            type: 'system',
            text: 'The server will restart in 60 seconds. All users will be disconnected.',
            voice: 'system',
            effects: 'radio_voice'
        });

        this.predefinedAnnouncements.set('backup_starting', {
            type: 'system',
            text: 'Automated backup process starting. You may experience brief audio interruptions.',
            voice: 'system',
            effects: 'radio_voice'
        });

        // Admin announcements
        this.predefinedAnnouncements.set('meeting_starting', {
            type: 'admin',
            text: 'The scheduled meeting will begin in 2 minutes. Please join the main conference room.',
            voice: 'admin',
            effects: 'podcast_voice'
        });

        this.predefinedAnnouncements.set('quiet_hours', {
            type: 'admin',
            text: 'Quiet hours are now in effect. Please keep voice communication to a minimum.',
            voice: 'admin',
            effects: 'podcast_voice'
        });

        this.predefinedAnnouncements.set('new_user_welcome', {
            type: 'admin',
            text: 'Welcome to VoiceLink. Please review the user guidelines and configure your audio settings.',
            voice: 'admin',
            effects: 'podcast_voice'
        });

        // Emergency announcements
        this.predefinedAnnouncements.set('fire_drill', {
            type: 'emergency',
            text: 'This is a fire drill. Please log off immediately and proceed to your designated assembly point.',
            voice: 'emergency',
            effects: 'emergency_alert'
        });

        this.predefinedAnnouncements.set('security_breach', {
            type: 'emergency',
            text: 'Security alert. Unauthorized access detected. All users must verify their identity.',
            voice: 'emergency',
            effects: 'emergency_alert'
        });

        this.predefinedAnnouncements.set('system_failure', {
            type: 'emergency',
            text: 'Critical system failure detected. Please disconnect immediately to prevent data loss.',
            voice: 'emergency',
            effects: 'emergency_alert'
        });

        // User helpful announcements
        this.predefinedAnnouncements.set('audio_test_reminder', {
            type: 'user',
            text: 'Remember to test your audio settings regularly for the best voice chat experience.',
            voice: 'user',
            effects: 'whisper_enhance'
        });

        this.predefinedAnnouncements.set('spatial_audio_tip', {
            type: 'user',
            text: 'Tip: Enable 3D spatial audio for a more immersive voice chat experience.',
            voice: 'user',
            effects: 'whisper_enhance'
        });

        this.predefinedAnnouncements.set('keyboard_shortcuts', {
            type: 'user',
            text: 'Press Control for global announcements, Command for direct messages, and Shift for whisper mode.',
            voice: 'user',
            effects: 'whisper_enhance'
        });

        // Fun announcements
        this.predefinedAnnouncements.set('birthday_celebration', {
            type: 'celebration',
            text: 'Happy birthday! The community wishes you a wonderful day filled with great conversations.',
            voice: 'celebration',
            effects: 'enhancer'
        });

        this.predefinedAnnouncements.set('milestone_reached', {
            type: 'celebration',
            text: 'Congratulations! The server has reached a new milestone of active users.',
            voice: 'celebration',
            effects: 'enhancer'
        });
    }

    // Create TTS announcement interface
    createAnnouncementInterface() {
        const interfaceHTML = `
            <div id="tts-announcement-interface" class="tts-interface hidden">
                <div class="tts-header">
                    <h3>📢 Text-to-Speech Announcements</h3>
                    <button id="close-tts-interface" class="close-button">×</button>
                </div>

                <div class="tts-content">
                    <div class="tts-tabs">
                        <button class="tts-tab active" data-tab="custom">Custom Message</button>
                        <button class="tts-tab" data-tab="predefined">Quick Announcements</button>
                        <button class="tts-tab" data-tab="settings">Voice Settings</button>
                    </div>

                    <div class="tts-tab-content active" data-tab="custom">
                        <h4>Custom Announcement</h4>
                        <div class="announcement-form">
                            <div class="form-group">
                                <label>Announcement Type:</label>
                                <select id="announcement-type">
                                    <option value="user">User Announcement</option>
                                    <option value="admin">Admin Announcement</option>
                                    <option value="system">System Notification</option>
                                    <option value="emergency">Emergency Alert</option>
                                </select>
                            </div>

                            <div class="form-group">
                                <label>Message Text:</label>
                                <textarea id="announcement-text" rows="4" placeholder="Enter your announcement message..."></textarea>
                                <div class="character-count">
                                    <span id="char-count">0</span>/500 characters
                                </div>
                            </div>

                            <div class="form-group">
                                <label>Voice:</label>
                                <select id="announcement-voice">
                                    <option value="default">Default System Voice</option>
                                </select>
                            </div>

                            <div class="form-group">
                                <label>Audio Effects:</label>
                                <select id="announcement-effects">
                                    <option value="none">No Effects</option>
                                    <option value="radio_voice">Radio Voice</option>
                                    <option value="podcast_voice">Podcast Voice</option>
                                    <option value="emergency_alert">Emergency Alert</option>
                                    <option value="intercom_classic">Intercom Classic</option>
                                    <option value="robot_voice">Robot Voice</option>
                                </select>
                            </div>

                            <div class="form-group">
                                <label>Delivery Method:</label>
                                <select id="delivery-method">
                                    <option value="global">Global Broadcast</option>
                                    <option value="room">Current Room Only</option>
                                    <option value="direct">Direct to Selected Users</option>
                                    <option value="proximity">Proximity-based</option>
                                </select>
                            </div>

                            <div class="form-buttons">
                                <button id="preview-announcement" class="button secondary">🔊 Preview</button>
                                <button id="send-announcement" class="button primary">📢 Send Announcement</button>
                            </div>
                        </div>
                    </div>

                    <div class="tts-tab-content" data-tab="predefined">
                        <h4>Quick Announcements</h4>
                        <div class="predefined-grid" id="predefined-announcements">
                            <!-- Predefined announcements will be populated here -->
                        </div>
                    </div>

                    <div class="tts-tab-content" data-tab="settings">
                        <h4>Voice Settings</h4>
                        <div class="voice-settings">
                            <div class="setting-group">
                                <label>Speech Rate:</label>
                                <input type="range" id="speech-rate" min="0.5" max="2.0" step="0.1" value="1.0">
                                <span class="range-value">1.0</span>
                            </div>

                            <div class="setting-group">
                                <label>Voice Pitch:</label>
                                <input type="range" id="voice-pitch" min="0.5" max="2.0" step="0.1" value="1.0">
                                <span class="range-value">1.0</span>
                            </div>

                            <div class="setting-group">
                                <label>Volume Level:</label>
                                <input type="range" id="voice-volume" min="0.1" max="1.0" step="0.1" value="1.0">
                                <span class="range-value">1.0</span>
                            </div>

                            <div class="setting-group">
                                <label>Default Language:</label>
                                <select id="default-language">
                                    <option value="en-US">English (US)</option>
                                    <option value="en-GB">English (UK)</option>
                                    <option value="es-ES">Spanish</option>
                                    <option value="fr-FR">French</option>
                                    <option value="de-DE">German</option>
                                    <option value="it-IT">Italian</option>
                                    <option value="pt-BR">Portuguese</option>
                                    <option value="ja-JP">Japanese</option>
                                    <option value="ko-KR">Korean</option>
                                    <option value="zh-CN">Chinese (Simplified)</option>
                                </select>
                            </div>

                            <div class="setting-group">
                                <label>
                                    <input type="checkbox" id="enable-effects" checked>
                                    Enable Audio Effects for Announcements
                                </label>
                            </div>

                            <div class="setting-group">
                                <label>Announcement Prefix:</label>
                                <input type="text" id="announcement-prefix" value="Attention all users" placeholder="Prefix for announcements">
                            </div>

                            <div class="setting-buttons">
                                <button id="test-voice-settings" class="button secondary">Test Voice</button>
                                <button id="save-voice-settings" class="button primary">Save Settings</button>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="announcement-queue" id="announcement-queue">
                    <h4>Announcement Queue (<span id="queue-count">0</span>)</h4>
                    <div class="queue-list" id="queue-list">
                        <!-- Queued announcements will appear here -->
                    </div>
                </div>
            </div>
        `;

        document.body.insertAdjacentHTML('beforeend', interfaceHTML);
        this.addTTSStyles();
        this.bindTTSEvents();
        this.populateVoiceOptions();
        this.populatePredefinedAnnouncements();
    }

    // Add CSS styles for TTS interface
    addTTSStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .tts-interface {
                position: fixed;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                width: 800px;
                max-width: 90vw;
                max-height: 90vh;
                background: linear-gradient(135deg, #1e3c72, #2a5298);
                border-radius: 15px;
                box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
                z-index: 10000;
                color: white;
                overflow: hidden;
            }

            .tts-interface.hidden {
                display: none;
            }

            .tts-header {
                background: linear-gradient(135deg, #667eea, #764ba2);
                padding: 20px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                border-bottom: 1px solid rgba(255, 255, 255, 0.2);
            }

            .tts-header h3 {
                margin: 0;
                font-size: 18px;
            }

            .tts-content {
                padding: 20px;
                max-height: 60vh;
                overflow-y: auto;
            }

            .tts-tabs {
                display: flex;
                gap: 10px;
                margin-bottom: 20px;
                border-bottom: 1px solid rgba(255, 255, 255, 0.2);
            }

            .tts-tab {
                padding: 10px 15px;
                background: none;
                border: none;
                color: rgba(255, 255, 255, 0.7);
                cursor: pointer;
                border-bottom: 2px solid transparent;
                transition: all 0.3s ease;
            }

            .tts-tab:hover {
                color: white;
            }

            .tts-tab.active {
                color: white;
                border-bottom-color: #667eea;
            }

            .tts-tab-content {
                display: none;
            }

            .tts-tab-content.active {
                display: block;
            }

            .announcement-form {
                display: flex;
                flex-direction: column;
                gap: 15px;
            }

            .form-group {
                display: flex;
                flex-direction: column;
                gap: 5px;
            }

            .form-group label {
                font-weight: 500;
                font-size: 14px;
            }

            .form-group input,
            .form-group select,
            .form-group textarea {
                padding: 10px;
                border: 1px solid rgba(255, 255, 255, 0.3);
                border-radius: 5px;
                background: rgba(255, 255, 255, 0.1);
                color: white;
                font-size: 14px;
            }

            .form-group input::placeholder,
            .form-group textarea::placeholder {
                color: rgba(255, 255, 255, 0.5);
            }

            .character-count {
                text-align: right;
                font-size: 12px;
                color: rgba(255, 255, 255, 0.6);
            }

            .form-buttons {
                display: flex;
                gap: 10px;
                justify-content: flex-end;
                margin-top: 10px;
            }

            .predefined-grid {
                display: grid;
                grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
                gap: 15px;
            }

            .predefined-item {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 8px;
                padding: 15px;
                border: 1px solid rgba(255, 255, 255, 0.2);
                cursor: pointer;
                transition: all 0.3s ease;
            }

            .predefined-item:hover {
                background: rgba(255, 255, 255, 0.2);
                transform: translateY(-2px);
            }

            .predefined-item h5 {
                margin: 0 0 10px 0;
                color: #667eea;
                font-size: 14px;
                text-transform: uppercase;
            }

            .predefined-item p {
                margin: 0;
                font-size: 13px;
                line-height: 1.4;
                color: rgba(255, 255, 255, 0.9);
            }

            .voice-settings {
                display: flex;
                flex-direction: column;
                gap: 15px;
            }

            .setting-group {
                display: flex;
                flex-direction: column;
                gap: 5px;
            }

            .setting-group label {
                font-weight: 500;
                font-size: 14px;
                display: flex;
                align-items: center;
                gap: 10px;
            }

            .setting-group input[type="range"] {
                width: 100%;
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

            .setting-buttons {
                display: flex;
                gap: 10px;
                justify-content: flex-end;
                margin-top: 15px;
            }

            .announcement-queue {
                background: rgba(0, 0, 0, 0.3);
                border-top: 1px solid rgba(255, 255, 255, 0.2);
                padding: 15px 20px;
                max-height: 200px;
                overflow-y: auto;
            }

            .announcement-queue h4 {
                margin: 0 0 10px 0;
                font-size: 14px;
                color: rgba(255, 255, 255, 0.8);
            }

            .queue-item {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 5px;
                padding: 10px;
                margin-bottom: 8px;
                display: flex;
                justify-content: space-between;
                align-items: center;
            }

            .queue-item-info {
                flex: 1;
            }

            .queue-item-type {
                font-size: 11px;
                text-transform: uppercase;
                color: #667eea;
                margin-bottom: 3px;
            }

            .queue-item-text {
                font-size: 13px;
                color: white;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                max-width: 300px;
            }

            .queue-item-controls {
                display: flex;
                gap: 5px;
            }

            .queue-item-controls button {
                padding: 4px 8px;
                font-size: 11px;
                border: none;
                border-radius: 3px;
                cursor: pointer;
                transition: background 0.3s ease;
            }

            .queue-item-controls .play-button {
                background: #28a745;
                color: white;
            }

            .queue-item-controls .remove-button {
                background: #dc3545;
                color: white;
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
        `;
        document.head.appendChild(style);
    }

    // Bind TTS interface events
    bindTTSEvents() {
        // Tab switching
        document.querySelectorAll('.tts-tab').forEach(tab => {
            tab.addEventListener('click', (e) => {
                const tabName = e.target.dataset.tab;
                this.switchTTSTab(tabName);
            });
        });

        // Close interface
        document.getElementById('close-tts-interface').addEventListener('click', () => {
            this.hideTTSInterface();
        });

        // Character count
        document.getElementById('announcement-text').addEventListener('input', (e) => {
            const count = e.target.value.length;
            document.getElementById('char-count').textContent = count;

            if (count > 500) {
                e.target.value = e.target.value.substring(0, 500);
                document.getElementById('char-count').textContent = 500;
            }
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

        // Preview announcement
        document.getElementById('preview-announcement').addEventListener('click', () => {
            this.previewAnnouncement();
        });

        // Send announcement
        document.getElementById('send-announcement').addEventListener('click', () => {
            this.sendCustomAnnouncement();
        });

        // Test voice settings
        document.getElementById('test-voice-settings').addEventListener('click', () => {
            this.testVoiceSettings();
        });

        // Save voice settings
        document.getElementById('save-voice-settings').addEventListener('click', () => {
            this.saveVoiceSettings();
        });
    }

    // Switch TTS tab
    switchTTSTab(tabName) {
        // Update tab buttons
        document.querySelectorAll('.tts-tab').forEach(tab => {
            tab.classList.remove('active');
        });
        document.querySelector(`[data-tab="${tabName}"]`).classList.add('active');

        // Update tab content
        document.querySelectorAll('.tts-tab-content').forEach(content => {
            content.classList.remove('active');
        });
        document.querySelector(`.tts-tab-content[data-tab="${tabName}"]`).classList.add('active');
    }

    // Show TTS interface
    showTTSInterface() {
        document.getElementById('tts-announcement-interface').classList.remove('hidden');
        this.updateAnnouncementQueue();
    }

    // Hide TTS interface
    hideTTSInterface() {
        document.getElementById('tts-announcement-interface').classList.add('hidden');
    }

    // Populate voice options
    populateVoiceOptions() {
        const voiceSelect = document.getElementById('announcement-voice');
        voiceSelect.innerHTML = '<option value="default">Default System Voice</option>';

        this.availableVoices.forEach(voice => {
            const option = document.createElement('option');
            option.value = voice.name;
            option.textContent = `${voice.name} (${voice.lang})`;
            voiceSelect.appendChild(option);
        });
    }

    // Populate predefined announcements
    populatePredefinedAnnouncements() {
        const grid = document.getElementById('predefined-announcements');
        grid.innerHTML = '';

        this.predefinedAnnouncements.forEach((announcement, key) => {
            const item = document.createElement('div');
            item.className = 'predefined-item';
            item.innerHTML = `
                <h5>${announcement.type} Announcement</h5>
                <p>${announcement.text}</p>
            `;

            item.addEventListener('click', () => {
                this.sendPredefinedAnnouncement(key);
            });

            grid.appendChild(item);
        });
    }

    // Preview announcement
    async previewAnnouncement() {
        const text = document.getElementById('announcement-text').value;
        const voiceName = document.getElementById('announcement-voice').value;
        const effects = document.getElementById('announcement-effects').value;

        if (!text.trim()) {
            alert('Please enter announcement text');
            return;
        }

        try {
            const audioData = await this.generateTTSAudio(text, voiceName, effects);
            this.playAudioPreview(audioData);
        } catch (error) {
            console.error('Error previewing announcement:', error);
            alert('Error generating preview');
        }
    }

    // Send custom announcement
    async sendCustomAnnouncement() {
        const type = document.getElementById('announcement-type').value;
        const text = document.getElementById('announcement-text').value;
        const voiceName = document.getElementById('announcement-voice').value;
        const effects = document.getElementById('announcement-effects').value;
        const delivery = document.getElementById('delivery-method').value;

        if (!text.trim()) {
            alert('Please enter announcement text');
            return;
        }

        const announcement = {
            id: `custom_${Date.now()}`,
            type: type,
            text: this.addPrefix(text, type),
            voice: voiceName,
            effects: effects,
            delivery: delivery,
            timestamp: Date.now()
        };

        this.queueAnnouncement(announcement);
    }

    // Send predefined announcement
    sendPredefinedAnnouncement(key) {
        const announcement = this.predefinedAnnouncements.get(key);
        if (announcement) {
            const queuedAnnouncement = {
                id: `predefined_${key}_${Date.now()}`,
                ...announcement,
                text: this.addPrefix(announcement.text, announcement.type),
                delivery: 'global',
                timestamp: Date.now()
            };

            this.queueAnnouncement(queuedAnnouncement);
        }
    }

    // Add prefix to announcement text
    addPrefix(text, type) {
        const prefixes = {
            admin: this.ttsConfig.adminPrefix,
            system: this.ttsConfig.systemPrefix,
            emergency: this.ttsConfig.emergencyPrefix,
            user: this.ttsConfig.announcementPrefix
        };

        const prefix = prefixes[type] || this.ttsConfig.announcementPrefix;
        return `${prefix}. ${text}`;
    }

    // Queue announcement
    queueAnnouncement(announcement) {
        this.announcementQueue.push(announcement);
        this.updateAnnouncementQueue();

        if (!this.isAnnouncing) {
            this.processAnnouncementQueue();
        }
    }

    // Process announcement queue
    async processAnnouncementQueue() {
        if (this.announcementQueue.length === 0 || this.isAnnouncing) {
            return;
        }

        this.isAnnouncing = true;

        while (this.announcementQueue.length > 0) {
            const announcement = this.announcementQueue.shift();

            try {
                await this.deliverAnnouncement(announcement);
                this.updateAnnouncementQueue();

                // Wait between announcements
                await new Promise(resolve => setTimeout(resolve, 1000));
            } catch (error) {
                console.error('Error delivering announcement:', error);
            }
        }

        this.isAnnouncing = false;
    }

    // Deliver announcement
    async deliverAnnouncement(announcement) {
        try {
            // Generate TTS audio
            const audioData = await this.generateTTSAudio(
                announcement.text,
                announcement.voice,
                announcement.effects
            );

            // Send via PA system based on delivery method
            switch (announcement.delivery) {
                case 'global':
                    await this.paSystemManager.broadcastTTSAnnouncement(audioData, announcement.type);
                    break;
                case 'room':
                    await this.paSystemManager.broadcastToRoom(audioData, announcement.type);
                    break;
                case 'direct':
                    await this.paSystemManager.sendDirectTTS(audioData, announcement.targetUsers);
                    break;
                case 'proximity':
                    await this.paSystemManager.proximityTTS(audioData);
                    break;
            }

            console.log('Announcement delivered:', announcement.text);
        } catch (error) {
            console.error('Error delivering announcement:', error);
            throw error;
        }
    }

    // Generate TTS audio
    async generateTTSAudio(text, voiceName, effects) {
        return new Promise((resolve, reject) => {
            if (!('speechSynthesis' in window)) {
                reject(new Error('Speech synthesis not supported'));
                return;
            }

            const utterance = new SpeechSynthesisUtterance(text);

            // Configure voice
            if (voiceName !== 'default') {
                const voice = this.availableVoices.find(v => v.name === voiceName);
                if (voice) {
                    utterance.voice = voice;
                }
            }

            // Configure speech parameters
            utterance.rate = this.ttsConfig.rate;
            utterance.pitch = this.ttsConfig.pitch;
            utterance.volume = this.ttsConfig.volume;
            utterance.lang = this.ttsConfig.language;

            // Create audio context for processing
            const audioContext = this.audioEngine.audioContext;
            const destination = audioContext.createMediaStreamDestination();

            // Apply effects if enabled
            if (this.ttsConfig.enableEffects && effects !== 'none' && this.effectsProcessor) {
                const effectChain = this.effectsProcessor.applyPreset(effects, destination);
                if (effectChain) {
                    destination.connect(effectChain.input);
                }
            }

            utterance.onend = () => {
                // Convert stream to audio data
                const stream = destination.stream;
                resolve(stream);
            };

            utterance.onerror = (event) => {
                reject(new Error(`TTS error: ${event.error}`));
            };

            speechSynthesis.speak(utterance);
        });
    }

    // Play audio preview
    playAudioPreview(audioData) {
        if (this.audioEngine.audioContext) {
            const source = this.audioEngine.audioContext.createMediaStreamSource(audioData);
            source.connect(this.audioEngine.audioContext.destination);
        }
    }

    // Update announcement queue display
    updateAnnouncementQueue() {
        const queueList = document.getElementById('queue-list');
        const queueCount = document.getElementById('queue-count');

        queueCount.textContent = this.announcementQueue.length;

        if (this.announcementQueue.length === 0) {
            queueList.innerHTML = '<p style="color: rgba(255,255,255,0.6); font-style: italic;">No announcements queued</p>';
            return;
        }

        queueList.innerHTML = this.announcementQueue.map((announcement, index) => `
            <div class="queue-item" data-index="${index}">
                <div class="queue-item-info">
                    <div class="queue-item-type">${announcement.type}</div>
                    <div class="queue-item-text">${announcement.text}</div>
                </div>
                <div class="queue-item-controls">
                    <button class="play-button" onclick="window.ttsAnnouncementManager.playQueuedAnnouncement(${index})">▶</button>
                    <button class="remove-button" onclick="window.ttsAnnouncementManager.removeQueuedAnnouncement(${index})">×</button>
                </div>
            </div>
        `).join('');
    }

    // Play queued announcement
    async playQueuedAnnouncement(index) {
        const announcement = this.announcementQueue[index];
        if (announcement) {
            try {
                await this.deliverAnnouncement(announcement);
                this.removeQueuedAnnouncement(index);
            } catch (error) {
                console.error('Error playing queued announcement:', error);
            }
        }
    }

    // Remove queued announcement
    removeQueuedAnnouncement(index) {
        this.announcementQueue.splice(index, 1);
        this.updateAnnouncementQueue();
    }

    // Test voice settings
    testVoiceSettings() {
        const testText = "This is a test of the voice settings. How does this sound?";
        this.generateTTSAudio(testText, 'default', 'none')
            .then(audioData => this.playAudioPreview(audioData))
            .catch(error => console.error('Error testing voice:', error));
    }

    // Save voice settings
    saveVoiceSettings() {
        this.ttsConfig.rate = parseFloat(document.getElementById('speech-rate').value);
        this.ttsConfig.pitch = parseFloat(document.getElementById('voice-pitch').value);
        this.ttsConfig.volume = parseFloat(document.getElementById('voice-volume').value);
        this.ttsConfig.language = document.getElementById('default-language').value;
        this.ttsConfig.enableEffects = document.getElementById('enable-effects').checked;
        this.ttsConfig.announcementPrefix = document.getElementById('announcement-prefix').value;

        this.saveTTSConfiguration();
        alert('Voice settings saved successfully!');
    }

    // Load TTS configuration
    loadTTSConfiguration() {
        const saved = localStorage.getItem('voicelink-tts-config');
        if (saved) {
            try {
                const config = JSON.parse(saved);
                this.ttsConfig = { ...this.ttsConfig, ...config };
                this.applyTTSConfiguration();
            } catch (error) {
                console.error('Error loading TTS configuration:', error);
            }
        }
    }

    // Save TTS configuration
    saveTTSConfiguration() {
        localStorage.setItem('voicelink-tts-config', JSON.stringify(this.ttsConfig));
    }

    // Apply TTS configuration to UI
    applyTTSConfiguration() {
        document.getElementById('speech-rate').value = this.ttsConfig.rate;
        document.getElementById('voice-pitch').value = this.ttsConfig.pitch;
        document.getElementById('voice-volume').value = this.ttsConfig.volume;
        document.getElementById('default-language').value = this.ttsConfig.language;
        document.getElementById('enable-effects').checked = this.ttsConfig.enableEffects;
        document.getElementById('announcement-prefix').value = this.ttsConfig.announcementPrefix;

        // Update range value displays
        document.querySelectorAll('input[type="range"]').forEach(range => {
            const valueSpan = range.parentNode.querySelector('.range-value');
            if (valueSpan) {
                valueSpan.textContent = range.value;
            }
        });
    }

    // Get TTS status
    getStatus() {
        return {
            isAnnouncing: this.isAnnouncing,
            queueLength: this.announcementQueue.length,
            availableVoices: this.availableVoices.length,
            config: this.ttsConfig
        };
    }
}

// Initialize TTS announcement manager
window.ttsAnnouncementManager = null;

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = TTSAnnouncementManager;
}