/**
 * Voice Prompt Manager
 * Handles ElevenLabs generated voice prompts for app notifications and actions
 */

class VoicePromptManager {
    constructor(audioEngine) {
        this.audioEngine = audioEngine;

        // Prompt cache
        this.promptCache = new Map(); // promptId -> AudioBuffer
        this.loadedPrompts = new Set();
        this.loadingPrompts = new Set();

        // Playback settings
        this.settings = {
            enabled: true,
            volume: 0.7,
            duckingEnabled: true,
            duckingLevel: 0.3,
            maxConcurrent: 2,
            fadeInDuration: 0.1,
            fadeOutDuration: 0.2
        };

        // Active playback tracking
        this.activePrompts = new Map(); // instanceId -> PromptInstance
        this.promptQueue = [];
        this.isProcessingQueue = false;
        this.promptRetryTimers = new Map(); // promptId -> timeoutId
        this.promptRetryState = new Map(); // promptId -> { attempts, nextRetryAt, cooldownUntil }
        this.retrySweepTimer = null;

        // Silent download/retry behavior for missing prompt packs
        this.downloadConfig = {
            maxAttempts: 8,
            retryIntervalMs: 5 * 60 * 1000, // 5 minutes
            cooldownAfterMaxMs: 60 * 60 * 1000, // 1 hour
            requestTimeoutMs: 12000
        };
        this.promptBaseUrls = [
            'assets/audio/voice-prompts/',
            '/assets/audio/voice-prompts/',
            '/downloads/voicelink/prompt-packs/default/',
            'https://voicelink.devinecreations.net/downloads/voicelink/prompt-packs/default/'
        ];

        // Voice prompt categories and files
        this.promptCatalog = {
            connection: {
                connected: 'connection-established.wav',
                connecting: 'connecting-to-server.wav',
                disconnected: 'connection-lost.wav',
                reconnecting: 'attempting-reconnect.wav',
                timeout: 'connection-timeout.wav',
                roomJoined: 'room-joined-successfully.wav',
                roomLeft: 'leaving-voice-room.wav'
            },
            audio: {
                micTest: 'microphone-test-starting.wav',
                micConfigured: 'microphone-configured.wav',
                spatialEnabled: 'spatial-audio-enabled.wav',
                spatialDisabled: 'spatial-audio-disabled.wav',
                qualityHigh: 'audio-quality-high.wav',
                qualityMedium: 'audio-quality-medium.wav',
                qualityLow: 'audio-quality-low.wav',
                voiceActivation: 'voice-activation-enabled.wav',
                pushToTalk: 'push-to-talk-activated.wav',
                muted: 'mute-activated.wav',
                unmuted: 'unmuted.wav'
            },
            streaming: {
                streamStarted: 'live-stream-started.wav',
                streamConnected: 'stream-connected-successfully.wav',
                streamDisconnected: 'stream-disconnected.wav',
                recording: 'recording-started.wav',
                recordingStopped: 'recording-stopped.wav',
                broadcasting: 'broadcasting-to-audience.wav',
                rtmpConnected: 'rtmp-stream-initialized.wav',
                icecastConnected: 'icecast-server-connected.wav',
                srtActive: 'srt-low-latency-active.wav',
                webrtcConnected: 'webrtc-peer-connected.wav'
            },
            system: {
                startup: 'voicelink-starting-up.wav',
                ready: 'application-ready.wav',
                settingsSaved: 'settings-saved.wav',
                minimized: 'minimized-to-tray.wav',
                updateAvailable: 'updates-available.wav',
                restartRequired: 'restart-required.wav'
            },
            media: {
                nowPlaying: 'now-playing.wav',
                paused: 'media-paused.wav',
                skipped: 'track-skipped.wav',
                playlistLoaded: 'playlist-loaded.wav',
                volumeAdjusted: 'volume-adjusted.wav'
            },
            errors: {
                highCpu: 'warning-high-cpu-usage.wav',
                micAccess: 'error-microphone-access.wav',
                networkInstable: 'network-instability-detected.wav',
                lowBattery: 'caution-low-battery.wav',
                deviceDisconnected: 'audio-device-disconnected.wav'
            },
            security: {
                encrypted: 'encryption-enabled.wav',
                authenticated: 'authentication-successful.wav',
                privacyMode: 'privacy-mode-activated.wav',
                biometric: 'biometric-authentication.wav'
            },
            tutorial: {
                welcome: 'welcome-to-voicelink.wav',
                setupComplete: 'setup-wizard-complete.wav',
                firstRoom: 'ready-to-join-first-room.wav',
                allSet: 'youre-all-set-up.wav'
            }
        };

        this.init();
    }

