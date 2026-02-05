/**
 * VoiceLink Whisper Mode Manager
 * Enables private whisper conversations between two users
 * - Hold Enter key to activate whisper mode
 * - Ducks other users' audio by -20dB with 1kHz lowpass filter
 * - 30ms fade in/out to prevent audio pops
 */

class WhisperModeManager {
    constructor(audioEngine) {
        this.audioEngine = audioEngine;
        this.isWhispering = false;
        this.whisperTargetUserId = null;
        this.originalGains = new Map();      // userId -> original gain value
        this.whisperFilters = new Map();     // userId -> lowpass BiquadFilterNode
        this.isKeyPressed = false;

        // Whisper settings
        this.settings = {
            duckingLevelDb: -20,              // -20dB ducking
            lowpassFrequency: 1000,           // 1kHz lowpass filter
            fadeTimeSeconds: 0.03,            // 30ms fade
            filterQ: 0.7                      // Filter Q factor
        };

        // Sound effects
        this.sounds = {
            whisperStart: null,
            whisperStop: null
        };

        // Callbacks for UI updates
        this.onWhisperStart = null;
        this.onWhisperStop = null;
        this.onTargetChange = null;

        this.loadSounds();
    }

    /**
     * Load whisper sound effects
     */
    async loadSounds() {
        try {
            // Try native app path first, then web path
            const basePath = window.nativeAPI ? '../source/assets/sounds/' : 'sounds/';

            this.sounds.whisperStart = new Audio(`${basePath}Whisper-start.wav`);
            this.sounds.whisperStop = new Audio(`${basePath}Whisper-Stop.wav`);

            // Preload
            this.sounds.whisperStart.load();
            this.sounds.whisperStop.load();

            console.log('Whisper sounds loaded');
        } catch (error) {
            console.warn('Could not load whisper sounds:', error);
        }
    }

    /**
     * Play a sound effect
     */
    playSound(soundName) {
        const sound = this.sounds[soundName];
        if (sound) {
            sound.currentTime = 0;
            sound.play().catch(e => console.warn('Sound play failed:', e));
        }
    }

    /**
     * Set the whisper target user
     * @param {string} userId - The user ID to whisper to
     * @param {string} username - Display name for UI feedback
     */
    setWhisperTarget(userId, username = null) {
        this.whisperTargetUserId = userId;
        this.whisperTargetUsername = username;

        if (this.onTargetChange) {
            this.onTargetChange(userId, username);
        }

        console.log(`Whisper target set to: ${username || userId}`);
    }

    /**
     * Clear the whisper target
     */
    clearWhisperTarget() {
        this.whisperTargetUserId = null;
        this.whisperTargetUsername = null;

        if (this.onTargetChange) {
            this.onTargetChange(null, null);
        }
    }

    /**
     * Start whispering to the target user
     * Ducks all other users' audio with lowpass filter
     */
    startWhisper() {
        if (this.isWhispering) return;
        if (!this.whisperTargetUserId) {
            console.warn('No whisper target set');
            return;
        }
        if (!this.audioEngine?.audioContext) {
            console.warn('Audio context not available');
            return;
        }

        this.isWhispering = true;
        this.playSound('whisperStart');

        const audioContext = this.audioEngine.audioContext;
        const now = audioContext.currentTime;
        const fadeTime = this.settings.fadeTimeSeconds;
        const linearLevel = Math.pow(10, this.settings.duckingLevelDb / 20); // -20dB = 0.1

        // Duck all users except the whisper target
        for (const [userId, nodes] of this.audioEngine.audioNodes) {
            // Skip the whisper target - they should hear us clearly
            if (userId === this.whisperTargetUserId) continue;

            // Store original gain for restoration
            this.originalGains.set(userId, nodes.gainNode.gain.value);

            // Apply ducking with smooth fade
            nodes.gainNode.gain.cancelScheduledValues(now);
            nodes.gainNode.gain.setValueAtTime(nodes.gainNode.gain.value, now);
            nodes.gainNode.gain.linearRampToValueAtTime(
                nodes.gainNode.gain.value * linearLevel,
                now + fadeTime
            );

            // Apply lowpass filter for muffled effect
            this.applyLowpassFilter(userId, nodes);
        }

        // Notify UI
        if (this.onWhisperStart) {
            this.onWhisperStart(this.whisperTargetUserId, this.whisperTargetUsername);
        }

        console.log(`Whisper started to: ${this.whisperTargetUsername || this.whisperTargetUserId}`);
    }

