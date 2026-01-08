/**
 * VoiceLink Audio Test Manager
 * Non-overlapping audio playback with play/stop controls
 */

class AudioTestManager {
    constructor(audioEngine, spatialAudio) {
        this.audioEngine = audioEngine;
        this.spatialAudio = spatialAudio;

        // Audio playback state
        this.currentAudio = null;
        this.isPlaying = false;
        this.audioFiles = new Map();
        this.testSources = new Map(); // testId -> audio source

        // Test audio files
        this.testFiles = [
            {
                id: 'main_test',
                name: 'Audio Portrait Sound Test',
                file: 'Audio-Portrit-Sound-Test.wav',
                description: 'Main audio quality test file'
            },
            {
                id: 'connected',
                name: 'Connected Sound',
                file: 'connected.wav',
                description: 'Connection established notification'
            },
            {
                id: 'disconnect',
                name: 'Disconnect Sound',
                file: 'disconnect.wav',
                description: 'Connection lost notification'
            },
            {
                id: 'message',
                name: 'Message Sound',
                file: 'message.wav',
                description: 'Incoming message notification'
            },
            {
                id: 'progress',
                name: 'Progress Sound',
                file: 'progress.wav',
                description: 'Process progress notification'
            },
            {
                id: 'reconnected',
                name: 'Reconnected Sound',
                file: 'reconnected.wav',
                description: 'Connection restored notification'
            },
            {
                id: 'file_complete',
                name: 'File Transfer Complete',
                file: 'file transfer complete.wav',
                description: 'File transfer completion notification'
            },
            {
                id: 'connection_lost',
                name: 'Connection Lost',
                file: 'connection lost.wav',
                description: 'Connection interrupted notification'
            }
        ];

        this.init();
    }

    async init() {
        console.log('Initializing Audio Test Manager...');

        // Preload all test audio files
        await this.preloadAudioFiles();

        // Create audio test interface
        this.createAudioTestInterface();

        // Setup audio test controls
        this.setupAudioTestControls();

        console.log('Audio Test Manager initialized with', this.testFiles.length, 'test files');
    }

    async preloadAudioFiles() {
        for (const testFile of this.testFiles) {
            try {
                const audio = new Audio();
                audio.preload = 'auto';
                audio.src = `assets/test-audio/${testFile.file}`;

                // Wait for audio to load
                await new Promise((resolve, reject) => {
                    audio.addEventListener('canplaythrough', resolve);
                    audio.addEventListener('error', reject);
                    audio.load();
                });

                this.audioFiles.set(testFile.id, {
                    ...testFile,
                    audio,
                    duration: audio.duration,
                    loaded: true
                });

                console.log(`Loaded audio test file: ${testFile.name} (${audio.duration.toFixed(1)}s)`);

            } catch (error) {
                console.error(`Failed to load audio test file ${testFile.name}:`, error);
                this.audioFiles.set(testFile.id, {
                    ...testFile,
                    audio: null,
                    loaded: false,
                    error: error.message
                });
            }
        }
    }

