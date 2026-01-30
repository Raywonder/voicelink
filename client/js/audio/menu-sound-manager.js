/**
 * VoiceLink Menu Sound Manager
 * Handles random woosh sound effects when menus are accessed
 */

class MenuSoundManager {
    constructor(spatialAudio) {
        this.spatialAudio = spatialAudio;
        this.audioContext = spatialAudio.audioContext;
        this.masterGain = spatialAudio.masterGain;

        // Sound files base path
        this.soundsBasePath = '/assets/sounds/peek/';

        // Menu sound settings
        this.menuSounds = {
            enabled: true,
            volume: 0.3,
            sounds: {} // Will be populated with loaded sound buffers
        };

        // Sound file mappings - actual files from assets/sounds
        this.soundFiles = {
            contextMenu: 'whoosh_fast1.wav',
            escapeMenu: 'whoosh_medium1.wav',
            inviteMenu: 'whoosh_fast2.wav',
            recordingMenu: 'whoosh_medium2.wav',
            settingsMenu: 'whoosh_slow1.wav',
            userJoin: 'user-join.wav',
            userLeave: 'user-leave.wav',
            buttonClick: 'button-click.wav',
            success: 'success.wav',
            error: 'error.wav',
            notification: 'notification.wav',
            connected: 'connected.wav',
            disconnected: 'connection lost.wav',
            reconnected: 'reconnected.wav',
            uiAppear: 'UI Animate Clean Beeps Appear (stereo).flac',
            uiDisappear: 'UI Animate Clean Beeps Disappear (stereo).flac',
            pttStart: 'Whisper-start.wav',
            pttStop: 'Whisper-Stop.wav',
            // Mute/unmute sounds (using button click)
            mute: 'button-click.wav',
            unmute: 'button-click.wav',
            deafen: 'switch_button_push_small_05.flac',
            undeafen: 'switch_button_push_small_05.flac',
            // PTT sounds (high beep = active, low beep = inactive)
            pttEnable: 'ptt-beep-high.flac',
            pttDisable: 'ptt-beep-low.flac',
            pttStart: 'ptt-beep-high.flac',   // When speaking starts
            pttStop: 'ptt-beep-low.flac'      // When speaking stops
        };

        this.init();
    }

    async init() {
        console.log('MenuSoundManager: Initializing with actual sound files...');
        await this.loadSoundFiles();
        console.log(`MenuSoundManager: Loaded ${Object.keys(this.menuSounds.sounds).length} sounds`);
    }

    async loadSoundFiles() {
        for (const [soundName, fileName] of Object.entries(this.soundFiles)) {
            try {
                const buffer = await this.loadSoundFile(fileName);
                if (buffer) {
                    this.menuSounds.sounds[soundName] = buffer;
                }
            } catch (error) {
                console.warn(`MenuSoundManager: Failed to load ${fileName}:`, error);
            }
        }
    }

    async loadSoundFile(fileName) {
        try {
            const response = await fetch(this.soundsBasePath + encodeURIComponent(fileName));
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            const arrayBuffer = await response.arrayBuffer();
            return await this.audioContext.decodeAudioData(arrayBuffer);
        } catch (error) {
            console.warn(`MenuSoundManager: Could not load ${fileName}:`, error);
            return null;
        }
    }

    // Core sound playback method
    playSoundByName(soundName) {
        if (!this.menuSounds.enabled) {
            return;
        }

        const buffer = this.menuSounds.sounds[soundName];
        if (!buffer) {
            console.warn(`MenuSoundManager: Sound '${soundName}' not loaded`);
            return;
        }

        try {
            const source = this.audioContext.createBufferSource();
            const gainNode = this.audioContext.createGain();

            source.buffer = buffer;
            gainNode.gain.setValueAtTime(this.menuSounds.volume, this.audioContext.currentTime);

            source.connect(gainNode);
            gainNode.connect(this.masterGain);
            source.start();

            console.log(`MenuSoundManager: Playing ${soundName}`);

            source.onended = () => {
                try {
                    source.disconnect();
                    gainNode.disconnect();
                } catch (e) {}
            };

        } catch (error) {
            console.warn('MenuSoundManager: Error playing sound:', error);
        }
    }

    // Distinct sounds for different menu types
    playContextMenuSound() {
        this.playSoundByName('contextMenu');
    }

    playEscapeMenuSound() {
        this.playSoundByName('escapeMenu');
    }

    playInviteMenuSound() {
        this.playSoundByName('inviteMenu');
    }

    playRecordingMenuSound() {
        this.playSoundByName('recordingMenu');
    }

    playSettingsMenuSound() {
        this.playSoundByName('settingsMenu');
    }

    // UI event sounds
    playUserJoinSound() {
        this.playSoundByName('userJoin');
    }

    playUserLeaveSound() {
        this.playSoundByName('userLeave');
    }

    playButtonClickSound() {
        this.playSoundByName('buttonClick');
    }

    playSuccessSound() {
        this.playSoundByName('success');
    }

    playErrorSound() {
        this.playSoundByName('error');
    }

    playNotificationSound() {
        this.playSoundByName('notification');
    }

    playConnectedSound() {
        this.playSoundByName('connected');
    }

    playDisconnectedSound() {
        this.playSoundByName('disconnected');
    }

    playReconnectedSound() {
        this.playSoundByName('reconnected');
    }

    playUIAppearSound() {
        this.playSoundByName('uiAppear');
    }

    playUIDisappearSound() {
        this.playSoundByName('uiDisappear');
    }

    playPTTStartSound() {
        this.playSoundByName('pttStart');
    }

    playPTTStopSound() {
        this.playSoundByName('pttStop');
    }

    // Mute/unmute sounds
    playMuteSound() {
        this.playSoundByName('mute');
    }

    playUnmuteSound() {
        this.playSoundByName('unmute');
    }

    playDeafenSound() {
        this.playSoundByName('deafen');
    }

    playUndeafenSound() {
        this.playSoundByName('undeafen');
    }

    playPTTEnableSound() {
        this.playSoundByName('pttEnable');
    }

    playPTTDisableSound() {
        this.playSoundByName('pttDisable');
    }

    // Legacy random woosh for backwards compatibility
    playRandomWoosh() {
        const wooshSounds = ['contextMenu', 'escapeMenu', 'inviteMenu', 'recordingMenu', 'settingsMenu'];
        const randomSound = wooshSounds[Math.floor(Math.random() * wooshSounds.length)];
        this.playSoundByName(randomSound);
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