/**
 * Audio Ducking Processor
 * Professional audio ducking system with configurable levels for feedback prevention
 */

class AudioDuckingProcessor {
    constructor(audioContext) {
        this.audioContext = audioContext;
        this.duckingNodes = new Map(); // inputType -> ducking chain
        this.duckingSettings = new Map(); // inputType -> settings
        this.analysers = new Map(); // inputType -> analyser for monitoring

        // Ducking level presets (in dB)
        this.duckingLevels = {
            '-5db': -5,
            '-10db': -10,
            '-15db': -15,
            '-20db': -20,
            '-25db': -25,
            '-30db': -30,
            '-35db': -35,
            '-40db': -40,
            '-45db': -45,
            '-50db': -50,
            '-60db': -60,
            '-70db': -70,
            '-80db': -80,
            '-90db': -90,
            '-100db': -100
        };

        // Ducking speed presets (10ms to 10 seconds range)
        this.duckingSpeedPresets = {
            instant: {
                attackTime: 0.01,  // 10ms attack
                releaseTime: 0.05, // 50ms release
                description: 'Instant ducking for emergency situations'
            },
            fastest: {
                attackTime: 0.02,  // 20ms attack
                releaseTime: 0.1,  // 100ms release
                description: 'Fastest ducking for live broadcasting'
            },
            fast: {
                attackTime: 0.05,  // 50ms attack
                releaseTime: 0.25, // 250ms release
                description: 'Fast ducking for voice-overs'
            },
            medium: {
                attackTime: 0.1,   // 100ms attack
                releaseTime: 0.5,  // 500ms release
                description: 'Medium speed for general use'
            },
            default_half_second: {
                attackTime: 0.05,  // 50ms attack
                releaseTime: 0.5,  // 500ms release (0.5 second default)
                description: 'Default 0.5 second ducking timing'
            },
            slow: {
                attackTime: 0.3,   // 300ms attack
                releaseTime: 1.5,  // 1.5s release
                description: 'Slow, gentle ducking for music'
            },
            very_slow: {
                attackTime: 0.8,   // 800ms attack
                releaseTime: 3.0,  // 3s release
                description: 'Very slow ducking for ambient sounds'
            },
            extended: {
                attackTime: 1.5,   // 1.5s attack
                releaseTime: 5.0,  // 5s release
                description: 'Extended ducking for long announcements'
            },
            ultra_long: {
                attackTime: 3.0,   // 3s attack
                releaseTime: 10.0, // 10s release
                description: 'Ultra-long ducking for special effects'
            }
        };

        // Server and user configuration
        this.serverDuckingConfig = null;
        this.userDuckingConfig = null;

        // Default ducking settings for each input type (can be overridden by server)
        this.defaultSettings = {
            microphone: {
                enabled: false,
                duckingLevel: -20, // dB
                threshold: -30, // dB
                attackTime: 0.01, // seconds
                releaseTime: 0.3, // seconds
                speedPreset: 'default_half_second', // 0.5 second default
                sideChainInput: 'output_monitor', // what triggers ducking
                duckingMode: 'compressor' // 'compressor' or 'gate'
            },
            media_streaming: {
                enabled: true,
                duckingLevel: -15,
                threshold: -25,
                attackTime: 0.05,
                releaseTime: 0.5,
                speedPreset: 'default_half_second',
                sideChainInput: 'microphone',
                duckingMode: 'compressor'
            },
            virtual_input: {
                enabled: false,
                duckingLevel: -10,
                threshold: -20,
                attackTime: 0.02,
                releaseTime: 0.4,
                speedPreset: 'fast',
                sideChainInput: 'microphone',
                duckingMode: 'compressor'
            },
            system_audio: {
                enabled: false,
                duckingLevel: -25,
                threshold: -35,
                attackTime: 0.01,
                releaseTime: 0.6,
                speedPreset: 'slow',
                sideChainInput: 'microphone',
                duckingMode: 'compressor'
            }
        };

        this.init();
    }

