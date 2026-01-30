/**
 * Media Metadata Detector
 * Detects and displays metadata from various streaming sources
 */

class MediaMetadataDetector {
    constructor(audioEngine) {
        this.audioEngine = audioEngine;
        this.metadataCache = new Map();
        this.activeStreams = new Map();
        this.updateInterval = null;
        this.detectionMethods = [];

        this.init();
    }

    init() {
        this.setupDetectionMethods();
        this.createMetadataDisplay();
        this.startDetection();
    }

    setupDetectionMethods() {
        // Browser tab media detection
        this.detectionMethods.push({
            name: 'Browser Media Session',
            detect: () => this.detectBrowserMediaSession()
        });

        // System audio detection via Web Audio API analysis
        this.detectionMethods.push({
            name: 'Audio Analysis',
            detect: () => this.detectViaAudioAnalysis()
        });

        // Virtual cable metadata (for supported applications)
        this.detectionMethods.push({
            name: 'Virtual Audio Metadata',
            detect: () => this.detectVirtualAudioMetadata()
        });

        // Application window title detection (limited in browser)
        this.detectionMethods.push({
            name: 'Window Detection',
            detect: () => this.detectActiveWindows()
        });
    }

    async detectBrowserMediaSession() {
        try {
            if ('mediaSession' in navigator) {
                const metadata = navigator.mediaSession.metadata;
                if (metadata) {
                    return {
                        source: 'Browser Tab',
                        title: metadata.title || 'Unknown',
                        artist: metadata.artist || 'Unknown Artist',
                        album: metadata.album || '',
                        artwork: metadata.artwork?.[0]?.src || null,
                        type: 'web-media',
                        timestamp: Date.now()
                    };
                }
            }
        } catch (error) {
            console.debug('Browser media session detection failed:', error);
        }
        return null;
    }

    async detectViaAudioAnalysis() {
        try {
            // Analyze audio streams for pattern recognition
            const streamInfo = this.audioEngine.getInputSourcesStatus();
            const results = [];

            for (const [inputType, status] of Object.entries(streamInfo)) {
                if (status.enabled && status.hasStream) {
                    const stream = this.audioEngine.inputStreams.get(inputType);
                    if (stream) {
                        const analysis = await this.analyzeAudioStream(stream, inputType);
                        if (analysis) {
                            results.push(analysis);
                        }
                    }
                }
            }

            return results.length > 0 ? results[0] : null;
        } catch (error) {
            console.debug('Audio analysis detection failed:', error);
        }
        return null;
    }

    async analyzeAudioStream(stream, inputType) {
        try {
            if (!this.audioEngine.audioContext) return null;

            const source = this.audioEngine.audioContext.createMediaStreamSource(stream);
            const analyser = this.audioEngine.audioContext.createAnalyser();
            analyser.fftSize = 2048;
            analyser.smoothingTimeConstant = 0.8;

            source.connect(analyser);

            const frequencyData = new Uint8Array(analyser.frequencyBinCount);
            const timeData = new Uint8Array(analyser.fftSize);

            analyser.getByteFrequencyData(frequencyData);
            analyser.getByteTimeDomainData(timeData);

            // Analyze audio characteristics
            const totalEnergy = frequencyData.reduce((sum, val) => sum + val, 0);
            const averageEnergy = totalEnergy / frequencyData.length;

            // Frequency distribution analysis
            const bassEnergy = frequencyData.slice(0, 64).reduce((sum, val) => sum + val, 0);
            const midEnergy = frequencyData.slice(64, 256).reduce((sum, val) => sum + val, 0);
            const trebleEnergy = frequencyData.slice(256).reduce((sum, val) => sum + val, 0);

            // Determine content type based on frequency profile
            let contentType = 'unknown';
            if (midEnergy > bassEnergy && midEnergy > trebleEnergy) {
                contentType = 'speech/podcast';
            } else if (bassEnergy > midEnergy * 1.5) {
                contentType = 'music';
            } else if (averageEnergy > 50) {
                contentType = 'mixed-content';
            }

            // Clean up
            source.disconnect();

            if (averageEnergy > 10) { // Only report if there's significant audio
                return {
                    source: this.getInputTypeDisplayName(inputType),
                    title: `${contentType} - Active`,
                    artist: `${inputType} input`,
                    type: 'audio-analysis',
                    energy: Math.round(averageEnergy),
                    contentType: contentType,
                    timestamp: Date.now(),
                    audioProfile: {
                        bass: Math.round(bassEnergy / 64),
                        mid: Math.round(midEnergy / 192),
                        treble: Math.round(trebleEnergy / (frequencyData.length - 256))
                    }
                };
            }
        } catch (error) {
            console.debug(`Audio analysis failed for ${inputType}:`, error);
        }
        return null;
    }

