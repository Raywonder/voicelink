/**
 * VoiceLink Audio Engine
 * Multi-output audio routing and device management
 */

class AudioEngine {
    constructor() {
        this.audioDevices = {
            inputs: [],
            outputs: []
        };
        this.selectedInputDevice = null;
        this.selectedOutputDevice = null;
        this.outputRouting = new Map(); // userId -> outputDeviceId
        this.userVolumes = new Map(); // userId -> volume
        this.localStream = null;
        this.audioContext = null;
        this.audioNodes = new Map(); // userId -> audioNode structure

        // Multi-input management
        this.inputStreams = new Map(); // inputType -> MediaStream
        this.inputSources = new Map(); // inputType -> AudioNode source
        this.inputTypes = {
            MICROPHONE: 'microphone',
            MEDIA_STREAMING: 'media_streaming',
            VIRTUAL_INPUT: 'virtual_input',
            SYSTEM_AUDIO: 'system_audio'
        };
        this.selectedInputDevices = new Map(); // inputType -> deviceId
        this.inputSettings = new Map(); // inputType -> settings object
        this.inputMixerNode = null;

        // Audio playback management
        this.currentTestAudio = null;
        this.isTestAudioPlaying = false;

        // Microphone monitoring
        this.micTestActive = false;
        this.micTestAnimationId = null;
        this.micPlaybackNode = null;
        this.micTestStream = null;

        // Audio ducking system
        this.duckingProcessor = null;

        this.settings = {
            inputVolume: 1.0,
            outputVolume: 1.0,
            noiseSuppression: true,
            echoCancellation: true,
            autoGainControl: true
        };

        this.init();
    }

    async init() {
        try {
            await this.setupAudioContext();
            this.setupEventListeners();

            // Try to enumerate devices after setup
            // This will show limited info until microphone permission is granted
            await this.enumerateDevices();

            console.log('Audio Engine initialized');
        } catch (error) {
            console.warn('Audio Engine initialization deferred:', error);
            // Set up minimal functionality
            this.audioContext = null;
        }
    }

    async enumerateDevices() {
        try {
            // First check if we have microphone permission for full device labels
            let hasPermission = false;
            try {
                const permissionStatus = await navigator.permissions.query({ name: 'microphone' });
                hasPermission = permissionStatus.state === 'granted';
            } catch (e) {
                // Permission API might not be available, try anyway
            }

            // If no permission, request temporary stream to unlock device labels
            let tempStream = null;
            if (!hasPermission) {
                try {
                    tempStream = await navigator.mediaDevices.getUserMedia({
                        audio: true,
                        video: false
                    });
                } catch (e) {
                    console.warn('Could not get microphone permission for full device enumeration');
                }
            }

            const devices = await navigator.mediaDevices.enumerateDevices();

            this.audioDevices.inputs = devices
                .filter(device => device.kind === 'audioinput')
                .map(device => ({
                    id: device.deviceId,
                    name: device.label || `Microphone ${device.deviceId.slice(0, 8)}`,
                    type: this.getDeviceType(device.label)
                }));

            this.audioDevices.outputs = devices
                .filter(device => device.kind === 'audiooutput')
                .map(device => ({
                    id: device.deviceId,
                    name: device.label || `Speaker ${device.deviceId.slice(0, 8)}`,
                    type: this.getDeviceType(device.label)
                }));

            // Add virtual multi-channel outputs for professional audio interfaces
            this.audioDevices.outputs.push(
                { id: 'output-3-4', name: 'Audio Interface 3-4', type: 'interface' },
                { id: 'output-5-6', name: 'Audio Interface 5-6', type: 'interface' },
                { id: 'output-7-8', name: 'Audio Interface 7-8', type: 'interface' }
            );

            // Clean up temporary stream
            if (tempStream) {
                tempStream.getTracks().forEach(track => track.stop());
            }

            console.log(`Enumerated ${this.audioDevices.inputs.length} input devices and ${this.audioDevices.outputs.length} output devices`);
            this.updateDeviceSelects();
        } catch (error) {
            console.error('Failed to enumerate devices:', error);
        }
    }

    getDeviceType(label) {
        if (!label) return 'unknown';
        const lowerLabel = label.toLowerCase();

        if (lowerLabel.includes('built-in') || lowerLabel.includes('default')) return 'builtin';
        if (lowerLabel.includes('usb')) return 'usb';
        if (lowerLabel.includes('bluetooth')) return 'bluetooth';
        if (lowerLabel.includes('headset')) return 'headset';
        if (lowerLabel.includes('interface')) return 'interface';

        return 'external';
    }