    createAudioTestInterface() {
        // Check if audio test interface already exists
        let audioTestPanel = document.getElementById('audio-test-panel');

        if (!audioTestPanel) {
            audioTestPanel = document.createElement('div');
            audioTestPanel.id = 'audio-test-panel';
            audioTestPanel.className = 'audio-test-panel hidden';
        }

        audioTestPanel.innerHTML = `
            <div class="audio-test-header">
                <h3>🔊 Audio Test Suite</h3>
                <div class="audio-test-controls">
                    <button id="stop-all-audio" class="stop-btn" disabled>⏹️ Stop All</button>
                    <button id="close-audio-test" class="close-btn">✕</button>
                </div>
            </div>

            <div class="audio-test-content">
                <div class="audio-test-info">
                    <div class="current-playback" id="current-playback">
                        <span class="status">No audio playing</span>
                        <div class="progress-bar hidden" id="audio-progress">
                            <div class="progress-fill"></div>
                            <span class="time-display">0:00 / 0:00</span>
                        </div>
                    </div>
                </div>

                <div class="audio-test-files" id="audio-test-files">
                    <!-- Audio test files will be populated here -->
                </div>

                <div class="audio-test-options">
                    <div class="test-option">
                        <label>
                            <input type="checkbox" id="spatial-audio-test" checked>
                            Enable 3D Spatial Audio
                        </label>
                    </div>
                    <div class="test-option">
                        <label>
                            <input type="checkbox" id="loop-audio-test">
                            Loop Audio
                        </label>
                    </div>
                    <div class="test-option">
                        <label>Volume:</label>
                        <input type="range" id="test-volume" min="0" max="100" value="50">
                        <span id="test-volume-value">50%</span>
                    </div>
                    <div class="test-option">
                        <label>Output Device:</label>
                        <select id="test-output-device">
                            <option value="default">Default Output</option>
                        </select>
                    </div>
                </div>

                <div class="audio-test-actions">
                    <button id="test-microphone-btn" class="test-btn">🎙️ Test Microphone</button>
                    <button id="test-speakers-btn" class="test-btn">🔊 Test Speakers</button>
                    <button id="test-spatial-btn" class="test-btn">🎧 Test 3D Audio</button>
                </div>
            </div>
        `;

        // Add to document if not already present
        if (!document.getElementById('audio-test-panel')) {
            document.body.appendChild(audioTestPanel);
        }

        this.audioTestPanel = audioTestPanel;

        // Populate audio test files
        this.populateAudioTestFiles();

        // Add CSS styles
        this.addAudioTestStyles();
    }

    populateAudioTestFiles() {
        const audioTestFiles = document.getElementById('audio-test-files');
        if (!audioTestFiles) return;

        audioTestFiles.innerHTML = '';

        this.audioFiles.forEach((fileData, fileId) => {
            const fileElement = document.createElement('div');
            fileElement.className = 'audio-test-file';
            fileElement.dataset.fileId = fileId;

            const statusClass = fileData.loaded ? 'loaded' : 'error';
            const statusIcon = fileData.loaded ? '✅' : '❌';
            const duration = fileData.loaded ? `${fileData.duration.toFixed(1)}s` : 'Error';

            fileElement.innerHTML = `
                <div class="file-info">
                    <div class="file-name">
                        <span class="status-icon">${statusIcon}</span>
                        <span class="name">${fileData.name}</span>
                        <span class="duration">(${duration})</span>
                    </div>
                    <div class="file-description">${fileData.description}</div>
                </div>
                <div class="file-controls">
                    <button class="play-btn" data-file-id="${fileId}" ${!fileData.loaded ? 'disabled' : ''}>
                        ▶️ Play
                    </button>
                </div>
            `;

            audioTestFiles.appendChild(fileElement);
        });
    }

    setupAudioTestControls() {
        // Play button handlers
        document.addEventListener('click', (e) => {
            if (e.target.classList.contains('play-btn')) {
                const fileId = e.target.dataset.fileId;
                this.toggleAudioPlayback(fileId, e.target);
            }
        });

        // Stop all audio
        document.getElementById('stop-all-audio').addEventListener('click', () => {
            this.stopAllAudio();
        });

        // Close audio test panel
        document.getElementById('close-audio-test').addEventListener('click', () => {
            this.hideAudioTestPanel();
        });

        // Volume control
        const volumeSlider = document.getElementById('test-volume');
        const volumeValue = document.getElementById('test-volume-value');

        volumeSlider.addEventListener('input', (e) => {
            const volume = e.target.value / 100;
            volumeValue.textContent = `${e.target.value}%`;

            if (this.currentAudio) {
                this.currentAudio.volume = volume;
            }
        });

        // Spatial audio toggle
        document.getElementById('spatial-audio-test').addEventListener('change', (e) => {
            console.log('3D Spatial Audio:', e.target.checked ? 'Enabled' : 'Disabled');
        });

        // Loop toggle
        document.getElementById('loop-audio-test').addEventListener('change', (e) => {
            if (this.currentAudio) {
                this.currentAudio.loop = e.target.checked;
            }
        });

        // Test buttons
        document.getElementById('test-microphone-btn').addEventListener('click', () => {
            this.testMicrophone();
        });

        document.getElementById('test-speakers-btn').addEventListener('click', () => {
            this.testSpeakers();
        });

        document.getElementById('test-spatial-btn').addEventListener('click', () => {
            this.test3DAudio();
        });

        // Populate output devices
        this.populateOutputDevices();
    }

