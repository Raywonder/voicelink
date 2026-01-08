/**
 * VoiceLink VST Streaming Engine
 * Real-time VST plugin streaming and processing
 */

class VSTStreamingEngine {
    constructor(audioContext, multiChannelEngine) {
        this.audioContext = audioContext;
        this.multiChannelEngine = multiChannelEngine;

        // VST Plugin Management
        this.vstPlugins = new Map(); // pluginId -> VSTPlugin
        this.userVSTChains = new Map(); // userId -> [pluginIds]
        this.vstStreams = new Map(); // streamId -> VSTStream

        // VST Plugin Library
        this.pluginLibrary = new Map(); // pluginName -> PluginDefinition
        this.pluginPresets = new Map(); // pluginId -> [presets]

        // Real-time processing
        this.processingNodes = new Map(); // pluginId -> AudioWorkletNode
        this.vstWorklets = new Map(); // workletName -> WorkletModule

        // Streaming configuration
        this.streamConfig = {
            sampleRate: 48000,
            bufferSize: 256, // Low latency
            bitDepth: 32,
            compression: 'lossless', // 'lossless' or 'lossy'
            latencyCompensation: true
        };

        this.init();
    }

    async init() {
        console.log('Initializing VST Streaming Engine...');

        // Load VST emulation worklets
        await this.loadVSTWorklets();

        // Initialize built-in VST plugins
        this.initializeBuiltInPlugins();

        // Setup streaming infrastructure
        this.setupStreamingInfrastructure();

        console.log('VST Streaming Engine initialized');
    }

    async loadVSTWorklets() {
        const worklets = [
            'reverb-vst-worklet.js',
            'compressor-vst-worklet.js',
            'eq-vst-worklet.js',
            'delay-vst-worklet.js',
            'chorus-vst-worklet.js',
            'distortion-vst-worklet.js',
            'pitch-shifter-vst-worklet.js',
            'vocoder-vst-worklet.js'
        ];

        for (const worklet of worklets) {
            try {
                // In a real implementation, these would be actual worklet files
                await this.createVSTWorklet(worklet);
                console.log(`Loaded VST worklet: ${worklet}`);
            } catch (error) {
                console.warn(`Failed to load VST worklet ${worklet}:`, error);
            }
        }
    }

    async createVSTWorklet(workletName) {
        // Create worklet code dynamically (in practice, these would be separate files)
        const workletCode = this.generateVSTWorkletCode(workletName);

        // Create blob URL for worklet
        const blob = new Blob([workletCode], { type: 'application/javascript' });
        const workletUrl = URL.createObjectURL(blob);

        // Load worklet
        await this.audioContext.audioWorklet.addModule(workletUrl);
        this.vstWorklets.set(workletName, workletUrl);

        // Clean up blob URL
        URL.revokeObjectURL(workletUrl);
    }

