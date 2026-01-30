/**
 * VoiceLink WebRTC Manager
 * P2P and Server Relay connection management for voice chat
 *
 * Connection Modes:
 * - 'p2p': Direct peer-to-peer (default, lowest latency)
 * - 'relay': Server relay (for NAT/firewall bypass or speed boost)
 * - 'auto': Automatic fallback (try P2P, fall back to relay)
 */

class WebRTCManager {
    constructor(socket, audioEngine, spatialAudio) {
        this.socket = socket;
        this.audioEngine = audioEngine;
        this.spatialAudio = spatialAudio;

        this.peers = new Map(); // userId -> peer connection
        this.localStream = null;
        this.connectionStates = new Map(); // userId -> connection state

        // Connection mode: 'p2p', 'relay', or 'auto'
        this.connectionMode = 'auto';
        this.useServerRelay = false;
        this.p2pConnectionTimeout = 5000; // 5 seconds to try P2P before fallback
        this.connectionAttempts = new Map(); // userId -> attempt count

        // Audio relay state
        this.isRelayMode = false;
        this.relayAudioContext = null;
        this.relayProcessor = null;

        // ICE configuration with STUN and TURN servers
        this.iceConfig = {
            iceServers: [
                // STUN servers (for P2P NAT traversal)
                { urls: 'stun:stun.l.google.com:19302' },
                { urls: 'stun:stun1.l.google.com:19302' },
                { urls: 'stun:stun2.l.google.com:19302' },
                // TURN servers (for relay fallback when P2P fails)
                {
                    urls: 'turn:turn.devinecreations.net:3478',
                    username: 'voicelink',
                    credential: 'voicelink2024'
                },
                {
                    urls: 'turns:turn.devinecreations.net:5349',
                    username: 'voicelink',
                    credential: 'voicelink2024'
                }
            ],
            iceCandidatePoolSize: 10
        };

        this.setupSocketListeners();
        this.setupRelayListeners();
    }

    /**
     * Set connection mode
     * @param {string} mode - 'p2p', 'relay', or 'auto'
     */
    setConnectionMode(mode) {
        const validModes = ['p2p', 'relay', 'auto'];
        if (!validModes.includes(mode)) {
            console.error('Invalid connection mode:', mode);
            return;
        }

        this.connectionMode = mode;
        this.useServerRelay = (mode === 'relay');

        console.log(`Connection mode set to: ${mode}`);

        // If switching to relay mode, enable server relay
        if (mode === 'relay') {
            this.enableServerRelay();
        } else if (mode === 'p2p') {
            this.disableServerRelay();
        }

        // Emit event for UI update
        if (typeof window !== 'undefined') {
            window.dispatchEvent(new CustomEvent('connectionModeChanged', {
                detail: { mode, isRelay: this.useServerRelay }
            }));
        }

        return { success: true, mode };
    }

    /**
     * Get current connection mode
     */
    getConnectionMode() {
        return {
            mode: this.connectionMode,
            isRelay: this.useServerRelay,
            p2pAvailable: this.peers.size > 0
        };
    }

    /**
     * Enable server relay for audio
     */
    enableServerRelay() {
        this.isRelayMode = true;
        this.socket.emit('enable-audio-relay', {
            enabled: true,
            sampleRate: 48000,
            channels: 2
        });
        console.log('Server audio relay enabled');
    }

    /**
     * Disable server relay
     */
    disableServerRelay() {
        this.isRelayMode = false;
        this.socket.emit('enable-audio-relay', { enabled: false });
        console.log('Server audio relay disabled');
    }

    /**
     * Setup listeners for server relay audio
     */
    setupRelayListeners() {
        // Receive relayed audio from server
        this.socket.on('relayed-audio', (data) => {
            if (this.isRelayMode || this.connectionMode === 'auto') {
                this.handleRelayedAudio(data);
            }
        });

        // Server relay status updates
        this.socket.on('relay-status', (status) => {
            console.log('Server relay status:', status);
            if (status.active) {
                this.isRelayMode = true;
            }
        });

        // P2P connection failed, auto-switch to relay
        this.socket.on('p2p-fallback-needed', (data) => {
            if (this.connectionMode === 'auto') {
                console.log('P2P connection failed, switching to server relay for user:', data.userId);
                this.enableServerRelay();
                this.connectionStates.set(data.userId, 'relay');
                this.updateUserConnectionStatus(data.userId, 'relay');
            }
        });
    }