    async setupAudioContext() {
        try {
            const AudioContext = window.AudioContext || window.webkitAudioContext;
            if (!AudioContext) {
                throw new Error('Web Audio API not supported');
            }

            this.audioContext = new AudioContext();

            // Create master output nodes for each possible output
            this.outputNodes = new Map();

            // Create default output
            const defaultOutput = this.audioContext.createGain();
            defaultOutput.connect(this.audioContext.destination);
            this.outputNodes.set('default', defaultOutput);

            // Create input mixer node for combining multiple input sources
            this.inputMixerNode = this.audioContext.createGain();
            this.inputMixerNode.connect(defaultOutput);

            // Initialize input settings for each input type
            Object.values(this.inputTypes).forEach(inputType => {
                this.inputSettings.set(inputType, {
                    enabled: false,
                    volume: 1.0,
                    muted: false,
                    processing: {
                        echoCancellation: true,
                        noiseSuppression: true,
                        autoGainControl: true
                    }
                });
            });

            // In a real implementation, we would set up routing to actual hardware outputs
            // For now, we simulate multi-output capability
            this.audioDevices.outputs.forEach(output => {
                if (!this.outputNodes.has(output.id)) {
                    const outputNode = this.audioContext.createGain();
                    outputNode.connect(this.audioContext.destination);
                    this.outputNodes.set(output.id, outputNode);
                }
            });

            // Initialize audio ducking processor
            if (typeof AudioDuckingProcessor !== 'undefined') {
                this.duckingProcessor = new AudioDuckingProcessor(this.audioContext);
                console.log('Audio ducking processor initialized');
            }

            console.log('Audio context setup complete with multi-input mixer');

        } catch (error) {
            console.error('Failed to setup audio context:', error);
        }
    }

    async getUserMedia(constraints = null) {
        const defaultConstraints = {
            audio: {
                deviceId: this.selectedInputDevice ? { exact: this.selectedInputDevice } : undefined,
                echoCancellation: this.settings.echoCancellation,
                noiseSuppression: this.settings.noiseSuppression,
                autoGainControl: this.settings.autoGainControl,
                sampleRate: 48000,
                channelCount: 1
            },
            video: false
        };

        const finalConstraints = constraints || defaultConstraints;

        try {
            if (this.localStream) {
                this.localStream.getTracks().forEach(track => track.stop());
            }

            this.localStream = await navigator.mediaDevices.getUserMedia(finalConstraints);
            this.setupInputProcessing();
            return this.localStream;
        } catch (error) {
            console.error('Failed to get user media:', error);
            throw error;
        }
    }

    setupInputProcessing() {
        if (!this.localStream || !this.audioContext) return;

        try {
            // Create input processing chain
            const source = this.audioContext.createMediaStreamSource(this.localStream);
            const inputGain = this.audioContext.createGain();
            const compressor = this.audioContext.createDynamicsCompressor();

            // Configure compressor for voice
            compressor.threshold.setValueAtTime(-24, this.audioContext.currentTime);
            compressor.knee.setValueAtTime(30, this.audioContext.currentTime);
            compressor.ratio.setValueAtTime(12, this.audioContext.currentTime);
            compressor.attack.setValueAtTime(0.003, this.audioContext.currentTime);
            compressor.release.setValueAtTime(0.25, this.audioContext.currentTime);

            // Connect processing chain
            source.connect(inputGain);
            inputGain.connect(compressor);

            // Set input volume
            inputGain.gain.value = this.settings.inputVolume;

            this.inputNodes = {
                source,
                inputGain,
                compressor
            };

        } catch (error) {
            console.error('Failed to setup input processing:', error);
        }
    }

    routeUserToOutput(userId, outputDeviceId) {
        this.outputRouting.set(userId, outputDeviceId);

        // Update existing audio node routing
        const audioNode = this.audioNodes.get(userId);
        if (audioNode) {
            this.updateUserOutputRouting(userId, audioNode);
        }

        // Emit routing change to server
        if (window.voiceLinkApp && window.voiceLinkApp.socket) {
            window.voiceLinkApp.socket.emit('set-audio-routing', {
                outputDevice: outputDeviceId
            });
        }

        console.log(`Routed user ${userId} to output ${outputDeviceId}`);
    }

    createUserAudioNode(userId, audioStream) {
        if (!this.audioContext) return null;

        try {
            const source = this.audioContext.createMediaStreamSource(audioStream);
            const gainNode = this.audioContext.createGain();
            const filterNode = this.audioContext.createBiquadFilter();

            // Configure filter
            filterNode.type = 'highpass';
            filterNode.frequency.value = 85; // Remove low-frequency noise

            // Connect nodes
            source.connect(filterNode);
            filterNode.connect(gainNode);

            const audioNode = {
                source,
                gainNode,
                filterNode,
                userId
            };

            this.audioNodes.set(userId, audioNode);
            this.updateUserOutputRouting(userId, audioNode);

            return audioNode;
        } catch (error) {
            console.error('Failed to create user audio node:', error);
            return null;
        }
    }

    updateUserOutputRouting(userId, audioNode) {
        const outputDeviceId = this.outputRouting.get(userId) || 'default';
        const outputNode = this.outputNodes.get(outputDeviceId);

        if (outputNode && audioNode) {
            // Disconnect from previous output
            audioNode.gainNode.disconnect();

            // Connect to new output
            audioNode.gainNode.connect(outputNode);

            // Apply user volume
            const volume = this.userVolumes.get(userId) || 1.0;
            audioNode.gainNode.gain.value = volume;
        }
    }