    async toggleAudioPlayback(fileId, buttonElement) {
        const fileData = this.audioFiles.get(fileId);
        if (!fileData || !fileData.loaded) return;

        // Stop any currently playing audio first
        if (this.isPlaying && this.currentAudio) {
            this.stopCurrentAudio();
        }

        // If this was the currently playing audio, just stop
        if (this.currentAudio === fileData.audio) {
            return;
        }

        try {
            // Start playing new audio
            await this.playAudio(fileData, buttonElement);

        } catch (error) {
            console.error('Failed to play audio:', error);
            this.updatePlaybackStatus('Error playing audio');
        }
    }

    async playAudio(fileData, buttonElement) {
        const audio = fileData.audio;

        // Configure audio
        const volume = document.getElementById('test-volume').value / 100;
        const loop = document.getElementById('loop-audio-test').checked;

        audio.volume = volume;
        audio.loop = loop;
        audio.currentTime = 0;

        // Setup event handlers
        audio.onended = () => {
            if (!audio.loop) {
                this.stopCurrentAudio();
            }
        };

        audio.onerror = (error) => {
            console.error('Audio playback error:', error);
            this.stopCurrentAudio();
        };

        // Update UI state
        this.isPlaying = true;
        this.currentAudio = audio;

        // Update button text
        buttonElement.textContent = '⏸️ Stop';
        buttonElement.classList.add('playing');

        // Enable stop all button
        document.getElementById('stop-all-audio').disabled = false;

        // Update status
        this.updatePlaybackStatus(`Playing: ${fileData.name}`);

        // Start progress tracking
        this.startProgressTracking(audio, fileData);

        // Play audio
        await audio.play();

        console.log(`Playing audio: ${fileData.name}`);
    }

    stopCurrentAudio() {
        if (this.currentAudio) {
            this.currentAudio.pause();
            this.currentAudio.currentTime = 0;
            this.currentAudio = null;
        }

        this.isPlaying = false;

        // Update all play buttons
        document.querySelectorAll('.play-btn').forEach(btn => {
            btn.textContent = '▶️ Play';
            btn.classList.remove('playing');
        });

        // Disable stop all button
        document.getElementById('stop-all-audio').disabled = true;

        // Update status
        this.updatePlaybackStatus('No audio playing');

        // Hide progress bar
        document.getElementById('audio-progress').classList.add('hidden');

        console.log('Audio playback stopped');
    }

    stopAllAudio() {
        this.stopCurrentAudio();

        // Also stop any other audio sources
        this.testSources.forEach((source, testId) => {
            if (source.stop) {
                source.stop();
            }
            this.testSources.delete(testId);
        });
    }

    startProgressTracking(audio, fileData) {
        const progressBar = document.getElementById('audio-progress');
        const progressFill = progressBar.querySelector('.progress-fill');
        const timeDisplay = progressBar.querySelector('.time-display');

        progressBar.classList.remove('hidden');

        const updateProgress = () => {
            if (audio === this.currentAudio && !audio.paused) {
                const progress = (audio.currentTime / audio.duration) * 100;
                progressFill.style.width = `${progress}%`;

                const currentTime = this.formatTime(audio.currentTime);
                const totalTime = this.formatTime(audio.duration);
                timeDisplay.textContent = `${currentTime} / ${totalTime}`;

                requestAnimationFrame(updateProgress);
            }
        };

        updateProgress();
    }

    updatePlaybackStatus(status) {
        const statusElement = document.querySelector('.current-playback .status');
        if (statusElement) {
            statusElement.textContent = status;
        }
    }

    formatTime(seconds) {
        const minutes = Math.floor(seconds / 60);
        const remainingSeconds = Math.floor(seconds % 60);
        return `${minutes}:${remainingSeconds.toString().padStart(2, '0')}`;
    }

    // Specialized Audio Tests

    async testMicrophone() {
        if (this.isPlaying) {
            this.stopAllAudio();
        }

        try {
            console.log('Starting microphone test...');

            // Use the audio engine's microphone test
            if (this.audioEngine && this.audioEngine.startMicrophoneTest) {
                this.audioEngine.startMicrophoneTest();
                this.updatePlaybackStatus('Testing microphone - speak now...');

                // Auto-stop after 10 seconds
                setTimeout(() => {
                    this.updatePlaybackStatus('Microphone test completed');
                }, 10000);
            } else {
                this.updatePlaybackStatus('Microphone test not available');
            }

        } catch (error) {
            console.error('Microphone test failed:', error);
            this.updatePlaybackStatus('Microphone test failed');
        }
    }