    async detectVirtualAudioMetadata() {
        try {
            // Check for common virtual audio device naming patterns that might contain metadata
            const virtualDevices = this.audioEngine.getVirtualAudioDevices();
            const results = [];

            for (const device of virtualDevices) {
                const metadata = this.parseDeviceNameForMetadata(device.label);
                if (metadata) {
                    results.push({
                        source: 'Virtual Audio Device',
                        title: metadata.title || device.label,
                        artist: metadata.artist || 'Unknown',
                        device: device.label,
                        type: 'virtual-audio',
                        timestamp: Date.now()
                    });
                }
            }

            return results.length > 0 ? results[0] : null;
        } catch (error) {
            console.debug('Virtual audio metadata detection failed:', error);
        }
        return null;
    }

    parseDeviceNameForMetadata(deviceName) {
        // Some virtual audio devices include metadata in their names
        const patterns = [
            /(.+?)\s*-\s*(.+)/,  // "Artist - Song"
            /(.+?)\s*\|\s*(.+)/,  // "Artist | Song"
            /(.+?)\s*:\s*(.+)/    // "Artist: Song"
        ];

        for (const pattern of patterns) {
            const match = deviceName.match(pattern);
            if (match) {
                return {
                    artist: match[1].trim(),
                    title: match[2].trim()
                };
            }
        }

        return null;
    }

    async detectActiveWindows() {
        try {
            // Limited window detection in browser environment
            // This would primarily work for the current tab
            const title = document.title;

            // Check for common media player patterns in page title
            const mediaPatterns = [
                /(.+?)\s*-\s*(.+?)\s*-\s*(YouTube|Spotify|SoundCloud|Apple Music)/i,
                /(.+?)\s*\|\s*(.+?)\s*-\s*(VLC|iTunes|Music)/i,
                /Now Playing:\s*(.+?)\s*-\s*(.+)/i
            ];

            for (const pattern of mediaPatterns) {
                const match = title.match(pattern);
                if (match) {
                    return {
                        source: match[3] || 'Web Player',
                        title: match[2] || match[1],
                        artist: match[1] || 'Unknown Artist',
                        type: 'window-title',
                        timestamp: Date.now()
                    };
                }
            }
        } catch (error) {
            console.debug('Window detection failed:', error);
        }
        return null;
    }

    getInputTypeDisplayName(inputType) {
        const names = {
            'microphone': 'Microphone',
            'media_streaming': 'Media Stream',
            'virtual_input': 'Virtual Input',
            'system_audio': 'System Audio'
        };
        return names[inputType] || inputType;
    }

    async updateMetadata() {
        const allMetadata = [];

        // Run all detection methods
        for (const method of this.detectionMethods) {
            try {
                const result = await method.detect();
                if (result) {
                    if (Array.isArray(result)) {
                        allMetadata.push(...result);
                    } else {
                        allMetadata.push(result);
                    }
                }
            } catch (error) {
                console.debug(`Detection method ${method.name} failed:`, error);
            }
        }

        // Update cache and display
        if (allMetadata.length > 0) {
            const latest = allMetadata[0]; // Use most recent/relevant
            this.metadataCache.set(latest.source, latest);
            this.updateDisplay();
        }
    }