    setUserVolume(userId, volume) {
        this.userVolumes.set(userId, volume);

        const audioNode = this.audioNodes.get(userId);
        if (audioNode) {
            audioNode.gainNode.gain.setValueAtTime(volume, this.audioContext.currentTime);
        }
    }

    setOutputVolume(outputDeviceId, volume) {
        const outputNode = this.outputNodes.get(outputDeviceId);
        if (outputNode) {
            outputNode.gain.setValueAtTime(volume, this.audioContext.currentTime);
        }
    }

    removeUser(userId) {
        const audioNode = this.audioNodes.get(userId);
        if (audioNode) {
            audioNode.source.disconnect();
            audioNode.gainNode.disconnect();
            audioNode.filterNode.disconnect();
        }

        this.audioNodes.delete(userId);
        this.outputRouting.delete(userId);
        this.userVolumes.delete(userId);

        // Clean up relay audio buffer
        if (this.relayAudioBuffers) {
            this.relayAudioBuffers.delete(userId);
        }
    }

    /**
     * Process audio received via server relay
     * Used when P2P connection is unavailable or relay mode is enabled
     */
    processRelayedAudio(userId, audioData, timestamp) {
        if (!this.audioContext) return;

        try {
            // Initialize relay audio buffers if needed
            if (!this.relayAudioBuffers) {
                this.relayAudioBuffers = new Map();
            }

            // Get or create audio buffer for this user
            let userBuffer = this.relayAudioBuffers.get(userId);
            if (!userBuffer) {
                userBuffer = {
                    buffer: [],
                    lastTimestamp: 0,
                    gainNode: this.audioContext.createGain(),
                    filterNode: this.audioContext.createBiquadFilter()
                };

                // Configure filter
                userBuffer.filterNode.type = 'highpass';
                userBuffer.filterNode.frequency.value = 85;

                // Connect nodes
                userBuffer.gainNode.connect(userBuffer.filterNode);
                userBuffer.filterNode.connect(this.audioContext.destination);

                // Set volume
                const volume = this.userVolumes.get(userId) || 1.0;
                userBuffer.gainNode.gain.value = volume;

                this.relayAudioBuffers.set(userId, userBuffer);
            }

            // Convert received audio data to AudioBuffer and play
            if (audioData && audioData.length > 0) {
                // Handle Float32Array or ArrayBuffer audio data
                let floatData;
                if (audioData instanceof Float32Array) {
                    floatData = audioData;
                } else if (audioData instanceof ArrayBuffer || audioData.buffer) {
                    floatData = new Float32Array(audioData.buffer || audioData);
                } else if (Array.isArray(audioData)) {
                    floatData = new Float32Array(audioData);
                } else {
                    console.warn('Unknown audio data format from relay');
                    return;
                }

                // Create audio buffer
                const sampleRate = this.audioContext.sampleRate;
                const audioBuffer = this.audioContext.createBuffer(1, floatData.length, sampleRate);
                audioBuffer.getChannelData(0).set(floatData);

                // Create buffer source and play
                const source = this.audioContext.createBufferSource();
                source.buffer = audioBuffer;
                source.connect(userBuffer.gainNode);
                source.start();

                userBuffer.lastTimestamp = timestamp;
            }
        } catch (error) {
            console.error('Error processing relayed audio:', error);
        }
    }

    /**
     * Capture audio for relay mode
     * Returns audio data that can be sent to server
     */
    captureAudioForRelay() {
        if (!this.localStream || !this.audioContext) return null;

        try {
            // Create script processor for capturing audio data
            if (!this.relayProcessor) {
                const bufferSize = 4096;
                this.relayProcessor = this.audioContext.createScriptProcessor(bufferSize, 1, 1);

                const source = this.audioContext.createMediaStreamSource(this.localStream);
                source.connect(this.relayProcessor);
                this.relayProcessor.connect(this.audioContext.destination);

                this.relayProcessor.onaudioprocess = (event) => {
                    if (this.onAudioDataReady) {
                        const inputData = event.inputBuffer.getChannelData(0);
                        // Convert to array for transmission
                        const audioData = Array.from(inputData);
                        this.onAudioDataReady(audioData);
                    }
                };
            }
        } catch (error) {
            console.error('Error setting up audio capture for relay:', error);
        }
    }

    /**
     * Set callback for when audio data is ready to send to relay
     */
    setAudioDataCallback(callback) {
        this.onAudioDataReady = callback;
    }

    async setInputDevice(deviceId) {
        this.selectedInputDevice = deviceId;

        // Restart user media with new device
        if (this.localStream) {
            await this.getUserMedia();
        }
    }

    setOutputDevice(deviceId) {
        this.selectedOutputDevice = deviceId;

        // In a real implementation, this would switch the actual output device
        // For now, we just update the routing for new users
        console.log(`Output device set to: ${deviceId}`);
    }