    async testSpeakers() {
        if (this.isPlaying) {
            this.stopAllAudio();
        }

        try {
            console.log('Starting speaker test...');

            // Use the audio engine's speaker test
            if (this.audioEngine && this.audioEngine.testSpeakers) {
                await this.audioEngine.testSpeakers();
                this.updatePlaybackStatus('Speaker test completed (440Hz tone)');
            } else {
                // Fallback: play a test tone manually
                await this.playTestTone(440, 1000); // 440Hz for 1 second
                this.updatePlaybackStatus('Speaker test completed');
            }

        } catch (error) {
            console.error('Speaker test failed:', error);
            this.updatePlaybackStatus('Speaker test failed');
        }
    }

    async test3DAudio() {
        if (this.isPlaying) {
            this.stopAllAudio();
        }

        try {
            console.log('Starting 3D audio test...');

            // Play the main test file with 3D positioning
            const mainTestFile = this.audioFiles.get('main_test');
            if (mainTestFile && mainTestFile.loaded) {
                // Enable spatial audio
                document.getElementById('spatial-audio-test').checked = true;

                // Create 3D positioned audio source
                if (this.spatialAudio) {
                    const testId = 'spatial_test_' + Date.now();

                    // Position audio source to the right
                    const position = { x: 5, y: 0, z: 0 };

                    // Play with spatial positioning
                    await this.playSpatialAudio(mainTestFile, position, testId);

                    this.updatePlaybackStatus('Playing 3D spatial audio test (positioned right)');

                    // Move audio source around after 2 seconds
                    setTimeout(() => {
                        if (this.spatialAudio && this.testSources.has(testId)) {
                            // Move to left
                            this.spatialAudio.setUserPosition(testId, { x: -5, y: 0, z: 0 });
                            this.updatePlaybackStatus('3D audio moved to left position');
                        }
                    }, 2000);

                    // Move to front after 4 seconds
                    setTimeout(() => {
                        if (this.spatialAudio && this.testSources.has(testId)) {
                            this.spatialAudio.setUserPosition(testId, { x: 0, y: 0, z: 5 });
                            this.updatePlaybackStatus('3D audio moved to front position');
                        }
                    }, 4000);

                } else {
                    // Fallback to regular playback
                    const playButton = document.querySelector(`[data-file-id="main_test"]`);
                    await this.playAudio(mainTestFile, playButton);
                    this.updatePlaybackStatus('3D audio not available - playing standard audio');
                }
            } else {
                this.updatePlaybackStatus('3D audio test file not available');
            }

        } catch (error) {
            console.error('3D audio test failed:', error);
            this.updatePlaybackStatus('3D audio test failed');
        }
    }

    async playSpatialAudio(fileData, position, testId) {
        // This would integrate with the spatial audio engine
        // For now, play regular audio
        const playButton = document.querySelector(`[data-file-id="${fileData.id}"]`);
        await this.playAudio(fileData, playButton);

        // Store test source reference
        this.testSources.set(testId, {
            audio: fileData.audio,
            position,
            stop: () => this.stopCurrentAudio()
        });
    }

    async playTestTone(frequency, duration) {
        if (!this.audioEngine || !this.audioEngine.audioContext) {
            console.warn('Audio context not available for test tone');
            return;
        }

        const audioContext = this.audioEngine.audioContext;
        const oscillator = audioContext.createOscillator();
        const gainNode = audioContext.createGain();

        oscillator.type = 'sine';
        oscillator.frequency.setValueAtTime(frequency, audioContext.currentTime);

        gainNode.gain.setValueAtTime(0, audioContext.currentTime);
        gainNode.gain.linearRampToValueAtTime(0.1, audioContext.currentTime + 0.05);
        gainNode.gain.linearRampToValueAtTime(0, audioContext.currentTime + duration / 1000 - 0.05);

        oscillator.connect(gainNode);
        gainNode.connect(audioContext.destination);

        oscillator.start(audioContext.currentTime);
        oscillator.stop(audioContext.currentTime + duration / 1000);

        return new Promise(resolve => {
            oscillator.onended = resolve;
        });
    }

