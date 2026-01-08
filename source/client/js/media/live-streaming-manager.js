/**
 * Live Streaming Manager
 * Handles Icecast, Shoutcast, and other live streaming sources
 */

class LiveStreamingManager {
    constructor() {
        this.streams = new Map(); // streamId -> stream config
        this.activeStreams = new Map(); // streamId -> audio element
        this.streamMetadata = new Map(); // streamId -> current metadata
        this.metadataUpdateInterval = null;

        // Supported streaming formats and protocols
        this.supportedFormats = {
            icecast: ['mp3', 'ogg', 'aac', 'opus'],
            shoutcast: ['mp3', 'aac'],
            generic: ['mp3', 'ogg', 'aac', 'opus', 'm3u8', 'pls']
        };

        // Stream quality presets
        this.qualityPresets = {
            low: { bitrate: 64, sampleRate: 22050, description: 'Low quality (64kbps)' },
            medium: { bitrate: 128, sampleRate: 44100, description: 'Medium quality (128kbps)' },
            high: { bitrate: 192, sampleRate: 48000, description: 'High quality (192kbps)' },
            ultra: { bitrate: 320, sampleRate: 48000, description: 'Ultra quality (320kbps)' }
        };

        this.init();
    }

    init() {
        this.loadStreamConfigurations();
        this.setupMetadataUpdater();
        console.log('Live Streaming Manager initialized');
    }

    /**
     * Add a new stream configuration
     */
    addStream(config) {
        const { name, url, type, description, genre, streamId } = config;

        if (!name || !url) {
            throw new Error('Stream name and URL are required');
        }

        const streamConfig = {
            id: streamId || this.generateStreamId(),
            name,
            url: this.normalizeStreamUrl(url),
            type: type || this.detectStreamType(url),
            description: description || '',
            genre: genre || 'Unknown',
            quality: this.detectStreamQuality(url),
            addedAt: Date.now(),
            lastPlayed: null,
            playCount: 0,
            isActive: false,
            volume: 0.8,
            crossfade: false
        };

        // Validate URL accessibility
        return this.validateStreamUrl(streamConfig.url)
            .then(() => {
                this.streams.set(streamConfig.id, streamConfig);
                this.saveStreamConfigurations();
                console.log(`Stream "${name}" added successfully`);
                return streamConfig;
            })
            .catch((error) => {
                throw new Error(`Failed to validate stream URL: ${error.message}`);
            });
    }

    /**
     * Start playing a stream
     */
    async playStream(streamId, options = {}) {
        const streamConfig = this.streams.get(streamId);
        if (!streamConfig) {
            throw new Error('Stream configuration not found');
        }

        try {
            // Stop any currently playing stream if not allowing multiple
            if (!options.allowMultiple && this.activeStreams.size > 0) {
                this.stopAllStreams();
            }

            // Create audio element
            const audio = new Audio();
            audio.crossOrigin = 'anonymous';
            audio.preload = 'none';

            // Set stream URL
            const streamUrl = this.buildStreamUrl(streamConfig, options);
            audio.src = streamUrl;

            // Configure audio properties
            audio.volume = options.volume || streamConfig.volume || 0.8;
            audio.loop = options.loop || false;

            // Set up event listeners
            this.setupStreamEventListeners(audio, streamConfig);

            // Store active stream
            this.activeStreams.set(streamId, {
                audio,
                config: streamConfig,
                startTime: Date.now(),
                options
            });

            // Update stream status
            streamConfig.isActive = true;
            streamConfig.lastPlayed = Date.now();
            streamConfig.playCount++;

            // Start playback
            await audio.play();

            // Integrate with audio engine
            if (window.audioEngine && window.audioEngine.audioContext) {
                this.integrateWithAudioEngine(streamId, audio);
            }

            // Start metadata updates for this stream
            this.startMetadataUpdates(streamId);

            console.log(`Started playing stream: ${streamConfig.name}`);
            this.notifyStreamEvent('started', streamConfig);

            return audio;

        } catch (error) {
            console.error('Failed to start stream playback:', error);
            streamConfig.isActive = false;
            throw error;
        }
    }

