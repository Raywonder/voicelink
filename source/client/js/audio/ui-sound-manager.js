/**
 * VoiceLink UI Sound Manager
 * Comprehensive UI sound system with TTS integration, startup sounds, and admin overrides
 */

class UISoundManager {
    constructor(spatialAudio, menuSoundManager) {
        this.spatialAudio = spatialAudio;
        this.audioContext = spatialAudio?.audioContext;
        this.masterGain = spatialAudio?.masterGain;
        this.menuSoundManager = menuSoundManager;

        // UI Sound settings
        this.settings = {
            enabled: true,
            volume: 0.5,
            useServerSettings: false,
            ttsEnabled: true,
            ttsVoice: 'default',
            ttsSpeed: 1.0,
            ttsVolume: 0.7,
            startupSoundEnabled: true,
            windowChangeSoundEnabled: true,
            buttonSoundEnabled: true,
            overrideByAdmin: false
        };

        // Server override settings
        this.serverOverrides = {
            active: false,
            settings: null,
            adminConnected: false
        };

        // Sound library
        this.sounds = {
            startup: null,
            windowChange: null,
            buttonClick: null,
            buttonHover: null,
            success: null,
            error: null,
            warning: null,
            notification: null,
            connect: null,
            disconnect: null
        };

        // TTS system
        this.tts = {
            enabled: false,
            voice: null,
            elevenlabs: {
                apiKey: null,
                voiceId: 'EXAVITQu4vr4xnSDxMaL', // Default Bella voice
                enabled: false
            }
        };

        // Runtime state
        this.isInitialized = false;
        this.playbackQueue = [];
        this.isPlaying = false;

        this.init();
    }

    async init() {
        console.log('UISoundManager: Initializing comprehensive UI sound system...');

        // Load settings
        this.loadSettings();

        // Initialize TTS
        this.initializeTTS();

        // Generate UI sounds
        await this.generateUISounds();

        // Setup event listeners
        this.setupEventListeners();

        // Play startup sound
        if (this.settings.startupSoundEnabled && this.getEffectiveSettings().enabled) {
            setTimeout(() => {
                this.playStartupSound();
            }, 500);
        }

        this.isInitialized = true;
        console.log('UISoundManager: UI sound system initialized');
    }

    initializeTTS() {
        if ('speechSynthesis' in window) {
            this.tts.enabled = true;

            // Get available voices
            const loadVoices = () => {
                const voices = speechSynthesis.getVoices();
                if (voices.length > 0) {
                    this.tts.voice = voices.find(voice => voice.lang.startsWith('en')) || voices[0];
                    console.log('UISoundManager: TTS initialized with voice:', this.tts.voice?.name);
                }
            };

            // Load voices immediately if available
            loadVoices();

            // Also listen for voices changed event
            speechSynthesis.addEventListener('voiceschanged', loadVoices);
        } else {
            console.warn('UISoundManager: Speech synthesis not supported');
        }

        // Check for ElevenLabs API key
        const apiKey = localStorage.getItem('voicelink_elevenlabs_api_key');
        if (apiKey) {
            this.tts.elevenlabs.apiKey = apiKey;
            this.tts.elevenlabs.enabled = true;
            console.log('UISoundManager: ElevenLabs TTS enabled');
        }
    }

    async generateUISounds() {
        console.log('UISoundManager: Generating UI sound library...');

        if (!this.audioContext) {
            console.warn('UISoundManager: No audio context available, deferring sound generation');
            return;
        }

        // Startup sound - ascending chime
        this.sounds.startup = await this.generateChimeSound(220, 440, 880, 0.3);

        // Window change beep - quick 0.1 second beep
        this.sounds.windowChange = await this.generateBeepSound(800, 0.1);

        // Button click - short pop
        this.sounds.buttonClick = await this.generateClickSound(600, 0.05);

        // Button hover - subtle chirp
        this.sounds.buttonHover = await this.generateClickSound(400, 0.03);

        // Success sound - positive tone
        this.sounds.success = await this.generateSuccessSound();

        // Error sound - negative buzz
        this.sounds.error = await this.generateErrorSound();

        // Warning sound - alert tone
        this.sounds.warning = await this.generateWarningSound();

        // Notification sound - gentle ping
        this.sounds.notification = await this.generateNotificationSound();

        // Connect sound - connection established
        this.sounds.connect = await this.generateConnectSound();

        // Disconnect sound - connection lost
        this.sounds.disconnect = await this.generateDisconnectSound();

        console.log('UISoundManager: Generated', Object.keys(this.sounds).length, 'UI sounds');
    }

