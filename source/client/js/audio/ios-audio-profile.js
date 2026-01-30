/**
 * VoiceLink iOS Audio Profile Manager
 * Handles iOS-specific audio initialization, stereo/3D audio,
 * and headphone detection for echo prevention
 */

class iOSAudioProfileManager {
    constructor() {
        this.isIOS = this.detectIOS();
        this.isSafari = this.detectSafari();
        this.audioContext = null;
        this.headphonesConnected = false;
        this.stereoEnabled = true;
        this.spatialEnabled = true;
        this.echoWarningShown = false;
        this.initialized = false;

        // Audio output device info
        this.outputDevice = null;

        // Callbacks
        this.onHeadphonesChange = null;
        this.onAudioReady = null;

        this.init();
    }

    detectIOS() {
        return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
            (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    }

    detectSafari() {
        return /^((?!chrome|android).)*safari/i.test(navigator.userAgent);
    }

    async init() {
        // Listen for headphone changes
        this.setupAudioOutputMonitoring();

        // Check initial headphone state
        await this.checkHeadphones();

        // iOS requires user interaction to start audio
        if (this.isIOS || this.isSafari) {
            console.log('[iOS Audio] Waiting for user interaction to initialize audio');
            this.setupIOSAudioUnlock();
        }

        console.log('[iOS Audio] Profile manager initialized', {
            isIOS: this.isIOS,
            isSafari: this.isSafari,
            headphones: this.headphonesConnected
        });
    }

    setupIOSAudioUnlock() {
        const unlockAudio = async () => {
            if (this.initialized) return;

            try {
                // Create and resume audio context
                this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
                    sampleRate: 48000,
                    latencyHint: 'interactive'
                });

                // iOS needs a silent buffer to be played
                if (this.audioContext.state === 'suspended') {
                    await this.audioContext.resume();
                }

                // Play a silent buffer to unlock audio
                const buffer = this.audioContext.createBuffer(1, 1, 22050);
                const source = this.audioContext.createBufferSource();
                source.buffer = buffer;
                source.connect(this.audioContext.destination);
                source.start(0);

                this.initialized = true;
                console.log('[iOS Audio] Audio context unlocked');

                // Remove unlock listeners
                document.removeEventListener('touchstart', unlockAudio);
                document.removeEventListener('touchend', unlockAudio);
                document.removeEventListener('click', unlockAudio);

                // Show headphones warning if needed
                if (!this.headphonesConnected) {
                    this.showEchoWarning();
                }

                // Notify ready
                if (this.onAudioReady) {
                    this.onAudioReady(this.audioContext);
                }

            } catch (error) {
                console.error('[iOS Audio] Failed to unlock audio:', error);
            }
        };

