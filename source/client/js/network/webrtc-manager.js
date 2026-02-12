/**
 * VoiceLink WebRTC Manager
 * P2P connection management for voice chat
 */

class WebRTCManager {
    constructor(socket, audioEngine, spatialAudio) {
        this.socket = socket;
        this.audioEngine = audioEngine;
        this.spatialAudio = spatialAudio;

        this.peers = new Map(); // userId -> peer connection
        this.localStream = null;
        this.connectionStates = new Map(); // userId -> connection state

        this.iceConfig = {
            iceServers: [
                { urls: 'stun:stun.l.google.com:19302' },
                { urls: 'stun:stun1.l.google.com:19302' },
                { urls: 'stun:stun2.l.google.com:19302' }
            ]
        };

        this.setupSocketListeners();
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
            console.log('Connected to peer:', userId);
            this.connectionStates.set(userId, 'connected');
            this.updateUserConnectionStatus(userId, 'connected');
        });

        peer.on('stream', (stream) => {
            console.log('Received stream from peer:', userId);
            this.handleRemoteStream(userId, stream);
        });

        peer.on('close', () => {
            console.log('Peer connection closed:', userId);
            this.connectionStates.set(userId, 'disconnected');
            this.handlePeerDisconnect(userId);
        });

        peer.on('error', (error) => {
            console.error('Peer connection error with', userId, error);
            this.connectionStates.set(userId, 'error');
            this.updateUserConnectionStatus(userId, 'error');
        });

        return peer;
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
                    'connecting': 'Connecting...',
                    'connected': 'Connected',
                    'disconnected': 'Disconnected',
                    'error': 'Connection Error'
                };

                statusElement.title = statusText[status] || status;
            }
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

            // Update UI
            const muteBtn = document.getElementById('mute-btn');
            if (muteBtn) {
                muteBtn.textContent = muted ? '🔇 Muted' : '🎙️ Unmuted';
                muteBtn.classList.toggle('active', muted);
            }

            console.log('Local audio', muted ? 'muted' : 'unmuted');
        }
    }

    // Deafen (stop receiving audio)
    setDeafened(deafened) {
        this.audioEngine.outputNodes.forEach(outputNode => {
            outputNode.gain.value = deafened ? 0 : this.audioEngine.settings.outputVolume;
        });

        // Update UI
        const deafenBtn = document.getElementById('deafen-btn');
        if (deafenBtn) {
            deafenBtn.textContent = deafened ? '🔇 Muted Output' : '🔊 Output On';
            deafenBtn.classList.toggle('active', deafened);
        }

        console.log('Audio output', deafened ? 'deafened' : 'enabled');
    }

    // Push-to-talk functionality
    setupPushToTalk(keyCode = 'Space') {
        let isPressed = false;
        let wasOriginallyMuted = false;

        const enablePTT = () => {
            document.addEventListener('keydown', (e) => {
                if (e.code === keyCode && !isPressed) {
                    isPressed = true;
                    wasOriginallyMuted = this.isLocalMuted();
                    this.setMuted(false);

                    // Update UI
                    const pttBtn = document.getElementById('push-to-talk-btn');
                    if (pttBtn) {
                        pttBtn.textContent = '🔓 PTT: Active';
                        pttBtn.classList.add('active');
                    }
                }
            });

            document.addEventListener('keyup', (e) => {
                if (e.code === keyCode && isPressed) {
                    isPressed = false;
                    this.setMuted(wasOriginallyMuted);

                    // Update UI
                    const pttBtn = document.getElementById('push-to-talk-btn');
                    if (pttBtn) {
                        pttBtn.textContent = '🔒 PTT: Off';
                        pttBtn.classList.remove('active');
                    }
                }
            });
        };

        enablePTT();
        console.log(`Push-to-talk enabled with key: ${keyCode}`);
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