    async generateChimeSound(freq1, freq2, freq3, duration) {
        const sampleRate = this.audioContext.sampleRate;
        const length = sampleRate * duration;
        const buffer = this.audioContext.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const data = buffer.getChannelData(channel);

            for (let i = 0; i < length; i++) {
                const progress = i / length;
                const timePos = i / sampleRate;

                // Three ascending tones
                let sample = 0;
                const envelope = Math.sin(Math.PI * progress) * 0.3;

                if (progress < 0.33) {
                    sample = Math.sin(2 * Math.PI * freq1 * timePos) * envelope;
                } else if (progress < 0.66) {
                    sample = Math.sin(2 * Math.PI * freq2 * timePos) * envelope;
                } else {
                    sample = Math.sin(2 * Math.PI * freq3 * timePos) * envelope;
                }

                data[i] = sample;
            }
        }

        return buffer;
    }

    async generateBeepSound(frequency, duration) {
        const sampleRate = this.audioContext.sampleRate;
        const length = sampleRate * duration;
        const buffer = this.audioContext.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const data = buffer.getChannelData(channel);

            for (let i = 0; i < length; i++) {
                const progress = i / length;
                const timePos = i / sampleRate;

                // Quick fade in/out envelope
                let envelope = 1;
                if (progress < 0.1) {
                    envelope = progress / 0.1;
                } else if (progress > 0.8) {
                    envelope = (1 - progress) / 0.2;
                }

                const sample = Math.sin(2 * Math.PI * frequency * timePos) * envelope * 0.2;
                data[i] = sample;
            }
        }

        return buffer;
    }

    async generateClickSound(frequency, duration) {
        const sampleRate = this.audioContext.sampleRate;
        const length = sampleRate * duration;
        const buffer = this.audioContext.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const data = buffer.getChannelData(channel);

            for (let i = 0; i < length; i++) {
                const progress = i / length;
                const timePos = i / sampleRate;

                // Sharp attack, quick decay
                const envelope = Math.exp(-progress * 8) * 0.15;
                const sample = Math.sin(2 * Math.PI * frequency * timePos) * envelope;

                data[i] = sample;
            }
        }

        return buffer;
    }

    async generateSuccessSound() {
        return await this.generateChimeSound(440, 554, 659, 0.4);
    }

    async generateErrorSound() {
        const sampleRate = this.audioContext.sampleRate;
        const duration = 0.3;
        const length = sampleRate * duration;
        const buffer = this.audioContext.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const data = buffer.getChannelData(channel);

            for (let i = 0; i < length; i++) {
                const progress = i / length;
                const timePos = i / sampleRate;

                const envelope = Math.sin(Math.PI * progress) * 0.2;
                // Harsh descending tone
                const frequency = 200 - (progress * 100);
                const sample = Math.sin(2 * Math.PI * frequency * timePos) * envelope;

                data[i] = sample;
            }
        }

        return buffer;
    }

    async generateWarningSound() {
        return await this.generateBeepSound(1000, 0.15);
    }

    async generateNotificationSound() {
        return await this.generateChimeSound(523, 659, 0, 0.25);
    }

    async generateConnectSound() {
        return await this.generateChimeSound(330, 440, 523, 0.3);
    }

    async generateDisconnectSound() {
        const sampleRate = this.audioContext.sampleRate;
        const duration = 0.25;
        const length = sampleRate * duration;
        const buffer = this.audioContext.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const data = buffer.getChannelData(channel);

            for (let i = 0; i < length; i++) {
                const progress = i / length;
                const timePos = i / sampleRate;

                const envelope = Math.sin(Math.PI * progress) * 0.2;
                // Descending tone
                const frequency = 440 - (progress * 220);
                const sample = Math.sin(2 * Math.PI * frequency * timePos) * envelope;

                data[i] = sample;
            }
        }

        return buffer;
    }

    setupEventListeners() {
        // Listen for window focus/blur for window change sounds
        window.addEventListener('focus', () => {
            if (this.settings.windowChangeSoundEnabled) {
                this.playSound('windowChange');
            }
        });

        window.addEventListener('blur', () => {
            if (this.settings.windowChangeSoundEnabled) {
                this.playSound('windowChange');
            }
        });

        // Listen for server override changes
        document.addEventListener('server-ui-settings-override', (event) => {
            this.handleServerOverride(event.detail);
        });

        // Auto-attach button sound events to existing buttons
        this.attachButtonSounds();
    }

    attachButtonSounds() {
        // Add click sounds to all buttons
        document.addEventListener('click', (event) => {
            if (event.target.matches('button, .btn, .button, [role="button"]')) {
                if (this.settings.buttonSoundEnabled && this.getEffectiveSettings().enabled) {
                    this.playSound('buttonClick', { x: 0, y: 0, z: -0.5 });
                }
            }
        });

        // Add hover sounds to buttons
        document.addEventListener('mouseenter', (event) => {
            if (event.target.matches('button, .btn, .button, [role="button"]')) {
                if (this.settings.buttonSoundEnabled && this.getEffectiveSettings().enabled) {
                    this.playSound('buttonHover', { x: 0, y: 0, z: -0.3 });
                }
            }
        }, true);
    }

    async playSound(soundName, spatialPosition = null, options = {}) {
        const effectiveSettings = this.getEffectiveSettings();

        if (!effectiveSettings.enabled) {
            return;
        }

        const soundBuffer = this.sounds[soundName];
        if (!soundBuffer || !this.audioContext) {
            console.warn(`UISoundManager: Sound '${soundName}' not available`);
            return;
        }

        try {
            // Ensure audio context is running
            if (this.audioContext.state === 'suspended') {
                await this.audioContext.resume();
            }

            const source = this.audioContext.createBufferSource();
            const gainNode = this.audioContext.createGain();

            source.buffer = soundBuffer;

            // Apply volume
            const volume = (options.volume || effectiveSettings.volume) * this.masterGain?.gain?.value || 1;
            gainNode.gain.setValueAtTime(volume, this.audioContext.currentTime);

            // Connect audio chain
            source.connect(gainNode);

            if (spatialPosition && this.spatialAudio) {
                // Use spatial audio if position provided
                const spatialNode = this.spatialAudio.createSpatialSource(spatialPosition);
                gainNode.connect(spatialNode);
                spatialNode.connect(this.spatialAudio.masterGain || this.audioContext.destination);
            } else {
                gainNode.connect(this.masterGain || this.audioContext.destination);
            }

            // Play sound
            source.start();

            console.log(`UISoundManager: Playing sound '${soundName}'${spatialPosition ? ' (spatial)' : ''}`);

            // Clean up after sound finishes
            source.onended = () => {
                try {
                    source.disconnect();
                    gainNode.disconnect();
                } catch (e) {
                    // Ignore disconnect errors
                }
            };

        } catch (error) {
            console.warn(`UISoundManager: Error playing sound '${soundName}':`, error);
        }
    }

    async playTTS(text, options = {}) {
        const effectiveSettings = this.getEffectiveSettings();

        if (!effectiveSettings.enabled || !effectiveSettings.ttsEnabled) {
            return;
        }

        try {
            // Try ElevenLabs first if available
            if (this.tts.elevenlabs.enabled && this.tts.elevenlabs.apiKey) {
                await this.playElevenLabsTTS(text, options);
            } else if (this.tts.enabled) {
                await this.playBrowserTTS(text, options);
            }
        } catch (error) {
            console.error('UISoundManager: TTS playback failed:', error);
        }
    }

    async playElevenLabsTTS(text, options = {}) {
        try {
            const response = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${this.tts.elevenlabs.voiceId}`, {
                method: 'POST',
                headers: {
                    'Accept': 'audio/mpeg',
                    'Content-Type': 'application/json',
                    'xi-api-key': this.tts.elevenlabs.apiKey
                },
                body: JSON.stringify({
                    text: text,
                    model_id: 'eleven_monolingual_v1',
                    voice_settings: {
                        stability: 0.5,
                        similarity_boost: 0.5,
                        style: 0.5,
                        use_speaker_boost: true
                    }
                })
            });

            if (response.ok) {
                const audioData = await response.arrayBuffer();
                const audioBuffer = await this.audioContext.decodeAudioData(audioData);

                const source = this.audioContext.createBufferSource();
                const gainNode = this.audioContext.createGain();

                source.buffer = audioBuffer;
                gainNode.gain.setValueAtTime(this.settings.ttsVolume, this.audioContext.currentTime);

                source.connect(gainNode);
                gainNode.connect(this.masterGain || this.audioContext.destination);

                source.start();

                console.log('UISoundManager: Playing ElevenLabs TTS:', text);
            } else {
                throw new Error('ElevenLabs API request failed');
            }
        } catch (error) {
            console.warn('UISoundManager: ElevenLabs TTS failed, falling back to browser TTS:', error);
            await this.playBrowserTTS(text, options);
        }
    }

    async playBrowserTTS(text, options = {}) {
        if (!this.tts.enabled || !this.tts.voice) {
            console.warn('UISoundManager: Browser TTS not available');
            return;
        }

        const utterance = new SpeechSynthesisUtterance(text);
        utterance.voice = this.tts.voice;
        utterance.rate = options.speed || this.settings.ttsSpeed;
        utterance.volume = options.volume || this.settings.ttsVolume;

        speechSynthesis.speak(utterance);
        console.log('UISoundManager: Playing browser TTS:', text);
    }

    playStartupSound() {
        this.playSound('startup');

        // Optional startup TTS announcement
        if (this.settings.ttsEnabled) {
            setTimeout(() => {
                this.playTTS('VoiceLink initialized');
            }, 1000);
        }
    }

    playWindowChangeSound() {
        this.playSound('windowChange');
    }

    // Convenience methods for common UI interactions
    playSuccessSound(spatialPosition = null) {
        this.playSound('success', spatialPosition);
        if (this.settings.ttsEnabled) {
            this.playTTS('Success');
        }
    }

    playErrorSound(message = 'Error', spatialPosition = null) {
        this.playSound('error', spatialPosition);
        if (this.settings.ttsEnabled) {
            this.playTTS(message);
        }
    }

    playConnectSound() {
        this.playSound('connect');
        if (this.settings.ttsEnabled) {
            this.playTTS('Connected');
        }
    }

    playDisconnectSound() {
        this.playSound('disconnect');
        if (this.settings.ttsEnabled) {
            this.playTTS('Disconnected');
        }
    }

    // Server override management
    handleServerOverride(overrideData) {
        console.log('UISoundManager: Received server override:', overrideData);

        this.serverOverrides.active = overrideData.active;
        this.serverOverrides.settings = overrideData.settings;
        this.serverOverrides.adminConnected = overrideData.adminConnected;

        if (overrideData.active) {
            console.log('UISoundManager: Server override active, using server settings');
        } else {
            console.log('UISoundManager: Server override disabled, using local settings');
        }
    }

    getEffectiveSettings() {
        if (this.serverOverrides.active && this.serverOverrides.settings) {
            return { ...this.settings, ...this.serverOverrides.settings };
        }
        return this.settings;
    }

    // Settings management
    loadSettings() {
        const saved = localStorage.getItem('voicelink_ui_sound_settings');
        if (saved) {
            try {
                const loadedSettings = JSON.parse(saved);
                this.settings = { ...this.settings, ...loadedSettings };
            } catch (error) {
                console.error('UISoundManager: Failed to load settings:', error);
            }
        }
    }

    saveSettings() {
        try {
            localStorage.setItem('voicelink_ui_sound_settings', JSON.stringify(this.settings));
        } catch (error) {
            console.error('UISoundManager: Failed to save settings:', error);
        }
    }

    updateSettings(newSettings) {
        this.settings = { ...this.settings, ...newSettings };
        this.saveSettings();

        // Notify of setting change
        document.dispatchEvent(new CustomEvent('setting-changed', {
            detail: {
                key: 'ui_sounds',
                value: this.settings
            }
        }));
    }

    setEnabled(enabled) {
        this.updateSettings({ enabled });
    }

    setVolume(volume) {
        this.updateSettings({ volume: Math.max(0, Math.min(1, volume)) });
    }

    setTTSEnabled(enabled) {
        this.updateSettings({ ttsEnabled: enabled });
    }

    setElevenLabsApiKey(apiKey) {
        localStorage.setItem('voicelink_elevenlabs_api_key', apiKey);
        this.tts.elevenlabs.apiKey = apiKey;
        this.tts.elevenlabs.enabled = !!apiKey;
    }

    // Public API for other components
    getSettings() {
        return {
            ...this.settings,
            serverOverride: this.serverOverrides.active,
            ttsAvailable: this.tts.enabled,
            elevenLabsAvailable: this.tts.elevenlabs.enabled
        };
    }

    // Test functions
    testAllSounds() {
        console.log('UISoundManager: Testing all sounds...');

        const soundNames = Object.keys(this.sounds);
        let index = 0;

        const playNext = () => {
            if (index < soundNames.length) {
                const soundName = soundNames[index];
                console.log(`Testing sound: ${soundName}`);
                this.playSound(soundName);
                index++;
                setTimeout(playNext, 800);
            }
        };

        playNext();
    }

    testTTS(text = 'This is a test of the text to speech system') {
        this.playTTS(text);
    }
}

// Global convenience functions
window.playUISound = function(soundName, spatialPosition = null, options = {}) {
    if (window.uiSoundManager) {
        window.uiSoundManager.playSound(soundName, spatialPosition, options);
    }
};

window.playUITTS = function(text, options = {}) {
    if (window.uiSoundManager) {
        window.uiSoundManager.playTTS(text, options);
    }
};

// Export for use in other modules
window.UISoundManager = UISoundManager;