    updateDeviceSelects() {
        // Update input device select
        const inputSelect = document.getElementById('input-device-select');
        if (inputSelect) {
            inputSelect.innerHTML = '';
            this.audioDevices.inputs.forEach(device => {
                const option = document.createElement('option');
                option.value = device.id;
                option.textContent = device.name;
                inputSelect.appendChild(option);
            });
        }

        // Update output device selects
        const outputSelects = [
            'output-device-select',
            'output-device-settings'
        ];

        outputSelects.forEach(selectId => {
            const select = document.getElementById(selectId);
            if (select) {
                select.innerHTML = '';
                this.audioDevices.outputs.forEach(device => {
                    const option = document.createElement('option');
                    option.value = device.id;
                    option.textContent = device.name;
                    select.appendChild(option);
                });
            }
        });
    }

    setupEventListeners() {
        // Listen for device changes
        navigator.mediaDevices.addEventListener('devicechange', () => {
            this.enumerateDevices();
        });

        // Input volume control
        const inputVolumeSlider = document.getElementById('input-volume');
        if (inputVolumeSlider) {
            inputVolumeSlider.addEventListener('input', (e) => {
                this.settings.inputVolume = e.target.value / 100;
                if (this.inputNodes) {
                    this.inputNodes.inputGain.gain.value = this.settings.inputVolume;
                }
                document.getElementById('input-volume-value').textContent = `${e.target.value}%`;
            });
        }

        // Output volume control
        const outputVolumeSlider = document.getElementById('output-volume');
        if (outputVolumeSlider) {
            outputVolumeSlider.addEventListener('input', (e) => {
                this.settings.outputVolume = e.target.value / 100;
                this.outputNodes.forEach(node => {
                    node.gain.value = this.settings.outputVolume;
                });
                document.getElementById('output-volume-value').textContent = `${e.target.value}%`;
            });
        }
    }

    // Audio level monitoring
    createLevelMeter(stream) {
        if (!this.audioContext) return null;

        const source = this.audioContext.createMediaStreamSource(stream);
        const analyser = this.audioContext.createAnalyser();
        analyser.fftSize = 256;

        source.connect(analyser);

        const dataArray = new Uint8Array(analyser.frequencyBinCount);

        return {
            analyser,
            dataArray,
            getLevel: () => {
                analyser.getByteFrequencyData(dataArray);
                const average = dataArray.reduce((a, b) => a + b) / dataArray.length;
                return average / 255; // Normalize to 0-1
            }
        };
    }

