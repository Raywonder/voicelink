/**
 * VoiceLink Accessibility Manager
 * Handles screen reader announcements and accessibility features
 */

class AccessibilityManager {
    constructor(uiSoundManager) {
        this.uiSoundManager = uiSoundManager;
        this.settings = {
            announcements: true,
            soundCues: true,
            ttsAnnouncements: true,
            announceNavigation: true,
            announceActions: true,
            announceStatus: true,

            // TTS Engine Selection
            ttsEngine: 'system', // 'system', 'nvda', 'sapi'

            // System TTS Settings
            systemTTS: {
                enabled: true,
                voice: null, // Will use default system voice
                rate: 1.0,   // 0.1 to 10
                pitch: 1.0,  // 0 to 2
                volume: 0.8  // 0 to 1
            },

            // NVDA Controller Settings
            nvda: {
                enabled: false,
                available: false,
                interrupt: true,
                priority: 'normal' // 'low', 'normal', 'high'
            },

            // Screen Reader Mode
            screenReaderMode: 'auto', // 'auto', 'nvda', 'jaws', 'system'

            // Announcement Categories
            announceCategories: {
                navigation: true,
                roomEvents: true,
                userActions: true,
                errors: true,
                success: true,
                status: true,
                audio: true,
                connection: true
            }
        };

        // Create ARIA live regions
        this.createLiveRegions();

        // Initialize available voices
        this.availableVoices = [];
        this.loadAvailableVoices();

        // Initialize NVDA Controller
        this.initializeNVDAController();

        // Detect screen reader
        this.detectScreenReader();

        // Load settings
        this.loadSettings();

        // Initialize page announcement
        this.announcePageLoad();
    }

    createLiveRegions() {
        // Create polite announcements region
        this.politeRegion = document.createElement('div');
        this.politeRegion.setAttribute('aria-live', 'polite');
        this.politeRegion.setAttribute('aria-atomic', 'true');
        this.politeRegion.setAttribute('aria-label', 'Screen reader announcements');
        this.politeRegion.style.position = 'absolute';
        this.politeRegion.style.left = '-10000px';
        this.politeRegion.style.width = '1px';
        this.politeRegion.style.height = '1px';
        this.politeRegion.style.overflow = 'hidden';
        this.politeRegion.id = 'accessibility-polite-region';
        document.body.appendChild(this.politeRegion);

        // Create assertive announcements region
        this.assertiveRegion = document.createElement('div');
        this.assertiveRegion.setAttribute('aria-live', 'assertive');
        this.assertiveRegion.setAttribute('aria-atomic', 'true');
        this.assertiveRegion.setAttribute('aria-label', 'Urgent screen reader announcements');
        this.assertiveRegion.style.position = 'absolute';
        this.assertiveRegion.style.left = '-10000px';
        this.assertiveRegion.style.width = '1px';
        this.assertiveRegion.style.height = '1px';
        this.assertiveRegion.style.overflow = 'hidden';
        this.assertiveRegion.id = 'accessibility-assertive-region';
        document.body.appendChild(this.assertiveRegion);

        // Create status region
        this.statusRegion = document.createElement('div');
        this.statusRegion.setAttribute('role', 'status');
        this.statusRegion.setAttribute('aria-live', 'polite');
        this.statusRegion.setAttribute('aria-label', 'Application status');
        this.statusRegion.style.position = 'absolute';
        this.statusRegion.style.left = '-10000px';
        this.statusRegion.style.width = '1px';
        this.statusRegion.style.height = '1px';
        this.statusRegion.style.overflow = 'hidden';
        this.statusRegion.id = 'accessibility-status-region';
        document.body.appendChild(this.statusRegion);
    }

    announcePageLoad() {
        setTimeout(() => {
            this.announce('VoiceLink Local application loaded. Use tab to navigate through the interface.', 'polite', true);
        }, 1000);
    }

    loadAvailableVoices() {
        if ('speechSynthesis' in window) {
            this.availableVoices = speechSynthesis.getVoices();

            // Fallback for some browsers that load voices asynchronously
            if (this.availableVoices.length === 0) {
                speechSynthesis.addEventListener('voiceschanged', () => {
                    this.availableVoices = speechSynthesis.getVoices();
                    console.log('Available voices loaded:', this.availableVoices.length);
                });
            }
        }
    }