    /**
     * Handle audio received via server relay
     */
    handleRelayedAudio(data) {
        const { userId, audioData, timestamp } = data;

        // Skip if we have a direct P2P connection to this user
        const peerState = this.connectionStates.get(userId);
        if (peerState === 'connected' && !this.useServerRelay) {
            return; // Use P2P instead
        }

        // Process relayed audio through audio engine
        if (this.audioEngine && audioData) {
            this.audioEngine.processRelayedAudio(userId, audioData, timestamp);
        }
    }

    /**
     * Send audio via server relay (when P2P unavailable)
     */
    sendAudioViaRelay(audioData) {
        if (this.isRelayMode && this.socket) {
            this.socket.emit('audio-data', {
                audioData: audioData,
                timestamp: Date.now(),
                sampleRate: 48000
            });
        }
    }

    setupSocketListeners() {
        // Handle incoming WebRTC offers
        this.socket.on('webrtc-offer', async (data) => {
            await this.handleOffer(data.fromUserId, data.offer);
        });

        // Handle incoming WebRTC answers
        this.socket.on('webrtc-answer', async (data) => {
            await this.handleAnswer(data.fromUserId, data.answer);
        });

        // Handle incoming ICE candidates
        this.socket.on('webrtc-ice-candidate', async (data) => {
            await this.handleIceCandidate(data.fromUserId, data.candidate);
        });

        // Handle user joining
        this.socket.on('user-joined', async (user) => {
            console.log('User joined, initiating connection:', user.name);
            await this.createPeerConnection(user.id, true); // Initiate offer
        });

        // Handle user leaving
        this.socket.on('user-left', (data) => {
            this.closePeerConnection(data.userId);
        });
    }

    async initializeLocalStream() {
        try {
            this.localStream = await this.audioEngine.getUserMedia();
            console.log('Local stream initialized');
            return this.localStream;
        } catch (error) {
            console.error('Failed to initialize local stream:', error);
            throw error;
        }
    }

    async createPeerConnection(userId, shouldOffer = false) {
        // If relay mode is forced, skip P2P entirely
        if (this.connectionMode === 'relay') {
            console.log('Relay mode active, skipping P2P for user:', userId);
            this.connectionStates.set(userId, 'relay');
            this.updateUserConnectionStatus(userId, 'relay');
            return null;
        }

        if (this.peers.has(userId)) {
            this.closePeerConnection(userId);
        }

        const peer = new SimplePeer({
            initiator: shouldOffer,
            config: this.iceConfig,
            stream: this.localStream,
            trickle: true
        });

        this.peers.set(userId, peer);
        this.connectionStates.set(userId, 'connecting');

        // Set up P2P connection timeout for auto mode
        let connectionTimeout = null;
        if (this.connectionMode === 'auto') {
            connectionTimeout = setTimeout(() => {
                const state = this.connectionStates.get(userId);
                if (state === 'connecting') {
                    console.log(`P2P connection timeout for user ${userId}, falling back to relay`);
                    this.handleP2PFallback(userId, 'timeout');
                }
            }, this.p2pConnectionTimeout);
        }

        // Handle peer events
        peer.on('signal', (signal) => {
            console.log('Sending signal to', userId, signal.type);

            if (signal.type === 'offer') {
                this.socket.emit('webrtc-offer', {
                    targetUserId: userId,
                    offer: signal
                });
            } else if (signal.type === 'answer') {
                this.socket.emit('webrtc-answer', {
                    targetUserId: userId,
                    answer: signal
                });
            } else if (signal.candidate) {
                this.socket.emit('webrtc-ice-candidate', {
                    targetUserId: userId,
                    candidate: signal
                });
            }
        });

        peer.on('connect', () => {
            console.log('P2P connected to peer:', userId);
            if (connectionTimeout) clearTimeout(connectionTimeout);
            this.connectionStates.set(userId, 'connected');
            this.updateUserConnectionStatus(userId, 'connected');

            // Disable relay for this user since P2P is working
            if (this.connectionMode === 'auto' && this.isRelayMode) {
                console.log('P2P established, using direct connection for:', userId);
            }
        });

        peer.on('stream', (stream) => {
            console.log('Received P2P stream from peer:', userId);
            this.handleRemoteStream(userId, stream);
        });

        peer.on('close', () => {
            console.log('Peer connection closed:', userId);
            if (connectionTimeout) clearTimeout(connectionTimeout);
            this.connectionStates.set(userId, 'disconnected');
            this.handlePeerDisconnect(userId);
        });

        peer.on('error', (error) => {
            console.error('Peer connection error with', userId, error);
            if (connectionTimeout) clearTimeout(connectionTimeout);

            // In auto mode, fall back to relay on error
            if (this.connectionMode === 'auto') {
                this.handleP2PFallback(userId, error.message || 'connection_error');
            } else {
                this.connectionStates.set(userId, 'error');
                this.updateUserConnectionStatus(userId, 'error');
            }
        });

        return peer;
    }