    createMetadataDisplay() {
        // Create floating metadata display
        this.displayContainer = document.createElement('div');
        this.displayContainer.id = 'media-metadata-display';
        this.displayContainer.className = 'metadata-overlay';
        this.displayContainer.style.display = 'none';

        this.displayContainer.innerHTML = `
            <div class="metadata-header">
                <h4>📻 Now Streaming</h4>
                <button class="metadata-close" onclick="mediaMetadataDetector.hideDisplay()">&times;</button>
            </div>
            <div class="metadata-content">
                <div class="metadata-artwork">
                    <div class="metadata-placeholder">🎵</div>
                </div>
                <div class="metadata-info">
                    <div class="metadata-title">No media detected</div>
                    <div class="metadata-artist">—</div>
                    <div class="metadata-source">—</div>
                </div>
                <div class="metadata-controls">
                    <button class="metadata-refresh" onclick="mediaMetadataDetector.forceUpdate()">🔄</button>
                    <button class="metadata-settings" onclick="mediaMetadataDetector.showSettings()">⚙️</button>
                </div>
            </div>
            <div class="metadata-details" style="display: none;">
                <div class="audio-analysis"></div>
            </div>
        `;

        document.body.appendChild(this.displayContainer);
        this.addStyles();
    }

    addStyles() {
        const styles = `
            <style id="metadata-display-styles">
                .metadata-overlay {
                    position: fixed;
                    top: 20px;
                    right: 20px;
                    width: 300px;
                    background: rgba(20, 20, 30, 0.95);
                    backdrop-filter: blur(10px);
                    border: 1px solid rgba(100, 200, 255, 0.3);
                    border-radius: 12px;
                    color: white;
                    z-index: 1001;
                    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                }

                .metadata-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    padding: 12px 16px;
                    border-bottom: 1px solid rgba(100, 200, 255, 0.2);
                    background: rgba(0, 50, 100, 0.3);
                    border-radius: 12px 12px 0 0;
                }

                .metadata-header h4 {
                    margin: 0;
                    color: #64c8ff;
                    font-size: 14px;
                    font-weight: 600;
                }

                .metadata-close {
                    background: none;
                    border: none;
                    color: #ff6b6b;
                    font-size: 18px;
                    cursor: pointer;
                    padding: 0;
                    width: 24px;
                    height: 24px;
                    border-radius: 50%;
                }

                .metadata-close:hover {
                    background: rgba(255, 107, 107, 0.2);
                }

                .metadata-content {
                    display: flex;
                    padding: 16px;
                    gap: 12px;
                }

                .metadata-artwork {
                    width: 50px;
                    height: 50px;
                    border-radius: 8px;
                    background: rgba(100, 200, 255, 0.1);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    flex-shrink: 0;
                }

                .metadata-artwork img {
                    width: 100%;
                    height: 100%;
                    border-radius: 8px;
                    object-fit: cover;
                }

                .metadata-placeholder {
                    font-size: 20px;
                    opacity: 0.6;
                }

                .metadata-info {
                    flex: 1;
                    min-width: 0;
                }

                .metadata-title {
                    font-weight: 600;
                    font-size: 14px;
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    margin-bottom: 4px;
                }

                .metadata-artist {
                    font-size: 12px;
                    color: rgba(255, 255, 255, 0.8);
                    white-space: nowrap;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    margin-bottom: 4px;
                }

                .metadata-source {
                    font-size: 10px;
                    color: rgba(100, 200, 255, 0.8);
                    font-weight: 500;
                }

                .metadata-controls {
                    display: flex;
                    flex-direction: column;
                    gap: 4px;
                }

                .metadata-controls button {
                    background: rgba(100, 200, 255, 0.2);
                    border: 1px solid rgba(100, 200, 255, 0.3);
                    border-radius: 4px;
                    color: white;
                    cursor: pointer;
                    padding: 4px;
                    font-size: 12px;
                    width: 28px;
                    height: 28px;
                }

                .metadata-controls button:hover {
                    background: rgba(100, 200, 255, 0.4);
                }

                .metadata-details {
                    padding: 0 16px 16px;
                    border-top: 1px solid rgba(100, 200, 255, 0.1);
                }

                .audio-analysis {
                    font-size: 11px;
                    color: rgba(255, 255, 255, 0.6);
                    margin-top: 8px;
                }

                .audio-analysis div {
                    margin: 2px 0;
                }

                .metadata-overlay.animate-in {
                    animation: slideInFromRight 0.3s ease-out;
                }

                @keyframes slideInFromRight {
                    from {
                        transform: translateX(100%);
                        opacity: 0;
                    }
                    to {
                        transform: translateX(0);
                        opacity: 1;
                    }
                }
            </style>
        `;

        if (!document.getElementById('metadata-display-styles')) {
            document.head.insertAdjacentHTML('beforeend', styles);
        }
    }