    initializeNVDAController() {
        // Check if NVDA Controller is available (Windows only)
        if (typeof window.nvdaController !== 'undefined' || typeof navigator.nvdaController !== 'undefined') {
            this.settings.nvda.available = true;
            console.log('NVDA Controller detected and available');
        } else if (window.nativeAPI?.checkNvdaController) {
            window.nativeAPI.checkNvdaController().then((available) => {
                this.settings.nvda.available = available;
                console.log('NVDA Controller availability:', available);
            }).catch(() => {
                console.log('NVDA Controller check failed');
            });
        }
    }

    detectScreenReader() {
        // Detect if a screen reader is active
        const userAgent = navigator.userAgent.toLowerCase();

        // Check for known screen reader indicators
        if (userAgent.includes('nvda') ||
            typeof window.nvdaController !== 'undefined' ||
            localStorage.getItem('accessibility_nvda_detected')) {
            this.settings.screenReaderMode = 'nvda';
            this.settings.nvda.enabled = true;
        } else if (userAgent.includes('jaws') ||
                   localStorage.getItem('accessibility_jaws_detected')) {
            this.settings.screenReaderMode = 'jaws';
        } else if (window.speechSynthesis &&
                   (window.navigator.userAgent.includes('Windows') &&
                    localStorage.getItem('accessibility_screen_reader_active'))) {
            this.settings.screenReaderMode = 'system';
        }

        // Auto-enable appropriate TTS engine based on detected screen reader
        if (this.settings.screenReaderMode === 'nvda' && this.settings.nvda.available) {
            this.settings.ttsEngine = 'nvda';
        } else {
            this.settings.ttsEngine = 'system';
        }

        console.log('Detected screen reader mode:', this.settings.screenReaderMode);
    }

    announce(message, priority = 'polite', withSound = false) {
        if (!this.settings.announcements) return;

        console.log(`Accessibility announcement (${priority}):`, message);

        // Choose the appropriate live region
        let region;
        switch (priority) {
            case 'assertive':
                region = this.assertiveRegion;
                break;
            case 'status':
                region = this.statusRegion;
                break;
            case 'polite':
            default:
                region = this.politeRegion;
                break;
        }

        // Clear and set the message
        region.textContent = '';
        setTimeout(() => {
            region.textContent = message;
        }, 100);

        // Play sound cue if enabled
        if (withSound && this.settings.soundCues && this.uiSoundManager) {
            this.uiSoundManager.playSound('info', { x: 0, y: 0, z: 0 });
        }

        // TTS announcement using selected engine
        if (this.settings.ttsAnnouncements) {
            this.speakMessage(message, {
                priority: priority === 'assertive' ? 'high' : 'normal',
                interrupt: priority === 'assertive'
            });
        }
    }

    announceNavigation(screenName, description = null) {
        if (!this.settings.announceNavigation) return;

        let message = `Navigated to ${screenName}`;
        if (description) {
            message += `. ${description}`;
        }

        this.announce(message, 'polite', true);
    }

    announceAction(action, result = null) {
        if (!this.settings.announceActions) return;

        let message = action;
        if (result) {
            message += `. ${result}`;
        }

        this.announce(message, 'polite', false);
    }

    announceStatus(status, priority = 'status') {
        if (!this.settings.announceStatus) return;

        this.announce(status, priority, priority === 'assertive');
    }

    announceError(error) {
        this.announce(`Error: ${error}`, 'assertive', true);
    }

    announceSuccess(message) {
        this.announce(`Success: ${message}`, 'polite', true);
    }

    // Screen-specific announcements
    announceMainScreen() {
        this.announceNavigation(
            'Main Menu',
            'Choose to create a new room, join an existing room, or access settings'
        );
    }

    announceRoomCreation() {
        this.announceNavigation(
            'Room Creation',
            'You can now create a new room. Fill in the form below and press Create Room to proceed'
        );
    }

    announceRoomJoin() {
        this.announceNavigation(
            'Join Room',
            'Enter the room ID and your name to join an existing room'
        );
    }