    init() {
        // Initialize ducking settings
        Object.entries(this.defaultSettings).forEach(([inputType, settings]) => {
            this.duckingSettings.set(inputType, { ...settings });
        });

        console.log('Audio ducking processor initialized');
    }

    /**
     * Create ducking chain for an input
     */
    createDuckingChain(inputType, inputNode) {
        if (!this.audioContext || !inputNode) return null;

        try {
            const settings = this.duckingSettings.get(inputType);
            if (!settings) return null;

            // Create ducking processing chain
            const inputGain = this.audioContext.createGain();
            const compressor = this.audioContext.createDynamicsCompressor();
            const duckingGain = this.audioContext.createGain();
            const outputGain = this.audioContext.createGain();
            const analyser = this.audioContext.createAnalyser();

            // Configure analyser for level monitoring
            analyser.fftSize = 256;
            analyser.smoothingTimeConstant = 0.8;

            // Configure compressor for ducking
            this.configureDuckingCompressor(compressor, settings);

            // Set initial gain levels
            inputGain.gain.value = 1.0;
            duckingGain.gain.value = this.dBToLinear(settings.duckingLevel);
            outputGain.gain.value = 1.0;

            // Connect the chain: input -> inputGain -> compressor -> duckingGain -> outputGain -> analyser
            inputNode.connect(inputGain);
            inputGain.connect(compressor);
            compressor.connect(duckingGain);
            duckingGain.connect(outputGain);
            outputGain.connect(analyser);

            // Store the ducking chain
            const duckingChain = {
                inputGain,
                compressor,
                duckingGain,
                outputGain,
                analyser,
                settings: { ...settings },
                enabled: settings.enabled
            };

            this.duckingNodes.set(inputType, duckingChain);
            this.analysers.set(inputType, analyser);

            console.log(`Created ducking chain for ${inputType}`);
            return outputGain; // Return output node for further connection

        } catch (error) {
            console.error(`Failed to create ducking chain for ${inputType}:`, error);
            return null;
        }
    }

    /**
     * Configure compressor for ducking behavior
     */
    configureDuckingCompressor(compressor, settings) {
        // Convert dB threshold to linear
        const thresholdLinear = this.dBToLinear(settings.threshold);

        compressor.threshold.value = settings.threshold;
        compressor.knee.value = 10; // Soft knee for smooth ducking
        compressor.ratio.value = settings.duckingMode === 'gate' ? 20 : 6; // High ratio for ducking
        compressor.attack.value = settings.attackTime;
        compressor.release.value = settings.releaseTime;
    }

    /**
     * Update ducking settings for an input type
     */
    updateDuckingSettings(inputType, newSettings) {
        const currentSettings = this.duckingSettings.get(inputType);
        if (!currentSettings) return;

        // Merge new settings
        const updatedSettings = { ...currentSettings, ...newSettings };
        this.duckingSettings.set(inputType, updatedSettings);

        // Update existing ducking chain if it exists
        const duckingChain = this.duckingNodes.get(inputType);
        if (duckingChain) {
            duckingChain.settings = updatedSettings;

            // Update compressor settings
            this.configureDuckingCompressor(duckingChain.compressor, updatedSettings);

            // Update ducking gain level
            duckingChain.duckingGain.gain.value = this.dBToLinear(updatedSettings.duckingLevel);

            // Update enabled state
            duckingChain.enabled = updatedSettings.enabled;
            if (!updatedSettings.enabled) {
                // Bypass ducking by setting gain to 1.0
                duckingChain.duckingGain.gain.value = 1.0;
            }
        }

        console.log(`Updated ducking settings for ${inputType}:`, updatedSettings);
    }

    /**
     * Enable/disable ducking for an input type
     */
    setDuckingEnabled(inputType, enabled) {
        this.updateDuckingSettings(inputType, { enabled });
    }

    /**
     * Set ducking level in dB
     */
    setDuckingLevel(inputType, levelDb) {
        // Clamp level between -100dB and -5dB
        const clampedLevel = Math.max(-100, Math.min(-5, levelDb));
        this.updateDuckingSettings(inputType, { duckingLevel: clampedLevel });
    }

