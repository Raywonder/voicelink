/**
 * VoiceLink Menu Sound Manager
 * Handles random woosh sound effects when menus are accessed
 */

class MenuSoundManager {
    constructor(spatialAudio) {
        this.spatialAudio = spatialAudio;
        this.audioContext = spatialAudio.audioContext;
        this.masterGain = spatialAudio.masterGain;

        // Menu sound settings
        this.menuSounds = {
            enabled: true,
            volume: 0.3, // Moderate volume for UI sounds
            sounds: [] // Will be populated with generated woosh sounds
        };

        this.init();
    }

    async init() {
        console.log('MenuSoundManager: Initializing menu sound effects...');

        // Generate synthetic woosh sounds
        await this.generateWooshSounds();

        console.log(`MenuSoundManager: Generated ${this.menuSounds.sounds.length} woosh sound variations`);
    }

    async generateWooshSounds() {
        // Generate 5 different woosh sound variations
        const wooshConfigs = [
            {
                name: 'woosh1',
                startFreq: 800,
                endFreq: 200,
                duration: 0.4,
                filterType: 'lowpass'
            },
            {
                name: 'woosh2',
                startFreq: 1200,
                endFreq: 300,
                duration: 0.3,
                filterType: 'bandpass'
            },
            {
                name: 'woosh3',
                startFreq: 600,
                endFreq: 150,
                duration: 0.5,
                filterType: 'lowpass'
            },
            {
                name: 'woosh4',
                startFreq: 1000,
                endFreq: 250,
                duration: 0.35,
                filterType: 'highpass'
            },
            {
                name: 'woosh5',
                startFreq: 900,
                endFreq: 180,
                duration: 0.45,
                filterType: 'lowpass'
            }
        ];

        for (const config of wooshConfigs) {
            try {
                const buffer = await this.generateWooshBuffer(config);
                this.menuSounds.sounds.push({
                    name: config.name,
                    buffer: buffer
                });
            } catch (error) {
                console.warn(`MenuSoundManager: Failed to generate ${config.name}:`, error);
            }
        }
    }

    async generateWooshBuffer(config) {
        const sampleRate = this.audioContext.sampleRate;
        const length = sampleRate * config.duration;
        const buffer = this.audioContext.createBuffer(1, length, sampleRate);
        const data = buffer.getChannelData(0);

        // Generate white noise with frequency sweep
        for (let i = 0; i < length; i++) {
            const progress = i / length;

            // Create envelope (fade in/out)
            let envelope = 1;
            if (progress < 0.1) {
                envelope = progress / 0.1; // Fade in
            } else if (progress > 0.7) {
                envelope = (1 - progress) / 0.3; // Fade out
            }

            // Generate noise with frequency modulation
            const freq = config.startFreq + (config.endFreq - config.startFreq) * progress;
            const noise = (Math.random() * 2 - 1) * envelope * 0.5;

            // Apply simple frequency filtering effect
            const timePos = i / sampleRate;
            const sine = Math.sin(2 * Math.PI * freq * timePos * 0.1);

            data[i] = noise * (1 + sine * 0.3) * 0.8;
        }

        return buffer;
    }

    playRandomWoosh() {
        if (!this.menuSounds.enabled || this.menuSounds.sounds.length === 0) {
            return;
        }

        try {
            // Select random woosh sound
            const randomIndex = Math.floor(Math.random() * this.menuSounds.sounds.length);
            const soundData = this.menuSounds.sounds[randomIndex];

            // Create audio nodes
            const source = this.audioContext.createBufferSource();
            const gainNode = this.audioContext.createGain();

            // Configure source
            source.buffer = soundData.buffer;

            // Configure gain
            gainNode.gain.setValueAtTime(this.menuSounds.volume, this.audioContext.currentTime);

            // Connect audio chain
            source.connect(gainNode);
            gainNode.connect(this.masterGain);

            // Play sound
            source.start();

            console.log(`MenuSoundManager: Playing ${soundData.name}`);

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
            console.warn('MenuSoundManager: Error playing woosh sound:', error);
        }
    }

    // Convenience methods for different menu types
    playContextMenuSound() {
        this.playRandomWoosh();
    }

    playEscapeMenuSound() {
        this.playRandomWoosh();
    }

    playInviteMenuSound() {
        this.playRandomWoosh();
    }

    playRecordingMenuSound() {
        this.playRandomWoosh();
    }

    // Settings management
    setEnabled(enabled) {
        this.menuSounds.enabled = enabled;
        console.log(`MenuSoundManager: Menu sounds ${enabled ? 'enabled' : 'disabled'}`);
    }

    setVolume(volume) {
        this.menuSounds.volume = Math.max(0, Math.min(1, volume));
        console.log(`MenuSoundManager: Menu sound volume set to ${this.menuSounds.volume}`);
    }

    getSettings() {
        return {
            enabled: this.menuSounds.enabled,
            volume: this.menuSounds.volume,
            soundCount: this.menuSounds.sounds.length
        };
    }
}

// Export for use in other modules
window.MenuSoundManager = MenuSoundManager;