    /**
     * Stop playing a specific stream
     */
    stopStream(streamId) {
        const activeStream = this.activeStreams.get(streamId);
        if (!activeStream) {
            return false;
        }

        try {
            // Stop audio playback
            activeStream.audio.pause();
            activeStream.audio.src = '';

            // Clean up audio nodes
            if (activeStream.audioNodes) {
                activeStream.audioNodes.source.disconnect();
            }

            // Update status
            activeStream.config.isActive = false;

            // Remove from active streams
            this.activeStreams.delete(streamId);

            console.log(`Stopped stream: ${activeStream.config.name}`);
            this.notifyStreamEvent('stopped', activeStream.config);

            return true;
        } catch (error) {
            console.error('Error stopping stream:', error);
            return false;
        }
    }

    /**
     * Stop all active streams
     */
    stopAllStreams() {
        const streamIds = Array.from(this.activeStreams.keys());
        streamIds.forEach(streamId => this.stopStream(streamId));
    }

    /**
     * Build stream URL with parameters
     */
    buildStreamUrl(streamConfig, options = {}) {
        let url = streamConfig.url;

        // Add quality parameters for supported formats
        if (streamConfig.type === 'icecast' || streamConfig.type === 'shoutcast') {
            const params = new URLSearchParams();

            if (options.quality) {
                const preset = this.qualityPresets[options.quality];
                if (preset) {
                    params.append('bitrate', preset.bitrate);
                }
            }

            if (options.format) {
                params.append('type', options.format);
            }

            if (params.toString()) {
                url += (url.includes('?') ? '&' : '?') + params.toString();
            }
        }

        return url;
    }

    /**
     * Setup event listeners for stream audio
     */
    setupStreamEventListeners(audio, streamConfig) {
        audio.addEventListener('loadstart', () => {
            console.log(`Loading stream: ${streamConfig.name}`);
            this.notifyStreamEvent('loading', streamConfig);
        });

        audio.addEventListener('canplay', () => {
            console.log(`Stream ready: ${streamConfig.name}`);
            this.notifyStreamEvent('ready', streamConfig);
        });

        audio.addEventListener('playing', () => {
            console.log(`Stream playing: ${streamConfig.name}`);
            this.notifyStreamEvent('playing', streamConfig);
        });

        audio.addEventListener('pause', () => {
            console.log(`Stream paused: ${streamConfig.name}`);
            this.notifyStreamEvent('paused', streamConfig);
        });

        audio.addEventListener('error', (event) => {
            console.error(`Stream error: ${streamConfig.name}`, event);
            streamConfig.isActive = false;
            this.notifyStreamEvent('error', streamConfig, event);
        });

        audio.addEventListener('ended', () => {
            console.log(`Stream ended: ${streamConfig.name}`);
            streamConfig.isActive = false;
            this.notifyStreamEvent('ended', streamConfig);
        });

        // Monitor for metadata changes
        audio.addEventListener('durationchange', () => {
            this.updateStreamMetadata(streamConfig.id);
        });
    }

    /**
     * Integrate stream audio with main audio engine
     */
    integrateWithAudioEngine(streamId, audioElement) {
        try {
            const audioContext = window.audioEngine.audioContext;
            const source = audioContext.createMediaElementSource(audioElement);

            // Create processing chain
            const gainNode = audioContext.createGain();
            const analyserNode = audioContext.createAnalyser();

            // Configure analyser for spectrum visualization
            analyserNode.fftSize = 256;
            analyserNode.smoothingTimeConstant = 0.8;

            // Connect nodes
            source.connect(gainNode);
            gainNode.connect(analyserNode);
            analyserNode.connect(audioContext.destination);

            // Store nodes for later control
            const activeStream = this.activeStreams.get(streamId);
            if (activeStream) {
                activeStream.audioNodes = {
                    source,
                    gainNode,
                    analyserNode
                };

                // Setup real-time audio visualization
                this.setupStreamVisualization(streamId, analyserNode);
            }

            console.log(`Stream integrated with audio engine: ${streamId}`);
        } catch (error) {
            console.error('Failed to integrate stream with audio engine:', error);
        }
    }

