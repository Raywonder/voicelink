/**
 * VoiceLink Multi-Channel Audio Engine
 * Professional 64-channel I/O with mono/stereo/3D binaural support
 */

class MultiChannelAudioEngine {
    constructor(audioContext) {
        this.audioContext = audioContext;
        this.maxChannels = 64;

        // Channel management
        this.inputChannels = new Map(); // channelId -> inputNode
        this.outputChannels = new Map(); // channelId -> outputNode
        this.channelTypes = new Map(); // channelId -> 'mono'|'stereo'|'binaural'

        // User-to-channel mapping
        this.userInputChannels = new Map(); // userId -> [channelIds]
        this.userOutputChannels = new Map(); // userId -> [channelIds]

        // 3D Binaural processing
        this.binauralProcessors = new Map(); // channelPairId -> BinauralProcessor
        this.hrtfDatabase = null;

        // Audio interface configuration
        this.audioInterface = {
            name: 'Professional Audio Interface',
            channels: {
                input: 64,
                output: 64
            },
            sampleRates: [44100, 48000, 96000, 192000],
            bitDepths: [16, 24, 32],
            currentSampleRate: 48000,
            currentBitDepth: 24
        };

        this.init();
    }

    async init() {
        console.log('Initializing Multi-Channel Audio Engine...');

        // Initialize channel infrastructure
        this.initializeChannelMatrix();

        // Load HRTF database for binaural processing
        await this.loadHRTFDatabase();

        // Setup default channel configurations
        this.setupDefaultChannelConfig();

        console.log(`Multi-Channel Audio Engine initialized: ${this.maxChannels} channels`);
    }

    initializeChannelMatrix() {
        // Create input channel matrix (1-64)
        for (let i = 1; i <= this.maxChannels; i++) {
            const inputNode = this.audioContext.createGain();
            inputNode.channelId = i;
            inputNode.gain.value = 1.0;

            this.inputChannels.set(i, {
                node: inputNode,
                type: 'mono',
                connected: false,
                source: null,
                effects: [],
                routing: []
            });
        }

        // Create output channel matrix (1-64)
        for (let i = 1; i <= this.maxChannels; i++) {
            const outputNode = this.audioContext.createGain();
            outputNode.channelId = i;
            outputNode.gain.value = 1.0;

            // Connect to destination (in practice, would route to hardware outputs)
            outputNode.connect(this.audioContext.destination);

            this.outputChannels.set(i, {
                node: outputNode,
                type: 'mono',
                connected: true,
                effects: [],
                users: new Set()
            });
        }

        // Create stereo pairs (1-2, 3-4, 5-6, etc.)
        for (let i = 1; i <= this.maxChannels; i += 2) {
            this.createStereoPair(i, i + 1);
        }

        // Create binaural pairs for 3D audio
        this.createBinauralChannels();
    }

    createStereoPair(leftChannel, rightChannel) {
        const stereoId = `stereo_${leftChannel}_${rightChannel}`;

        const leftInput = this.inputChannels.get(leftChannel);
        const rightInput = this.inputChannels.get(rightChannel);
        const leftOutput = this.outputChannels.get(leftChannel);
        const rightOutput = this.outputChannels.get(rightChannel);

        if (leftInput && rightInput && leftOutput && rightOutput) {
            // Create stereo merger/splitter
            const merger = this.audioContext.createChannelMerger(2);
            const splitter = this.audioContext.createChannelSplitter(2);

            // Mark as stereo pair
            leftInput.type = 'stereo_left';
            rightInput.type = 'stereo_right';
            leftOutput.type = 'stereo_left';
            rightOutput.type = 'stereo_right';

            leftInput.stereoPair = rightChannel;
            rightInput.stereoPair = leftChannel;
            leftOutput.stereoPair = rightChannel;
            rightOutput.stereoPair = leftChannel;

            console.log(`Created stereo pair: channels ${leftChannel}-${rightChannel}`);
        }
    }

    createBinauralChannels() {
        // Create binaural processor pairs for 3D audio
        // Using channels 57-64 for binaural processing by default
        for (let i = 57; i <= 63; i += 2) {
            const binauralId = `binaural_${i}_${i + 1}`;

            const binauralProcessor = new BinauralProcessor(
                this.audioContext,
                i, // left ear channel
                i + 1, // right ear channel
                this.hrtfDatabase
            );

            this.binauralProcessors.set(binauralId, binauralProcessor);

            // Mark channels as binaural
            const leftChannel = this.outputChannels.get(i);
            const rightChannel = this.outputChannels.get(i + 1);

            if (leftChannel && rightChannel) {
                leftChannel.type = 'binaural_left';
                rightChannel.type = 'binaural_right';
                leftChannel.binauralPair = i + 1;
                rightChannel.binauralPair = i;
                leftChannel.processor = binauralProcessor;
                rightChannel.processor = binauralProcessor;
            }

            console.log(`Created binaural pair: channels ${i}-${i + 1}`);
        }
    }