    generateVSTWorkletCode(workletName) {
        const baseName = workletName.replace('-vst-worklet.js', '');

        return `
            class ${baseName.charAt(0).toUpperCase() + baseName.slice(1)}VSTProcessor extends AudioWorkletProcessor {
                constructor(options) {
                    super();

                    this.parameters = options.processorOptions.parameters || {};
                    this.presets = options.processorOptions.presets || {};
                    this.vstType = '${baseName}';

                    // Initialize DSP state
                    this.initializeDSP();

                    // Handle parameter changes
                    this.port.onmessage = (event) => {
                        this.handleMessage(event.data);
                    };
                }

                initializeDSP() {
                    // DSP initialization specific to each VST type
                    switch(this.vstType) {
                        case 'reverb':
                            this.initializeReverb();
                            break;
                        case 'compressor':
                            this.initializeCompressor();
                            break;
                        case 'eq':
                            this.initializeEQ();
                            break;
                        case 'delay':
                            this.initializeDelay();
                            break;
                        case 'chorus':
                            this.initializeChorus();
                            break;
                        case 'distortion':
                            this.initializeDistortion();
                            break;
                        case 'pitch-shifter':
                            this.initializePitchShifter();
                            break;
                        case 'vocoder':
                            this.initializeVocoder();
                            break;
                    }
                }

                initializeReverb() {
                    this.delayLines = [];
                    this.allpassFilters = [];
                    this.dampingFilters = [];

                    // Create Schroeder reverb structure
                    const delayLengths = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116];
                    delayLengths.forEach(length => {
                        this.delayLines.push(new Float32Array(length).fill(0));
                    });

                    this.delayIndices = new Array(delayLengths.length).fill(0);
                    this.feedback = 0.5;
                    this.damping = 0.2;
                    this.wetLevel = 0.3;
                }

                initializeCompressor() {
                    this.threshold = -20; // dB
                    this.ratio = 4.0;
                    this.attack = 0.003; // seconds
                    this.release = 0.1; // seconds
                    this.makeupGain = 0; // dB

                    this.envelope = 0;
                    this.gainReduction = 0;
                }

                initializeEQ() {
                    this.bands = [
                        { freq: 80, gain: 0, q: 0.7, type: 'highpass' },
                        { freq: 200, gain: 0, q: 1.0, type: 'peaking' },
                        { freq: 1000, gain: 0, q: 1.0, type: 'peaking' },
                        { freq: 5000, gain: 0, q: 1.0, type: 'peaking' },
                        { freq: 12000, gain: 0, q: 0.7, type: 'lowpass' }
                    ];

                    // Initialize biquad filter coefficients
                    this.filters = this.bands.map(() => ({
                        b0: 1, b1: 0, b2: 0,
                        a1: 0, a2: 0,
                        x1: 0, x2: 0,
                        y1: 0, y2: 0
                    }));
                }

                initializeDelay() {
                    this.maxDelayTime = 2.0; // seconds
                    this.delayBuffer = new Float32Array(sampleRate * this.maxDelayTime);
                    this.writeIndex = 0;
                    this.delayTime = 0.25; // seconds
                    this.feedback = 0.3;
                    this.wetLevel = 0.3;
                }

                initializeChorus() {
                    this.delayBuffer = new Float32Array(sampleRate * 0.05); // 50ms max delay
                    this.writeIndex = 0;
                    this.lfoPhase = 0;
                    this.lfoRate = 2.0; // Hz
                    this.depth = 0.005; // seconds
                    this.wetLevel = 0.5;
                }

                initializeDistortion() {
                    this.drive = 5.0;
                    this.tone = 0.5;
                    this.level = 0.5;
                    this.type = 'overdrive'; // 'overdrive', 'fuzz', 'bitcrush'
                }

                initializePitchShifter() {
                    this.pitchRatio = 1.0; // 1.0 = no change, 2.0 = octave up, 0.5 = octave down
                    this.windowSize = 2048;
                    this.overlapFactor = 4;
                    this.hopSize = this.windowSize / this.overlapFactor;

                    this.inputBuffer = new Float32Array(this.windowSize * 2);
                    this.outputBuffer = new Float32Array(this.windowSize * 2);
                    this.window = this.createHannWindow(this.windowSize);
                }

                initializeVocoder() {
                    this.carrierBuffer = new Float32Array(1024);
                    this.modulatorBuffer = new Float32Array(1024);
                    this.bands = 16;
                    this.envelopes = new Array(this.bands).fill(0);
                    this.filters = [];

                    // Create filter bank
                    for (let i = 0; i < this.bands; i++) {
                        const freq = 100 * Math.pow(2, i * 8 / this.bands);
                        this.filters.push(this.createBandpassFilter(freq));
                    }
                }

                process(inputs, outputs, parameters) {
                    const input = inputs[0];
                    const output = outputs[0];

                    if (input.length === 0) return true;

                    const inputChannel = input[0];
                    const outputChannel = output[0];

                    // Process audio based on VST type
                    switch(this.vstType) {
                        case 'reverb':
                            this.processReverb(inputChannel, outputChannel);
                            break;
                        case 'compressor':
                            this.processCompressor(inputChannel, outputChannel);
                            break;
                        case 'eq':
                            this.processEQ(inputChannel, outputChannel);
                            break;
                        case 'delay':
                            this.processDelay(inputChannel, outputChannel);
                            break;
                        case 'chorus':
                            this.processChorus(inputChannel, outputChannel);
                            break;
                        case 'distortion':
                            this.processDistortion(inputChannel, outputChannel);
                            break;
                        case 'pitch-shifter':
                            this.processPitchShifter(inputChannel, outputChannel);
                            break;
                        case 'vocoder':
                            this.processVocoder(inputChannel, outputChannel);
                            break;
                        default:
                            // Bypass
                            outputChannel.set(inputChannel);
                    }

                    return true;
                }

                processReverb(input, output) {
                    for (let i = 0; i < input.length; i++) {
                        let reverbSample = 0;

                        // Process through delay lines
                        this.delayLines.forEach((delayLine, index) => {
                            const delayIndex = this.delayIndices[index];
                            const delaySample = delayLine[delayIndex];

                            // Add feedback
                            delayLine[delayIndex] = input[i] + (delaySample * this.feedback);

                            reverbSample += delaySample;

                            // Advance delay index
                            this.delayIndices[index] = (delayIndex + 1) % delayLine.length;
                        });

                        // Mix dry and wet
                        output[i] = input[i] + (reverbSample * this.wetLevel);
                    }
                }

                processCompressor(input, output) {
                    const attackCoeff = Math.exp(-1 / (this.attack * sampleRate));
                    const releaseCoeff = Math.exp(-1 / (this.release * sampleRate));

                    for (let i = 0; i < input.length; i++) {
                        const inputLevel = Math.abs(input[i]);
                        const inputLevelDb = 20 * Math.log10(inputLevel + 1e-10);

                        // Calculate gain reduction
                        let gainReductionDb = 0;
                        if (inputLevelDb > this.threshold) {
                            const overThreshold = inputLevelDb - this.threshold;
                            gainReductionDb = overThreshold * (1 - 1/this.ratio);
                        }

                        // Smooth gain reduction
                        const targetGainReduction = Math.pow(10, -gainReductionDb / 20);
                        if (targetGainReduction < this.gainReduction) {
                            this.gainReduction += (targetGainReduction - this.gainReduction) * (1 - attackCoeff);
                        } else {
                            this.gainReduction += (targetGainReduction - this.gainReduction) * (1 - releaseCoeff);
                        }

                        // Apply compression and makeup gain
                        const makeupGainLinear = Math.pow(10, this.makeupGain / 20);
                        output[i] = input[i] * this.gainReduction * makeupGainLinear;
                    }
                }

                handleMessage(data) {
                    switch(data.type) {
                        case 'parameter':
                            this.updateParameter(data.name, data.value);
                            break;
                        case 'preset':
                            this.loadPreset(data.preset);
                            break;
                        case 'bypass':
                            this.bypassed = data.bypassed;
                            break;
                    }
                }

                updateParameter(name, value) {
                    this.parameters[name] = value;

                    // Update internal state based on parameter
                    switch(name) {
                        case 'wetLevel':
                            this.wetLevel = value;
                            break;
                        case 'feedback':
                            this.feedback = value;
                            break;
                        case 'threshold':
                            this.threshold = value;
                            break;
                        case 'ratio':
                            this.ratio = value;
                            break;
                        // Add more parameters as needed
                    }

                    // Send parameter change confirmation
                    this.port.postMessage({
                        type: 'parameterChanged',
                        name: name,
                        value: value
                    });
                }
            }

            registerProcessor('${baseName}-vst', ${baseName.charAt(0).toUpperCase() + baseName.slice(1)}VSTProcessor);
        `;
    }