    /**
     * Setup real-time audio visualization for stream
     */
    setupStreamVisualization(streamId, analyserNode) {
        const bufferLength = analyserNode.frequencyBinCount;
        const dataArray = new Uint8Array(bufferLength);

        const updateVisualization = () => {
            if (!this.activeStreams.has(streamId)) {
                return; // Stream stopped, exit animation loop
            }

            analyserNode.getByteFrequencyData(dataArray);

            // Emit visualization data
            this.notifyStreamVisualization(streamId, dataArray);

            requestAnimationFrame(updateVisualization);
        };

        updateVisualization();
    }

    /**
     * Stream metadata management
     */
    setupMetadataUpdater() {
        // Update metadata every 30 seconds for active streams
        this.metadataUpdateInterval = setInterval(() => {
            this.activeStreams.forEach((stream, streamId) => {
                this.updateStreamMetadata(streamId);
            });
        }, 30000);
    }

    async updateStreamMetadata(streamId) {
        const activeStream = this.activeStreams.get(streamId);
        if (!activeStream) return;

        try {
            // Try to fetch metadata from various sources
            const metadata = await this.fetchStreamMetadata(activeStream.config);

            if (metadata) {
                this.streamMetadata.set(streamId, {
                    ...metadata,
                    updatedAt: Date.now()
                });

                this.notifyStreamEvent('metadata', activeStream.config, metadata);
            }
        } catch (error) {
            console.warn(`Failed to update metadata for stream ${streamId}:`, error);
        }
    }

    async fetchStreamMetadata(streamConfig) {
        // Different metadata fetching strategies based on stream type
        switch (streamConfig.type) {
            case 'icecast':
                return this.fetchIcecastMetadata(streamConfig);
            case 'shoutcast':
                return this.fetchShoutcastMetadata(streamConfig);
            default:
                return this.fetchGenericMetadata(streamConfig);
        }
    }

    async fetchIcecastMetadata(streamConfig) {
        try {
            // Icecast usually provides metadata via status-json.xsl
            const statusUrl = streamConfig.url.replace(/\/[^\/]*$/, '/status-json.xsl');
            const response = await fetch(statusUrl);

            if (response.ok) {
                const data = await response.json();
                return {
                    title: data.icestats?.source?.title || 'Unknown',
                    artist: data.icestats?.source?.artist || 'Unknown',
                    genre: data.icestats?.source?.genre || streamConfig.genre,
                    bitrate: data.icestats?.source?.bitrate,
                    listeners: data.icestats?.source?.listeners
                };
            }
        } catch (error) {
            console.warn('Failed to fetch Icecast metadata:', error);
        }
        return null;
    }

    async fetchShoutcastMetadata(streamConfig) {
        try {
            // Shoutcast metadata can be fetched via 7.html endpoint
            const statsUrl = streamConfig.url.replace(/\/[^\/]*$/, '/7.html');
            const response = await fetch(statsUrl);

            if (response.ok) {
                const text = await response.text();
                // Parse comma-separated values from Shoutcast stats
                const values = text.split(',');

                return {
                    listeners: parseInt(values[0]) || 0,
                    title: values[6] || 'Unknown',
                    bitrate: parseInt(values[5]) || streamConfig.quality?.bitrate,
                    genre: values[9] || streamConfig.genre
                };
            }
        } catch (error) {
            console.warn('Failed to fetch Shoutcast metadata:', error);
        }
        return null;
    }

    async fetchGenericMetadata(streamConfig) {
        // For generic streams, we can only provide basic info
        return {
            title: streamConfig.name,
            artist: 'Live Stream',
            genre: streamConfig.genre,
            url: streamConfig.url
        };
    }