    async loadHRTFDatabase() {
        // In a real implementation, this would load HRTF data
        // For now, we'll create a synthetic HRTF database
        this.hrtfDatabase = {
            elevations: [], // -40° to +90° in 10° steps
            azimuths: [], // 0° to 355° in 5° steps
            impulseResponses: new Map()
        };

        // Generate elevation angles
        for (let elev = -40; elev <= 90; elev += 10) {
            this.hrtfDatabase.elevations.push(elev);
        }

        // Generate azimuth angles
        for (let azim = 0; azim < 360; azim += 5) {
            this.hrtfDatabase.azimuths.push(azim);
        }

        // Generate synthetic HRTF impulse responses
        this.hrtfDatabase.elevations.forEach(elevation => {
            this.hrtfDatabase.azimuths.forEach(azimuth => {
                const key = `${elevation}_${azimuth}`;
                const impulseResponse = this.generateHRTFImpulseResponse(elevation, azimuth);
                this.hrtfDatabase.impulseResponses.set(key, impulseResponse);
            });
        });

        console.log('HRTF database loaded with', this.hrtfDatabase.impulseResponses.size, 'impulse responses');
    }

    generateHRTFImpulseResponse(elevation, azimuth) {
        // Generate synthetic HRTF impulse response
        const length = 512; // 512 samples at 48kHz ≈ 10.67ms
        const sampleRate = this.audioContext.sampleRate;

        const buffer = this.audioContext.createBuffer(2, length, sampleRate);
        const leftChannel = buffer.getChannelData(0);
        const rightChannel = buffer.getChannelData(1);

        // Simplified HRTF modeling
        const azimuthRad = (azimuth * Math.PI) / 180;
        const elevationRad = (elevation * Math.PI) / 180;

        // Head shadow and pinna effects
        const headRadius = 0.0875; // 8.75cm average head radius
        const speedOfSound = 343; // m/s

        for (let i = 0; i < length; i++) {
            const t = i / sampleRate;

            // Calculate time delays for left and right ears
            const leftDelay = this.calculateEarDelay(azimuthRad, elevationRad, 'left', headRadius, speedOfSound);
            const rightDelay = this.calculateEarDelay(azimuthRad, elevationRad, 'right', headRadius, speedOfSound);

            // Generate impulse response with delay and filtering
            const leftSample = this.generateEarResponse(t, leftDelay, azimuthRad, elevationRad, 'left');
            const rightSample = this.generateEarResponse(t, rightDelay, azimuthRad, elevationRad, 'right');

            leftChannel[i] = leftSample;
            rightChannel[i] = rightSample;
        }

        return buffer;
    }

    calculateEarDelay(azimuth, elevation, ear, headRadius, speedOfSound) {
        // Simplified spherical head model
        const earAngle = ear === 'left' ? Math.PI / 2 : -Math.PI / 2;
        const relativeAngle = azimuth - earAngle;

        // Time delay due to head shadow
        const delay = (headRadius / speedOfSound) * (1 + Math.cos(relativeAngle));
        return delay;
    }

    generateEarResponse(t, delay, azimuth, elevation, ear) {
        if (t < delay) return 0;

        const adjustedTime = t - delay;

        // Frequency-dependent attenuation based on angle
        const highFreqAttenuation = Math.exp(-Math.abs(azimuth) * 0.5);
        const lowFreqAttenuation = 1.0 - Math.abs(elevation) * 0.3;

        // Generate impulse with frequency shaping
        let sample = 0;

        // High frequency components
        sample += 0.4 * Math.exp(-adjustedTime * 1000) * Math.sin(2 * Math.PI * 2000 * adjustedTime) * highFreqAttenuation;

        // Mid frequency components
        sample += 0.3 * Math.exp(-adjustedTime * 500) * Math.sin(2 * Math.PI * 1000 * adjustedTime);

        // Low frequency components
        sample += 0.3 * Math.exp(-adjustedTime * 200) * Math.sin(2 * Math.PI * 400 * adjustedTime) * lowFreqAttenuation;

        return sample * 0.1; // Scale down amplitude
    }

