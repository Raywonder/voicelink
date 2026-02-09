/**
 * VoiceLink Spatial Audio Engine
 * 3D binaural audio processing for immersive voice chat
 */

class SpatialAudioEngine {
    constructor() {
        this.audioContext = null;
        this.listenerPosition = { x: 0, y: 0, z: 0 };
        this.roomModel = 'large-room';
        this.spatialNodes = new Map(); // userId -> spatialNode
        this.userPositions = new Map(); // userId -> {x, y, z}
        this.enabled = true;

        this.init();
    }

    async init() {
        try {
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)();

            // Create master gain node
            this.masterGain = this.audioContext.createGain();
            this.masterGain.connect(this.audioContext.destination);

            // Create convolver for room acoustics
            this.convolver = this.audioContext.createConvolver();
            this.convolver.connect(this.masterGain);

            // Load room impulse response
            await this.loadRoomImpulseResponse(this.roomModel);

            console.log('Spatial Audio Engine initialized');
        } catch (error) {
            console.error('Failed to initialize spatial audio:', error);
            this.enabled = false;
        }
    }

    async loadRoomImpulseResponse(roomType) {
        // In a real implementation, these would be actual impulse response files
        // For now, we'll create synthetic impulse responses
        const impulseResponse = this.createSyntheticImpulseResponse(roomType);
        this.convolver.buffer = impulseResponse;
    }

    createSyntheticImpulseResponse(roomType) {
        const length = this.audioContext.sampleRate * 2; // 2 seconds
        const impulse = this.audioContext.createBuffer(2, length, this.audioContext.sampleRate);

        const left = impulse.getChannelData(0);
        const right = impulse.getChannelData(1);

        // Room acoustic parameters
        const roomParams = {
            'none': { decay: 0.1, reflection: 0.0 },
            'small-room': { decay: 0.3, reflection: 0.2 },
            'large-room': { decay: 0.6, reflection: 0.4 },
            'hall': { decay: 1.2, reflection: 0.7 },
            'cathedral': { decay: 2.0, reflection: 0.9 }
        };

        const params = roomParams[roomType] || roomParams['large-room'];

        for (let i = 0; i < length; i++) {
            const t = i / this.audioContext.sampleRate;
            const decay = Math.exp(-t / params.decay);
            const reflection = params.reflection * decay;

            // Add some randomness for realism
            const noise = (Math.random() - 0.5) * 0.1;

            left[i] = reflection * (noise + Math.sin(t * 440) * 0.1) * decay;
            right[i] = reflection * (noise + Math.sin(t * 330) * 0.1) * decay;
        }

        return impulse;
    }

    createSpatialNode(userId, audioStream) {
        if (!this.enabled || !this.audioContext) {
            return null;
        }

        try {
            // Create source node from stream
            const source = this.audioContext.createMediaStreamSource(audioStream);

            // Create panner node for 3D positioning
            const panner = this.audioContext.createPanner();
            panner.panningModel = 'HRTF';
            panner.distanceModel = 'inverse';
            panner.refDistance = 1;
            panner.maxDistance = 20;
            panner.rolloffFactor = 1;
            panner.coneInnerAngle = 360;
            panner.coneOuterAngle = 0;
            panner.coneOuterGain = 0;

            // Create gain node for individual volume control
            const gainNode = this.audioContext.createGain();
            gainNode.gain.value = 1.0;

            // Dry/wet split so voice remains clearly audible
            const dryGain = this.audioContext.createGain();
            dryGain.gain.value = 1.0;
            const reverbSend = this.audioContext.createGain();
            reverbSend.gain.value = 0.25;

            // Create filter for distance effects
            const filter = this.audioContext.createBiquadFilter();
            filter.type = 'lowpass';
            filter.frequency.value = 20000; // Start with no filtering

            // Connect audio pipeline
            source.connect(gainNode);
            gainNode.connect(filter);
            filter.connect(panner);
            panner.connect(dryGain);
            panner.connect(reverbSend);
            dryGain.connect(this.masterGain);
            reverbSend.connect(this.convolver);

            const spatialNode = {
                source,
                panner,
                gainNode,
                dryGain,
                reverbSend,
                filter,
                userId
            };

            this.spatialNodes.set(userId, spatialNode);

            // Set initial position
            const initialPosition = { x: 0, y: 0, z: 5 };
            this.setUserPosition(userId, initialPosition);

            return spatialNode;
        } catch (error) {
            console.error('Failed to create spatial node:', error);
            return null;
        }
    }

    setUserPosition(userId, position) {
        if (!this.enabled) return;

        this.userPositions.set(userId, position);
        const spatialNode = this.spatialNodes.get(userId);

        if (spatialNode) {
            // Set 3D position
            spatialNode.panner.positionX.setValueAtTime(position.x, this.audioContext.currentTime);
            spatialNode.panner.positionY.setValueAtTime(position.y, this.audioContext.currentTime);
            spatialNode.panner.positionZ.setValueAtTime(position.z, this.audioContext.currentTime);

            // Calculate distance for filtering effects
            const distance = this.calculateDistance(this.listenerPosition, position);
            this.applyDistanceEffects(spatialNode, distance);

            // Update visual representation
            this.updateUserPositionVisual(userId, position);
        }
    }

    setListenerPosition(position) {
        if (!this.enabled) return;

        this.listenerPosition = position;

        if (this.audioContext && this.audioContext.listener) {
            this.audioContext.listener.positionX.setValueAtTime(position.x, this.audioContext.currentTime);
            this.audioContext.listener.positionY.setValueAtTime(position.y, this.audioContext.currentTime);
            this.audioContext.listener.positionZ.setValueAtTime(position.z, this.audioContext.currentTime);
        }

        // Update distances for all users
        this.userPositions.forEach((userPos, userId) => {
            const distance = this.calculateDistance(position, userPos);
            const spatialNode = this.spatialNodes.get(userId);
            if (spatialNode) {
                this.applyDistanceEffects(spatialNode, distance);
            }
        });
    }

    calculateDistance(pos1, pos2) {
        const dx = pos1.x - pos2.x;
        const dy = pos1.y - pos2.y;
        const dz = pos1.z - pos2.z;
        return Math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    applyDistanceEffects(spatialNode, distance) {
        // Apply low-pass filter based on distance
        const maxDistance = 20;
        const minFreq = 1000;
        const maxFreq = 20000;

        const normalizedDistance = Math.min(distance / maxDistance, 1);
        const frequency = maxFreq - (normalizedDistance * (maxFreq - minFreq));

        spatialNode.filter.frequency.setValueAtTime(frequency, this.audioContext.currentTime);

        // Apply volume attenuation
        const volumeAttenuation = Math.max(0.1, 1 - (normalizedDistance * 0.7));
        spatialNode.gainNode.gain.setValueAtTime(volumeAttenuation, this.audioContext.currentTime);
    }

    setUserVolume(userId, volume) {
        const spatialNode = this.spatialNodes.get(userId);
        if (spatialNode) {
            spatialNode.gainNode.gain.setValueAtTime(volume, this.audioContext.currentTime);
        }
    }

    setRoomModel(roomType) {
        this.roomModel = roomType;
        this.loadRoomImpulseResponse(roomType);
    }

    removeUser(userId) {
        const spatialNode = this.spatialNodes.get(userId);
        if (spatialNode) {
            spatialNode.source.disconnect();
            spatialNode.gainNode.disconnect();
            spatialNode.dryGain.disconnect();
            spatialNode.reverbSend.disconnect();
            spatialNode.filter.disconnect();
            spatialNode.panner.disconnect();
        }

        this.spatialNodes.delete(userId);
        this.userPositions.delete(userId);
        this.removeUserPositionVisual(userId);
    }

    updateUserPositionVisual(userId, position) {
        const canvas = document.getElementById('spatial-audio-canvas');
        if (!canvas) return;

        let userElement = document.getElementById(`user-pos-${userId}`);

        if (!userElement) {
            userElement = document.createElement('div');
            userElement.id = `user-pos-${userId}`;
            userElement.className = 'user-position';
            userElement.textContent = '👤';
            userElement.title = `User ${userId}`;

            // Make draggable
            userElement.draggable = true;
            userElement.addEventListener('dragend', (e) => {
                const rect = canvas.getBoundingClientRect();
                const x = ((e.clientX - rect.left) / rect.width - 0.5) * 20; // Scale to audio coordinates
                const z = ((e.clientY - rect.top) / rect.height - 0.5) * 20;

                const newPosition = { x, y: 0, z };
                this.setUserPosition(userId, newPosition);

                // Emit position change to other users
                if (window.voiceLinkApp && window.voiceLinkApp.socket) {
                    window.voiceLinkApp.socket.emit('set-spatial-position', { position: newPosition });
                }
            });

            canvas.appendChild(userElement);
        }

        // Convert 3D position to 2D canvas coordinates
        const canvasRect = canvas.getBoundingClientRect();
        const x = (position.x / 20 + 0.5) * canvasRect.width;
        const z = (position.z / 20 + 0.5) * canvasRect.height;

        userElement.style.left = `${x}px`;
        userElement.style.top = `${z}px`;
        userElement.style.transform = 'translate(-50%, -50%)';

        // Add distance-based opacity
        const distance = this.calculateDistance(this.listenerPosition, position);
        const opacity = Math.max(0.3, 1 - (distance / 20));
        userElement.style.opacity = opacity;
    }

    removeUserPositionVisual(userId) {
        const userElement = document.getElementById(`user-pos-${userId}`);
        if (userElement) {
            userElement.remove();
        }
    }

    enable() {
        this.enabled = true;
        if (this.audioContext && this.audioContext.state === 'suspended') {
            this.audioContext.resume();
        }
    }

    disable() {
        this.enabled = false;
        if (this.audioContext) {
            this.audioContext.suspend();
        }
    }

    getMasterVolume() {
        return this.masterGain ? this.masterGain.gain.value : 1.0;
    }

    setMasterVolume(volume) {
        if (this.masterGain) {
            this.masterGain.gain.setValueAtTime(volume, this.audioContext.currentTime);
        }
    }

    // Get audio context for other components
    getAudioContext() {
        return this.audioContext;
    }

    // Resume audio context on user interaction (required by browsers)
    async resumeAudioContext() {
        if (this.audioContext && this.audioContext.state === 'suspended') {
            await this.audioContext.resume();
        }
    }
}

// Export for use in other modules
window.SpatialAudioEngine = SpatialAudioEngine;