    /**
     * Helper methods
     */
    normalizeStreamUrl(url) {
        // Ensure protocol
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
            url = 'https://' + url;
        }
        return url;
    }

    detectStreamType(url) {
        const urlLower = url.toLowerCase();

        if (urlLower.includes('icecast') || urlLower.includes(':8000')) {
            return 'icecast';
        } else if (urlLower.includes('shoutcast') || urlLower.includes(':8080')) {
            return 'shoutcast';
        } else if (urlLower.includes('.m3u8')) {
            return 'hls';
        } else if (urlLower.includes('.pls')) {
            return 'playlist';
        }

        return 'generic';
    }

    detectStreamQuality(url) {
        // Try to detect quality from URL patterns
        const urlLower = url.toLowerCase();

        if (urlLower.includes('320') || urlLower.includes('high')) {
            return 'ultra';
        } else if (urlLower.includes('192') || urlLower.includes('hq')) {
            return 'high';
        } else if (urlLower.includes('128') || urlLower.includes('med')) {
            return 'medium';
        } else if (urlLower.includes('64') || urlLower.includes('low')) {
            return 'low';
        }

        return 'medium'; // Default
    }

    async validateStreamUrl(url) {
        try {
            // Simple HEAD request to check if URL is accessible
            const response = await fetch(url, {
                method: 'HEAD',
                mode: 'no-cors' // Avoid CORS issues for validation
            });
            return true;
        } catch (error) {
            // If HEAD fails, try a simple GET with a short timeout
            try {
                const controller = new AbortController();
                const timeoutId = setTimeout(() => controller.abort(), 5000);

                await fetch(url, {
                    signal: controller.signal,
                    mode: 'no-cors'
                });

                clearTimeout(timeoutId);
                return true;
            } catch (error) {
                throw new Error('Stream URL is not accessible');
            }
        }
    }

    generateStreamId() {
        return 'stream_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
    }

    /**
     * Storage methods
     */
    saveStreamConfigurations() {
        const configs = Object.fromEntries(this.streams);
        localStorage.setItem('voicelink_live_streams', JSON.stringify(configs));
    }

    loadStreamConfigurations() {
        try {
            const saved = localStorage.getItem('voicelink_live_streams');
            if (saved) {
                const configs = JSON.parse(saved);
                Object.entries(configs).forEach(([id, config]) => {
                    this.streams.set(id, config);
                });
            }
        } catch (error) {
            console.error('Failed to load stream configurations:', error);
        }
    }

    /**
     * Event notification methods
     */
    notifyStreamEvent(type, streamConfig, data = null) {
        const event = new CustomEvent('liveStreamEvent', {
            detail: { type, stream: streamConfig, data }
        });
        window.dispatchEvent(event);
    }

    notifyStreamVisualization(streamId, frequencyData) {
        const event = new CustomEvent('streamVisualization', {
            detail: { streamId, frequencyData }
        });
        window.dispatchEvent(event);
    }

    /**
     * Public API methods
     */
    getStreams() {
        return Array.from(this.streams.values());
    }

    getActiveStreams() {
        return Array.from(this.activeStreams.values()).map(stream => ({
            ...stream.config,
            metadata: this.streamMetadata.get(stream.config.id)
        }));
    }

    getStreamById(streamId) {
        return this.streams.get(streamId);
    }

    updateStreamVolume(streamId, volume) {
        const activeStream = this.activeStreams.get(streamId);
        if (activeStream) {
            activeStream.audio.volume = Math.max(0, Math.min(1, volume));
            if (activeStream.audioNodes) {
                activeStream.audioNodes.gainNode.gain.value = volume;
            }
        }
    }

    removeStream(streamId) {
        // Stop stream if playing
        this.stopStream(streamId);

        // Remove from configuration
        this.streams.delete(streamId);
        this.streamMetadata.delete(streamId);

        this.saveStreamConfigurations();
    }

    // Cleanup
    destroy() {
        this.stopAllStreams();

        if (this.metadataUpdateInterval) {
            clearInterval(this.metadataUpdateInterval);
        }

        this.streams.clear();
        this.activeStreams.clear();
        this.streamMetadata.clear();
    }
}

// Export for use in other modules
window.LiveStreamingManager = LiveStreamingManager;