    async init() {
        // Load user settings
        this.loadSettings();

        // Create audio context nodes
        this.createAudioNodes();

        // Pre-load essential prompts
        await this.preloadEssentialPrompts();
        this.startSilentRetrySweep();

        console.log('Voice Prompt Manager initialized');
    }

    createAudioNodes() {
        if (!this.audioEngine?.audioContext) return;

        const audioContext = this.audioEngine.audioContext;

        // Create main output node for prompts
        this.outputNode = audioContext.createGain();
        this.outputNode.gain.value = this.settings.volume;

        // Create ducking node for background audio
        this.duckingNode = audioContext.createGain();
        this.duckingNode.gain.value = 1.0;

        // Connect to audio engine
        this.outputNode.connect(audioContext.destination);

        if (this.audioEngine.outputNode) {
            this.audioEngine.outputNode.connect(this.duckingNode);
            this.duckingNode.connect(audioContext.destination);
        }
    }

    async preloadEssentialPrompts() {
        const essential = [
            'connection.connected',
            'connection.disconnected',
            'audio.muted',
            'audio.unmuted',
            'system.ready',
            'errors.micAccess'
        ];

        const loadPromises = essential.map(promptId => this.loadPrompt(promptId));
        await Promise.allSettled(loadPromises);

        console.log(`Preloaded ${essential.length} essential voice prompts`);
    }

    /**
     * Load a voice prompt audio file
     */
    async loadPrompt(promptId) {
        if (this.loadedPrompts.has(promptId) || this.loadingPrompts.has(promptId)) {
            return;
        }
        if (!this.isRetryAllowed(promptId)) {
            return;
        }

        this.loadingPrompts.add(promptId);

        try {
            const arrayBuffer = await this.fetchPromptAudioData(promptId);
            const audioBuffer = await this.audioEngine.audioContext.decodeAudioData(arrayBuffer);

            this.promptCache.set(promptId, audioBuffer);
            this.loadedPrompts.add(promptId);
            this.markPromptDownloadSuccess(promptId);

            console.log(`Loaded voice prompt: ${promptId}`);
        } catch (error) {
            // Silent retry strategy: don't interrupt users for missing prompt files.
            this.markPromptDownloadFailure(promptId);
            this.schedulePromptRetry(promptId);
            console.debug(`Voice prompt unavailable (will retry silently): ${promptId}`);
        } finally {
            this.loadingPrompts.delete(promptId);
        }
    }

    getPromptFilename(promptId) {
        const [category, name] = promptId.split('.');
        const filename = this.promptCatalog[category]?.[name];

        if (!filename) {
            throw new Error(`Unknown prompt ID: ${promptId}`);
        }

        return filename;
    }

    getPromptCandidatePaths(promptId) {
        const filename = this.getPromptFilename(promptId);
        return this.promptBaseUrls.map(base => `${base}${filename}`);
    }