    setupDefaultChannelConfig() {
        // Default professional audio configuration

        // Channels 1-16: Microphone inputs (mono)
        for (let i = 1; i <= 16; i++) {
            this.channelTypes.set(i, 'mono');
        }

        // Channels 17-32: Stereo line inputs (stereo pairs)
        for (let i = 17; i <= 32; i += 2) {
            this.channelTypes.set(i, 'stereo_left');
            this.channelTypes.set(i + 1, 'stereo_right');
        }

        // Channels 33-48: Direct outs (mono/stereo configurable)
        for (let i = 33; i <= 48; i++) {
            this.channelTypes.set(i, 'mono');
        }

        // Channels 49-56: Main mix outputs (stereo pairs)
        for (let i = 49; i <= 56; i += 2) {
            this.channelTypes.set(i, 'stereo_left');
            this.channelTypes.set(i + 1, 'stereo_right');
        }

        // Channels 57-64: 3D Binaural outputs (binaural pairs)
        for (let i = 57; i <= 64; i += 2) {
            this.channelTypes.set(i, 'binaural_left');
            this.channelTypes.set(i + 1, 'binaural_right');
        }
    }

    // User channel assignment methods
    assignUserToInputChannels(userId, channelIds, mode = 'mono') {
        const assignment = {
            userId,
            channels: channelIds,
            mode, // 'mono', 'stereo', or 'binaural'
            timestamp: Date.now()
        };

        this.userInputChannels.set(userId, assignment);

        // Configure channels based on mode
        if (mode === 'stereo' && channelIds.length >= 2) {
            this.configureUserStereoInput(userId, channelIds[0], channelIds[1]);
        } else if (mode === 'binaural' && channelIds.length >= 2) {
            this.configureUserBinauralInput(userId, channelIds[0], channelIds[1]);
        } else {
            // Mono configuration
            channelIds.forEach(channelId => {
                this.configureUserMonoInput(userId, channelId);
            });
        }

        console.log(`Assigned user ${userId} to input channels:`, channelIds, `(${mode})`);
    }

    assignUserToOutputChannels(userId, channelIds, mode = 'mono') {
        const assignment = {
            userId,
            channels: channelIds,
            mode, // 'mono', 'stereo', or 'binaural'
            timestamp: Date.now()
        };

        this.userOutputChannels.set(userId, assignment);

        // Configure channels based on mode
        if (mode === 'stereo' && channelIds.length >= 2) {
            this.configureUserStereoOutput(userId, channelIds[0], channelIds[1]);
        } else if (mode === 'binaural' && channelIds.length >= 2) {
            this.configureUserBinauralOutput(userId, channelIds[0], channelIds[1]);
        } else {
            // Mono configuration
            channelIds.forEach(channelId => {
                this.configureUserMonoOutput(userId, channelId);
            });
        }

        console.log(`Assigned user ${userId} to output channels:`, channelIds, `(${mode})`);
    }

    configureUserMonoInput(userId, channelId) {
        const channel = this.inputChannels.get(channelId);
        if (channel) {
            channel.users = channel.users || new Set();
            channel.users.add(userId);
            channel.type = 'mono';
        }
    }

    configureUserStereoInput(userId, leftChannelId, rightChannelId) {
        const leftChannel = this.inputChannels.get(leftChannelId);
        const rightChannel = this.inputChannels.get(rightChannelId);

        if (leftChannel && rightChannel) {
            leftChannel.users = leftChannel.users || new Set();
            rightChannel.users = rightChannel.users || new Set();

            leftChannel.users.add(userId);
            rightChannel.users.add(userId);

            leftChannel.type = 'stereo_left';
            rightChannel.type = 'stereo_right';

            leftChannel.stereoPair = rightChannelId;
            rightChannel.stereoPair = leftChannelId;
        }
    }

    configureUserBinauralInput(userId, leftChannelId, rightChannelId) {
        const leftChannel = this.inputChannels.get(leftChannelId);
        const rightChannel = this.inputChannels.get(rightChannelId);

        if (leftChannel && rightChannel) {
            leftChannel.users = leftChannel.users || new Set();
            rightChannel.users = rightChannel.users || new Set();

            leftChannel.users.add(userId);
            rightChannel.users.add(userId);

            leftChannel.type = 'binaural_left';
            rightChannel.type = 'binaural_right';

            leftChannel.binauralPair = rightChannelId;
            rightChannel.binauralPair = leftChannelId;

            // Create binaural processor if needed
            const binauralId = `binaural_${leftChannelId}_${rightChannelId}`;
            if (!this.binauralProcessors.has(binauralId)) {
                const processor = new BinauralProcessor(
                    this.audioContext,
                    leftChannelId,
                    rightChannelId,
                    this.hrtfDatabase
                );
                this.binauralProcessors.set(binauralId, processor);
            }
        }
    }