    /**
     * Set ducking threshold in dB
     */
    setDuckingThreshold(inputType, thresholdDb) {
        this.updateDuckingSettings(inputType, { threshold: thresholdDb });
    }

    /**
     * Set ducking timing parameters
     */
    setDuckingTiming(inputType, attackTime, releaseTime) {
        this.updateDuckingSettings(inputType, {
            attackTime: Math.max(0.001, attackTime),
            releaseTime: Math.max(0.01, releaseTime)
        });
    }

    /**
     * Set ducking mode (compressor or gate)
     */
    setDuckingMode(inputType, mode) {
        if (['compressor', 'gate'].includes(mode)) {
            this.updateDuckingSettings(inputType, { duckingMode: mode });
        }
    }

    /**
     * Set ducking speed preset
     */
    setDuckingSpeedPreset(inputType, speedPreset) {
        const preset = this.duckingSpeedPresets[speedPreset];
        if (!preset) {
            console.warn(`Unknown ducking speed preset: ${speedPreset}`);
            return;
        }

        this.updateDuckingSettings(inputType, {
            speedPreset: speedPreset,
            attackTime: preset.attackTime,
            releaseTime: preset.releaseTime
        });

        console.log(`Applied ${speedPreset} ducking preset to ${inputType}: ${preset.description}`);
    }

    /**
     * Get available ducking speed presets
     */
    getDuckingSpeedPresets() {
        return Object.keys(this.duckingSpeedPresets);
    }

    /**
     * Get ducking speed preset details
     */
    getDuckingSpeedPresetDetails(speedPreset) {
        return this.duckingSpeedPresets[speedPreset] || null;
    }

    /**
     * Set custom ducking timing (outside of presets)
     */
    setCustomDuckingTiming(inputType, attackTimeMs, releaseTimeMs) {
        // Convert milliseconds to seconds and clamp values
        const attackTime = Math.max(0.01, Math.min(10.0, attackTimeMs / 1000)); // 10ms to 10s
        const releaseTime = Math.max(0.01, Math.min(10.0, releaseTimeMs / 1000)); // 10ms to 10s

        this.updateDuckingSettings(inputType, {
            speedPreset: 'custom',
            attackTime: attackTime,
            releaseTime: releaseTime
        });

        console.log(`Custom ducking timing set for ${inputType}: ${attackTimeMs}ms attack, ${releaseTimeMs}ms release`);
    }

    /**
     * Auto-ducking based on microphone activity
     */
    enableAutoDucking(inputType, microphoneThreshold = -40) {
        const duckingChain = this.duckingNodes.get(inputType);
        if (!duckingChain || !duckingChain.enabled) return;

        // This would be triggered by microphone level detection
        // For now, we'll set up the basic framework
        const settings = duckingChain.settings;

        console.log(`Auto-ducking enabled for ${inputType} with mic threshold ${microphoneThreshold}dB`);
    }

    /**
     * Manual ducking trigger
     */
    triggerDucking(inputType, duckingAmount = null) {
        const duckingChain = this.duckingNodes.get(inputType);
        if (!duckingChain || !duckingChain.enabled) return;

        const level = duckingAmount !== null ? duckingAmount : duckingChain.settings.duckingLevel;
        const linearLevel = this.dBToLinear(level);

        // Smooth transition to ducked level
        const now = this.audioContext.currentTime;
        const attackTime = duckingChain.settings.attackTime;

        duckingChain.duckingGain.gain.cancelScheduledValues(now);
        duckingChain.duckingGain.gain.linearRampToValueAtTime(linearLevel, now + attackTime);

        console.log(`Manual ducking triggered for ${inputType}: ${level}dB`);
    }

