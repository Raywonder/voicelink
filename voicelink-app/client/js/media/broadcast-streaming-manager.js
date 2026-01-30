/**
 * Broadcast Streaming Manager
 * Handles outgoing streaming to various protocols (RTMP, SRT, Icecast, etc.)
 */

class BroadcastStreamingManager {
    constructor(audioEngine) {
        this.audioEngine = audioEngine;

        // Broadcast configurations
        this.broadcastConfigs = new Map(); // configId -> BroadcastConfig
        this.activeBroadcasts = new Map(); // broadcastId -> ActiveBroadcast
        this.encoders = new Map(); // encoderId -> EncoderInstance

        // Supported broadcast protocols
        this.supportedProtocols = {
            rtmp: {
                name: 'RTMP',
                description: 'Real-Time Messaging Protocol',
                ports: [1935],
                formats: ['mp4', 'flv'],
                codecs: ['h264', 'aac']
            },
            srt: {
                name: 'SRT',
                description: 'Secure Reliable Transport',
                ports: [9998],
                formats: ['ts'],
                codecs: ['h264', 'aac'],
                features: ['low-latency', 'error-correction']
            },
            webrtc: {
                name: 'WebRTC',
                description: 'Web Real-Time Communication',
                ports: [443, 80],
                formats: ['webm'],
                codecs: ['vp8', 'vp9', 'opus'],
                features: ['p2p', 'ultra-low-latency']
            },
            hls: {
                name: 'HLS',
                description: 'HTTP Live Streaming',
                ports: [80, 443],
                formats: ['m3u8', 'ts'],
                codecs: ['h264', 'aac'],
                features: ['adaptive-bitrate', 'cdn-friendly']
            },
            icecast: {
                name: 'Icecast',
                description: 'Open source streaming server',
                ports: [8000],
                formats: ['ogg', 'mp3', 'aac'],
                codecs: ['vorbis', 'opus', 'mp3', 'aac'],
                features: ['metadata', 'multiple-mounts']
            },
            ndi: {
                name: 'NDI',
                description: 'Network Device Interface',
                ports: [5960, 5961],
                formats: ['ndi'],
                codecs: ['ndi-hx', 'ndi-hq'],
                features: ['professional', 'zero-latency', 'discovery']
            },
            whip: {
                name: 'WHIP',
                description: 'WebRTC-HTTP Ingestion Protocol',
                ports: [443],
                formats: ['webrtc'],
                codecs: ['vp8', 'vp9', 'opus'],
                features: ['webrtc-over-http', 'standardized']
            }
        };

        this.init();
    }

    init() {
        this.loadBroadcastConfigurations();
        this.initializeEncoders();
        console.log('Broadcast Streaming Manager initialized');
    }

    /**
     * Create a new broadcast configuration
     */
    createBroadcastConfig(config) {
        const {
            name,
            protocol,
            server,
            port,
            streamKey,
            username,
            password,
            quality,
            description
        } = config;

        if (!name || !protocol || !server) {
            throw new Error('Name, protocol, and server are required');
        }

        if (!this.supportedProtocols[protocol]) {
            throw new Error(`Unsupported protocol: ${protocol}`);
        }

        const configId = this.generateConfigId();
        const broadcastConfig = {
            id: configId,
            name,
            protocol,
            server,
            port: port || this.supportedProtocols[protocol].ports[0],
            streamKey: streamKey || '',
            username: username || '',
            password: password || '',
            quality: quality || 'medium',
            description: description || '',
            createdAt: Date.now(),
            enabled: true,
            autoStart: false
        };

        this.broadcastConfigs.set(configId, broadcastConfig);
        this.saveBroadcastConfigurations();

        console.log(`Created broadcast config: ${name} (${protocol})`);
        return broadcastConfig;
    }

    /**
     * Start broadcasting to a configured endpoint
     */
    async startBroadcast(configId, options = {}) {
        const config = this.broadcastConfigs.get(configId);
        if (!config) {
            throw new Error('Broadcast configuration not found');
        }

        if (this.activeBroadcasts.has(configId)) {
            throw new Error('Broadcast already active');
        }

        try {
            const broadcastId = `${configId}_${Date.now()}`;

            // Create encoder for this broadcast
            const encoder = await this.createEncoder(config, options);

            // Create broadcast instance
            const broadcast = {
                id: broadcastId,
                configId,
                config,
                encoder,
                startTime: Date.now(),
                status: 'starting',
                stats: {
                    bytesTransmitted: 0,
                    framesEncoded: 0,
                    droppedFrames: 0,
                    bitrate: 0,
                    uptime: 0
                }
            };

            this.activeBroadcasts.set(configId, broadcast);

            // Connect to audio source
            await this.connectAudioSource(broadcast);

            // Start the actual streaming
            await this.startStreaming(broadcast);

            broadcast.status = 'active';

            console.log(`Started broadcast: ${config.name} (${config.protocol})`);
            this.notifyBroadcastEvent('started', broadcast);

            return broadcast;

        } catch (error) {
            console.error('Failed to start broadcast:', error);
            this.activeBroadcasts.delete(configId);
            throw error;
        }
    }