    initializeBuiltInPlugins() {
        // Define built-in VST plugins
        const builtInPlugins = [
            {
                name: 'ReverbPlus',
                type: 'reverb',
                category: 'spatial',
                parameters: {
                    roomSize: { min: 0, max: 1, default: 0.5 },
                    damping: { min: 0, max: 1, default: 0.2 },
                    wetLevel: { min: 0, max: 1, default: 0.3 },
                    earlyReflections: { min: 0, max: 1, default: 0.4 }
                }
            },
            {
                name: 'CompressorPro',
                type: 'compressor',
                category: 'dynamics',
                parameters: {
                    threshold: { min: -60, max: 0, default: -20 },
                    ratio: { min: 1, max: 20, default: 4 },
                    attack: { min: 0.001, max: 0.1, default: 0.003 },
                    release: { min: 0.01, max: 1, default: 0.1 },
                    makeupGain: { min: -20, max: 20, default: 0 }
                }
            },
            {
                name: 'EQMaster',
                type: 'eq',
                category: 'filter',
                parameters: {
                    lowGain: { min: -15, max: 15, default: 0 },
                    lowMidGain: { min: -15, max: 15, default: 0 },
                    midGain: { min: -15, max: 15, default: 0 },
                    highMidGain: { min: -15, max: 15, default: 0 },
                    highGain: { min: -15, max: 15, default: 0 }
                }
            },
            {
                name: 'DelayFX',
                type: 'delay',
                category: 'modulation',
                parameters: {
                    delayTime: { min: 0.001, max: 2, default: 0.25 },
                    feedback: { min: 0, max: 0.95, default: 0.3 },
                    wetLevel: { min: 0, max: 1, default: 0.3 },
                    pingPong: { min: 0, max: 1, default: 0 }
                }
            },
            {
                name: 'ChorusWave',
                type: 'chorus',
                category: 'modulation',
                parameters: {
                    rate: { min: 0.1, max: 10, default: 2 },
                    depth: { min: 0, max: 0.02, default: 0.005 },
                    wetLevel: { min: 0, max: 1, default: 0.5 },
                    voices: { min: 1, max: 4, default: 2 }
                }
            },
            {
                name: 'DistortionDrive',
                type: 'distortion',
                category: 'saturation',
                parameters: {
                    drive: { min: 1, max: 20, default: 5 },
                    tone: { min: 0, max: 1, default: 0.5 },
                    level: { min: 0, max: 2, default: 0.5 },
                    type: { options: ['overdrive', 'fuzz', 'bitcrush'], default: 'overdrive' }
                }
            },
            {
                name: 'PitchShifter',
                type: 'pitch-shifter',
                category: 'pitch',
                parameters: {
                    pitchShift: { min: -24, max: 24, default: 0 }, // semitones
                    formantCorrection: { min: 0, max: 1, default: 1 },
                    wetLevel: { min: 0, max: 1, default: 1 }
                }
            },
            {
                name: 'VocoderFX',
                type: 'vocoder',
                category: 'creative',
                parameters: {
                    bands: { min: 8, max: 32, default: 16 },
                    carrierType: { options: ['sawtooth', 'square', 'noise'], default: 'sawtooth' },
                    attack: { min: 0.001, max: 0.1, default: 0.01 },
                    release: { min: 0.01, max: 1, default: 0.1 }
                }
            }
        ];

        builtInPlugins.forEach(plugin => {
            this.pluginLibrary.set(plugin.name, plugin);
        });

        console.log(`Loaded ${builtInPlugins.length} built-in VST plugins`);
    }