    populateOutputDevices() {
        const outputSelect = document.getElementById('test-output-device');
        if (!outputSelect) return;

        // Get available devices from audio engine
        if (this.audioEngine && this.audioEngine.getDevices) {
            const devices = this.audioEngine.getDevices();
            outputSelect.innerHTML = '';

            devices.outputs.forEach(device => {
                const option = document.createElement('option');
                option.value = device.id;
                option.textContent = device.name;
                outputSelect.appendChild(option);
            });
        }
    }

    addAudioTestStyles() {
        if (document.getElementById('audio-test-styles')) return;

        const styles = document.createElement('style');
        styles.id = 'audio-test-styles';
        styles.textContent = `
            .audio-test-panel {
                position: fixed;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                width: 600px;
                max-height: 80vh;
                background: rgba(0, 0, 0, 0.9);
                border-radius: 15px;
                border: 2px solid rgba(255, 255, 255, 0.3);
                color: white;
                z-index: 10000;
                backdrop-filter: blur(10px);
                overflow-y: auto;
            }

            .audio-test-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 1rem;
                border-bottom: 1px solid rgba(255, 255, 255, 0.2);
            }

            .audio-test-header h3 {
                margin: 0;
                font-size: 1.2rem;
            }

            .audio-test-controls {
                display: flex;
                gap: 0.5rem;
            }

            .stop-btn, .close-btn {
                padding: 0.5rem;
                border: none;
                border-radius: 5px;
                cursor: pointer;
                font-size: 0.9rem;
            }

            .stop-btn {
                background: #f44336;
                color: white;
            }

            .stop-btn:disabled {
                background: #666;
                cursor: not-allowed;
            }

            .close-btn {
                background: #666;
                color: white;
            }

            .audio-test-content {
                padding: 1rem;
            }

            .current-playback {
                background: rgba(255, 255, 255, 0.1);
                border-radius: 8px;
                padding: 1rem;
                margin-bottom: 1rem;
            }

            .progress-bar {
                margin-top: 0.5rem;
                background: rgba(255, 255, 255, 0.2);
                border-radius: 10px;
                height: 20px;
                position: relative;
                overflow: hidden;
            }

            .progress-fill {
                height: 100%;
                background: linear-gradient(90deg, #4CAF50, #45a049);
                width: 0%;
                transition: width 0.1s ease;
            }

            .time-display {
                position: absolute;
                top: 50%;
                left: 50%;
                transform: translate(-50%, -50%);
                font-size: 0.8rem;
                text-shadow: 1px 1px 2px rgba(0, 0, 0, 0.8);
            }

            .audio-test-files {
                max-height: 300px;
                overflow-y: auto;
                margin-bottom: 1rem;
            }

            .audio-test-file {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 0.75rem;
                margin: 0.5rem 0;
                background: rgba(255, 255, 255, 0.1);
                border-radius: 8px;
                border: 1px solid rgba(255, 255, 255, 0.2);
            }

            .file-info {
                flex: 1;
            }

            .file-name {
                font-weight: bold;
                margin-bottom: 0.25rem;
            }

            .file-name .duration {
                color: #ccc;
                font-size: 0.9rem;
            }

            .file-description {
                font-size: 0.8rem;
                color: #bbb;
            }

            .file-controls {
                margin-left: 1rem;
            }

            .play-btn {
                padding: 0.5rem 1rem;
                border: none;
                border-radius: 5px;
                background: #4CAF50;
                color: white;
                cursor: pointer;
                font-size: 0.9rem;
            }

            .play-btn:hover {
                background: #45a049;
            }

            .play-btn:disabled {
                background: #666;
                cursor: not-allowed;
            }

            .play-btn.playing {
                background: #f44336;
            }

            .audio-test-options {
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 1rem;
                margin: 1rem 0;
                padding: 1rem;
                background: rgba(255, 255, 255, 0.05);
                border-radius: 8px;
            }

            .test-option {
                display: flex;
                align-items: center;
                gap: 0.5rem;
            }

            .test-option input[type="range"] {
                flex: 1;
            }

            .test-option select {
                flex: 1;
                padding: 0.25rem;
                border-radius: 4px;
                border: 1px solid #666;
                background: #333;
                color: white;
            }

            .audio-test-actions {
                display: flex;
                gap: 0.5rem;
                justify-content: center;
            }

            .test-btn {
                padding: 0.75rem 1rem;
                border: none;
                border-radius: 8px;
                background: linear-gradient(45deg, #2196F3, #1976D2);
                color: white;
                cursor: pointer;
                font-size: 0.9rem;
            }

            .test-btn:hover {
                transform: translateY(-1px);
                box-shadow: 0 4px 12px rgba(33, 150, 243, 0.3);
            }

            .hidden {
                display: none !important;
            }
        `;

        document.head.appendChild(styles);
    }

