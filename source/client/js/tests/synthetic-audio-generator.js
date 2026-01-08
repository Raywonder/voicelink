class SyntheticAudioGenerator {
    constructor() {
        this.ttsApi = null;
        this.apiKey = null; // Will be set via settings
        this.supportedVoices = [
            { id: 'rachel', name: 'Rachel (Natural)', gender: 'female', accent: 'american' },
            { id: 'clyde', name: 'Clyde (Strong)', gender: 'male', accent: 'american' },
            { id: 'domi', name: 'Domi (Strong)', gender: 'female', accent: 'american' },
            { id: 'dave', name: 'Dave (Conversational)', gender: 'male', accent: 'british' },
            { id: 'fin', name: 'Fin (Sailor)', gender: 'male', accent: 'irish' },
            { id: 'sarah', name: 'Sarah (Soft)', gender: 'female', accent: 'american' },
            { id: 'antoni', name: 'Antoni (Well-rounded)', gender: 'male', accent: 'american' },
            { id: 'thomas', name: 'Thomas (Calm)', gender: 'male', accent: 'american' }
        ];

        this.testScenarios = [
            {
                id: 'spatial_directions',
                name: '3D Spatial Direction Test',
                texts: [
                    'Testing audio from the left side',
                    'Testing audio from the right side',
                    'Testing audio from behind you',
                    'Testing audio from in front of you',
                    'Testing audio from above',
                    'Testing audio from below'
                ],
                positions: [
                    { x: -5, y: 0, z: 0 },
                    { x: 5, y: 0, z: 0 },
                    { x: 0, y: 0, z: -5 },
                    { x: 0, y: 0, z: 5 },
                    { x: 0, y: 5, z: 0 },
                    { x: 0, y: -5, z: 0 }
                ]
            },
            {
                id: 'distance_test',
                name: 'Distance Perception Test',
                texts: [
                    'Very close whisper - one meter away',
                    'Normal conversation - three meters away',
                    'Speaking from across the room - seven meters away',
                    'Shouting from far distance - fifteen meters away'
                ],
                positions: [
                    { x: 1, y: 0, z: 0 },
                    { x: 3, y: 0, z: 0 },
                    { x: 7, y: 0, z: 0 },
                    { x: 15, y: 0, z: 0 }
                ]
            },
            {
                id: 'multi_voice_test',
                name: 'Multi-Voice Separation Test',
                texts: [
                    'Speaker one from the left side',
                    'Speaker two from the right side',
                    'Speaker three from behind you',
                    'Speaker four from in front'
                ],
                voices: ['rachel', 'clyde', 'domi', 'dave'],
                positions: [
                    { x: -3, y: 0, z: 0 },
                    { x: 3, y: 0, z: 0 },
                    { x: 0, y: 0, z: -3 },
                    { x: 0, y: 0, z: 3 }
                ]
            },
            {
                id: 'room_acoustics_test',
                name: 'Room Acoustics Test',
                texts: [
                    'Testing in anechoic chamber environment',
                    'Testing in small room with reflections',
                    'Testing in large hall with reverb',
                    'Testing in outdoor open space'
                ],
                roomTypes: ['anechoic', 'small-room', 'large-room', 'outdoor']
            },
            {
                id: 'frequency_test',
                name: 'Frequency Range Test',
                texts: [
                    'Low frequency bass voice test',
                    'Mid frequency normal speech test',
                    'High frequency clear voice test',
                    'Full range dynamic voice test'
                ],
                frequencies: ['low', 'mid', 'high', 'full']
            }
        ];

        this.generatedTests = new Map();
        this.isGenerating = false;
    }

    // Set API key for Eleven Labs or other TTS service
    setApiKey(apiKey, provider = 'elevenlabs') {
        this.apiKey = apiKey;
        this.ttsApi = provider;
    }

    // Generate all test audio files
    async generateAllTests(progressCallback = null) {
        if (!this.apiKey) {
            throw new Error('API key not configured. Please set API key in settings.');
        }

        this.isGenerating = true;
        const totalTests = this.testScenarios.reduce((sum, scenario) => sum + scenario.texts.length, 0);
        let completed = 0;

        try {
            for (const scenario of this.testScenarios) {
                await this.generateScenarioTests(scenario, (progress) => {
                    completed++;
                    if (progressCallback) {
                        progressCallback(completed, totalTests, scenario.name);
                    }
                });
            }
        } finally {
            this.isGenerating = false;
        }
    }

    // Generate tests for a specific scenario
    async generateScenarioTests(scenario, progressCallback = null) {
        const scenarioTests = [];

        for (let i = 0; i < scenario.texts.length; i++) {
            const text = scenario.texts[i];
            const voiceId = scenario.voices ? scenario.voices[i % scenario.voices.length] : 'rachel';

            try {
                const audioData = await this.generateSpeech(text, voiceId);
                const testData = {
                    id: `${scenario.id}_${i}`,
                    name: `${scenario.name} - ${i + 1}`,
                    text: text,
                    voice: voiceId,
                    audioData: audioData,
                    position: scenario.positions ? scenario.positions[i] : { x: 0, y: 0, z: 0 },
                    roomType: scenario.roomTypes ? scenario.roomTypes[i] : 'large-room',
                    frequency: scenario.frequencies ? scenario.frequencies[i] : 'full'
                };

                scenarioTests.push(testData);

                if (progressCallback) {
                    progressCallback(testData);
                }
            } catch (error) {
                console.error(`Failed to generate audio for "${text}":`, error);
            }
        }

        this.generatedTests.set(scenario.id, scenarioTests);
        return scenarioTests;
    }

    // Generate speech using TTS API
    async generateSpeech(text, voiceId = 'rachel', options = {}) {
        const defaultOptions = {
            model_id: 'eleven_monolingual_v1',
            voice_settings: {
                stability: 0.5,
                similarity_boost: 0.5,
                style: 0.0,
                use_speaker_boost: true
            }
        };

        const settings = { ...defaultOptions, ...options };

        if (this.ttsApi === 'elevenlabs') {
            return await this.generateElevenLabsSpeech(text, voiceId, settings);
        } else {
            // Fallback to Web Speech API for testing
            return await this.generateWebSpeechSynthesis(text, voiceId);
        }
    }

    // Generate speech using Eleven Labs API
    async generateElevenLabsSpeech(text, voiceId, settings) {
        const url = `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`;

        const response = await fetch(url, {
            method: 'POST',
            headers: {
                'Accept': 'audio/mpeg',
                'Content-Type': 'application/json',
                'xi-api-key': this.apiKey
            },
            body: JSON.stringify({
                text: text,
                model_id: settings.model_id,
                voice_settings: settings.voice_settings
            })
        });

        if (!response.ok) {
            throw new Error(`Eleven Labs API error: ${response.status} ${response.statusText}`);
        }

        const arrayBuffer = await response.arrayBuffer();
        return arrayBuffer;
    }

    // Fallback: Generate speech using Web Speech API
    async generateWebSpeechSynthesis(text, voiceId) {
        return new Promise((resolve, reject) => {
            if (!('speechSynthesis' in window)) {
                reject(new Error('Speech synthesis not supported'));
                return;
            }

            const utterance = new SpeechSynthesisUtterance(text);
            const voices = speechSynthesis.getVoices();

            // Try to match voice characteristics
            const voice = voices.find(v =>
                v.name.toLowerCase().includes(voiceId) ||
                (voiceId === 'rachel' && v.name.toLowerCase().includes('female')) ||
                (voiceId === 'clyde' && v.name.toLowerCase().includes('male'))
            ) || voices[0];

            if (voice) {
                utterance.voice = voice;
            }

            utterance.rate = 1.0;
            utterance.pitch = 1.0;
            utterance.volume = 1.0;

            // Capture audio using MediaRecorder (simplified approach)
            utterance.onend = () => {
                // For web speech synthesis, we'll return a placeholder
                // In a real implementation, you'd need to capture the audio output
                const placeholder = new ArrayBuffer(8);
                resolve(placeholder);
            };

            utterance.onerror = (event) => {
                reject(new Error(`Speech synthesis error: ${event.error}`));
            };

            speechSynthesis.speak(utterance);
        });
    }

    // Play a generated test with 3D positioning
    async playTest(testId, spatialAudioEngine = null) {
        const test = this.findTestById(testId);
        if (!test) {
            throw new Error(`Test not found: ${testId}`);
        }

        try {
            // Convert audio data to playable format
            const audioContext = spatialAudioEngine?.audioContext || new AudioContext();
            const audioBuffer = await audioContext.decodeAudioData(test.audioData.slice());

            // Create source
            const source = audioContext.createBufferSource();
            source.buffer = audioBuffer;

            if (spatialAudioEngine && test.position) {
                // Use spatial audio if available
                const spatialNode = spatialAudioEngine.createSpatialNode(testId, source);
                spatialAudioEngine.updateUserPosition(testId, test.position.x, test.position.y, test.position.z);
                source.connect(spatialNode);
                spatialNode.connect(audioContext.destination);
            } else {
                // Standard stereo playback
                source.connect(audioContext.destination);
            }

            // Play audio
            source.start();

            return new Promise((resolve) => {
                source.onended = resolve;
            });
        } catch (error) {
            console.error('Error playing test audio:', error);
            throw error;
        }
    }

    // Find a test by ID
    findTestById(testId) {
        for (const [scenarioId, tests] of this.generatedTests) {
            const test = tests.find(t => t.id === testId);
            if (test) return test;
        }
        return null;
    }

    // Get all tests for a scenario
    getScenarioTests(scenarioId) {
        return this.generatedTests.get(scenarioId) || [];
    }

    // Get all generated tests
    getAllTests() {
        const allTests = [];
        for (const [scenarioId, tests] of this.generatedTests) {
            allTests.push(...tests);
        }
        return allTests;
    }

    // Create test audio using tone generation (for testing without API)
    generateToneTest(frequency = 440, duration = 1, position = { x: 0, y: 0, z: 0 }) {
        const sampleRate = 44100;
        const samples = sampleRate * duration;
        const audioBuffer = new Float32Array(samples);

        for (let i = 0; i < samples; i++) {
            audioBuffer[i] = Math.sin(2 * Math.PI * frequency * i / sampleRate) * 0.3;
        }

        return {
            id: `tone_${frequency}hz`,
            name: `${frequency}Hz Tone Test`,
            audioData: audioBuffer,
            position: position,
            type: 'tone'
        };
    }

    // Generate pink noise for testing
    generatePinkNoiseTest(duration = 2, position = { x: 0, y: 0, z: 0 }) {
        const sampleRate = 44100;
        const samples = sampleRate * duration;
        const audioBuffer = new Float32Array(samples);

        // Simple pink noise generation
        let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;

        for (let i = 0; i < samples; i++) {
            const white = Math.random() * 2 - 1;
            b0 = 0.99886 * b0 + white * 0.0555179;
            b1 = 0.99332 * b1 + white * 0.0750759;
            b2 = 0.96900 * b2 + white * 0.1538520;
            b3 = 0.86650 * b3 + white * 0.3104856;
            b4 = 0.55000 * b4 + white * 0.5329522;
            b5 = -0.7616 * b5 - white * 0.0168980;

            const pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362;
            b6 = white * 0.115926;

            audioBuffer[i] = pink * 0.11;
        }

        return {
            id: 'pink_noise',
            name: 'Pink Noise Test',
            audioData: audioBuffer,
            position: position,
            type: 'noise'
        };
    }

    // Export generated tests
    exportTests() {
        const exportData = {
            timestamp: new Date().toISOString(),
            scenarios: this.testScenarios,
            tests: Object.fromEntries(this.generatedTests)
        };

        const blob = new Blob([JSON.stringify(exportData, null, 2)], { type: 'application/json' });
        const url = URL.createObjectURL(blob);

        const a = document.createElement('a');
        a.href = url;
        a.download = 'voicelink-audio-tests.json';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }

    // Import tests
    async importTests(file) {
        const text = await file.text();
        const data = JSON.parse(text);

        if (data.tests) {
            for (const [scenarioId, tests] of Object.entries(data.tests)) {
                this.generatedTests.set(scenarioId, tests);
            }
        }
    }

    // Get generation status
    getStatus() {
        return {
            isGenerating: this.isGenerating,
            hasApiKey: !!this.apiKey,
            totalScenarios: this.testScenarios.length,
            generatedScenarios: this.generatedTests.size,
            totalTests: this.getAllTests().length
        };
    }
}

// Initialize synthetic audio generator
window.syntheticAudioGenerator = new SyntheticAudioGenerator();