    /**
     * Stop whispering - restore all audio to normal
     */
    stopWhisper() {
        if (!this.isWhispering) return;

        this.isWhispering = false;
        this.playSound('whisperStop');

        const audioContext = this.audioEngine?.audioContext;
        if (!audioContext) return;

        const now = audioContext.currentTime;
        const fadeTime = this.settings.fadeTimeSeconds;

        // Restore all ducked users
        for (const [userId, originalGain] of this.originalGains) {
            const nodes = this.audioEngine.audioNodes.get(userId);
            if (nodes) {
                // Restore gain with smooth fade
                nodes.gainNode.gain.cancelScheduledValues(now);
                nodes.gainNode.gain.setValueAtTime(nodes.gainNode.gain.value, now);
                nodes.gainNode.gain.linearRampToValueAtTime(originalGain, now + fadeTime);

                // Remove lowpass filter
                this.removeLowpassFilter(userId, nodes);
            }
        }

        this.originalGains.clear();

        // Notify UI
        if (this.onWhisperStop) {
            this.onWhisperStop();
        }

        console.log('Whisper stopped');
    }

    /**
     * Apply lowpass filter to a user's audio chain
     * Chain becomes: source → filterNode → lowpass → gainNode
     */
    applyLowpassFilter(userId, nodes) {
        if (this.whisperFilters.has(userId)) return; // Already has filter

        const audioContext = this.audioEngine.audioContext;
        const lowpass = audioContext.createBiquadFilter();
        lowpass.type = 'lowpass';
        lowpass.frequency.value = this.settings.lowpassFrequency;
        lowpass.Q.value = this.settings.filterQ;

        // Disconnect existing chain and insert lowpass
        // Original: filterNode → gainNode
        // New: filterNode → lowpass → gainNode
        nodes.filterNode.disconnect();
        nodes.filterNode.connect(lowpass);
        lowpass.connect(nodes.gainNode);

        this.whisperFilters.set(userId, lowpass);
    }

    /**
     * Remove lowpass filter from a user's audio chain
     * Restore: source → filterNode → gainNode
     */
    removeLowpassFilter(userId, nodes) {
        const lowpass = this.whisperFilters.get(userId);
        if (!lowpass) return;

        // Restore original chain: filterNode → gainNode
        nodes.filterNode.disconnect();
        lowpass.disconnect();
        nodes.filterNode.connect(nodes.gainNode);

        this.whisperFilters.delete(userId);
    }

    /**
     * Set up push-to-talk keyboard listener for Enter key
     */
    setupWhisperPTT() {
        document.addEventListener('keydown', (e) => {
            // Enter key to whisper (not in text inputs)
            if (e.code === 'Enter' && !this.isKeyPressed) {
                // Don't trigger in text inputs
                const activeElement = document.activeElement;
                const isTextInput = activeElement && (
                    activeElement.tagName === 'INPUT' ||
                    activeElement.tagName === 'TEXTAREA' ||
                    activeElement.isContentEditable
                );

                if (!isTextInput && this.whisperTargetUserId) {
                    e.preventDefault();
                    this.isKeyPressed = true;
                    this.startWhisper();
                }
            }
        });

        document.addEventListener('keyup', (e) => {
            if (e.code === 'Enter' && this.isKeyPressed) {
                this.isKeyPressed = false;
                this.stopWhisper();
            }
        });

        // Also stop whisper if window loses focus
        window.addEventListener('blur', () => {
            if (this.isWhispering) {
                this.isKeyPressed = false;
                this.stopWhisper();
            }
        });

        console.log('Whisper PTT initialized (Enter key)');
    }

    /**
     * Get current whisper status
     */
    getStatus() {
        return {
            isWhispering: this.isWhispering,
            targetUserId: this.whisperTargetUserId,
            targetUsername: this.whisperTargetUsername,
            settings: { ...this.settings }
        };
    }

    /**
     * Update whisper settings
     */
    updateSettings(newSettings) {
        Object.assign(this.settings, newSettings);
        console.log('Whisper settings updated:', this.settings);
    }

    /**
     * Clean up when leaving room or disconnecting
     */
    cleanup() {
        if (this.isWhispering) {
            this.stopWhisper();
        }
        this.clearWhisperTarget();
        this.originalGains.clear();
        this.whisperFilters.clear();
    }
}

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
    module.exports = WhisperModeManager;
}