    configureUserMonoOutput(userId, channelId) {
        const channel = this.outputChannels.get(channelId);
        if (channel) {
            channel.users.add(userId);
            channel.type = 'mono';
        }
    }

    configureUserStereoOutput(userId, leftChannelId, rightChannelId) {
        const leftChannel = this.outputChannels.get(leftChannelId);
        const rightChannel = this.outputChannels.get(rightChannelId);

        if (leftChannel && rightChannel) {
            leftChannel.users.add(userId);
            rightChannel.users.add(userId);

            leftChannel.type = 'stereo_left';
            rightChannel.type = 'stereo_right';

            leftChannel.stereoPair = rightChannelId;
            rightChannel.stereoPair = leftChannelId;
        }
    }

    configureUserBinauralOutput(userId, leftChannelId, rightChannelId) {
        const leftChannel = this.outputChannels.get(leftChannelId);
        const rightChannel = this.outputChannels.get(rightChannelId);

        if (leftChannel && rightChannel) {
            leftChannel.users.add(userId);
            rightChannel.users.add(userId);

            leftChannel.type = 'binaural_left';
            rightChannel.type = 'binaural_right';

            leftChannel.binauralPair = rightChannelId;
            rightChannel.binauralPair = leftChannelId;

            // Get or create binaural processor
            const binauralId = `binaural_${leftChannelId}_${rightChannelId}`;
            let processor = this.binauralProcessors.get(binauralId);

            if (!processor) {
                processor = new BinauralProcessor(
                    this.audioContext,
                    leftChannelId,
                    rightChannelId,
                    this.hrtfDatabase
                );
                this.binauralProcessors.set(binauralId, processor);
            }

            leftChannel.processor = processor;
            rightChannel.processor = processor;
        }
    }

    // Channel matrix operations
    routeInputToOutput(inputChannelId, outputChannelId, gain = 1.0) {
        const inputChannel = this.inputChannels.get(inputChannelId);
        const outputChannel = this.outputChannels.get(outputChannelId);

        if (inputChannel && outputChannel) {
            const gainNode = this.audioContext.createGain();
            gainNode.gain.value = gain;

            inputChannel.node.connect(gainNode);
            gainNode.connect(outputChannel.node);

            // Track routing
            inputChannel.routing = inputChannel.routing || [];
            inputChannel.routing.push({
                outputChannel: outputChannelId,
                gainNode,
                gain
            });

            console.log(`Routed input ${inputChannelId} to output ${outputChannelId} (gain: ${gain})`);
        }
    }

    // Channel control methods
    setChannelGain(channelId, gain, isOutput = true) {
        const channel = isOutput
            ? this.outputChannels.get(channelId)
            : this.inputChannels.get(channelId);

        if (channel) {
            channel.node.gain.setValueAtTime(gain, this.audioContext.currentTime);
        }
    }

    muteChannel(channelId, isOutput = true) {
        this.setChannelGain(channelId, 0, isOutput);
    }

    unmuteChannel(channelId, isOutput = true) {
        this.setChannelGain(channelId, 1, isOutput);
    }

    // Get channel information
    getChannelInfo(channelId, isOutput = true) {
        const channel = isOutput
            ? this.outputChannels.get(channelId)
            : this.inputChannels.get(channelId);

        if (channel) {
            return {
                id: channelId,
                type: channel.type,
                connected: channel.connected,
                users: Array.from(channel.users || []),
                gain: channel.node.gain.value,
                routing: channel.routing || []
            };
        }

        return null;
    }

    // Get all channel states
    getAllChannelStates() {
        const inputs = {};
        const outputs = {};

        for (let i = 1; i <= this.maxChannels; i++) {
            inputs[i] = this.getChannelInfo(i, false);
            outputs[i] = this.getChannelInfo(i, true);
        }

        return { inputs, outputs };
    }

    // Audio interface configuration
    setAudioInterfaceConfig(config) {
        Object.assign(this.audioInterface, config);
        console.log('Audio interface configuration updated:', this.audioInterface);
    }

    getAudioInterfaceConfig() {
        return { ...this.audioInterface };
    }
}

/**
 * Binaural Audio Processor
 * Handles 3D spatial audio processing for binaural channel pairs
 */
