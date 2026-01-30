class PASystemManager {
    constructor(socket, audioEngine, spatialAudio, webrtcManager) {
        this.socket = socket;
        this.audioEngine = audioEngine;
        this.spatialAudio = spatialAudio;
        this.webrtcManager = webrtcManager;

        // User permissions
        this.userRole = 'user'; // 'admin', 'moderator', 'user'
        this.permissions = {
            globalBroadcast: false,
            directMessage: false,
            intercomAccess: false,
            emergencyBroadcast: false
        };

        // Push-to-talk configuration
        this.pttConfig = {
            global: {
                key: 'ControlLeft', // Ctrl key for global announcements
                altKey: false,
                shiftKey: false,
                metaKey: false,
                enabled: true
            },
            direct: {
                key: 'MetaLeft', // Cmd/Windows key for direct messages
                altKey: false,
                shiftKey: false,
                metaKey: false,
                enabled: true
            },
            intercom: {
                key: 'AltLeft', // Alt key for intercom
                altKey: false,
                shiftKey: true, // Alt+Shift for intercom
                metaKey: false,
                enabled: true
            },
            emergency: {
                key: 'F1', // F1 for emergency broadcasts
                altKey: false,
                shiftKey: false,
                metaKey: false,
                enabled: true
            },
            whisper: {
                key: 'ShiftLeft', // Shift key for whisper mode
                altKey: false,
                shiftKey: false,
                metaKey: false,
                enabled: true
            }
        };

        // Whisper mode configuration
        this.whisperConfig = {
            maxDistance: 5.0, // Maximum distance for whisper detection
            falloffRate: 2.0, // Audio falloff rate
            autoDetect: true, // Auto-detect nearby users
            requireProximity: true, // Require physical proximity
            muteGlobalWhileWhispering: true // Auto-mute global transmission
        };

        // Whisper state
        this.isWhispering = false;
        this.whisperTargets = [];
        this.previousGlobalMuteState = false;

        // Broadcast state
        this.isTransmitting = false;
        this.currentTransmissionType = null;
        this.targetUsers = [];
        this.recordingStartTime = null;

        // Audio processing for broadcasts
        this.broadcastProcessor = null;
        this.intercomEffects = {
            lowpass: null,
            highpass: null,
            compression: null,
            distortion: null,
            reverb: null
        };

        // Visual indicators
        this.transmissionIndicator = null;
        this.recordingVisualizer = null;

        this.init();
    }

    init() {
        this.setupKeyboardListeners();
        this.setupAudioProcessing();
        this.createTransmissionUI();
        this.setupSocketListeners();
        this.loadPTTConfiguration();
    }

    // Setup keyboard listeners for push-to-talk
    setupKeyboardListeners() {
        document.addEventListener('keydown', (event) => {
            if (this.isKeyMatch(event, 'whisper')) {
                this.startWhisperMode(event);
            } else if (this.isKeyMatch(event, 'global') && this.permissions.globalBroadcast) {
                this.startGlobalBroadcast(event);
            } else if (this.isKeyMatch(event, 'direct') && this.permissions.directMessage) {
                this.startDirectMessage(event);
            } else if (this.isKeyMatch(event, 'intercom') && this.permissions.intercomAccess) {
                this.startIntercomTransmission(event);
            } else if (this.isKeyMatch(event, 'emergency') && this.permissions.emergencyBroadcast) {
                this.startEmergencyBroadcast(event);
            }
        });

        document.addEventListener('keyup', (event) => {
            if (this.isWhispering && this.isKeyMatch(event, 'whisper')) {
                this.stopWhisperMode();
            } else if (this.isTransmitting) {
                if (this.isKeyMatch(event, this.currentTransmissionType)) {
                    this.stopTransmission();
                }
            }
        });

        // Handle window focus loss (stop transmission)
        window.addEventListener('blur', () => {
            if (this.isTransmitting) {
                this.stopTransmission();
            }
        });
    }

    // Check if keyboard event matches PTT configuration
    isKeyMatch(event, type) {
        const config = this.pttConfig[type];
        if (!config.enabled) return false;

        return (
            event.code === config.key &&
            event.altKey === config.altKey &&
            event.shiftKey === config.shiftKey &&
            event.metaKey === config.metaKey
        );
    }

    // Setup audio processing for broadcasts
    setupAudioProcessing() {
        if (!this.audioEngine.audioContext) return;

        const audioContext = this.audioEngine.audioContext;

        // Create broadcast audio processor
        this.broadcastProcessor = audioContext.createScriptProcessor(4096, 1, 1);

        // Setup intercom effects
        this.intercomEffects.lowpass = audioContext.createBiquadFilter();
        this.intercomEffects.lowpass.type = 'lowpass';
        this.intercomEffects.lowpass.frequency.value = 3000;
        this.intercomEffects.lowpass.Q.value = 0.7;

        this.intercomEffects.highpass = audioContext.createBiquadFilter();
        this.intercomEffects.highpass.type = 'highpass';
        this.intercomEffects.highpass.frequency.value = 300;
        this.intercomEffects.highpass.Q.value = 0.7;

        this.intercomEffects.compression = audioContext.createDynamicsCompressor();
        this.intercomEffects.compression.threshold.value = -24;
        this.intercomEffects.compression.knee.value = 30;
        this.intercomEffects.compression.ratio.value = 12;
        this.intercomEffects.compression.attack.value = 0.003;
        this.intercomEffects.compression.release.value = 0.25;

        // Create convolver for intercom reverb
        this.intercomEffects.reverb = audioContext.createConvolver();
        this.createIntercomImpulseResponse();

        // Connect effects chain for intercom
        this.intercomEffects.highpass.connect(this.intercomEffects.lowpass);
        this.intercomEffects.lowpass.connect(this.intercomEffects.compression);
        this.intercomEffects.compression.connect(this.intercomEffects.reverb);
    }

    // Create impulse response for intercom reverb
    createIntercomImpulseResponse() {
        const audioContext = this.audioEngine.audioContext;
        const sampleRate = audioContext.sampleRate;
        const length = sampleRate * 0.5; // 0.5 seconds
        const impulse = audioContext.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const channelData = impulse.getChannelData(channel);
            for (let i = 0; i < length; i++) {
                const decay = Math.pow(1 - (i / length), 2);
                channelData[i] = (Math.random() * 2 - 1) * decay * 0.1;
            }
        }

        this.intercomEffects.reverb.buffer = impulse;
    }

    // Create transmission UI elements
    createTransmissionUI() {
        // Transmission indicator
        this.transmissionIndicator = document.createElement('div');
        this.transmissionIndicator.id = 'transmission-indicator';
        this.transmissionIndicator.className = 'transmission-indicator hidden';
        this.transmissionIndicator.innerHTML = `
            <div class="transmission-content">
                <div class="transmission-icon">📡</div>
                <div class="transmission-text">
                    <div class="transmission-type">PA System Active</div>
                    <div class="transmission-target">Global Announcement</div>
                    <div class="transmission-timer">00:00</div>
                </div>
                <div class="transmission-controls">
                    <button id="emergency-stop-transmission" class="emergency-stop">Emergency Stop</button>
                </div>
            </div>
        `;

        // Recording visualizer
        this.recordingVisualizer = document.createElement('canvas');
        this.recordingVisualizer.id = 'recording-visualizer';
        this.recordingVisualizer.className = 'recording-visualizer hidden';
        this.recordingVisualizer.width = 300;
        this.recordingVisualizer.height = 100;

        document.body.appendChild(this.transmissionIndicator);
        document.body.appendChild(this.recordingVisualizer);

        // Emergency stop button
        document.getElementById('emergency-stop-transmission')?.addEventListener('click', () => {
            this.stopTransmission();
        });

        this.addTransmissionStyles();
    }

    // Add CSS styles for transmission UI
    addTransmissionStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .transmission-indicator {
                position: fixed;
                top: 20px;
                left: 50%;
                transform: translateX(-50%);
                background: linear-gradient(135deg, #ff4444, #cc0000);
                color: white;
                padding: 15px 25px;
                border-radius: 10px;
                box-shadow: 0 4px 20px rgba(255, 68, 68, 0.5);
                z-index: 10000;
                animation: pulse 2s infinite;
                min-width: 300px;
                text-align: center;
            }

            .transmission-indicator.hidden {
                display: none;
            }

            .transmission-indicator.intercom {
                background: linear-gradient(135deg, #4444ff, #0000cc);
                box-shadow: 0 4px 20px rgba(68, 68, 255, 0.5);
            }

            .transmission-indicator.direct {
                background: linear-gradient(135deg, #44ff44, #00cc00);
                box-shadow: 0 4px 20px rgba(68, 255, 68, 0.5);
            }

            .transmission-indicator.emergency {
                background: linear-gradient(135deg, #ff8800, #ff4400);
                box-shadow: 0 4px 20px rgba(255, 136, 0, 0.8);
                animation: emergency-pulse 0.5s infinite;
            }

            @keyframes pulse {
                0%, 100% { transform: translateX(-50%) scale(1); }
                50% { transform: translateX(-50%) scale(1.05); }
            }

            @keyframes emergency-pulse {
                0%, 100% { transform: translateX(-50%) scale(1); opacity: 1; }
                50% { transform: translateX(-50%) scale(1.1); opacity: 0.8; }
            }

            .transmission-content {
                display: flex;
                align-items: center;
                gap: 15px;
            }

            .transmission-icon {
                font-size: 24px;
                animation: rotate 2s linear infinite;
            }

            @keyframes rotate {
                from { transform: rotate(0deg); }
                to { transform: rotate(360deg); }
            }

            .transmission-text {
                flex: 1;
                text-align: left;
            }

            .transmission-type {
                font-weight: bold;
                font-size: 16px;
                margin-bottom: 5px;
            }

            .transmission-target {
                font-size: 12px;
                opacity: 0.9;
                margin-bottom: 3px;
            }

            .transmission-timer {
                font-family: monospace;
                font-size: 14px;
                font-weight: bold;
            }

            .emergency-stop {
                background: rgba(255, 255, 255, 0.2);
                border: 1px solid rgba(255, 255, 255, 0.3);
                color: white;
                padding: 8px 12px;
                border-radius: 5px;
                cursor: pointer;
                font-size: 12px;
                transition: background 0.3s ease;
            }

            .emergency-stop:hover {
                background: rgba(255, 255, 255, 0.3);
            }

            .recording-visualizer {
                position: fixed;
                bottom: 20px;
                left: 50%;
                transform: translateX(-50%);
                background: rgba(0, 0, 0, 0.8);
                border-radius: 10px;
                padding: 10px;
                z-index: 9999;
            }

            .recording-visualizer.hidden {
                display: none;
            }

            .broadcast-controls {
                position: fixed;
                bottom: 20px;
                right: 20px;
                background: rgba(0, 0, 0, 0.9);
                border-radius: 10px;
                padding: 15px;
                color: white;
                z-index: 9998;
                min-width: 250px;
            }

            .broadcast-controls.hidden {
                display: none;
            }

            .ptt-key-indicator {
                display: inline-block;
                background: rgba(255, 255, 255, 0.2);
                padding: 2px 6px;
                border-radius: 3px;
                margin: 0 2px;
                font-family: monospace;
                font-size: 11px;
            }
        `;
        document.head.appendChild(style);
    }

    // Setup socket listeners for broadcast events
    setupSocketListeners() {
        this.socket.on('user-role-updated', (data) => {
            this.updateUserRole(data.role, data.permissions);
        });

        this.socket.on('broadcast-received', (data) => {
            this.handleIncomingBroadcast(data);
        });

        this.socket.on('direct-message-received', (data) => {
            this.handleIncomingDirectMessage(data);
        });

        this.socket.on('intercom-received', (data) => {
            this.handleIncomingIntercom(data);
        });

        this.socket.on('emergency-broadcast-received', (data) => {
            this.handleIncomingEmergencyBroadcast(data);
        });
    }

    // Update user role and permissions
    updateUserRole(role, permissions) {
        this.userRole = role;
        this.permissions = { ...this.permissions, ...permissions };

        // Update UI to show available broadcast options
        this.updateBroadcastControls();
    }

    // Start global broadcast
    async startGlobalBroadcast(event) {
        if (this.isTransmitting) return;

        event.preventDefault();
        event.stopPropagation();

        try {
            await this.startTransmission('global', []);
            this.showTransmissionIndicator('Global Announcement', 'global');
        } catch (error) {
            console.error('Failed to start global broadcast:', error);
        }
    }

    // Start direct message to specific user(s)
    async startDirectMessage(event) {
        if (this.isTransmitting) return;

        event.preventDefault();
        event.stopPropagation();

        // Get target users (could be from selected users in UI)
        const targetUsers = this.getSelectedUsers();
        if (targetUsers.length === 0) {
            this.showUserSelectionDialog('direct');
            return;
        }

        try {
            await this.startTransmission('direct', targetUsers);
            const targetNames = targetUsers.map(u => u.name).join(', ');
            this.showTransmissionIndicator(`Direct to: ${targetNames}`, 'direct');
        } catch (error) {
            console.error('Failed to start direct message:', error);
        }
    }

    // Start intercom transmission with effects
    async startIntercomTransmission(event) {
        if (this.isTransmitting) return;

        event.preventDefault();
        event.stopPropagation();

        try {
            await this.startTransmission('intercom', []);
            this.showTransmissionIndicator('Intercom System', 'intercom');
        } catch (error) {
            console.error('Failed to start intercom transmission:', error);
        }
    }

    // Start emergency broadcast
    async startEmergencyBroadcast(event) {
        if (this.isTransmitting) return;

        event.preventDefault();
        event.stopPropagation();

        try {
            // Emergency broadcasts override everything
            await this.startTransmission('emergency', []);
            this.showTransmissionIndicator('EMERGENCY BROADCAST', 'emergency');
        } catch (error) {
            console.error('Failed to start emergency broadcast:', error);
        }
    }

    // Start whisper mode for proximity-based communication
    async startWhisperMode(event) {
        if (this.isWhispering || this.isTransmitting) return;

        event.preventDefault();
        event.stopPropagation();

        try {
            // Find nearby users based on spatial positions
            const nearbyUsers = this.findNearbyUsers();

            if (nearbyUsers.length === 0) {
                this.showWhisperMessage('No nearby users found for whispering');
                return;
            }

            this.isWhispering = true;
            this.whisperTargets = nearbyUsers;

            // Mute global transmission if configured
            if (this.whisperConfig.muteGlobalWhileWhispering) {
                this.previousGlobalMuteState = this.webrtcManager?.isLocalMuted() || false;
                this.webrtcManager?.setGlobalMuted(true);
            }

            // Start whisper transmission
            await this.startWhisperTransmission();

            const targetNames = nearbyUsers.map(u => u.name).join(', ');
            this.showWhisperIndicator(`Whispering to: ${targetNames}`);

        } catch (error) {
            console.error('Failed to start whisper mode:', error);
        }
    }

    // Stop whisper mode
    stopWhisperMode() {
        if (!this.isWhispering) return;

        // Restore global transmission state
        if (this.whisperConfig.muteGlobalWhileWhispering) {
            this.webrtcManager?.setGlobalMuted(this.previousGlobalMuteState);
        }

        // Stop whisper transmission
        this.stopWhisperTransmission();

        this.isWhispering = false;
        this.whisperTargets = [];
        this.hideWhisperIndicator();

        console.log('Whisper mode ended');
    }

    // Find nearby users based on spatial positions
    findNearbyUsers() {
        const nearbyUsers = [];
        const currentUser = window.app?.currentUser;

        if (!currentUser || !this.spatialAudio) {
            return nearbyUsers;
        }

        const currentPosition = this.spatialAudio.getUserPosition(currentUser.id) || { x: 0, y: 0, z: 0 };

        // Check all users in the room
        const allUsers = Array.from(window.app?.users?.values() || []);

        allUsers.forEach(user => {
            if (user.id === currentUser.id) return;

            const userPosition = this.spatialAudio.getUserPosition(user.id) || { x: 0, y: 0, z: 0 };
            const distance = this.calculateDistance(currentPosition, userPosition);

            if (distance <= this.whisperConfig.maxDistance) {
                nearbyUsers.push({
                    ...user,
                    distance: distance,
                    position: userPosition
                });
            }
        });

        // Sort by distance (closest first)
        nearbyUsers.sort((a, b) => a.distance - b.distance);

        return nearbyUsers;
    }

    // Calculate 3D distance between two positions
    calculateDistance(pos1, pos2) {
        const dx = pos1.x - pos2.x;
        const dy = pos1.y - pos2.y;
        const dz = pos1.z - pos2.z;
        return Math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    // Start whisper transmission with binaural audio
    async startWhisperTransmission() {
        const constraints = {
            audio: {
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true, // Keep AGC for whisper
                sampleRate: 48000,
                channelCount: 1
            }
        };

        const stream = await navigator.mediaDevices.getUserMedia(constraints);

        // Apply whisper processing (softer, more intimate sound)
        const processedStream = this.applyWhisperProcessing(stream);

        // Send to nearby users with proximity-based volume
        for (const user of this.whisperTargets) {
            const volumeMultiplier = this.calculateWhisperVolume(user.distance);

            await this.webrtcManager.sendDirectStream(user.id, processedStream, {
                type: 'whisper',
                binaural: true,
                volume: volumeMultiplier,
                position: user.position,
                priority: 'low' // Low priority so it doesn't interrupt other audio
            });
        }
    }

    // Apply whisper-specific audio processing
    applyWhisperProcessing(stream) {
        const audioContext = this.audioEngine.audioContext;
        const source = audioContext.createMediaStreamSource(stream);

        // Create whisper effect chain
        const lowpass = audioContext.createBiquadFilter();
        lowpass.type = 'lowpass';
        lowpass.frequency.value = 2000; // Soften high frequencies
        lowpass.Q.value = 0.5;

        const compressor = audioContext.createDynamicsCompressor();
        compressor.threshold.value = -30; // Gentle compression
        compressor.knee.value = 10;
        compressor.ratio.value = 3;
        compressor.attack.value = 0.01;
        compressor.release.value = 0.5;

        const gainNode = audioContext.createGain();
        gainNode.gain.value = 0.7; // Reduce overall volume for whisper

        // Connect effect chain
        source.connect(lowpass);
        lowpass.connect(compressor);
        compressor.connect(gainNode);

        // Create destination and return stream
        const destination = audioContext.createMediaStreamDestination();
        gainNode.connect(destination);

        return destination.stream;
    }

    // Calculate volume based on distance for whisper
    calculateWhisperVolume(distance) {
        const maxVolume = 1.0;
        const minVolume = 0.1;

        if (distance <= 1.0) {
            return maxVolume;
        }

        const volumeMultiplier = Math.max(
            minVolume,
            maxVolume * Math.pow(1.0 / distance, this.whisperConfig.falloffRate)
        );

        return volumeMultiplier;
    }

    // Stop whisper transmission
    stopWhisperTransmission() {
        // Stop sending whisper streams to target users
        for (const user of this.whisperTargets) {
            this.webrtcManager?.stopDirectStream?.(user.id, 'whisper');
        }
    }

    // Show whisper indicator
    showWhisperIndicator(text) {
        // Create or update whisper indicator
        let indicator = document.getElementById('whisper-indicator');

        if (!indicator) {
            indicator = document.createElement('div');
            indicator.id = 'whisper-indicator';
            indicator.className = 'whisper-indicator';
            document.body.appendChild(indicator);
        }

        indicator.innerHTML = `
            <div class="whisper-content">
                <div class="whisper-icon">🤫</div>
                <div class="whisper-text">${text}</div>
                <div class="whisper-distance">Range: ${this.whisperConfig.maxDistance}m</div>
            </div>
        `;

        indicator.classList.remove('hidden');
    }

    // Hide whisper indicator
    hideWhisperIndicator() {
        const indicator = document.getElementById('whisper-indicator');
        if (indicator) {
            indicator.classList.add('hidden');
        }
    }

    // Show whisper message
    showWhisperMessage(message) {
        // Create temporary message
        const messageDiv = document.createElement('div');
        messageDiv.className = 'whisper-message';
        messageDiv.textContent = message;

        document.body.appendChild(messageDiv);

        // Auto-remove after 3 seconds
        setTimeout(() => {
            if (messageDiv.parentElement) {
                messageDiv.remove();
            }
        }, 3000);
    }

    // Start transmission (common logic)
    async startTransmission(type, targetUsers) {
        this.isTransmitting = true;
        this.currentTransmissionType = type;
        this.targetUsers = targetUsers;
        this.recordingStartTime = Date.now();

        // Get user media with high quality settings for broadcasts
        const constraints = {
            audio: {
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: false,
                sampleRate: 48000,
                channelCount: 1
            }
        };

        const stream = await navigator.mediaDevices.getUserMedia(constraints);

        // Apply audio processing based on transmission type
        const processedStream = this.applyTransmissionProcessing(stream, type);

        // Send to appropriate targets
        await this.sendTransmission(processedStream, type, targetUsers);

        // Start recording visualizer
        this.startRecordingVisualizer(processedStream);

        // Start transmission timer
        this.startTransmissionTimer();

        // Notify server about transmission start
        this.socket.emit('transmission-started', {
            type,
            targetUsers: targetUsers.map(u => u.id),
            timestamp: this.recordingStartTime
        });
    }

    // Apply audio processing based on transmission type
    applyTransmissionProcessing(stream, type) {
        const audioContext = this.audioEngine.audioContext;
        const source = audioContext.createMediaStreamSource(stream);
        let processedSource = source;

        switch (type) {
            case 'intercom':
                // Apply intercom effects
                processedSource.connect(this.intercomEffects.highpass);
                processedSource = this.intercomEffects.reverb;
                break;

            case 'emergency':
                // Apply emergency processing (compression + slight distortion)
                const emergencyCompressor = audioContext.createDynamicsCompressor();
                emergencyCompressor.threshold.value = -18;
                emergencyCompressor.knee.value = 40;
                emergencyCompressor.ratio.value = 16;
                emergencyCompressor.attack.value = 0.001;
                emergencyCompressor.release.value = 0.1;

                processedSource.connect(emergencyCompressor);
                processedSource = emergencyCompressor;
                break;

            case 'global':
            case 'direct':
                // High quality processing with minimal effects
                const globalCompressor = audioContext.createDynamicsCompressor();
                globalCompressor.threshold.value = -12;
                globalCompressor.knee.value = 20;
                globalCompressor.ratio.value = 4;
                globalCompressor.attack.value = 0.003;
                globalCompressor.release.value = 0.25;

                processedSource.connect(globalCompressor);
                processedSource = globalCompressor;
                break;
        }

        // Create destination and return new stream
        const destination = audioContext.createMediaStreamDestination();
        processedSource.connect(destination);

        return destination.stream;
    }

    // Send transmission to targets
    async sendTransmission(stream, type, targetUsers) {
        switch (type) {
            case 'global':
                // Send to all users in the room
                await this.webrtcManager.broadcastToAll(stream, {
                    type: 'global_broadcast',
                    binaural: true,
                    priority: 'high'
                });
                break;

            case 'direct':
                // Send to specific users
                for (const user of targetUsers) {
                    await this.webrtcManager.sendDirectStream(user.id, stream, {
                        type: 'direct_message',
                        binaural: true,
                        priority: 'medium'
                    });
                }
                break;

            case 'intercom':
                // Send with intercom positioning (overhead/ambient)
                await this.webrtcManager.broadcastToAll(stream, {
                    type: 'intercom',
                    binaural: true,
                    position: { x: 0, y: 5, z: 0 }, // Overhead position
                    priority: 'high'
                });
                break;

            case 'emergency':
                // Emergency override - interrupts all other audio
                await this.webrtcManager.emergencyBroadcast(stream, {
                    type: 'emergency_broadcast',
                    binaural: true,
                    override: true,
                    priority: 'critical'
                });
                break;
        }
    }

    // Stop transmission
    stopTransmission() {
        if (!this.isTransmitting) return;

        const duration = Date.now() - this.recordingStartTime;

        // Stop audio processing
        this.stopRecordingVisualizer();

        // Hide transmission indicator
        this.hideTransmissionIndicator();

        // Notify server
        this.socket.emit('transmission-ended', {
            type: this.currentTransmissionType,
            duration,
            timestamp: Date.now()
        });

        // Reset state
        this.isTransmitting = false;
        this.currentTransmissionType = null;
        this.targetUsers = [];
        this.recordingStartTime = null;

        console.log(`Transmission ended. Duration: ${duration}ms`);
    }

    // Show transmission indicator
    showTransmissionIndicator(targetText, type) {
        this.transmissionIndicator.classList.remove('hidden', 'global', 'direct', 'intercom', 'emergency');
        this.transmissionIndicator.classList.add(type);

        const targetElement = this.transmissionIndicator.querySelector('.transmission-target');
        const typeElement = this.transmissionIndicator.querySelector('.transmission-type');

        targetElement.textContent = targetText;
        typeElement.textContent = this.getTransmissionTypeText(type);
    }

    // Hide transmission indicator
    hideTransmissionIndicator() {
        this.transmissionIndicator.classList.add('hidden');
    }

    // Get transmission type display text
    getTransmissionTypeText(type) {
        const typeTexts = {
            global: 'PA System - Global',
            direct: 'PA System - Direct',
            intercom: 'PA System - Intercom',
            emergency: 'PA SYSTEM - EMERGENCY'
        };
        return typeTexts[type] || 'PA System Active';
    }

    // Start transmission timer
    startTransmissionTimer() {
        const timerElement = this.transmissionIndicator.querySelector('.transmission-timer');

        const updateTimer = () => {
            if (!this.isTransmitting) return;

            const elapsed = Math.floor((Date.now() - this.recordingStartTime) / 1000);
            const minutes = Math.floor(elapsed / 60).toString().padStart(2, '0');
            const seconds = (elapsed % 60).toString().padStart(2, '0');

            timerElement.textContent = `${minutes}:${seconds}`;

            if (this.isTransmitting) {
                setTimeout(updateTimer, 1000);
            }
        };

        updateTimer();
    }

    // Start recording visualizer
    startRecordingVisualizer(stream) {
        const canvas = this.recordingVisualizer;
        const ctx = canvas.getContext('2d');
        const audioContext = this.audioEngine.audioContext;

        canvas.classList.remove('hidden');

        const source = audioContext.createMediaStreamSource(stream);
        const analyser = audioContext.createAnalyser();
        analyser.fftSize = 256;
        analyser.smoothingTimeConstant = 0.8;

        source.connect(analyser);

        const bufferLength = analyser.frequencyBinCount;
        const dataArray = new Uint8Array(bufferLength);

        const draw = () => {
            if (!this.isTransmitting) return;

            analyser.getByteFrequencyData(dataArray);

            ctx.clearRect(0, 0, canvas.width, canvas.height);

            // Draw frequency bars
            const barWidth = canvas.width / bufferLength * 2;
            let x = 0;

            for (let i = 0; i < bufferLength; i++) {
                const barHeight = (dataArray[i] / 255) * canvas.height * 0.8;

                const hue = (i / bufferLength) * 120; // Green to red
                ctx.fillStyle = `hsl(${hue}, 80%, 60%)`;

                ctx.fillRect(x, canvas.height - barHeight, barWidth, barHeight);
                x += barWidth + 1;
            }

            // Draw transmission type indicator
            ctx.fillStyle = 'white';
            ctx.font = '12px Arial';
            ctx.textAlign = 'center';
            ctx.fillText(
                this.getTransmissionTypeText(this.currentTransmissionType),
                canvas.width / 2,
                20
            );

            if (this.isTransmitting) {
                requestAnimationFrame(draw);
            }
        };

        draw();
    }

    // Stop recording visualizer
    stopRecordingVisualizer() {
        this.recordingVisualizer.classList.add('hidden');
    }

    // Get selected users for direct messaging
    getSelectedUsers() {
        // This would integrate with the user list UI to get selected users
        // For now, return empty array - would be implemented with UI selection
        return [];
    }

    // Show user selection dialog for direct messaging
    showUserSelectionDialog(type) {
        // Create a quick user selection dialog
        const dialog = document.createElement('div');
        dialog.className = 'user-selection-dialog';
        dialog.innerHTML = `
            <div class="dialog-content">
                <h3>Select Users for ${type === 'direct' ? 'Direct Message' : 'Broadcast'}</h3>
                <div class="user-selection-list" id="user-selection-list">
                    <!-- Users will be populated here -->
                </div>
                <div class="dialog-buttons">
                    <button id="confirm-user-selection" class="button primary">Send Message</button>
                    <button id="cancel-user-selection" class="button secondary">Cancel</button>
                </div>
            </div>
        `;

        document.body.appendChild(dialog);

        // Populate users
        this.populateUserSelectionList();

        // Event listeners
        document.getElementById('confirm-user-selection').addEventListener('click', () => {
            const selectedUsers = this.getSelectedUsersFromDialog();
            dialog.remove();

            if (selectedUsers.length > 0) {
                if (type === 'direct') {
                    this.startDirectMessage({ preventDefault: () => {}, stopPropagation: () => {} });
                }
            }
        });

        document.getElementById('cancel-user-selection').addEventListener('click', () => {
            dialog.remove();
        });
    }

    // Populate user selection list
    populateUserSelectionList() {
        const listElement = document.getElementById('user-selection-list');
        if (!listElement) return;

        // Get users from the current room
        const users = Array.from(window.app?.users?.values() || []);

        listElement.innerHTML = users.map(user => `
            <label class="user-selection-item">
                <input type="checkbox" value="${user.id}" class="user-checkbox">
                <span class="user-name">${user.name}</span>
                <span class="user-role">${user.role || 'User'}</span>
            </label>
        `).join('');
    }

    // Get selected users from dialog
    getSelectedUsersFromDialog() {
        const checkboxes = document.querySelectorAll('.user-checkbox:checked');
        const selectedIds = Array.from(checkboxes).map(cb => cb.value);

        return Array.from(window.app?.users?.values() || [])
            .filter(user => selectedIds.includes(user.id));
    }

    // Update broadcast controls UI
    updateBroadcastControls() {
        // Remove existing controls
        const existingControls = document.getElementById('broadcast-controls');
        if (existingControls) {
            existingControls.remove();
        }

        // Create new controls based on permissions
        if (this.hasAnyBroadcastPermission()) {
            this.createBroadcastControlsUI();
        }
    }

    // Check if user has any broadcast permissions
    hasAnyBroadcastPermission() {
        return Object.values(this.permissions).some(permission => permission);
    }

    // Create broadcast controls UI
    createBroadcastControlsUI() {
        const controlsHTML = `
            <div id="broadcast-controls" class="broadcast-controls">
                <h4>🔊 PA System Controls</h4>
                <div class="broadcast-options">
                    ${this.permissions.globalBroadcast ? `
                        <div class="broadcast-option">
                            <span>📢 Global Announcement</span>
                            <span class="ptt-key-indicator">${this.getPTTKeyText('global')}</span>
                        </div>
                    ` : ''}
                    ${this.permissions.directMessage ? `
                        <div class="broadcast-option">
                            <span>📞 Direct Message</span>
                            <span class="ptt-key-indicator">${this.getPTTKeyText('direct')}</span>
                        </div>
                    ` : ''}
                    ${this.permissions.intercomAccess ? `
                        <div class="broadcast-option">
                            <span>📻 Intercom System</span>
                            <span class="ptt-key-indicator">${this.getPTTKeyText('intercom')}</span>
                        </div>
                    ` : ''}
                    ${this.permissions.emergencyBroadcast ? `
                        <div class="broadcast-option emergency">
                            <span>🚨 Emergency Alert</span>
                            <span class="ptt-key-indicator">${this.getPTTKeyText('emergency')}</span>
                        </div>
                    ` : ''}
                </div>
                <div class="broadcast-status">
                    <small>Hold key to transmit announcement, release to end</small>
                </div>
            </div>
        `;

        document.body.insertAdjacentHTML('beforeend', controlsHTML);
    }

    // Get PTT key text for display
    getPTTKeyText(type) {
        const config = this.pttConfig[type];
        let keyText = config.key.replace('Left', '').replace('Right', '');

        if (config.shiftKey) keyText = 'Shift+' + keyText;
        if (config.altKey) keyText = 'Alt+' + keyText;
        if (config.metaKey) keyText = 'Cmd+' + keyText;

        return keyText;
    }

    // Handle incoming broadcasts
    handleIncomingBroadcast(data) {
        console.log('Incoming global broadcast:', data);
        this.playIncomingAudio(data, 'global');
    }

    handleIncomingDirectMessage(data) {
        console.log('Incoming direct message:', data);
        this.playIncomingAudio(data, 'direct');
    }

    handleIncomingIntercom(data) {
        console.log('Incoming intercom:', data);
        this.playIncomingAudio(data, 'intercom');
    }

    handleIncomingEmergencyBroadcast(data) {
        console.log('Incoming emergency broadcast:', data);
        this.playIncomingAudio(data, 'emergency');

        // Show emergency alert
        this.showEmergencyAlert(data);
    }

    // Play incoming audio with appropriate processing
    playIncomingAudio(data, type) {
        if (!data.audioData || !this.spatialAudio) return;

        // Create audio context and decode data
        const audioContext = this.audioEngine.audioContext;

        audioContext.decodeAudioData(data.audioData)
            .then(audioBuffer => {
                const source = audioContext.createBufferSource();
                source.buffer = audioBuffer;

                if (data.binaural && this.spatialAudio) {
                    // Apply spatial positioning
                    const spatialNode = this.spatialAudio.createSpatialNode(data.senderId, source);

                    if (data.position) {
                        this.spatialAudio.updateUserPosition(data.senderId,
                            data.position.x, data.position.y, data.position.z);
                    }

                    source.connect(spatialNode);
                    spatialNode.connect(audioContext.destination);
                } else {
                    // Standard stereo playback
                    source.connect(audioContext.destination);
                }

                source.start();
            })
            .catch(error => {
                console.error('Error decoding incoming audio:', error);
            });
    }

    // Show emergency alert
    showEmergencyAlert(data) {
        const alert = document.createElement('div');
        alert.className = 'emergency-alert';
        alert.innerHTML = `
            <div class="emergency-content">
                <h2>🚨 EMERGENCY BROADCAST 🚨</h2>
                <p>From: ${data.senderName}</p>
                <p>Time: ${new Date(data.timestamp).toLocaleTimeString()}</p>
                <button onclick="this.parentElement.parentElement.remove()">Acknowledge</button>
            </div>
        `;

        document.body.appendChild(alert);

        // Auto-remove after 30 seconds
        setTimeout(() => {
            if (alert.parentElement) {
                alert.remove();
            }
        }, 30000);
    }

    // Configure PTT keys
    configurePTTKey(type, keyConfig) {
        this.pttConfig[type] = { ...this.pttConfig[type], ...keyConfig };
        this.savePTTConfiguration();
        this.updateBroadcastControls();
    }

    // Load PTT configuration from storage
    loadPTTConfiguration() {
        const saved = localStorage.getItem('voicelink-ptt-config');
        if (saved) {
            try {
                const config = JSON.parse(saved);
                this.pttConfig = { ...this.pttConfig, ...config };
            } catch (error) {
                console.error('Error loading PTT configuration:', error);
            }
        }
    }

    // Save PTT configuration to storage
    savePTTConfiguration() {
        localStorage.setItem('voicelink-ptt-config', JSON.stringify(this.pttConfig));
    }

    // Get current configuration
    getConfiguration() {
        return {
            userRole: this.userRole,
            permissions: this.permissions,
            pttConfig: this.pttConfig,
            isTransmitting: this.isTransmitting,
            currentTransmissionType: this.currentTransmissionType
        };
    }
}

// Initialize PA System manager
window.paSystemManager = null;

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = PASystemManager;
}