    async startMicrophoneTest() {
        try {
            console.log('Starting/stopping microphone test...');

            const meterElement = document.querySelector('#mic-level-meter .level-bar');
            if (!meterElement) {
                console.warn('Microphone level meter element not found');
                return;
            }

            // If test is already active, stop it
            if (this.micTestActive) {
                console.log('Stopping microphone test...');
                this.micTestActive = false;

                // Stop animation frame
                if (this.micTestAnimationId) {
                    cancelAnimationFrame(this.micTestAnimationId);
                    this.micTestAnimationId = null;
                }

                // Disconnect and clean up audio nodes for live playback
                if (this.micPlaybackNode) {
                    this.micPlaybackNode.disconnect();
                    this.micPlaybackNode = null;
                }

                // Stop test stream if it's different from local stream
                if (this.micTestStream && this.micTestStream !== this.localStream) {
                    this.micTestStream.getTracks().forEach(track => track.stop());
                    this.micTestStream = null;
                }

                meterElement.style.width = '0%';
                console.log('Microphone test with live playback stopped');
                return;
            }

            // Start new test
            console.log('Starting microphone test...');

            // Get microphone access with optimal settings for live monitoring
            let testStream = this.localStream;
            if (!testStream) {
                console.log('Getting microphone access for test...');
                try {
                    testStream = await navigator.mediaDevices.getUserMedia({
                        audio: {
                            deviceId: this.selectedInputDevice ? { exact: this.selectedInputDevice } : undefined,
                            echoCancellation: false, // Disable for live monitoring to avoid feedback issues
                            noiseSuppression: false,
                            autoGainControl: false,
                            latency: 0.01, // Request low latency
                            sampleRate: 48000,
                            channelCount: 1
                        }
                    });
                    this.micTestStream = testStream; // Store separately so we can clean it up
                } catch (micError) {
                    console.error('Could not access microphone:', micError);
                    meterElement.style.width = '0%';
                    return;
                }
            }

            if (!testStream) {
                console.warn('Could not access microphone for test');
                return;
            }

            // Create audio context if needed
            if (!this.audioContext) {
                const AudioContext = window.AudioContext || window.webkitAudioContext;
                if (AudioContext) {
                    this.audioContext = new AudioContext();
                    if (this.audioContext.state === 'suspended') {
                        await this.audioContext.resume();
                    }
                }
            }

            if (!this.audioContext) {
                console.warn('No audio context available for microphone test');
                return;
            }

            // Create audio processing chain for level meter AND live playback
            const source = this.audioContext.createMediaStreamSource(testStream);
            const analyser = this.audioContext.createAnalyser();
            const inputGain = this.audioContext.createGain();
            const outputGain = this.audioContext.createGain();

            // Configure analyser for level monitoring
            analyser.fftSize = 256;
            analyser.smoothingTimeConstant = 0.3;

            // Set up audio routing: source -> analyser (for meter) and source -> inputGain -> outputGain -> speakers
            source.connect(analyser);
            source.connect(inputGain);
            inputGain.connect(outputGain);
            outputGain.connect(this.audioContext.destination);

            // Set initial volumes (start with moderate volume to prevent feedback)
            inputGain.gain.value = 0.4; // 40% input
            outputGain.gain.value = 0.6; // 60% output

            // Store the playback node for cleanup
            this.micPlaybackNode = outputGain;

            console.log('🎙️ Live microphone playback active - you should hear your voice through speakers');
            console.log('⚠️ Note: If you hear feedback, try using headphones or reducing speaker volume');

            const dataArray = new Uint8Array(analyser.frequencyBinCount);
            this.micTestActive = true;

            const updateLevel = () => {
                if (!this.micTestActive) return;

                analyser.getByteFrequencyData(dataArray);
                const average = dataArray.reduce((a, b) => a + b) / dataArray.length;
                const level = average / 255; // Normalize to 0-1

                meterElement.style.width = `${level * 100}%`;
                this.micTestAnimationId = requestAnimationFrame(updateLevel);
            };

            updateLevel();
            console.log('Microphone test with live playback active - click again to stop');

            // Auto-stop after 30 seconds
            setTimeout(() => {
                if (this.micTestActive) {
                    console.log('Auto-stopping microphone test after 30 seconds...');
                    this.startMicrophoneTest(); // This will stop it since micTestActive is true
                }
            }, 30000);

        } catch (error) {
            console.error('Microphone test failed:', error);

            // Clean up on error
            this.micTestActive = false;
            if (this.micTestAnimationId) {
                cancelAnimationFrame(this.micTestAnimationId);
                this.micTestAnimationId = null;
            }
            if (this.micPlaybackNode) {
                this.micPlaybackNode.disconnect();
                this.micPlaybackNode = null;
            }
            if (this.micTestStream && this.micTestStream !== this.localStream) {
                this.micTestStream.getTracks().forEach(track => track.stop());
                this.micTestStream = null;
            }
        }
    }

    async testSpeakers() {
        try {
            console.log('Testing speakers...');

            // If audio is currently playing, stop it
            if (this.currentTestAudio && !this.currentTestAudio.paused) {
                console.log('Stopping current test audio...');
                this.currentTestAudio.pause();
                this.currentTestAudio.currentTime = 0;
                this.currentTestAudio = null;
                this.isTestAudioPlaying = false;
                console.log('Speaker test stopped');
                return;
            }

            // Try to play audio file first
            const candidates = [
                'sounds/your-sound-test.wav',
                'assets/sounds/your-sound-test.wav',
                'client/sounds/your-sound-test.wav',
                'source/assets/sounds/your-sound-test.wav'
            ];

            for (const path of candidates) {
                try {
                    this.currentTestAudio = new Audio(path);
                    this.isTestAudioPlaying = true;

                    // Set up event handlers
                    this.currentTestAudio.onended = () => {
                        console.log('Speaker test audio completed');
                        this.currentTestAudio = null;
                        this.isTestAudioPlaying = false;
                    };

                    this.currentTestAudio.onerror = (error) => {
                        console.error('Speaker test audio error:', error);
                        this.currentTestAudio = null;
                        this.isTestAudioPlaying = false;
                    };

                    await this.currentTestAudio.play();
                    console.log(`Speaker test completed using audio file: ${path}`);
                    return;
                } catch (audioFileError) {
                    console.log(`Audio file playback failed for ${path}, trying next...`);
                    this.currentTestAudio = null;
                    this.isTestAudioPlaying = false;
                }
            }

            // Fallback to generated tone
            if (!this.audioContext) {
                console.warn('No audio context available for speaker test');
                return;
            }

            // Ensure audio context is running
            if (this.audioContext.state === 'suspended') {
                console.log('Resuming audio context for speaker test...');
                await this.audioContext.resume();
            }

            // Create test tone
            const oscillator = this.audioContext.createOscillator();
            const gainNode = this.audioContext.createGain();

            oscillator.type = 'sine';
            oscillator.frequency.setValueAtTime(440, this.audioContext.currentTime); // A4 note

            // Increase volume for audibility
            gainNode.gain.setValueAtTime(0, this.audioContext.currentTime);
            gainNode.gain.linearRampToValueAtTime(0.3, this.audioContext.currentTime + 0.1); // Increased from 0.1 to 0.3
            gainNode.gain.linearRampToValueAtTime(0.1, this.audioContext.currentTime + 0.8); // Hold volume longer
            gainNode.gain.linearRampToValueAtTime(0, this.audioContext.currentTime + 1);

            oscillator.connect(gainNode);
            gainNode.connect(this.audioContext.destination);

            console.log('Playing speaker test tone at 440Hz...');
            oscillator.start(this.audioContext.currentTime);
            oscillator.stop(this.audioContext.currentTime + 1);

        } catch (error) {
            console.error('Speaker test failed:', error);
        }
    }