    async fetchWithTimeout(url) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), this.downloadConfig.requestTimeoutMs);

        try {
            const response = await fetch(url, {
                signal: controller.signal,
                cache: 'no-store'
            });
            return response;
        } finally {
            clearTimeout(timer);
        }
    }

    async fetchPromptAudioData(promptId) {
        const candidates = this.getPromptCandidatePaths(promptId);
        let lastError = null;

        for (const url of candidates) {
            try {
                const response = await this.fetchWithTimeout(url);
                if (!response.ok) {
                    lastError = new Error(`HTTP ${response.status} for ${url}`);
                    continue;
                }
                return await response.arrayBuffer();
            } catch (error) {
                lastError = error;
            }
        }

        throw lastError || new Error(`No prompt source available for ${promptId}`);
    }

    isRetryAllowed(promptId) {
        const state = this.promptRetryState.get(promptId);
        if (!state) return true;

        const now = Date.now();
        return now >= (state.nextRetryAt || 0);
    }

    markPromptDownloadSuccess(promptId) {
        this.promptRetryState.delete(promptId);
        const existingTimer = this.promptRetryTimers.get(promptId);
        if (existingTimer) {
            clearTimeout(existingTimer);
            this.promptRetryTimers.delete(promptId);
        }
    }

    markPromptDownloadFailure(promptId) {
        const now = Date.now();
        const state = this.promptRetryState.get(promptId) || {
            attempts: 0,
            nextRetryAt: now,
            cooldownUntil: 0
        };

        state.attempts += 1;

        if (state.attempts >= this.downloadConfig.maxAttempts) {
            state.cooldownUntil = now + this.downloadConfig.cooldownAfterMaxMs;
            state.nextRetryAt = state.cooldownUntil;
            state.attempts = 0; // allow retries again after cooldown window
        } else {
            state.nextRetryAt = now + this.downloadConfig.retryIntervalMs;
        }

        this.promptRetryState.set(promptId, state);
    }

    schedulePromptRetry(promptId) {
        if (this.loadedPrompts.has(promptId)) return;
        if (this.promptRetryTimers.has(promptId)) return;

        const state = this.promptRetryState.get(promptId);
        if (!state) return;

        const delay = Math.max(1000, state.nextRetryAt - Date.now());
        const timerId = setTimeout(async () => {
            this.promptRetryTimers.delete(promptId);
            await this.loadPrompt(promptId);
        }, delay);

        this.promptRetryTimers.set(promptId, timerId);
    }

    getAllPromptIds() {
        const ids = [];
        for (const [category, prompts] of Object.entries(this.promptCatalog)) {
            for (const name of Object.keys(prompts)) {
                ids.push(`${category}.${name}`);
            }
        }
        return ids;
    }

    startSilentRetrySweep() {
        if (this.retrySweepTimer) return;

        this.retrySweepTimer = setInterval(async () => {
            const promptIds = this.getAllPromptIds();
            for (const promptId of promptIds) {
                if (this.loadedPrompts.has(promptId) || this.loadingPrompts.has(promptId)) {
                    continue;
                }
                if (!this.isRetryAllowed(promptId)) {
                    continue;
                }
                // Fire and continue, no hard failure propagation.
                this.loadPrompt(promptId);
            }
        }, this.downloadConfig.retryIntervalMs);
    }

    retryAllFailedPrompts(force = false) {
        for (const [promptId, state] of this.promptRetryState.entries()) {
            if (force) {
                state.nextRetryAt = Date.now();
                state.cooldownUntil = 0;
                state.attempts = 0;
                this.promptRetryState.set(promptId, state);
            }
            this.schedulePromptRetry(promptId);
        }
    }

    /**
     * Play a voice prompt
     */
    async playPrompt(promptId, options = {}) {
        if (!this.settings.enabled) return null;

        // Load prompt if not cached
        if (!this.promptCache.has(promptId)) {
            await this.loadPrompt(promptId);
        }

        const audioBuffer = this.promptCache.get(promptId);
        if (!audioBuffer) {
            console.warn(`Voice prompt not available: ${promptId}`);
            return null;
        }

        // Check concurrent limit
        if (this.activePrompts.size >= this.settings.maxConcurrent) {
            if (options.priority === 'high') {
                this.stopOldestPrompt();
            } else {
                this.queuePrompt(promptId, options);
                return null;
            }
        }

        return this.playAudioBuffer(audioBuffer, promptId, options);
    }

    playAudioBuffer(audioBuffer, promptId, options = {}) {
        const audioContext = this.audioEngine.audioContext;
        const instanceId = `${promptId}_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

        // Create audio nodes
        const source = audioContext.createBufferSource();
        const gainNode = audioContext.createGain();
        const fadeNode = audioContext.createGain();

        source.buffer = audioBuffer;

        // Configure volume
        const volume = options.volume ?? this.settings.volume;
        gainNode.gain.value = volume;
        fadeNode.gain.value = 0; // Start silent for fade-in

        // Connect nodes
        source.connect(fadeNode);
        fadeNode.connect(gainNode);
        gainNode.connect(this.outputNode);

        // Create prompt instance
        const promptInstance = {
            id: instanceId,
            promptId,
            source,
            gainNode,
            fadeNode,
            startTime: audioContext.currentTime,
            duration: audioBuffer.duration,
            options
        };

        this.activePrompts.set(instanceId, promptInstance);

        // Apply audio ducking if enabled
        if (this.settings.duckingEnabled && options.duck !== false) {
            this.applyDucking(audioBuffer.duration);
        }

        // Fade in
        this.fadeIn(fadeNode, this.settings.fadeInDuration);

        // Set up completion handler
        source.onended = () => {
            this.activePrompts.delete(instanceId);
            this.processQueue();
        };

        // Start playback
        source.start();

        console.log(`Playing voice prompt: ${promptId}`);
        return promptInstance;
    }

    /**
     * Audio ducking for background audio
     */
    applyDucking(duration) {
        if (!this.duckingNode) return;

        const audioContext = this.audioEngine.audioContext;
        const now = audioContext.currentTime;
        const fadeTime = 0.1;

        // Duck down
        this.duckingNode.gain.cancelScheduledValues(now);
        this.duckingNode.gain.setValueAtTime(this.duckingNode.gain.value, now);
        this.duckingNode.gain.linearRampToValueAtTime(this.settings.duckingLevel, now + fadeTime);

        // Duck up after prompt
        const restoreTime = now + duration + this.settings.fadeOutDuration;
        this.duckingNode.gain.linearRampToValueAtTime(1.0, restoreTime + fadeTime);
    }

    fadeIn(node, duration) {
        const audioContext = this.audioEngine.audioContext;
        const now = audioContext.currentTime;

        node.gain.cancelScheduledValues(now);
        node.gain.setValueAtTime(0, now);
        node.gain.linearRampToValueAtTime(1, now + duration);
    }

    fadeOut(node, duration) {
        const audioContext = this.audioEngine.audioContext;
        const now = audioContext.currentTime;

        node.gain.cancelScheduledValues(now);
        node.gain.setValueAtTime(node.gain.value, now);
        node.gain.linearRampToValueAtTime(0, now + duration);
    }

    /**
     * Queue management
     */
    queuePrompt(promptId, options) {
        this.promptQueue.push({ promptId, options });

        if (this.promptQueue.length > 5) {
            this.promptQueue.shift(); // Remove oldest queued prompt
        }
    }

    async processQueue() {
        if (this.isProcessingQueue || this.promptQueue.length === 0) return;
        if (this.activePrompts.size >= this.settings.maxConcurrent) return;

        this.isProcessingQueue = true;

        const { promptId, options } = this.promptQueue.shift();
        await this.playPrompt(promptId, options);

        this.isProcessingQueue = false;

        // Process next in queue if space available
        if (this.promptQueue.length > 0 && this.activePrompts.size < this.settings.maxConcurrent) {
            setTimeout(() => this.processQueue(), 100);
        }
    }

    stopOldestPrompt() {
        let oldestInstance = null;
        let oldestTime = Infinity;

        for (const instance of this.activePrompts.values()) {
            if (instance.startTime < oldestTime) {
                oldestTime = instance.startTime;
                oldestInstance = instance;
            }
        }

        if (oldestInstance) {
            this.stopPrompt(oldestInstance.id);
        }
    }

    stopPrompt(instanceId) {
        const instance = this.activePrompts.get(instanceId);
        if (!instance) return;

        // Fade out then stop
        this.fadeOut(instance.fadeNode, this.settings.fadeOutDuration);

        setTimeout(() => {
            instance.source.stop();
            this.activePrompts.delete(instanceId);
        }, this.settings.fadeOutDuration * 1000);
    }

    stopAllPrompts() {
        for (const instanceId of this.activePrompts.keys()) {
            this.stopPrompt(instanceId);
        }
        this.promptQueue.length = 0;
    }

    /**
     * Convenience methods for common prompts
     */
    playConnectionEstablished() {
        return this.playPrompt('connection.connected');
    }

    playConnectionLost() {
        return this.playPrompt('connection.disconnected', { priority: 'high' });
    }

    playMuted() {
        return this.playPrompt('audio.muted');
    }

    playUnmuted() {
        return this.playPrompt('audio.unmuted');
    }

    playApplicationReady() {
        return this.playPrompt('system.ready');
    }

    playStreamStarted() {
        return this.playPrompt('streaming.streamStarted');
    }

    playError(errorType = 'micAccess') {
        return this.playPrompt(`errors.${errorType}`, { priority: 'high' });
    }

    playWelcome() {
        return this.playPrompt('tutorial.welcome');
    }

    /**
     * Settings management
     */
    updateSettings(newSettings) {
        this.settings = { ...this.settings, ...newSettings };

        // Apply volume change immediately
        if (this.outputNode && newSettings.volume !== undefined) {
            this.outputNode.gain.value = newSettings.volume;
        }

        this.saveSettings();
    }

    saveSettings() {
        localStorage.setItem('voicelink_prompt_settings', JSON.stringify(this.settings));
    }

    loadSettings() {
        try {
            const saved = localStorage.getItem('voicelink_prompt_settings');
            if (saved) {
                this.settings = { ...this.settings, ...JSON.parse(saved) };
            }
        } catch (error) {
            console.error('Failed to load voice prompt settings:', error);
        }
    }

    /**
     * Batch operations
     */
    async preloadCategory(category) {
        const prompts = this.promptCatalog[category];
        if (!prompts) return;

        const loadPromises = Object.keys(prompts).map(name =>
            this.loadPrompt(`${category}.${name}`)
        );

        await Promise.allSettled(loadPromises);
        console.log(`Preloaded ${category} voice prompts`);
    }

    getLoadedPrompts() {
        return Array.from(this.loadedPrompts);
    }

    getActivePrompts() {
        return Array.from(this.activePrompts.values()).map(instance => ({
            id: instance.id,
            promptId: instance.promptId,
            duration: instance.duration,
            elapsed: this.audioEngine.audioContext.currentTime - instance.startTime
        }));
    }

    getCatalog() {
        return this.promptCatalog;
    }

    /**
     * Cleanup
     */
    destroy() {
        this.stopAllPrompts();

        if (this.outputNode) {
            this.outputNode.disconnect();
        }

        if (this.duckingNode) {
            this.duckingNode.disconnect();
        }

        this.promptCache.clear();
        this.loadedPrompts.clear();
        this.activePrompts.clear();
        this.promptQueue.length = 0;
        for (const timerId of this.promptRetryTimers.values()) {
            clearTimeout(timerId);
        }
        this.promptRetryTimers.clear();
        this.promptRetryState.clear();
        if (this.retrySweepTimer) {
            clearInterval(this.retrySweepTimer);
            this.retrySweepTimer = null;
        }
    }
}

// Export for use in other modules
window.VoicePromptManager = VoicePromptManager;