    /**
     * Handle P2P connection failure and fall back to relay
     */
    handleP2PFallback(userId, reason) {
        console.log(`P2P fallback for user ${userId}: ${reason}`);

        // Notify server about P2P failure
        this.socket.emit('p2p-connection-failed', {
            targetUserId: userId,
            reason: reason
        });

        // Update state to relay
        this.connectionStates.set(userId, 'relay');
        this.updateUserConnectionStatus(userId, 'relay');

        // Enable server relay if not already enabled
        if (!this.isRelayMode) {
            this.enableServerRelay();
        }

        // Set up audio capture for relay if not already done
        if (this.audioEngine && !this.audioEngine.relayProcessor) {
            this.audioEngine.captureAudioForRelay();
            this.audioEngine.setAudioDataCallback((audioData) => {
                this.sendAudioViaRelay(audioData);
            });
        }
    }

    async handleOffer(userId, offer) {
        console.log('Handling offer from:', userId);

        const peer = await this.createPeerConnection(userId, false);
        peer.signal(offer);
    }

    async handleAnswer(userId, answer) {
        console.log('Handling answer from:', userId);

        const peer = this.peers.get(userId);
        if (peer) {
            peer.signal(answer);
        }
    }

    async handleIceCandidate(userId, candidate) {
        const peer = this.peers.get(userId);
        if (peer) {
            peer.signal(candidate);
        }
    }

    handleRemoteStream(userId, stream) {
        // Create audio processing chain
        const audioNode = this.audioEngine.createUserAudioNode(userId, stream);

        // Create spatial audio processing
        const spatialNode = this.spatialAudio.createSpatialNode(userId, stream);

        // Update UI
        this.updateUserAudioStatus(userId, true);

        console.log('Remote stream setup complete for user:', userId);
    }

    handlePeerDisconnect(userId) {
        // Clean up audio processing
        this.audioEngine.removeUser(userId);
        this.spatialAudio.removeUser(userId);

        // Update UI
        this.updateUserAudioStatus(userId, false);
        this.updateUserConnectionStatus(userId, 'disconnected');

        console.log('Cleaned up disconnected peer:', userId);
    }

    closePeerConnection(userId) {
        const peer = this.peers.get(userId);
        if (peer) {
            peer.destroy();
            this.peers.delete(userId);
        }

        this.connectionStates.delete(userId);
        this.handlePeerDisconnect(userId);
    }

    updateUserConnectionStatus(userId, status) {
        const userElement = document.querySelector(`[data-user-id=\"${userId}\"]`);
        if (userElement) {
            const statusElement = userElement.querySelector('.user-status');
            if (statusElement) {
                statusElement.className = `user-status ${status}`;

                // Update tooltip
                const statusText = {
                    'connecting': 'Connecting (P2P)...',
                    'connected': 'Connected (P2P Direct)',
                    'relay': 'Connected (Server Relay)',
                    'disconnected': 'Disconnected',
                    'error': 'Connection Error'
                };

                statusElement.title = statusText[status] || status;

                // Add visual indicator for relay mode
                if (status === 'relay') {
                    statusElement.innerHTML = '🔄'; // Relay indicator
                } else if (status === 'connected') {
                    statusElement.innerHTML = '🔗'; // P2P indicator
                }
            }
        }

        // Emit event for UI components
        if (typeof window !== 'undefined') {
            window.dispatchEvent(new CustomEvent('userConnectionStatusChanged', {
                detail: { userId, status, isRelay: status === 'relay' }
            }));
        }
    }

    updateUserAudioStatus(userId, hasAudio) {
        const userElement = document.querySelector(`[data-user-id=\"${userId}\"]`);
        if (userElement) {
            const audioIndicator = userElement.querySelector('.audio-indicator');
            if (audioIndicator) {
                audioIndicator.style.display = hasAudio ? 'inline' : 'none';
            }
        }
    }