    // Get current settings
    getSettings() {
        return { ...this.settings };
    }

    // Update settings
    updateSettings(newSettings) {
        Object.assign(this.settings, newSettings);

        // Restart input stream if audio processing settings changed
        if (this.localStream && (
            'echoCancellation' in newSettings ||
            'noiseSuppression' in newSettings ||
            'autoGainControl' in newSettings
        )) {
            this.getUserMedia();
        }
    }

    // Resume audio context (required for user interaction)
    async resumeAudioContext() {
        if (this.audioContext && this.audioContext.state === 'suspended') {
            await this.audioContext.resume();
        }
    }

    // Get available devices
    getDevices() {
        return this.audioDevices;
    }

    // Save default audio settings
    saveDefaultSettings() {
        const defaultSettings = {
            inputDevice: this.selectedInputDevice,
            outputDevice: this.selectedOutputDevice,
            inputVolume: this.settings.inputVolume,
            outputVolume: this.settings.outputVolume,
            noiseSuppression: this.settings.noiseSuppression,
            echoCancellation: this.settings.echoCancellation,
            autoGainControl: this.settings.autoGainControl
        };

        try {
            localStorage.setItem('voicelink-default-audio-settings', JSON.stringify(defaultSettings));
            console.log('Default audio settings saved:', defaultSettings);
            return true;
        } catch (error) {
            console.error('Failed to save default audio settings:', error);
            return false;
        }
    }

    // Load default audio settings
    loadDefaultSettings() {
        try {
            const savedSettings = localStorage.getItem('voicelink-default-audio-settings');
            if (!savedSettings) {
                console.log('No saved default audio settings found');
                return false;
            }

            const settings = JSON.parse(savedSettings);
            console.log('Loading default audio settings:', settings);

            // Apply the settings
            if (settings.inputDevice) {
                this.selectedInputDevice = settings.inputDevice;
            }
            if (settings.outputDevice) {
                this.selectedOutputDevice = settings.outputDevice;
            }
            if (settings.inputVolume !== undefined) {
                this.settings.inputVolume = settings.inputVolume;
                if (this.inputNodes?.inputGain) {
                    this.inputNodes.inputGain.gain.value = settings.inputVolume;
                }
            }
            if (settings.outputVolume !== undefined) {
                this.settings.outputVolume = settings.outputVolume;
                this.outputNodes?.forEach(node => {
                    if (node) node.gain.value = settings.outputVolume;
                });
            }
            if (settings.noiseSuppression !== undefined) {
                this.settings.noiseSuppression = settings.noiseSuppression;
            }
            if (settings.echoCancellation !== undefined) {
                this.settings.echoCancellation = settings.echoCancellation;
            }
            if (settings.autoGainControl !== undefined) {
                this.settings.autoGainControl = settings.autoGainControl;
            }

            // Update UI elements
            this.updateUIWithSettings();

            console.log('Default audio settings loaded successfully');
            return true;
        } catch (error) {
            console.error('Failed to load default audio settings:', error);
            return false;
        }
    }

    // Update UI elements with current settings
    updateUIWithSettings() {
        // Update device selects
        const inputSelect = document.getElementById('input-device-select');
        if (inputSelect && this.selectedInputDevice) {
            inputSelect.value = this.selectedInputDevice;
        }

        const outputSelect = document.getElementById('output-device-settings');
        if (outputSelect && this.selectedOutputDevice) {
            outputSelect.value = this.selectedOutputDevice;
        }

        // Update volume sliders
        const inputVolumeSlider = document.getElementById('input-volume');
        if (inputVolumeSlider) {
            inputVolumeSlider.value = this.settings.inputVolume * 100;
            const valueDisplay = document.getElementById('input-volume-value');
            if (valueDisplay) {
                valueDisplay.textContent = `${Math.round(this.settings.inputVolume * 100)}%`;
            }
        }

        const outputVolumeSlider = document.getElementById('output-volume');
        if (outputVolumeSlider) {
            outputVolumeSlider.value = this.settings.outputVolume * 100;
            const valueDisplay = document.getElementById('output-volume-value');
            if (valueDisplay) {
                valueDisplay.textContent = `${Math.round(this.settings.outputVolume * 100)}%`;
            }
        }

        // Update checkboxes
        const noiseSuppressionBox = document.getElementById('noise-suppression');
        if (noiseSuppressionBox) {
            noiseSuppressionBox.checked = this.settings.noiseSuppression;
        }

        const echoCancellationBox = document.getElementById('echo-cancellation');
        if (echoCancellationBox) {
            echoCancellationBox.checked = this.settings.echoCancellation;
        }
    }