    /**
     * Release ducking (return to normal level)
     */
    releaseDucking(inputType) {
        const duckingChain = this.duckingNodes.get(inputType);
        if (!duckingChain) return;

        const now = this.audioContext.currentTime;
        const releaseTime = duckingChain.settings.releaseTime;

        duckingChain.duckingGain.gain.cancelScheduledValues(now);
        duckingChain.duckingGain.gain.linearRampToValueAtTime(1.0, now + releaseTime);

        console.log(`Ducking released for ${inputType}`);
    }

    /**
     * Get current ducking level for an input
     */
    getCurrentDuckingLevel(inputType) {
        const duckingChain = this.duckingNodes.get(inputType);
        if (!duckingChain) return 0;

        const linearLevel = duckingChain.duckingGain.gain.value;
        return this.linearTodB(linearLevel);
    }

    /**
     * Get ducking settings for an input type
     */
    getDuckingSettings(inputType) {
        return this.duckingSettings.get(inputType) || null;
    }

    /**
     * Get all ducking settings
     */
    getAllDuckingSettings() {
        const settings = {};
        for (const [inputType, setting] of this.duckingSettings.entries()) {
            settings[inputType] = { ...setting };
        }
        return settings;
    }

    /**
     * Create feedback prevention system
     */
    createFeedbackPrevention(microphoneInput, outputMonitor) {
        if (!microphoneInput || !outputMonitor) return;

        try {
            // Create feedback detection analyser
            const feedbackAnalyser = this.audioContext.createAnalyser();
            feedbackAnalyser.fftSize = 2048;
            feedbackAnalyser.smoothingTimeConstant = 0.3;

            outputMonitor.connect(feedbackAnalyser);

            // Monitor for feedback and trigger ducking
            const feedbackData = new Uint8Array(feedbackAnalyser.frequencyBinCount);
            let feedbackDetected = false;

            const checkFeedback = () => {
                feedbackAnalyser.getByteFrequencyData(feedbackData);

                // Simple feedback detection: look for sustained high-frequency content
                const highFreqStart = Math.floor(feedbackData.length * 0.7);
                const highFreqEnergy = feedbackData.slice(highFreqStart).reduce((sum, val) => sum + val, 0);
                const avgHighFreq = highFreqEnergy / (feedbackData.length - highFreqStart);

                if (avgHighFreq > 180 && !feedbackDetected) {
                    // Feedback detected - trigger ducking
                    feedbackDetected = true;
                    console.warn('Feedback detected - triggering emergency ducking');

                    // Duck all inputs except microphone
                    ['media_streaming', 'virtual_input', 'system_audio'].forEach(inputType => {
                        this.triggerDucking(inputType, -60); // Emergency duck to -60dB
                    });

                    // Release after 2 seconds
                    setTimeout(() => {
                        ['media_streaming', 'virtual_input', 'system_audio'].forEach(inputType => {
                            this.releaseDucking(inputType);
                        });
                        feedbackDetected = false;
                        console.log('Emergency ducking released');
                    }, 2000);
                }

                requestAnimationFrame(checkFeedback);
            };

            checkFeedback();
            console.log('Feedback prevention system activated');

        } catch (error) {
            console.error('Failed to create feedback prevention:', error);
        }
    }

    /**
     * Remove ducking chain for an input type
     */
    removeDuckingChain(inputType) {
        const duckingChain = this.duckingNodes.get(inputType);
        if (duckingChain) {
            // Disconnect all nodes
            try {
                duckingChain.inputGain.disconnect();
                duckingChain.compressor.disconnect();
                duckingChain.duckingGain.disconnect();
                duckingChain.outputGain.disconnect();
            } catch (error) {
                console.debug('Some nodes already disconnected:', error);
            }

            this.duckingNodes.delete(inputType);
            this.analysers.delete(inputType);
            console.log(`Removed ducking chain for ${inputType}`);
        }
    }

    /**
     * Save ducking settings to localStorage
     */
    saveDuckingSettings() {
        const settings = this.getAllDuckingSettings();
        localStorage.setItem('voicelink_ducking_settings', JSON.stringify(settings));
        console.log('Ducking settings saved');
    }