    setupStreamingInfrastructure() {
        // VST streaming infrastructure
        this.streamingBuffer = new Map(); // streamId -> CircularBuffer
        this.compressionWorkers = [];
        this.latencyBuffer = new Map(); // userId -> LatencyCompensationBuffer

        // Initialize compression workers
        for (let i = 0; i < 4; i++) {
            const worker = new Worker(this.createCompressionWorker());
            this.compressionWorkers.push(worker);
        }
    }

    createCompressionWorker() {
        // Create compression worker for real-time audio streaming
        const workerCode = `
            // Audio compression worker
            self.onmessage = function(e) {
                const { type, data } = e.data;

                switch(type) {
                    case 'compress':
                        const compressed = compressAudio(data.audioData, data.quality);
                        self.postMessage({
                            type: 'compressed',
                            streamId: data.streamId,
                            data: compressed
                        });
                        break;

                    case 'decompress':
                        const decompressed = decompressAudio(data.compressedData);
                        self.postMessage({
                            type: 'decompressed',
                            streamId: data.streamId,
                            data: decompressed
                        });
                        break;
                }
            };

            function compressAudio(audioData, quality) {
                // Implement audio compression (e.g., FLAC-like lossless or lossy)
                // For now, return raw data (would implement actual compression)
                return {
                    format: 'raw',
                    sampleRate: 48000,
                    channels: 1,
                    data: audioData
                };
            }

            function decompressAudio(compressedData) {
                // Implement audio decompression
                return compressedData.data;
            }
        `;

        const blob = new Blob([workerCode], { type: 'application/javascript' });
        return URL.createObjectURL(blob);
    }