    /**
     * Stop an active broadcast
     */
    async stopBroadcast(configId) {
        const broadcast = this.activeBroadcasts.get(configId);
        if (!broadcast) {
            return false;
        }

        try {
            broadcast.status = 'stopping';

            // Disconnect audio source
            if (broadcast.audioSource) {
                broadcast.audioSource.disconnect();
            }

            // Stop encoder
            if (broadcast.encoder) {
                await this.stopEncoder(broadcast.encoder);
            }

            // Close streaming connection
            if (broadcast.stream) {
                broadcast.stream.close();
            }

            this.activeBroadcasts.delete(configId);

            console.log(`Stopped broadcast: ${broadcast.config.name}`);
            this.notifyBroadcastEvent('stopped', broadcast);

            return true;

        } catch (error) {
            console.error('Error stopping broadcast:', error);
            return false;
        }
    }

    /**
     * Create an encoder for the broadcast protocol
     */
    async createEncoder(config, options) {
        const protocol = this.supportedProtocols[config.protocol];
        const encoderId = `${config.protocol}_${Date.now()}`;

        let encoder;

        switch (config.protocol) {
            case 'rtmp':
                encoder = await this.createRTMPEncoder(config, options);
                break;
            case 'srt':
                encoder = await this.createSRTEncoder(config, options);
                break;
            case 'webrtc':
                encoder = await this.createWebRTCEncoder(config, options);
                break;
            case 'hls':
                encoder = await this.createHLSEncoder(config, options);
                break;
            case 'icecast':
                encoder = await this.createIcecastEncoder(config, options);
                break;
            case 'ndi':
                encoder = await this.createNDIEncoder(config, options);
                break;
            case 'whip':
                encoder = await this.createWHIPEncoder(config, options);
                break;
            default:
                throw new Error(`No encoder available for protocol: ${config.protocol}`);
        }

        encoder.id = encoderId;
        this.encoders.set(encoderId, encoder);

        return encoder;
    }

    /**
     * Protocol-specific encoder implementations
     */
    async createRTMPEncoder(config, options) {
        // RTMP encoder using WebRTC to RTMP gateway or FFmpeg-like approach
        const encoder = {
            type: 'rtmp',
            config,
            connection: null,
            stream: null
        };

        // For web-based RTMP, we'd need a WebRTC to RTMP bridge service
        const rtmpUrl = `rtmp://${config.server}:${config.port}/live/${config.streamKey}`;
        console.log(`RTMP Encoder configured for: ${rtmpUrl}`);

        return encoder;
    }

    async createSRTEncoder(config, options) {
        // SRT encoder for low-latency streaming
        const encoder = {
            type: 'srt',
            config,
            connection: null,
            latency: options.latency || 200 // milliseconds
        };

        const srtUrl = `srt://${config.server}:${config.port}`;
        console.log(`SRT Encoder configured for: ${srtUrl}`);

        return encoder;
    }

    async createWebRTCEncoder(config, options) {
        // WebRTC encoder for peer-to-peer or WHEP
        const encoder = {
            type: 'webrtc',
            config,
            peerConnection: null,
            dataChannel: null
        };

        // Create RTCPeerConnection
        encoder.peerConnection = new RTCPeerConnection({
            iceServers: [
                { urls: 'stun:stun.l.google.com:19302' }
            ]
        });

        console.log('WebRTC Encoder configured');
        return encoder;
    }

    async createHLSEncoder(config, options) {
        // HLS encoder for adaptive streaming
        const encoder = {
            type: 'hls',
            config,
            segments: [],
            segmentDuration: options.segmentDuration || 6,
            playlist: null
        };

        console.log(`HLS Encoder configured for: ${config.server}`);
        return encoder;
    }

    async createIcecastEncoder(config, options) {
        // Icecast encoder for open-source streaming
        const encoder = {
            type: 'icecast',
            config,
            connection: null,
            metadata: {
                title: '',
                artist: '',
                album: ''
            }
        };

        const icecastUrl = `http://${config.server}:${config.port}/${config.streamKey || 'stream'}`;
        console.log(`Icecast Encoder configured for: ${icecastUrl}`);

        return encoder;
    }

    async createNDIEncoder(config, options) {
        // NDI encoder for professional video over IP
        const encoder = {
            type: 'ndi',
            config,
            source: null,
            quality: options.quality || 'high'
        };

        console.log(`NDI Encoder configured: ${config.name}`);
        return encoder;
    }

    async createWHIPEncoder(config, options) {
        // WHIP encoder (WebRTC-HTTP Ingestion Protocol)
        const encoder = {
            type: 'whip',
            config,
            peerConnection: null,
            httpEndpoint: `https://${config.server}/whip`
        };

        encoder.peerConnection = new RTCPeerConnection({
            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
        });

        console.log(`WHIP Encoder configured for: ${encoder.httpEndpoint}`);
        return encoder;
    }