    // Public interface methods

    showAudioTestPanel() {
        this.audioTestPanel.classList.remove('hidden');
    }

    hideAudioTestPanel() {
        this.stopAllAudio();
        this.audioTestPanel.classList.add('hidden');
    }

    toggleAudioTestPanel() {
        if (this.audioTestPanel.classList.contains('hidden')) {
            this.showAudioTestPanel();
        } else {
            this.hideAudioTestPanel();
        }
    }

    // Basic audio test method for simple testing
    async runBasicTest() {
        try {
            console.log('Running basic audio test...');
            console.log('Audio engine available:', !!this.audioEngine);
            console.log('Audio context available:', !!this.audioEngine?.audioContext);
            console.log('Audio context state:', this.audioEngine?.audioContext?.state);

            // Check if we have audio files loaded
            if (this.testFiles && this.testFiles.length > 0) {
                console.log('Attempting to play test file...');
                // Try to play the first available test file
                const firstTest = this.testFiles[0];
                const button = document.createElement('button'); // Temporary button for test

                await this.toggleAudioPlayback(firstTest.id, button);
                console.log('Basic audio test completed using test file');
                return;
            }

            // Fallback to tone generation
            console.log('No test files available, generating tone...');
            await this.generateTestTone();
            console.log('Basic audio test completed using generated tone');

        } catch (error) {
            console.error('Basic audio test failed:', error);
            throw error;
        }
    }

    // Generate a simple test tone
    async generateTestTone() {
        if (!this.audioEngine || !this.audioEngine.audioContext) {
            throw new Error('Audio engine not available');
        }

        const audioContext = this.audioEngine.audioContext;

        // Ensure audio context is running (Safari requirement)
        if (audioContext.state === 'suspended') {
            await audioContext.resume();
        }

        // Stop any currently playing audio
        this.stopCurrentAudio();

        console.log('Generating test tone chord progression...');

        // Configure test tone - play a nice chord progression
        const frequencies = [440, 554.37, 659.25]; // A-C#-E chord
        let startTime = audioContext.currentTime;

        frequencies.forEach((freq, index) => {
            const osc = audioContext.createOscillator();
            const gain = audioContext.createGain();

            osc.connect(gain);
            gain.connect(audioContext.destination);

            osc.frequency.setValueAtTime(freq, startTime);
            osc.type = 'sine';

            // Volume envelope - increased volume for audibility
            gain.gain.setValueAtTime(0, startTime);
            gain.gain.linearRampToValueAtTime(0.3, startTime + 0.1); // Increased from 0.15 to 0.3
            gain.gain.linearRampToValueAtTime(0.1, startTime + 0.7);  // Changed to linear ramp and higher end volume
            gain.gain.linearRampToValueAtTime(0, startTime + 0.8);

            console.log(`Starting oscillator ${index + 1} at ${freq}Hz, time: ${startTime}`);

            osc.start(startTime);
            osc.stop(startTime + 0.8);

            startTime += 0.3; // Stagger the notes
        });

        // Mark as playing
        this.isPlaying = true;

        // Set timeout to mark as stopped
        setTimeout(() => {
            this.isPlaying = false;
        }, 1500);

        return Promise.resolve();
    }

    // Get test status
    getTestStatus() {
        return {
            isPlaying: this.isPlaying,
            currentAudio: this.currentAudio,
            availableTests: this.testFiles.length,
            audioEngine: !!this.audioEngine,
            spatialAudio: !!this.spatialAudio
        };
    }
}

// Export for use in other modules
window.AudioTestManager = AudioTestManager;