    // VST Plugin Instance Management
    async createVSTInstance(pluginName, userId, channelId) {
        const pluginDefinition = this.pluginLibrary.get(pluginName);
        if (!pluginDefinition) {
            throw new Error(`VST plugin ${pluginName} not found`);
        }

        const vstId = `${userId}_${pluginName}_${Date.now()}`;

        try {
            // Create AudioWorkletNode for VST processing
            const vstNode = new AudioWorkletNode(this.audioContext, `${pluginDefinition.type}-vst`, {
                processorOptions: {
                    parameters: pluginDefinition.parameters,
                    presets: this.pluginPresets.get(pluginName) || []
                }
            });

            const vstInstance = {
                id: vstId,
                name: pluginName,
                type: pluginDefinition.type,
                userId,
                channelId,
                node: vstNode,
                parameters: { ...pluginDefinition.parameters },
                bypassed: false,
                streaming: false,
                streamTargets: new Set() // userIds receiving this VST stream
            };

            // Setup parameter change handling
            vstNode.port.onmessage = (event) => {
                this.handleVSTMessage(vstId, event.data);
            };

            this.vstPlugins.set(vstId, vstInstance);

            // Connect to user's audio chain
            this.connectVSTToChannel(vstInstance, channelId);

            console.log(`Created VST instance: ${pluginName} for user ${userId}`);
            return vstInstance;

        } catch (error) {
            console.error('Failed to create VST instance:', error);
            throw error;
        }
    }

    connectVSTToChannel(vstInstance, channelId) {
        // Connect VST to the specified audio channel
        const inputChannel = this.multiChannelEngine.inputChannels.get(channelId);
        const outputChannel = this.multiChannelEngine.outputChannels.get(channelId);

        if (inputChannel && outputChannel) {
            // Insert VST into the audio chain
            inputChannel.node.disconnect();
            inputChannel.node.connect(vstInstance.node);
            vstInstance.node.connect(outputChannel.node);

            vstInstance.connectedChannel = channelId;
        }
    }