    // Mute/unmute local audio
    setMuted(muted) {
        if (this.localStream) {
            this.localStream.getAudioTracks().forEach(track => {
                track.enabled = !muted;
            });

            // Update button UI
            const muteBtn = document.getElementById('mute-btn');
            if (muteBtn) {
                const icon = muteBtn.querySelector('.btn-icon');
                const label = muteBtn.querySelector('.btn-label');

                if (icon) icon.textContent = muted ? '🔇' : '🎙️';
                if (label) label.textContent = muted ? 'Mic: Off' : 'Mic: On';

                muteBtn.classList.toggle('active', muted);
                muteBtn.setAttribute('aria-pressed', muted.toString());
                muteBtn.setAttribute('aria-label', muted
                    ? 'Microphone is off. Click to unmute.'
                    : 'Microphone is on. Click to mute.');
            }

            // Update status message
            const muteStatus = document.getElementById('mute-status');
            if (muteStatus) {
                muteStatus.textContent = muted ? 'You are muted' : 'Microphone active';
                muteStatus.className = 'status-message ' + (muted ? 'muted' : 'active');
            }

            // Announce to screen readers
            this.announceStatus(muted ? 'Microphone muted' : 'Microphone unmuted');

            console.log('Local audio', muted ? 'muted' : 'unmuted');
        }
    }

    // Deafen (stop receiving audio)
    setDeafened(deafened) {
        this.audioEngine.outputNodes.forEach(outputNode => {
            outputNode.gain.value = deafened ? 0 : this.audioEngine.settings.outputVolume;
        });

        // Update button UI
        const deafenBtn = document.getElementById('deafen-btn');
        if (deafenBtn) {
            const icon = deafenBtn.querySelector('.btn-icon');
            const label = deafenBtn.querySelector('.btn-label');

            if (icon) icon.textContent = deafened ? '🔇' : '🔊';
            if (label) label.textContent = deafened ? 'Audio: Off' : 'Audio: On';

            deafenBtn.classList.toggle('active', deafened);
            deafenBtn.setAttribute('aria-pressed', deafened.toString());
            deafenBtn.setAttribute('aria-label', deafened
                ? 'Audio is off. Click to hear others.'
                : 'Audio is on. Click to deafen.');
        }

        // Update status message
        const deafenStatus = document.getElementById('deafen-status');
        if (deafenStatus) {
            deafenStatus.textContent = deafened ? 'Audio deafened' : 'Hearing others';
            deafenStatus.className = 'status-message ' + (deafened ? 'muted' : 'active');
        }

        // Announce to screen readers
        this.announceStatus(deafened ? 'Audio deafened' : 'Audio enabled');

        console.log('Audio output', deafened ? 'deafened' : 'enabled');
    }

    // Announce status for screen readers
    announceStatus(message) {
        const announcer = document.getElementById('sr-announcer') || this.createAnnouncer();
        if (announcer) {
            announcer.textContent = message;
            // Clear after announcement
            setTimeout(() => { announcer.textContent = ''; }, 1000);
        }
    }

    // Create screen reader announcer element if needed
    createAnnouncer() {
        let announcer = document.getElementById('sr-announcer');
        if (!announcer) {
            announcer = document.createElement('div');
            announcer.id = 'sr-announcer';
            announcer.setAttribute('role', 'status');
            announcer.setAttribute('aria-live', 'polite');
            announcer.setAttribute('aria-atomic', 'true');
            announcer.className = 'sr-only';
            announcer.style.cssText = 'position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0;';
            document.body.appendChild(announcer);
        }
        return announcer;
    }