    // === MULTI-INPUT SOURCE MANAGEMENT ===

    /**
     * Set up a specific input source with independent settings
     */
    async setupInputSource(inputType, deviceId = null, customConstraints = null) {
        try {
            console.log(`Setting up input source: ${inputType} with device: ${deviceId}`);

            // Stop existing stream for this input type
            await this.stopInputSource(inputType);

            let constraints;

            if (inputType === this.inputTypes.MICROPHONE) {
                constraints = {
                    audio: {
                        deviceId: deviceId ? { exact: deviceId } : undefined,
                        echoCancellation: this.inputSettings.get(inputType).processing.echoCancellation,
                        noiseSuppression: this.inputSettings.get(inputType).processing.noiseSuppression,
                        autoGainControl: this.inputSettings.get(inputType).processing.autoGainControl,
                        sampleRate: 48000,
                        channelCount: 1
                    },
                    video: false
                };
            } else if (inputType === this.inputTypes.MEDIA_STREAMING) {
                constraints = {
                    audio: {
                        deviceId: deviceId ? { exact: deviceId } : undefined,
                        echoCancellation: false, // Raw audio for streaming
                        noiseSuppression: false,
                        autoGainControl: false,
                        sampleRate: 48000,
                        channelCount: 2 // Stereo for media
                    },
                    video: false
                };
            } else if (inputType === this.inputTypes.VIRTUAL_INPUT) {
                // For virtual inputs, we might need different constraints
                constraints = customConstraints || {
                    audio: {
                        deviceId: deviceId ? { exact: deviceId } : undefined,
                        echoCancellation: false,
                        noiseSuppression: false,
                        autoGainControl: false,
                        sampleRate: 48000,
                        channelCount: 2
                    },
                    video: false
                };
            } else {
                // System audio or other types
                constraints = customConstraints || {
                    audio: {
                        deviceId: deviceId ? { exact: deviceId } : undefined,
                        sampleRate: 48000,
                        channelCount: 2
                    },
                    video: false
                };
            }

            // Get the media stream
            const stream = await navigator.mediaDevices.getUserMedia(constraints);
            this.inputStreams.set(inputType, stream);
            this.selectedInputDevices.set(inputType, deviceId);

            // Create audio processing chain for this input
            await this.createInputProcessingChain(inputType, stream);

            // Update settings
            const settings = this.inputSettings.get(inputType);
            settings.enabled = true;
            this.inputSettings.set(inputType, settings);

            console.log(`Successfully set up input source: ${inputType}`);
            return stream;

        } catch (error) {
            console.error(`Failed to setup input source ${inputType}:`, error);
            throw error;
        }
    }

    /**
     * Create audio processing chain for a specific input source
     */
    async createInputProcessingChain(inputType, stream) {
        if (!this.audioContext || !stream) return;

        try {
            // Create source node
            const source = this.audioContext.createMediaStreamSource(stream);

            // Create processing nodes
            const inputGain = this.audioContext.createGain();
            const compressor = this.audioContext.createDynamicsCompressor();
            const filter = this.audioContext.createBiquadFilter();

            // Configure based on input type
            if (inputType === this.inputTypes.MICROPHONE) {
                // Voice processing chain
                compressor.threshold.value = -24;
                compressor.knee.value = 30;
                compressor.ratio.value = 4;
                compressor.attack.value = 0.003;
                compressor.release.value = 0.25;

                filter.type = 'highpass';
                filter.frequency.value = 100; // Remove low-frequency noise
            } else if (inputType === this.inputTypes.MEDIA_STREAMING) {
                // Media streaming chain (minimal processing)
                compressor.threshold.value = -12;
                compressor.knee.value = 15;
                compressor.ratio.value = 2;

                filter.type = 'allpass'; // No filtering for media
            } else {
                // Generic processing for virtual/system audio
                compressor.threshold.value = -18;
                compressor.knee.value = 20;
                compressor.ratio.value = 3;

                filter.type = 'peaking';
                filter.frequency.value = 1000;
                filter.Q.value = 1;
                filter.gain.value = 0;
            }

            // Create ducking chain if ducking processor is available
            let finalOutputNode = inputGain;
            if (this.duckingProcessor) {
                const duckingOutput = this.duckingProcessor.createDuckingChain(inputType, inputGain);
                if (duckingOutput) {
                    finalOutputNode = duckingOutput;
                }
            }

            // Connect the processing chain
            source.connect(filter);
            filter.connect(compressor);
            compressor.connect(inputGain);
            finalOutputNode.connect(this.inputMixerNode);

            // Set initial volume
            const settings = this.inputSettings.get(inputType);
            inputGain.gain.value = settings.muted ? 0 : settings.volume;

            // Store the processing chain
            this.inputSources.set(inputType, {
                source,
                inputGain,
                compressor,
                filter,
                stream,
                duckingOutput: finalOutputNode
            });

            console.log(`Created processing chain for ${inputType}`);

        } catch (error) {
            console.error(`Failed to create processing chain for ${inputType}:`, error);
        }
    }