    // VST Streaming Methods
    startVSTStreaming(vstId, targetUserIds) {
        const vstInstance = this.vstPlugins.get(vstId);
        if (!vstInstance) return false;

        vstInstance.streaming = true;
        vstInstance.streamTargets = new Set(targetUserIds);

        // Create stream buffer
        const streamId = `vst_${vstId}_${Date.now()}`;
        this.vstStreams.set(streamId, {
            vstId,
            targetUsers: new Set(targetUserIds),
            buffer: new CircularBuffer(this.streamConfig.bufferSize * 10),
            active: true
        });

        // Setup real-time capture from VST output
        this.setupVSTCapture(vstInstance, streamId);

        // Notify target users
        this.notifyVSTStreamStart(streamId, vstInstance, targetUserIds);

        console.log(`Started VST streaming: ${vstInstance.name} to ${targetUserIds.length} users`);
        return streamId;
    }

    setupVSTCapture(vstInstance, streamId) {
        // Create a media stream destination to capture VST output
        const destination = this.audioContext.createMediaStreamDestination();
        vstInstance.node.connect(destination);

        // Setup recorder for streaming
        const mediaRecorder = new MediaRecorder(destination.stream, {
            mimeType: 'audio/webm;codecs=opus',
            audioBitsPerSecond: 320000 // High quality for VST streaming
        });

        const vstStream = this.vstStreams.get(streamId);

        mediaRecorder.ondataavailable = (event) => {
            if (event.data.size > 0 && vstStream.active) {
                // Process and stream VST audio data
                this.processVSTStreamData(streamId, event.data);
            }
        };

        mediaRecorder.start(this.streamConfig.bufferSize / this.audioContext.sampleRate * 1000);
        vstStream.recorder = mediaRecorder;
    }

    async processVSTStreamData(streamId, audioData) {
        const vstStream = this.vstStreams.get(streamId);
        if (!vstStream) return;

        try {
            // Convert to array buffer
            const arrayBuffer = await audioData.arrayBuffer();
            const audioBuffer = await this.audioContext.decodeAudioData(arrayBuffer);

            // Get audio samples
            const samples = audioBuffer.getChannelData(0);

            // Compress if needed
            if (this.streamConfig.compression === 'lossy') {
                const worker = this.compressionWorkers[streamId.charCodeAt(0) % this.compressionWorkers.length];
                worker.postMessage({
                    type: 'compress',
                    data: {
                        streamId,
                        audioData: samples,
                        quality: 0.8
                    }
                });
            } else {
                // Send raw data for lossless
                this.broadcastVSTStream(streamId, samples);
            }

        } catch (error) {
            console.error('Failed to process VST stream data:', error);
        }
    }

    broadcastVSTStream(streamId, audioData) {
        const vstStream = this.vstStreams.get(streamId);
        if (!vstStream) return;

        const streamPacket = {
            type: 'vst_stream',
            streamId,
            audioData: Array.from(audioData), // Convert Float32Array to Array for JSON
            timestamp: this.audioContext.currentTime,
            sampleRate: this.audioContext.sampleRate
        };

        // Send to target users via WebRTC or Socket.IO
        vstStream.targetUsers.forEach(userId => {
            this.sendVSTStreamToUser(userId, streamPacket);
        });
    }

    sendVSTStreamToUser(userId, streamPacket) {
        // Send VST stream data to specific user
        if (window.voiceLinkApp && window.voiceLinkApp.socket) {
            window.voiceLinkApp.socket.emit('vst_stream_data', {
                targetUserId: userId,
                streamData: streamPacket
            });
        }
    }

    stopVSTStreaming(streamId) {
        const vstStream = this.vstStreams.get(streamId);
        if (vstStream) {
            vstStream.active = false;
            if (vstStream.recorder) {
                vstStream.recorder.stop();
            }

            // Notify users of stream end
            vstStream.targetUsers.forEach(userId => {
                this.notifyVSTStreamEnd(streamId, userId);
            });

            this.vstStreams.delete(streamId);
            console.log(`Stopped VST streaming: ${streamId}`);
        }
    }