    announceSettings() {
        this.announceNavigation(
            'Settings',
            'Configure audio, accessibility, and other application preferences'
        );
    }

    announceRoomScreen(roomName) {
        this.announceNavigation(
            'Voice Room',
            `You are now in room: ${roomName}. Use spacebar to push-to-talk, or adjust settings in the controls panel`
        );
    }

    announceRoomCreated(roomName, roomId) {
        this.announceSuccess(`Room "${roomName}" created successfully with ID: ${roomId}. You have been automatically joined to the room`);
    }

    announceRoomJoined(roomName) {
        this.announceSuccess(`Successfully joined room: ${roomName}`);
    }

    announceRoomLeft() {
        this.announceAction('Left room', 'Returned to main menu');
    }

    announceUserJoined(userName) {
        this.announceStatus(`${userName} joined the room`);
    }

    announceUserLeft(userName) {
        this.announceStatus(`${userName} left the room`);
    }

    announceConnectionStatus(status) {
        const messages = {
            'connected': 'Connected to server',
            'disconnected': 'Disconnected from server',
            'connecting': 'Connecting to server',
            'error': 'Connection error occurred'
        };

        const priority = status === 'error' ? 'assertive' : 'status';
        this.announceStatus(messages[status] || status, priority);
    }

    announceAudioStatus(status) {
        const messages = {
            'muted': 'Microphone muted',
            'unmuted': 'Microphone unmuted',
            'deafened': 'Audio deafened - you cannot hear others',
            'undeafened': 'Audio undeafened - you can now hear others'
        };

        this.announceStatus(messages[status] || status);
    }

    // Settings management
    loadSettings() {
        const saved = localStorage.getItem('voicelink_accessibility_settings');
        if (saved) {
            try {
                const settings = JSON.parse(saved);
                this.settings = { ...this.settings, ...settings };
            } catch (error) {
                console.error('Failed to load accessibility settings:', error);
            }
        }
    }

    saveSettings() {
        try {
            localStorage.setItem('voicelink_accessibility_settings', JSON.stringify(this.settings));
        } catch (error) {
            console.error('Failed to save accessibility settings:', error);
        }
    }

    updateSetting(key, value) {
        this.settings[key] = value;
        this.saveSettings();
        this.announceAction(`${key} ${value ? 'enabled' : 'disabled'}`);
    }

    // Enhanced focus management
    announceElementFocus(element) {
        if (!element) return;

        const tagName = element.tagName.toLowerCase();
        const role = element.getAttribute('role');
        const label = element.getAttribute('aria-label') ||
                     element.getAttribute('alt') ||
                     element.textContent?.trim() ||
                     element.value ||
                     element.placeholder;

        let announcement = '';

        // Determine element type
        if (role) {
            announcement = `${role}`;
        } else if (tagName === 'button') {
            announcement = 'button';
        } else if (tagName === 'input') {
            const type = element.type || 'text';
            announcement = `${type} input`;
        } else if (tagName === 'select') {
            announcement = 'dropdown';
        } else if (tagName === 'textarea') {
            announcement = 'text area';
        } else if (tagName === 'a') {
            announcement = 'link';
        } else {
            announcement = tagName;
        }

        if (label) {
            announcement += `: ${label}`;
        }

        // Add state information
        if (element.disabled) {
            announcement += ', disabled';
        }
        if (element.checked !== undefined) {
            announcement += element.checked ? ', checked' : ', unchecked';
        }
        if (element.getAttribute('aria-expanded')) {
            const expanded = element.getAttribute('aria-expanded') === 'true';
            announcement += expanded ? ', expanded' : ', collapsed';
        }

        this.announce(announcement, 'polite', false);
    }

    // Keyboard navigation help
    announceKeyboardHelp() {
        const help = [
            'Keyboard navigation help:',
            'Tab: Move to next element',
            'Shift+Tab: Move to previous element',
            'Enter or Space: Activate buttons',
            'Escape: Close dialogs or return to previous screen',
            'Arrow keys: Navigate within lists or radio groups'
        ].join('. ');

        this.announce(help, 'polite', true);
    }