    /**
     * Stop a specific input source
     */
    async stopInputSource(inputType) {
        try {
            // Stop the stream
            const stream = this.inputStreams.get(inputType);
            if (stream) {
                stream.getTracks().forEach(track => track.stop());
                this.inputStreams.delete(inputType);
            }

            // Disconnect audio nodes
            const sourceChain = this.inputSources.get(inputType);
            if (sourceChain) {
                sourceChain.source.disconnect();
                sourceChain.inputGain.disconnect();
                sourceChain.compressor.disconnect();
                sourceChain.filter.disconnect();
                if (sourceChain.duckingOutput && sourceChain.duckingOutput !== sourceChain.inputGain) {
                    sourceChain.duckingOutput.disconnect();
                }
                this.inputSources.delete(inputType);
            }

            // Remove ducking chain if it exists
            if (this.duckingProcessor) {
                this.duckingProcessor.removeDuckingChain(inputType);
            }

            // Update settings
            const settings = this.inputSettings.get(inputType);
            if (settings) {
                settings.enabled = false;
                this.inputSettings.set(inputType, settings);
            }

            console.log(`Stopped input source: ${inputType}`);

        } catch (error) {
            console.error(`Failed to stop input source ${inputType}:`, error);
        }
    }

    /**
     * Set volume for a specific input source
     */
    setInputVolume(inputType, volume) {
        const settings = this.inputSettings.get(inputType);
        if (settings) {
            settings.volume = Math.max(0, Math.min(1, volume));
            this.inputSettings.set(inputType, settings);

            const sourceChain = this.inputSources.get(inputType);
            if (sourceChain && !settings.muted) {
                sourceChain.inputGain.gain.value = settings.volume;
            }
        }
    }

    /**
     * Mute/unmute a specific input source
     */
    setInputMute(inputType, muted) {
        const settings = this.inputSettings.get(inputType);
        if (settings) {
            settings.muted = muted;
            this.inputSettings.set(inputType, settings);

            const sourceChain = this.inputSources.get(inputType);
            if (sourceChain) {
                sourceChain.inputGain.gain.value = muted ? 0 : settings.volume;
            }
        }
    }

    /**
     * Get available virtual audio devices (e.g., Loopback, VB-Cable, etc.)
     */
    getVirtualAudioDevices() {
        return this.audioDevices.inputs.filter(device => {
            const name = device.label.toLowerCase();
            return name.includes('virtual') ||
                   name.includes('loopback') ||
                   name.includes('vb-cable') ||
                   name.includes('cable') ||
                   name.includes('aggregate') ||
                   name.includes('multi-output') ||
                   name.includes('blackhole') ||
                   name.includes('soundflower');
        });
    }

    /**
     * Get status of all input sources
     */
    getInputSourcesStatus() {
        const status = {};
        Object.values(this.inputTypes).forEach(inputType => {
            const settings = this.inputSettings.get(inputType);
            const stream = this.inputStreams.get(inputType);
            const deviceId = this.selectedInputDevices.get(inputType);

            status[inputType] = {
                enabled: settings?.enabled || false,
                volume: settings?.volume || 1.0,
                muted: settings?.muted || false,
                hasStream: !!stream,
                deviceId: deviceId || null,
                deviceName: this.getDeviceName(deviceId)
            };
        });
        return status;
    }

    /**
     * Get device name by ID
     */
    getDeviceName(deviceId) {
        if (!deviceId) return 'Default';
        const device = this.audioDevices.inputs.find(d => d.id === deviceId);
        return device ? device.label : 'Unknown Device';
    }

    /**
     * Save multi-input settings to localStorage
     */
    saveMultiInputSettings() {
        const settings = {
            selectedDevices: Object.fromEntries(this.selectedInputDevices),
            inputSettings: Object.fromEntries(this.inputSettings)
        };
        localStorage.setItem('voicelink_multi_input_settings', JSON.stringify(settings));
        console.log('Multi-input settings saved');
    }

    /**
     * Load multi-input settings from localStorage
     */
    loadMultiInputSettings() {
        try {
            const saved = localStorage.getItem('voicelink_multi_input_settings');
            if (saved) {
                const settings = JSON.parse(saved);

                if (settings.selectedDevices) {
                    this.selectedInputDevices = new Map(Object.entries(settings.selectedDevices));
                }

                if (settings.inputSettings) {
                    Object.entries(settings.inputSettings).forEach(([inputType, inputSetting]) => {
                        this.inputSettings.set(inputType, inputSetting);
                    });
                }

                console.log('Multi-input settings loaded');
            }
        } catch (error) {
            console.error('Failed to load multi-input settings:', error);
        }
    }
}

// Export for use in other modules
window.AudioEngine = AudioEngine;