    // VST Stream Receiving
    handleIncomingVSTStream(streamData) {
        const { streamId, audioData, timestamp, sampleRate } = streamData;

        try {
            // Convert array back to Float32Array
            const samples = new Float32Array(audioData);

            // Create audio buffer
            const audioBuffer = this.audioContext.createBuffer(1, samples.length, sampleRate);
            audioBuffer.copyToChannel(samples, 0);

            // Apply latency compensation
            this.applyLatencyCompensation(streamId, audioBuffer, timestamp);

            // Play received VST stream
            this.playVSTStream(streamId, audioBuffer);

        } catch (error) {
            console.error('Failed to handle incoming VST stream:', error);
        }
    }

    applyLatencyCompensation(streamId, audioBuffer, originalTimestamp) {
        const currentTime = this.audioContext.currentTime;
        const latency = currentTime - originalTimestamp;

        // Adjust playback timing based on latency
        const compensationDelay = Math.max(0, 0.05 - latency); // Target 50ms total latency

        let compensationBuffer = this.latencyBuffer.get(streamId);
        if (!compensationBuffer) {
            compensationBuffer = new DelayBuffer(this.audioContext, 0.1); // 100ms max compensation
            this.latencyBuffer.set(streamId, compensationBuffer);
        }

        compensationBuffer.setDelay(compensationDelay);
        return compensationBuffer.process(audioBuffer);
    }

    playVSTStream(streamId, audioBuffer) {
        // Create buffer source to play VST stream
        const source = this.audioContext.createBufferSource();
        source.buffer = audioBuffer;

        // Connect to appropriate output channel
        const vstStream = this.vstStreams.get(streamId);
        if (vstStream) {
            // Route to designated output channels
            source.connect(this.audioContext.destination);
        }

        source.start();
    }

    // VST Parameter Control
    setVSTParameter(vstId, parameterName, value) {
        const vstInstance = this.vstPlugins.get(vstId);
        if (vstInstance) {
            vstInstance.node.port.postMessage({
                type: 'parameter',
                name: parameterName,
                value: value
            });

            vstInstance.parameters[parameterName] = value;

            // If streaming, notify remote users of parameter change
            if (vstInstance.streaming) {
                this.broadcastVSTParameterChange(vstId, parameterName, value);
            }
        }
    }

    broadcastVSTParameterChange(vstId, parameterName, value) {
        const vstInstance = this.vstPlugins.get(vstId);
        if (vstInstance && vstInstance.streaming) {
            const parameterChange = {
                type: 'vst_parameter_change',
                vstId,
                parameter: parameterName,
                value,
                timestamp: this.audioContext.currentTime
            };

            vstInstance.streamTargets.forEach(userId => {
                this.sendVSTParameterChange(userId, parameterChange);
            });
        }
    }

    sendVSTParameterChange(userId, parameterChange) {
        if (window.voiceLinkApp && window.voiceLinkApp.socket) {
            window.voiceLinkApp.socket.emit('vst_parameter_change', {
                targetUserId: userId,
                parameterData: parameterChange
            });
        }
    }

    // VST Preset Management
    saveVSTPreset(vstId, presetName) {
        const vstInstance = this.vstPlugins.get(vstId);
        if (vstInstance) {
            const preset = {
                name: presetName,
                plugin: vstInstance.name,
                parameters: { ...vstInstance.parameters },
                timestamp: Date.now()
            };

            let presets = this.pluginPresets.get(vstInstance.name) || [];
            presets.push(preset);
            this.pluginPresets.set(vstInstance.name, presets);

            console.log(`Saved VST preset: ${presetName} for ${vstInstance.name}`);
            return preset;
        }
    }

    loadVSTPreset(vstId, presetName) {
        const vstInstance = this.vstPlugins.get(vstId);
        if (vstInstance) {
            const presets = this.pluginPresets.get(vstInstance.name) || [];
            const preset = presets.find(p => p.name === presetName);

            if (preset) {
                Object.keys(preset.parameters).forEach(paramName => {
                    this.setVSTParameter(vstId, paramName, preset.parameters[paramName]);
                });

                console.log(`Loaded VST preset: ${presetName} for ${vstInstance.name}`);
                return true;
            }
        }
        return false;
    }