    // Enable/disable all accessibility features
    setEnabled(enabled) {
        this.settings.announcements = enabled;
        this.settings.soundCues = enabled;
        this.settings.ttsAnnouncements = enabled;
        this.saveSettings();

        this.announce(
            `Accessibility features ${enabled ? 'enabled' : 'disabled'}`,
            'assertive',
            true
        );
    }

    // TTS Engine Methods
    speakMessage(message, options = {}) {
        const {
            priority = 'normal',
            interrupt = false
        } = options;

        switch (this.settings.ttsEngine) {
            case 'nvda':
                this.speakWithNVDA(message, interrupt);
                break;
            case 'system':
            default:
                this.speakWithSystemTTS(message, interrupt);
                break;
        }
    }

    speakWithSystemTTS(message, interrupt = false) {
        if (!('speechSynthesis' in window) || !this.settings.systemTTS.enabled) {
            console.warn('System TTS not available or disabled');
            return;
        }

        // Stop current speech if interrupting
        if (interrupt) {
            speechSynthesis.cancel();
        }

        const utterance = new SpeechSynthesisUtterance(message);

        // Apply system TTS settings
        utterance.rate = this.settings.systemTTS.rate;
        utterance.pitch = this.settings.systemTTS.pitch;
        utterance.volume = this.settings.systemTTS.volume;

        // Set voice if specified
        if (this.settings.systemTTS.voice && this.availableVoices.length > 0) {
            const selectedVoice = this.availableVoices.find(
                voice => voice.name === this.settings.systemTTS.voice ||
                         voice.voiceURI === this.settings.systemTTS.voice
            );
            if (selectedVoice) {
                utterance.voice = selectedVoice;
            }
        }

        // Error handling
        utterance.onerror = (event) => {
            console.error('System TTS error:', event.error);
        };

        speechSynthesis.speak(utterance);
    }

    speakWithNVDA(message, interrupt = false) {
        if (!this.settings.nvda.available || !this.settings.nvda.enabled) {
            console.warn('NVDA Controller not available or disabled');
            // Fallback to system TTS
            this.speakWithSystemTTS(message, interrupt);
            return;
        }

        try {
            // For NVDA Controller Client
            if (typeof window.nvdaController !== 'undefined') {
                if (interrupt && this.settings.nvda.interrupt) {
                    window.nvdaController.cancelSpeech();
                }
                window.nvdaController.speakText(message);
            }
            // For native NVDA bridge
            else if (window.nativeAPI?.nvdaSpeak) {
                window.nativeAPI.nvdaSpeak({
                    message,
                    interrupt: interrupt && this.settings.nvda.interrupt,
                    priority: this.settings.nvda.priority
                });
            }
        } catch (error) {
            console.error('NVDA Controller error:', error);
            // Fallback to system TTS
            this.speakWithSystemTTS(message, interrupt);
        }
    }

    // Voice Management
    getAvailableVoices() {
        return this.availableVoices.map(voice => ({
            name: voice.name,
            lang: voice.lang,
            uri: voice.voiceURI,
            default: voice.default,
            localService: voice.localService
        }));
    }

    setSystemVoice(voiceName) {
        const voice = this.availableVoices.find(
            v => v.name === voiceName || v.voiceURI === voiceName
        );
        if (voice) {
            this.settings.systemTTS.voice = voice.voiceURI;
            this.saveSettings();
            return true;
        }
        return false;
    }

    updateSystemTTSSettings(settings) {
        this.settings.systemTTS = { ...this.settings.systemTTS, ...settings };
        this.saveSettings();
    }

    updateNVDASettings(settings) {
        this.settings.nvda = { ...this.settings.nvda, ...settings };
        this.saveSettings();
    }

    setTTSEngine(engine) {
        if (['system', 'nvda'].includes(engine)) {
            this.settings.ttsEngine = engine;
            this.saveSettings();
            this.announce(`TTS engine switched to ${engine}`, 'polite', true);
        }
    }

    testTTS(message = 'This is a test of the text-to-speech system') {
        this.speakMessage(message, { interrupt: true });
    }

    // Get current settings for UI
    getSettings() {
        return { ...this.settings };
    }
}

// Export for use in other modules
window.AccessibilityManager = AccessibilityManager;