        document.addEventListener('touchstart', unlockAudio, { once: false });
        document.addEventListener('touchend', unlockAudio, { once: false });
        document.addEventListener('click', unlockAudio, { once: false });
    }

    async checkHeadphones() {
        try {
            // Use Web Audio API to check for stereo output (indicates headphones/external)
            if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
                const devices = await navigator.mediaDevices.enumerateDevices();
                const audioOutputs = devices.filter(d => d.kind === 'audiooutput');

                // Check for headphone-like device names
                const headphoneKeywords = ['headphone', 'headset', 'airpod', 'earbud', 'bluetooth', 'bt'];
                this.headphonesConnected = audioOutputs.some(device => {
                    const label = device.label.toLowerCase();
                    return headphoneKeywords.some(kw => label.includes(kw));
                });

                // Store current output device
                this.outputDevice = audioOutputs.find(d => d.deviceId === 'default') || audioOutputs[0];

                console.log('[iOS Audio] Headphones detected:', this.headphonesConnected);
            }
        } catch (error) {
            console.error('[iOS Audio] Failed to check headphones:', error);
            // Assume no headphones for safety
            this.headphonesConnected = false;
        }

        return this.headphonesConnected;
    }

    setupAudioOutputMonitoring() {
        // Listen for device changes
        if (navigator.mediaDevices) {
            navigator.mediaDevices.addEventListener('devicechange', async () => {
                const previousState = this.headphonesConnected;
                await this.checkHeadphones();

                if (previousState !== this.headphonesConnected) {
                    console.log('[iOS Audio] Headphones state changed:', this.headphonesConnected);

                    if (this.onHeadphonesChange) {
                        this.onHeadphonesChange(this.headphonesConnected);
                    }

                    // Show or hide echo warning
                    if (!this.headphonesConnected) {
                        this.showEchoWarning();
                    } else {
                        this.hideEchoWarning();
                    }
                }
            });
        }
    }

    showEchoWarning() {
        if (this.echoWarningShown) return;

        // Check if warning element exists, create if not
        let warning = document.getElementById('headphones-warning');
        if (!warning) {
            warning = document.createElement('div');
            warning.id = 'headphones-warning';
            warning.className = 'headphones-warning';

            const content = document.createElement('div');
            content.className = 'headphones-warning-content';

            // Create headphones icon (SVG)
            const iconSvg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
            iconSvg.setAttribute('class', 'headphones-icon');
            iconSvg.setAttribute('viewBox', '0 0 24 24');
            iconSvg.setAttribute('width', '24');
            iconSvg.setAttribute('height', '24');
            const iconPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
            iconPath.setAttribute('fill', 'currentColor');
            iconPath.setAttribute('d', 'M12,1A9,9,0,0,0,3,10v8a3,3,0,0,0,3,3H7a1,1,0,0,0,1-1V13a1,1,0,0,0-1-1H5V10a7,7,0,0,1,14,0v2H17a1,1,0,0,0-1,1v7a1,1,0,0,0,1,1h1a3,3,0,0,0,3-3V10A9,9,0,0,0,12,1Z');
            iconSvg.appendChild(iconPath);

            // Create text content
            const textDiv = document.createElement('div');
            textDiv.className = 'warning-text';
            const strong = document.createElement('strong');
            strong.textContent = 'Use Headphones';
            const p = document.createElement('p');
            p.textContent = 'Headphones recommended to prevent echo feedback';
            textDiv.appendChild(strong);
            textDiv.appendChild(p);

            // Create dismiss button
            const dismissBtn = document.createElement('button');
            dismissBtn.className = 'dismiss-warning';
            dismissBtn.onclick = () => this.dismissEchoWarning();
            const dismissSvg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
            dismissSvg.setAttribute('viewBox', '0 0 24 24');
            dismissSvg.setAttribute('width', '16');
            dismissSvg.setAttribute('height', '16');
            const dismissPath = document.createElementNS('http://www.w3.org/2000/svg', 'path');
            dismissPath.setAttribute('fill', 'currentColor');
            dismissPath.setAttribute('d', 'M19,6.41L17.59,5L12,10.59L6.41,5L5,6.41L10.59,12L5,17.59L6.41,19L12,13.41L17.59,19L19,17.59L13.41,12L19,6.41Z');
            dismissSvg.appendChild(dismissPath);
            dismissBtn.appendChild(dismissSvg);

            content.appendChild(iconSvg);
            content.appendChild(textDiv);
            content.appendChild(dismissBtn);
            warning.appendChild(content);
            document.body.appendChild(warning);
        }

        warning.classList.add('visible');
        this.echoWarningShown = true;

        // Auto-hide after 10 seconds
        setTimeout(() => {
            if (this.echoWarningShown && !this.headphonesConnected) {
                // Keep showing but make it less intrusive
                warning.classList.add('minimized');
            }
        }, 10000);
    }

    hideEchoWarning() {
        const warning = document.getElementById('headphones-warning');
        if (warning) {
            warning.classList.remove('visible');
            warning.classList.remove('minimized');
        }
        this.echoWarningShown = false;
    }

    dismissEchoWarning() {
        const warning = document.getElementById('headphones-warning');
        if (warning) {
            warning.classList.add('minimized');
        }
    }

    /**
     * Get audio configuration optimized for iOS
     */
    getAudioConfig() {
        const config = {
            sampleRate: 48000,
            channelCount: 2, // Stereo
            echoCancellation: !this.headphonesConnected,
            noiseSuppression: true,
            autoGainControl: true,
            latencyHint: 'interactive'
        };

        // iOS Safari-specific optimizations
        if (this.isIOS || this.isSafari) {
            config.channelCountMode = 'explicit';
            config.channelInterpretation = 'speakers';
        }

        return config;
    }

    /**
     * Get media constraints for stereo input
     */
    getMediaConstraints() {
        return {
            audio: {
                echoCancellation: !this.headphonesConnected,
                noiseSuppression: true,
                autoGainControl: true,
                channelCount: { ideal: 2 }, // Request stereo
                sampleRate: { ideal: 48000 },
                sampleSize: { ideal: 16 }
            }
        };
    }

    /**
     * Enable/disable stereo output
     */
    setStereoEnabled(enabled) {
        this.stereoEnabled = enabled;
        console.log('[iOS Audio] Stereo:', enabled);
    }

    /**
     * Enable/disable spatial (3D) audio
     */
    setSpatialEnabled(enabled) {
        this.spatialEnabled = enabled;
        console.log('[iOS Audio] Spatial audio:', enabled);
    }

    /**
     * Get the audio context (creates if needed)
     */
    async getAudioContext() {
        if (!this.audioContext || this.audioContext.state === 'closed') {
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)(
                this.getAudioConfig()
            );
        }

        if (this.audioContext.state === 'suspended') {
            await this.audioContext.resume();
        }

        return this.audioContext;
    }

    /**
     * Create a stereo panner for 3D positioning
     */
    createStereoPanner(audioContext) {
        if (!this.stereoEnabled) {
            return null;
        }

        try {
            const panner = audioContext.createPanner();
            panner.panningModel = this.spatialEnabled ? 'HRTF' : 'equalpower';
            panner.distanceModel = 'inverse';
            panner.refDistance = 1;
            panner.maxDistance = 20;
            panner.rolloffFactor = 1;
            return panner;
        } catch (error) {
            console.error('[iOS Audio] Failed to create stereo panner:', error);
            return null;
        }
    }

    /**
     * Check if audio is ready for playback
     */
    isReady() {
        return this.initialized && this.audioContext?.state === 'running';
    }

    /**
     * Get current audio profile status
     */
    getStatus() {
        return {
            isIOS: this.isIOS,
            isSafari: this.isSafari,
            initialized: this.initialized,
            headphonesConnected: this.headphonesConnected,
            stereoEnabled: this.stereoEnabled,
            spatialEnabled: this.spatialEnabled,
            audioContextState: this.audioContext?.state,
            outputDevice: this.outputDevice?.label || 'Unknown'
        };
    }
}