    /**
     * Load ducking settings from localStorage
     */
    loadDuckingSettings() {
        try {
            const saved = localStorage.getItem('voicelink_ducking_settings');
            if (saved) {
                const settings = JSON.parse(saved);
                Object.entries(settings).forEach(([inputType, setting]) => {
                    this.duckingSettings.set(inputType, setting);
                });
                console.log('Ducking settings loaded');
                return true;
            }
        } catch (error) {
            console.error('Failed to load ducking settings:', error);
        }
        return false;
    }

    /**
     * Convert dB to linear scale
     */
    dBToLinear(dB) {
        return Math.pow(10, dB / 20);
    }

    /**
     * Convert linear scale to dB
     */
    linearTodB(linear) {
        return 20 * Math.log10(Math.max(0.000001, linear)); // Avoid log(0)
    }

    /**
     * Get available ducking level presets
     */
    getDuckingLevelPresets() {
        return Object.keys(this.duckingLevels);
    }

    /**
     * Set server ducking configuration (overrides defaults)
     */
    setServerDuckingConfig(serverConfig) {
        this.serverDuckingConfig = serverConfig;

        // Apply server defaults to all input types
        if (serverConfig.globalDefaults) {
            Object.values(this.inputTypes).forEach(inputType => {
                const currentSettings = this.duckingSettings.get(inputType);
                const mergedSettings = {
                    ...currentSettings,
                    ...serverConfig.globalDefaults
                };

                // Apply server-specific overrides for this input type
                if (serverConfig.inputSpecific && serverConfig.inputSpecific[inputType]) {
                    Object.assign(mergedSettings, serverConfig.inputSpecific[inputType]);
                }

                this.duckingSettings.set(inputType, mergedSettings);
            });
        }

        console.log('Server ducking configuration applied:', serverConfig);
    }

    /**
     * Set user ducking preferences (overrides server defaults)
     */
    setUserDuckingConfig(userConfig) {
        this.userDuckingConfig = userConfig;

        // Apply user preferences over server and default settings
        Object.entries(userConfig).forEach(([inputType, userSettings]) => {
            if (this.duckingSettings.has(inputType)) {
                const currentSettings = this.duckingSettings.get(inputType);
                const mergedSettings = { ...currentSettings, ...userSettings };
                this.duckingSettings.set(inputType, mergedSettings);
            }
        });

        console.log('User ducking configuration applied:', userConfig);
    }

    /**
     * Get effective ducking configuration (combines server, user, and defaults)
     */
    getEffectiveConfiguration() {
        const config = {
            server: this.serverDuckingConfig,
            user: this.userDuckingConfig,
            effective: this.getAllDuckingSettings(),
            hierarchy: 'defaults -> server -> user (highest priority)'
        };
        return config;
    }

    /**
     * Reset to server defaults (removes user overrides)
     */
    resetToServerDefaults() {
        if (this.serverDuckingConfig) {
            this.setServerDuckingConfig(this.serverDuckingConfig);
        } else {
            // Reset to built-in defaults
            Object.entries(this.defaultSettings).forEach(([inputType, settings]) => {
                this.duckingSettings.set(inputType, { ...settings });
            });
        }
        console.log('Reset to server defaults');
    }

    /**
     * Export current ducking configuration for server storage
     */
    exportConfiguration() {
        return {
            duckingSettings: this.getAllDuckingSettings(),
            timestamp: Date.now(),
            version: '1.0.0'
        };
    }

    /**
     * Import ducking configuration from server
     */
    importConfiguration(config) {
        if (config.duckingSettings) {
            Object.entries(config.duckingSettings).forEach(([inputType, settings]) => {
                this.duckingSettings.set(inputType, settings);
            });
            console.log('Ducking configuration imported from server');
        }
    }

    /**
     * Destroy all ducking chains
     */
    destroy() {
        for (const inputType of this.duckingNodes.keys()) {
            this.removeDuckingChain(inputType);
        }
        console.log('Audio ducking processor destroyed');
    }
}

// Export for use in other modules
window.AudioDuckingProcessor = AudioDuckingProcessor;