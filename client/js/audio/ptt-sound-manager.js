/**
 * VoiceLink Push-To-Talk Sound Manager
 * Handles transmission start/stop sounds for PTT functionality
 */

class PTTSoundManager {
    constructor(spatialAudio) {
        this.spatialAudio = spatialAudio;
        this.audioContext = spatialAudio.audioContext;
        this.masterGain = spatialAudio.masterGain;

        // PTT sound settings
        this.pttSounds = {
            enabled: true,
            volume: 0.4, // Slightly higher for transmission feedback
            transmissionStartSounds: [],
            transmissionStopSounds: []
        };

        this.init();
    }

    async init() {
        console.log('PTTSoundManager: Initializing PTT transmission sounds...');

        // Generate synthetic transmission sounds
        await this.generateTransmissionSounds();

        console.log(`PTTSoundManager: Generated ${this.pttSounds.transmissionStartSounds.length} start sounds and ${this.pttSounds.transmissionStopSounds.length} stop sounds`);
    }

    async generateTransmissionSounds() {
        // Generate transmission start sounds (short beeps/chirps)
        const startConfigs = [
            {
                name: 'start_beep1',
                frequency: 800,
                duration: 0.15,
                type: 'sine',
                envelope: 'quick_fade'
            },
            {
                name: 'start_chirp1',
                startFreq: 600,
                endFreq: 900,
                duration: 0.12,
                type: 'sweep',
                envelope: 'quick_fade'
            },
            {
                name: 'start_tone1',
                frequency: 1000,
                duration: 0.1,
                type: 'square',
                envelope: 'sharp'
            }
        ];

        // Generate transmission stop sounds (lower tones/drops)
        const stopConfigs = [
            {
                name: 'stop_drop1',
                startFreq: 800,
                endFreq: 400,
                duration: 0.2,
                type: 'sweep',
                envelope: 'fade_out'
            },
            {
                name: 'stop_beep1',
                frequency: 500,
                duration: 0.18,
                type: 'sine',
                envelope: 'fade_out'
            },
            {
                name: 'stop_tone1',
                frequency: 600,
                duration: 0.15,
                type: 'triangle',
                envelope: 'quick_fade'
            }
        ];

        // Generate start sounds
        for (const config of startConfigs) {
            try {
                const buffer = await this.generatePTTBuffer(config);
                this.pttSounds.transmissionStartSounds.push({
                    name: config.name,
                    buffer: buffer
                });
            } catch (error) {
                console.warn(`PTTSoundManager: Failed to generate ${config.name}:`, error);
            }
        }

        // Generate stop sounds
        for (const config of stopConfigs) {
            try {
                const buffer = await this.generatePTTBuffer(config);
                this.pttSounds.transmissionStopSounds.push({
                    name: config.name,
                    buffer: buffer
                });
            } catch (error) {
                console.warn(`PTTSoundManager: Failed to generate ${config.name}:`, error);
            }
        }
    }

    async generatePTTBuffer(config) {
        const sampleRate = this.audioContext.sampleRate;
        const length = sampleRate * config.duration;
        const buffer = this.audioContext.createBuffer(1, length, sampleRate);
        const data = buffer.getChannelData(0);

        for (let i = 0; i < length; i++) {
            const progress = i / length;
            const timePos = i / sampleRate;

            let amplitude = 1;
            let frequency = config.frequency || config.startFreq;

            // Handle frequency sweeps
            if (config.type === 'sweep' && config.startFreq && config.endFreq) {
                frequency = config.startFreq + (config.endFreq - config.startFreq) * progress;
            }

            // Generate waveform based on type
            let sample = 0;
            const phase = 2 * Math.PI * frequency * timePos;

            switch (config.type) {
                case 'sine':
                    sample = Math.sin(phase);
                    break;
                case 'square':
                    sample = Math.sin(phase) > 0 ? 1 : -1;
                    break;
                case 'triangle':
                    sample = (2 / Math.PI) * Math.asin(Math.sin(phase));
                    break;
                case 'sweep':
                default:
                    sample = Math.sin(phase);
                    break;
            }

            // Apply envelope
            switch (config.envelope) {
                case 'quick_fade':
                    if (progress < 0.1) {
                        amplitude = progress / 0.1;
                    } else if (progress > 0.8) {
                        amplitude = (1 - progress) / 0.2;
                    }
                    break;
                case 'fade_out':
                    amplitude = 1 - progress;
                    break;
                case 'sharp':
                    if (progress < 0.05) {
                        amplitude = progress / 0.05;
                    } else if (progress > 0.9) {
                        amplitude = (1 - progress) / 0.1;
                    }
                    break;
                default:
                    amplitude = 1;
                    break;
            }

            data[i] = sample * amplitude * 0.3; // Keep moderate volume
        }

        return buffer;
    }

    playTransmissionStart() {
        if (!this.pttSounds.enabled || this.pttSounds.transmissionStartSounds.length === 0) {
            return;
        }

        try {
            // Select random start sound
            const randomIndex = Math.floor(Math.random() * this.pttSounds.transmissionStartSounds.length);
            const soundData = this.pttSounds.transmissionStartSounds[randomIndex];

            this.playPTTSound(soundData, 'transmission start');
        } catch (error) {
            console.warn('PTTSoundManager: Error playing transmission start sound:', error);
        }
    }

    playTransmissionStop() {
        if (!this.pttSounds.enabled || this.pttSounds.transmissionStopSounds.length === 0) {
            return;
        }

        try {
            // Select random stop sound
            const randomIndex = Math.floor(Math.random() * this.pttSounds.transmissionStopSounds.length);
            const soundData = this.pttSounds.transmissionStopSounds[randomIndex];

            this.playPTTSound(soundData, 'transmission stop');
        } catch (error) {
            console.warn('PTTSoundManager: Error playing transmission stop sound:', error);
        }
    }

    playPTTSound(soundData, type) {
        try {
            // Create audio nodes
            const source = this.audioContext.createBufferSource();
            const gainNode = this.audioContext.createGain();

            // Configure source
            source.buffer = soundData.buffer;

            // Configure gain
            gainNode.gain.setValueAtTime(this.pttSounds.volume, this.audioContext.currentTime);

            // Connect audio chain
            source.connect(gainNode);
            gainNode.connect(this.masterGain);

            // Play sound
            source.start();

            console.log(`PTTSoundManager: Playing ${type} sound - ${soundData.name}`);

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
            console.warn('PTTSoundManager: Error playing PTT sound:', error);
        }
    }

    // Settings management
    setEnabled(enabled) {
        this.pttSounds.enabled = enabled;
        console.log(`PTTSoundManager: PTT sounds ${enabled ? 'enabled' : 'disabled'}`);
    }

    setVolume(volume) {
        this.pttSounds.volume = Math.max(0, Math.min(1, volume));
        console.log(`PTTSoundManager: PTT sound volume set to ${this.pttSounds.volume}`);
    }

    getSettings() {
        return {
            enabled: this.pttSounds.enabled,
            volume: this.pttSounds.volume,
            startSoundCount: this.pttSounds.transmissionStartSounds.length,
            stopSoundCount: this.pttSounds.transmissionStopSounds.length
        };
    }
}

// Export for use in other modules
window.PTTSoundManager = PTTSoundManager;