    updateDisplay() {
        if (this.metadataCache.size === 0) {
            this.hideDisplay();
            return;
        }

        // Get the most recent metadata
        let latestMetadata = null;
        let latestTime = 0;

        for (const metadata of this.metadataCache.values()) {
            if (metadata.timestamp > latestTime) {
                latestTime = metadata.timestamp;
                latestMetadata = metadata;
            }
        }

        if (!latestMetadata) return;

        // Update display elements
        const titleElement = this.displayContainer.querySelector('.metadata-title');
        const artistElement = this.displayContainer.querySelector('.metadata-artist');
        const sourceElement = this.displayContainer.querySelector('.metadata-source');
        const artworkElement = this.displayContainer.querySelector('.metadata-artwork');
        const detailsElement = this.displayContainer.querySelector('.audio-analysis');

        if (titleElement) titleElement.textContent = latestMetadata.title || 'Unknown Title';
        if (artistElement) artistElement.textContent = latestMetadata.artist || 'Unknown Artist';
        if (sourceElement) sourceElement.textContent = latestMetadata.source || 'Unknown Source';

        // Update artwork
        if (artworkElement) {
            if (latestMetadata.artwork) {
                artworkElement.innerHTML = `<img src="${latestMetadata.artwork}" alt="Album Art">`;
            } else {
                artworkElement.innerHTML = '<div class="metadata-placeholder">🎵</div>';
            }
        }

        // Update details if available
        if (detailsElement && latestMetadata.audioProfile) {
            detailsElement.innerHTML = `
                <div>Content: ${latestMetadata.contentType}</div>
                <div>Energy: ${latestMetadata.energy}</div>
                <div>Bass: ${latestMetadata.audioProfile.bass}</div>
                <div>Mid: ${latestMetadata.audioProfile.mid}</div>
                <div>Treble: ${latestMetadata.audioProfile.treble}</div>
            `;
        }

        this.showDisplay();
    }

    showDisplay() {
        this.displayContainer.style.display = 'block';
        this.displayContainer.classList.add('animate-in');
    }

    hideDisplay() {
        this.displayContainer.style.display = 'none';
        this.displayContainer.classList.remove('animate-in');
    }

    forceUpdate() {
        console.log('Forcing metadata update...');
        this.updateMetadata();
    }

    showSettings() {
        // Open settings or multi-input manager
        if (window.multiInputManager) {
            window.multiInputManager.show();
        } else {
            console.log('Multi-input manager not available');
        }
    }

    startDetection() {
        console.log('Starting media metadata detection...');

        // Initial detection
        this.updateMetadata();

        // Set up periodic updates
        this.updateInterval = setInterval(() => {
            this.updateMetadata();
        }, 5000); // Update every 5 seconds
    }

    stopDetection() {
        if (this.updateInterval) {
            clearInterval(this.updateInterval);
            this.updateInterval = null;
        }
        this.hideDisplay();
        console.log('Media metadata detection stopped');
    }

    destroy() {
        this.stopDetection();
        if (this.displayContainer) {
            this.displayContainer.remove();
        }
    }
}

// Export for use in other modules
window.MediaMetadataDetector = MediaMetadataDetector;