class BinauralProcessor {
    constructor(audioContext, leftChannelId, rightChannelId, hrtfDatabase) {
        this.audioContext = audioContext;
        this.leftChannelId = leftChannelId;
        this.rightChannelId = rightChannelId;
        this.hrtfDatabase = hrtfDatabase;

        this.spatialSources = new Map(); // sourceId -> spatialNode
        this.listenerPosition = { x: 0, y: 0, z: 0 };
        this.listenerOrientation = { azimuth: 0, elevation: 0 };

        this.setupBinauralProcessing();
    }

    setupBinauralProcessing() {
        // Create binaural output nodes
        this.leftOutput = this.audioContext.createGain();
        this.rightOutput = this.audioContext.createGain();

        // Create master convolver for room acoustics
        this.roomConvolver = this.audioContext.createConvolver();

        console.log(`Binaural processor setup for channels ${this.leftChannelId}-${this.rightChannelId}`);
    }

    addSpatialSource(sourceId, audioNode, position = { x: 0, y: 1, z: 0 }) {
        const spatialNode = {
            source: audioNode,
            position,
            leftConvolver: this.audioContext.createConvolver(),
            rightConvolver: this.audioContext.createConvolver(),
            leftGain: this.audioContext.createGain(),
            rightGain: this.audioContext.createGain()
        };

        // Update HRTF based on position
        this.updateSourceHRTF(spatialNode);

        // Connect processing chain
        audioNode.connect(spatialNode.leftConvolver);
        audioNode.connect(spatialNode.rightConvolver);

        spatialNode.leftConvolver.connect(spatialNode.leftGain);
        spatialNode.rightConvolver.connect(spatialNode.rightGain);

        spatialNode.leftGain.connect(this.leftOutput);
        spatialNode.rightGain.connect(this.rightOutput);

        this.spatialSources.set(sourceId, spatialNode);

        console.log(`Added spatial source ${sourceId} at position`, position);
    }

    updateSourcePosition(sourceId, position) {
        const spatialNode = this.spatialSources.get(sourceId);
        if (spatialNode) {
            spatialNode.position = position;
            this.updateSourceHRTF(spatialNode);
        }
    }

    updateSourceHRTF(spatialNode) {
        // Calculate azimuth and elevation relative to listener
        const relativePos = {
            x: spatialNode.position.x - this.listenerPosition.x,
            y: spatialNode.position.y - this.listenerPosition.y,
            z: spatialNode.position.z - this.listenerPosition.z
        };

        const distance = Math.sqrt(relativePos.x ** 2 + relativePos.y ** 2 + relativePos.z ** 2);
        const azimuth = Math.atan2(relativePos.x, relativePos.z) * (180 / Math.PI);
        const elevation = Math.asin(relativePos.y / distance) * (180 / Math.PI);

        // Get HRTF impulse response
        const hrtfIR = this.getHRTFImpulseResponse(azimuth, elevation);

        if (hrtfIR) {
            spatialNode.leftConvolver.buffer = hrtfIR;
            spatialNode.rightConvolver.buffer = hrtfIR;

            // Apply distance attenuation
            const attenuation = Math.max(0.1, 1 / (1 + distance * 0.1));
            spatialNode.leftGain.gain.setValueAtTime(attenuation, this.audioContext.currentTime);
            spatialNode.rightGain.gain.setValueAtTime(attenuation, this.audioContext.currentTime);
        }
    }

    getHRTFImpulseResponse(azimuth, elevation) {
        // Find closest HRTF in database
        const closestElevation = this.findClosestValue(this.hrtfDatabase.elevations, elevation);
        const closestAzimuth = this.findClosestValue(this.hrtfDatabase.azimuths, azimuth);

        const key = `${closestElevation}_${closestAzimuth}`;
        return this.hrtfDatabase.impulseResponses.get(key);
    }

    findClosestValue(array, target) {
        return array.reduce((prev, curr) =>
            Math.abs(curr - target) < Math.abs(prev - target) ? curr : prev
        );
    }

    setListenerPosition(position) {
        this.listenerPosition = position;

        // Update all spatial sources
        this.spatialSources.forEach(spatialNode => {
            this.updateSourceHRTF(spatialNode);
        });
    }

    removeSpatialSource(sourceId) {
        const spatialNode = this.spatialSources.get(sourceId);
        if (spatialNode) {
            spatialNode.source.disconnect();
            spatialNode.leftConvolver.disconnect();
            spatialNode.rightConvolver.disconnect();
            spatialNode.leftGain.disconnect();
            spatialNode.rightGain.disconnect();

            this.spatialSources.delete(sourceId);
        }
    }
}

// Export for use in other modules
window.MultiChannelAudioEngine = MultiChannelAudioEngine;
window.BinauralProcessor = BinauralProcessor;