    /**
     * Connect audio source to broadcast
     */
    async connectAudioSource(broadcast) {
        if (!this.audioEngine || !this.audioEngine.audioContext) {
            throw new Error('Audio engine not available');
        }

        const audioContext = this.audioEngine.audioContext;

        // Create audio processing chain
        const source = audioContext.createGain();
        const compressor = audioContext.createDynamicsCompressor();
        const limiter = audioContext.createGain();

        // Configure audio processing
        compressor.threshold.value = -24;
        compressor.knee.value = 30;
        compressor.ratio.value = 4;
        compressor.attack.value = 0.003;
        compressor.release.value = 0.25;

        // Connect processing chain
        source.connect(compressor);
        compressor.connect(limiter);

        // Connect to main audio output
        if (this.audioEngine.outputNode) {
            this.audioEngine.outputNode.connect(source);
        }

        broadcast.audioSource = source;
        broadcast.audioProcessor = compressor;

        console.log('Audio source connected to broadcast');
    }

    /**
     * Start the actual streaming process
     */
    async startStreaming(broadcast) {
        const { encoder, config } = broadcast;

        switch (encoder.type) {
            case 'webrtc':
                await this.startWebRTCStreaming(broadcast);
                break;
            case 'hls':
                await this.startHLSStreaming(broadcast);
                break;
            case 'icecast':
                await this.startIcecastStreaming(broadcast);
                break;
            default:
                console.warn(`Streaming not implemented for ${encoder.type}`);
        }
    }

    async startWebRTCStreaming(broadcast) {
        const { encoder } = broadcast;
        const pc = encoder.peerConnection;

        // Add audio track
        if (broadcast.audioSource) {
            const destination = this.audioEngine.audioContext.createMediaStreamDestination();
            broadcast.audioSource.connect(destination);

            destination.stream.getTracks().forEach(track => {
                pc.addTrack(track, destination.stream);
            });
        }

        // Create offer
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);

        console.log('WebRTC streaming started');
    }

    async startHLSStreaming(broadcast) {
        const { encoder } = broadcast;

        // Start HLS segment generation
        broadcast.hlsInterval = setInterval(() => {
            this.generateHLSSegment(broadcast);
        }, encoder.segmentDuration * 1000);

        console.log('HLS streaming started');
    }

    async startIcecastStreaming(broadcast) {
        const { encoder, config } = broadcast;

        // Connect to Icecast server
        try {
            const ws = new WebSocket(`ws://${config.server}:${config.port + 1}/stream`);

            ws.onopen = () => {
                console.log('Connected to Icecast server');
                encoder.connection = ws;
            };

            ws.onerror = (error) => {
                console.error('Icecast connection error:', error);
            };

        } catch (error) {
            console.error('Failed to connect to Icecast:', error);
        }
    }

    /**
     * Stop encoder
     */
    async stopEncoder(encoder) {
        switch (encoder.type) {
            case 'webrtc':
                if (encoder.peerConnection) {
                    encoder.peerConnection.close();
                }
                break;
            case 'hls':
                if (encoder.hlsInterval) {
                    clearInterval(encoder.hlsInterval);
                }
                break;
            case 'icecast':
                if (encoder.connection) {
                    encoder.connection.close();
                }
                break;
        }

        this.encoders.delete(encoder.id);
    }

    /**
     * Configuration management
     */
    saveBroadcastConfigurations() {
        const configs = Object.fromEntries(this.broadcastConfigs);
        localStorage.setItem('voicelink_broadcast_configs', JSON.stringify(configs));
    }

    loadBroadcastConfigurations() {
        try {
            const saved = localStorage.getItem('voicelink_broadcast_configs');
            if (saved) {
                const configs = JSON.parse(saved);
                Object.entries(configs).forEach(([id, config]) => {
                    this.broadcastConfigs.set(id, config);
                });
            }
        } catch (error) {
            console.error('Failed to load broadcast configurations:', error);
        }
    }

    /**
     * Utility methods
     */
    generateConfigId() {
        return 'broadcast_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
    }

    initializeEncoders() {
        console.log('Encoders initialized');
    }

    notifyBroadcastEvent(type, broadcast) {
        const event = new CustomEvent('broadcastEvent', {
            detail: { type, broadcast }
        });
        window.dispatchEvent(event);
    }

    /**
     * Public API
     */
    getBroadcastConfigs() {
        return Array.from(this.broadcastConfigs.values());
    }

    getActiveBroadcasts() {
        return Array.from(this.activeBroadcasts.values());
    }

    getSupportedProtocols() {
        return this.supportedProtocols;
    }

    removeBroadcastConfig(configId) {
        // Stop broadcast if active
        if (this.activeBroadcasts.has(configId)) {
            this.stopBroadcast(configId);
        }

        this.broadcastConfigs.delete(configId);
        this.saveBroadcastConfigurations();
    }

    // Cleanup
    destroy() {
        // Stop all active broadcasts
        Array.from(this.activeBroadcasts.keys()).forEach(configId => {
            this.stopBroadcast(configId);
        });

        this.broadcastConfigs.clear();
        this.activeBroadcasts.clear();
        this.encoders.clear();
    }
}

// Export for use in other modules
window.BroadcastStreamingManager = BroadcastStreamingManager;