    // Push-to-talk functionality
    setupPushToTalk(keyCode = 'Space') {
        let isPressed = false;
        let wasOriginallyMuted = false;
        this.pttEnabled = false;

        const updatePTTUI = (active) => {
            const pttBtn = document.getElementById('push-to-talk-btn');
            if (pttBtn) {
                const icon = pttBtn.querySelector('.btn-icon');
                const label = pttBtn.querySelector('.btn-label');

                if (active) {
                    if (icon) icon.textContent = '🎤';
                    if (label) label.textContent = 'PTT: Speaking';
                    pttBtn.classList.add('active');
                    pttBtn.setAttribute('aria-pressed', 'true');
                } else if (this.pttEnabled) {
                    if (icon) icon.textContent = '🔓';
                    if (label) label.textContent = 'PTT: On';
                    pttBtn.classList.remove('active');
                    pttBtn.setAttribute('aria-pressed', 'false');
                } else {
                    if (icon) icon.textContent = '🔒';
                    if (label) label.textContent = 'PTT: Off';
                    pttBtn.classList.remove('active');
                    pttBtn.setAttribute('aria-pressed', 'false');
                }
            }

            // Update status message
            const pttStatus = document.getElementById('ptt-status');
            if (pttStatus) {
                if (active) {
                    pttStatus.textContent = 'Speaking...';
                    pttStatus.className = 'status-message active';
                } else if (this.pttEnabled) {
                    pttStatus.textContent = 'Hold Space to talk';
                    pttStatus.className = 'status-message';
                } else {
                    pttStatus.textContent = '';
                    pttStatus.className = 'status-message';
                }
            }
        };

        const enablePTT = () => {
            document.addEventListener('keydown', (e) => {
                if (e.code === keyCode && !isPressed && this.pttEnabled) {
                    isPressed = true;
                    wasOriginallyMuted = this.isLocalMuted();
                    this.setMuted(false);
                    updatePTTUI(true);
                }
            });

            document.addEventListener('keyup', (e) => {
                if (e.code === keyCode && isPressed) {
                    isPressed = false;
                    this.setMuted(wasOriginallyMuted);
                    updatePTTUI(false);
                }
            });

            // Touch support for mobile PTT
            const pttBtn = document.getElementById('push-to-talk-btn');
            if (pttBtn) {
                pttBtn.addEventListener('touchstart', (e) => {
                    if (this.pttEnabled && !isPressed) {
                        e.preventDefault();
                        isPressed = true;
                        wasOriginallyMuted = this.isLocalMuted();
                        this.setMuted(false);
                        updatePTTUI(true);
                    }
                }, { passive: false });

                pttBtn.addEventListener('touchend', (e) => {
                    if (isPressed) {
                        e.preventDefault();
                        isPressed = false;
                        this.setMuted(wasOriginallyMuted);
                        updatePTTUI(false);
                    }
                }, { passive: false });
            }
        };

        enablePTT();
        console.log(`Push-to-talk enabled with key: ${keyCode}`);
    }

    // Toggle PTT mode
    togglePTT() {
        this.pttEnabled = !this.pttEnabled;
        const pttBtn = document.getElementById('push-to-talk-btn');
        const pttStatus = document.getElementById('ptt-status');

        if (pttBtn) {
            const icon = pttBtn.querySelector('.btn-icon');
            const label = pttBtn.querySelector('.btn-label');

            if (this.pttEnabled) {
                if (icon) icon.textContent = '🔓';
                if (label) label.textContent = 'PTT: On';
                pttBtn.setAttribute('aria-label', 'Push to talk is enabled. Hold Space to speak.');
            } else {
                if (icon) icon.textContent = '🔒';
                if (label) label.textContent = 'PTT: Off';
                pttBtn.setAttribute('aria-label', 'Push to talk is disabled. Click to enable.');
            }
        }

        if (pttStatus) {
            pttStatus.textContent = this.pttEnabled ? 'Hold Space to talk' : '';
            pttStatus.className = 'status-message';
        }

        this.announceStatus(this.pttEnabled ? 'Push to talk enabled' : 'Push to talk disabled');
        return this.pttEnabled;
    }

    isLocalMuted() {
        if (this.localStream) {
            const audioTrack = this.localStream.getAudioTracks()[0];
            return audioTrack ? !audioTrack.enabled : true;
        }
        return true;
    }

    // Get connection statistics
    getConnectionStats(userId) {
        const peer = this.peers.get(userId);
        if (peer && peer._pc) {
            return peer._pc.getStats();
        }
        return null;
    }

    // Get all peer connection states
    getAllConnectionStates() {
        const states = {};
        this.connectionStates.forEach((state, userId) => {
            states[userId] = state;
        });
        return states;
    }

    // Restart connection with user
    async restartConnection(userId) {
        console.log('Restarting connection with user:', userId);
        this.closePeerConnection(userId);
        await this.createPeerConnection(userId, true);
    }

    // Clean up all connections
    destroy() {
        this.peers.forEach((peer, userId) => {
            this.closePeerConnection(userId);
        });

        if (this.localStream) {
            this.localStream.getTracks().forEach(track => track.stop());
            this.localStream = null;
        }

        console.log('WebRTC Manager destroyed');
    }
}

// Export for use in other modules
window.WebRTCManager = WebRTCManager;