// CSS for headphones warning
const headphonesWarningStyles = document.createElement('style');
headphonesWarningStyles.textContent = `
    .headphones-warning {
        position: fixed;
        top: 20px;
        left: 50%;
        transform: translateX(-50%) translateY(-100px);
        background: linear-gradient(135deg, #ff6b6b 0%, #ee5a5a 100%);
        color: white;
        padding: 12px 20px;
        border-radius: 12px;
        box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3);
        z-index: 10000;
        transition: transform 0.3s ease, opacity 0.3s ease;
        opacity: 0;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }

    .headphones-warning.visible {
        transform: translateX(-50%) translateY(0);
        opacity: 1;
    }

    .headphones-warning.minimized {
        transform: translateX(-50%) translateY(0) scale(0.8);
        opacity: 0.7;
        top: 10px;
    }

    .headphones-warning-content {
        display: flex;
        align-items: center;
        gap: 12px;
    }

    .headphones-icon {
        flex-shrink: 0;
    }

    .warning-text strong {
        display: block;
        font-size: 14px;
        margin-bottom: 2px;
    }

    .warning-text p {
        font-size: 12px;
        opacity: 0.9;
        margin: 0;
    }

    .dismiss-warning {
        background: rgba(255, 255, 255, 0.2);
        border: none;
        border-radius: 50%;
        width: 28px;
        height: 28px;
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        transition: background 0.2s;
        color: white;
    }

    .dismiss-warning:hover {
        background: rgba(255, 255, 255, 0.3);
    }

    @media (max-width: 480px) {
        .headphones-warning {
            left: 10px;
            right: 10px;
            transform: translateX(0) translateY(-100px);
        }

        .headphones-warning.visible {
            transform: translateX(0) translateY(0);
        }

        .headphones-warning.minimized {
            transform: translateX(0) translateY(0) scale(0.9);
        }
    }
`;
document.head.appendChild(headphonesWarningStyles);

// Create global instance
window.iosAudioProfile = new iOSAudioProfileManager();

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
    module.exports = iOSAudioProfileManager;
}