    // Utility Methods
    notifyVSTStreamStart(streamId, vstInstance, targetUserIds) {
        // Notify users that a VST stream is starting
        console.log(`VST Stream Started: ${vstInstance.name} (${streamId})`);
    }

    notifyVSTStreamEnd(streamId, userId) {
        // Notify user that a VST stream has ended
        console.log(`VST Stream Ended: ${streamId} for user ${userId}`);
    }

    handleVSTMessage(vstId, message) {
        // Handle messages from VST worklet
        switch (message.type) {
            case 'parameterChanged':
                console.log(`VST ${vstId} parameter changed: ${message.name} = ${message.value}`);
                break;
            case 'error':
                console.error(`VST ${vstId} error:`, message.error);
                break;
        }
    }

    // Get VST information
    getAvailablePlugins() {
        return Array.from(this.pluginLibrary.values());
    }

    getUserVSTInstances(userId) {
        const userInstances = [];
        this.vstPlugins.forEach(instance => {
            if (instance.userId === userId) {
                userInstances.push(instance);
            }
        });
        return userInstances;
    }

    removeVSTInstance(vstId) {
        const vstInstance = this.vstPlugins.get(vstId);
        if (vstInstance) {
            // Stop streaming if active
            if (vstInstance.streaming) {
                const activeStreams = Array.from(this.vstStreams.keys()).filter(streamId =>
                    this.vstStreams.get(streamId).vstId === vstId
                );
                activeStreams.forEach(streamId => this.stopVSTStreaming(streamId));
            }

            // Disconnect and cleanup
            vstInstance.node.disconnect();
            this.vstPlugins.delete(vstId);

            console.log(`Removed VST instance: ${vstId}`);
        }
    }
}

// Utility Classes
class CircularBuffer {
    constructor(size) {
        this.buffer = new Float32Array(size);
        this.writeIndex = 0;
        this.readIndex = 0;
        this.size = size;
    }

    write(data) {
        for (let i = 0; i < data.length; i++) {
            this.buffer[this.writeIndex] = data[i];
            this.writeIndex = (this.writeIndex + 1) % this.size;
        }
    }

    read(length) {
        const result = new Float32Array(length);
        for (let i = 0; i < length; i++) {
            result[i] = this.buffer[this.readIndex];
            this.readIndex = (this.readIndex + 1) % this.size;
        }
        return result;
    }
}

class DelayBuffer {
    constructor(audioContext, maxDelay) {
        this.audioContext = audioContext;
        this.maxDelay = maxDelay;
        this.buffer = new Float32Array(Math.ceil(maxDelay * audioContext.sampleRate));
        this.writeIndex = 0;
        this.delayTime = 0;
    }

    setDelay(delayTime) {
        this.delayTime = Math.min(delayTime, this.maxDelay);
    }

    process(audioBuffer) {
        const output = this.audioContext.createBuffer(
            audioBuffer.numberOfChannels,
            audioBuffer.length,
            audioBuffer.sampleRate
        );

        const delaySamples = Math.floor(this.delayTime * audioBuffer.sampleRate);

        for (let channel = 0; channel < audioBuffer.numberOfChannels; channel++) {
            const inputData = audioBuffer.getChannelData(channel);
            const outputData = output.getChannelData(channel);

            for (let i = 0; i < inputData.length; i++) {
                const readIndex = (this.writeIndex - delaySamples + this.buffer.length) % this.buffer.length;
                outputData[i] = this.buffer[readIndex];

                this.buffer[this.writeIndex] = inputData[i];
                this.writeIndex = (this.writeIndex + 1) % this.buffer.length;
            }
        }

        return output;
    }
}

// Export for use in other modules
window.VSTStreamingEngine = VSTStreamingEngine;