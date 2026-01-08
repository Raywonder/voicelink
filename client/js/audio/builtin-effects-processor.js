class BuiltinEffectsProcessor {
    constructor(audioContext) {
        this.audioContext = audioContext;
        this.effectsChain = new Map();
        this.presets = new Map();
        this.masterGain = audioContext.createGain();
        this.masterGain.gain.value = 1.0;

        // Available effect types
        this.availableEffects = {
            reverb: 'Reverb',
            noiseGate: 'Noise Gate',
            eq: '3-Band EQ',
            distortion: 'Distortion',
            drive: 'Tube Drive',
            compressor: 'Compressor',
            chorus: 'Chorus',
            delay: 'Delay',
            phaser: 'Phaser',
            flanger: 'Flanger',
            bitCrusher: 'Bit Crusher',
            exciter: 'Harmonic Exciter',
            deEsser: 'De-Esser',
            enhancer: 'Voice Enhancer',
            robotizer: 'Robotizer'
        };

        this.init();
    }

    init() {
        this.createEffectPresets();
        this.initializeImpulseResponses();
    }

    // Create effect with parameters
    createEffect(type, parameters = {}) {
        const effectId = `${type}_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

        switch (type) {
            case 'reverb':
                return this.createReverbEffect(effectId, parameters);
            case 'noiseGate':
                return this.createNoiseGateEffect(effectId, parameters);
            case 'eq':
                return this.createEQEffect(effectId, parameters);
            case 'distortion':
                return this.createDistortionEffect(effectId, parameters);
            case 'drive':
                return this.createDriveEffect(effectId, parameters);
            case 'compressor':
                return this.createCompressorEffect(effectId, parameters);
            case 'chorus':
                return this.createChorusEffect(effectId, parameters);
            case 'delay':
                return this.createDelayEffect(effectId, parameters);
            case 'phaser':
                return this.createPhaserEffect(effectId, parameters);
            case 'flanger':
                return this.createFlangerEffect(effectId, parameters);
            case 'bitCrusher':
                return this.createBitCrusherEffect(effectId, parameters);
            case 'exciter':
                return this.createExciterEffect(effectId, parameters);
            case 'deEsser':
                return this.createDeEsserEffect(effectId, parameters);
            case 'enhancer':
                return this.createEnhancerEffect(effectId, parameters);
            case 'robotizer':
                return this.createRobotizerEffect(effectId, parameters);
            default:
                throw new Error(`Unknown effect type: ${type}`);
        }
    }

    // Reverb Effect
    createReverbEffect(effectId, params = {}) {
        const defaults = {
            roomSize: 0.5,
            wetness: 0.3,
            dryness: 0.7,
            damping: 0.2,
            roomType: 'hall' // hall, room, chamber, plate, spring
        };

        const settings = { ...defaults, ...params };
        const convolver = this.audioContext.createConvolver();
        const wetGain = this.audioContext.createGain();
        const dryGain = this.audioContext.createGain();
        const output = this.audioContext.createGain();

        wetGain.gain.value = settings.wetness;
        dryGain.gain.value = settings.dryness;

        // Generate impulse response based on room type and size
        convolver.buffer = this.generateReverbImpulse(settings.roomType, settings.roomSize, settings.damping);

        const effect = {
            id: effectId,
            type: 'reverb',
            input: this.audioContext.createGain(),
            output: output,
            nodes: { convolver, wetGain, dryGain },
            parameters: settings
        };

        // Connect audio graph
        effect.input.connect(dryGain);
        effect.input.connect(convolver);
        convolver.connect(wetGain);
        dryGain.connect(output);
        wetGain.connect(output);

        return effect;
    }

    // Noise Gate Effect
    createNoiseGateEffect(effectId, params = {}) {
        const defaults = {
            threshold: -40, // dB
            ratio: 10,
            attack: 0.001, // seconds
            release: 0.1, // seconds
            knee: 0
        };

        const settings = { ...defaults, ...params };

        // Use scriptProcessor for more precise gating
        const processor = this.audioContext.createScriptProcessor(4096, 1, 1);
        let envelope = 0;

        processor.onaudioprocess = (event) => {
            const input = event.inputBuffer.getChannelData(0);
            const output = event.outputBuffer.getChannelData(0);

            for (let i = 0; i < input.length; i++) {
                const inputLevel = Math.abs(input[i]);
                const inputLevelDb = 20 * Math.log10(inputLevel + 1e-10);

                // Calculate gate reduction
                let gateReduction = 1;
                if (inputLevelDb < settings.threshold) {
                    gateReduction = 1 / settings.ratio;
                }

                // Apply attack/release envelope
                const targetGain = gateReduction;
                const rate = targetGain > envelope ? settings.attack : settings.release;
                envelope += (targetGain - envelope) * (1 - Math.exp(-1 / (rate * this.audioContext.sampleRate)));

                output[i] = input[i] * envelope;
            }
        };

        const effect = {
            id: effectId,
            type: 'noiseGate',
            input: processor,
            output: processor,
            nodes: { processor },
            parameters: settings
        };

        return effect;
    }

    // 3-Band EQ Effect
    createEQEffect(effectId, params = {}) {
        const defaults = {
            lowGain: 0, // dB
            midGain: 0, // dB
            highGain: 0, // dB
            lowFreq: 320,
            highFreq: 3200
        };

        const settings = { ...defaults, ...params };

        const lowShelf = this.audioContext.createBiquadFilter();
        const midPeak = this.audioContext.createBiquadFilter();
        const highShelf = this.audioContext.createBiquadFilter();

        lowShelf.type = 'lowshelf';
        lowShelf.frequency.value = settings.lowFreq;
        lowShelf.gain.value = settings.lowGain;

        midPeak.type = 'peaking';
        midPeak.frequency.value = Math.sqrt(settings.lowFreq * settings.highFreq);
        midPeak.Q.value = 0.7;
        midPeak.gain.value = settings.midGain;

        highShelf.type = 'highshelf';
        highShelf.frequency.value = settings.highFreq;
        highShelf.gain.value = settings.highGain;

        // Connect EQ chain
        lowShelf.connect(midPeak);
        midPeak.connect(highShelf);

        const effect = {
            id: effectId,
            type: 'eq',
            input: lowShelf,
            output: highShelf,
            nodes: { lowShelf, midPeak, highShelf },
            parameters: settings
        };

        return effect;
    }

    // Distortion Effect
    createDistortionEffect(effectId, params = {}) {
        const defaults = {
            amount: 20,
            tone: 2000,
            level: 1.0
        };

        const settings = { ...defaults, ...params };

        const waveshaper = this.audioContext.createWaveShaper();
        const preGain = this.audioContext.createGain();
        const toneFilter = this.audioContext.createBiquadFilter();
        const postGain = this.audioContext.createGain();

        preGain.gain.value = settings.amount;
        postGain.gain.value = settings.level / settings.amount;

        toneFilter.type = 'lowpass';
        toneFilter.frequency.value = settings.tone;

        // Create distortion curve
        const samples = 44100;
        const curve = new Float32Array(samples);
        const deg = Math.PI / 180;

        for (let i = 0; i < samples; i++) {
            const x = (i * 2) / samples - 1;
            curve[i] = ((3 + settings.amount) * x * 20 * deg) / (Math.PI + settings.amount * Math.abs(x));
        }

        waveshaper.curve = curve;
        waveshaper.oversample = '4x';

        // Connect distortion chain
        preGain.connect(waveshaper);
        waveshaper.connect(toneFilter);
        toneFilter.connect(postGain);

        const effect = {
            id: effectId,
            type: 'distortion',
            input: preGain,
            output: postGain,
            nodes: { preGain, waveshaper, toneFilter, postGain },
            parameters: settings
        };

        return effect;
    }

    // Tube Drive Effect
    createDriveEffect(effectId, params = {}) {
        const defaults = {
            drive: 5,
            tone: 1000,
            level: 0.8,
            warmth: 0.3
        };

        const settings = { ...defaults, ...params };

        const preGain = this.audioContext.createGain();
        const waveshaper = this.audioContext.createWaveShaper();
        const toneStack = this.audioContext.createBiquadFilter();
        const warmthFilter = this.audioContext.createBiquadFilter();
        const postGain = this.audioContext.createGain();

        preGain.gain.value = settings.drive;
        postGain.gain.value = settings.level;

        // Tube-style saturation curve
        const samples = 44100;
        const curve = new Float32Array(samples);

        for (let i = 0; i < samples; i++) {
            const x = (i * 2) / samples - 1;
            // Soft tube saturation
            curve[i] = Math.tanh(x * settings.drive) * (1 + settings.warmth * Math.sin(x * Math.PI));
        }

        waveshaper.curve = curve;
        waveshaper.oversample = '2x';

        toneStack.type = 'peaking';
        toneStack.frequency.value = settings.tone;
        toneStack.Q.value = 0.5;
        toneStack.gain.value = 3;

        warmthFilter.type = 'lowpass';
        warmthFilter.frequency.value = 5000 - (settings.warmth * 2000);
        warmthFilter.Q.value = 0.7;

        // Connect tube drive chain
        preGain.connect(waveshaper);
        waveshaper.connect(toneStack);
        toneStack.connect(warmthFilter);
        warmthFilter.connect(postGain);

        const effect = {
            id: effectId,
            type: 'drive',
            input: preGain,
            output: postGain,
            nodes: { preGain, waveshaper, toneStack, warmthFilter, postGain },
            parameters: settings
        };

        return effect;
    }

    // Compressor Effect
    createCompressorEffect(effectId, params = {}) {
        const defaults = {
            threshold: -18,
            knee: 6,
            ratio: 4,
            attack: 0.003,
            release: 0.25,
            makeupGain: 1.0
        };

        const settings = { ...defaults, ...params };

        const compressor = this.audioContext.createDynamicsCompressor();
        const makeupGain = this.audioContext.createGain();

        compressor.threshold.value = settings.threshold;
        compressor.knee.value = settings.knee;
        compressor.ratio.value = settings.ratio;
        compressor.attack.value = settings.attack;
        compressor.release.value = settings.release;

        makeupGain.gain.value = settings.makeupGain;

        compressor.connect(makeupGain);

        const effect = {
            id: effectId,
            type: 'compressor',
            input: compressor,
            output: makeupGain,
            nodes: { compressor, makeupGain },
            parameters: settings
        };

        return effect;
    }

    // Chorus Effect
    createChorusEffect(effectId, params = {}) {
        const defaults = {
            rate: 0.5, // Hz
            depth: 0.002, // seconds
            wetness: 0.5,
            voices: 3
        };

        const settings = { ...defaults, ...params };

        const delays = [];
        const lfos = [];
        const wetGain = this.audioContext.createGain();
        const dryGain = this.audioContext.createGain();
        const output = this.audioContext.createGain();

        wetGain.gain.value = settings.wetness;
        dryGain.gain.value = 1 - settings.wetness;

        // Create multiple delayed voices
        for (let i = 0; i < settings.voices; i++) {
            const delay = this.audioContext.createDelay(0.1);
            const lfo = this.audioContext.createOscillator();
            const lfoGain = this.audioContext.createGain();

            lfo.type = 'sine';
            lfo.frequency.value = settings.rate * (1 + i * 0.1);
            lfoGain.gain.value = settings.depth;

            delay.delayTime.value = 0.01 + (i * 0.005);

            lfo.connect(lfoGain);
            lfoGain.connect(delay.delayTime);
            delay.connect(wetGain);

            lfo.start();

            delays.push(delay);
            lfos.push({ lfo, lfoGain });
        }

        const splitter = this.audioContext.createGain();

        const effect = {
            id: effectId,
            type: 'chorus',
            input: splitter,
            output: output,
            nodes: { splitter, delays, lfos, wetGain, dryGain },
            parameters: settings
        };

        // Connect audio graph
        splitter.connect(dryGain);
        delays.forEach(delay => splitter.connect(delay));
        dryGain.connect(output);
        wetGain.connect(output);

        return effect;
    }

    // Delay Effect
    createDelayEffect(effectId, params = {}) {
        const defaults = {
            time: 0.25, // seconds
            feedback: 0.3,
            wetness: 0.3,
            highCut: 5000
        };

        const settings = { ...defaults, ...params };

        const delay = this.audioContext.createDelay(2.0);
        const feedback = this.audioContext.createGain();
        const wetGain = this.audioContext.createGain();
        const dryGain = this.audioContext.createGain();
        const highCut = this.audioContext.createBiquadFilter();
        const output = this.audioContext.createGain();

        delay.delayTime.value = settings.time;
        feedback.gain.value = settings.feedback;
        wetGain.gain.value = settings.wetness;
        dryGain.gain.value = 1 - settings.wetness;

        highCut.type = 'lowpass';
        highCut.frequency.value = settings.highCut;
        highCut.Q.value = 0.7;

        const effect = {
            id: effectId,
            type: 'delay',
            input: this.audioContext.createGain(),
            output: output,
            nodes: { delay, feedback, wetGain, dryGain, highCut },
            parameters: settings
        };

        // Connect delay feedback loop
        effect.input.connect(dryGain);
        effect.input.connect(delay);
        delay.connect(highCut);
        highCut.connect(feedback);
        feedback.connect(delay);
        delay.connect(wetGain);
        dryGain.connect(output);
        wetGain.connect(output);

        return effect;
    }

    // Bit Crusher Effect
    createBitCrusherEffect(effectId, params = {}) {
        const defaults = {
            bits: 8,
            sampleRate: 8000,
            mix: 1.0
        };

        const settings = { ...defaults, ...params };

        const processor = this.audioContext.createScriptProcessor(4096, 1, 1);
        let sampleCounter = 0;
        let lastSample = 0;

        processor.onaudioprocess = (event) => {
            const input = event.inputBuffer.getChannelData(0);
            const output = event.outputBuffer.getChannelData(0);

            const step = Math.floor(this.audioContext.sampleRate / settings.sampleRate);
            const bitDepth = Math.pow(2, settings.bits - 1);

            for (let i = 0; i < input.length; i++) {
                if (sampleCounter % step === 0) {
                    // Quantize to bit depth
                    lastSample = Math.floor(input[i] * bitDepth) / bitDepth;
                }
                output[i] = input[i] * (1 - settings.mix) + lastSample * settings.mix;
                sampleCounter++;
            }
        };

        const effect = {
            id: effectId,
            type: 'bitCrusher',
            input: processor,
            output: processor,
            nodes: { processor },
            parameters: settings
        };

        return effect;
    }

    // Harmonic Exciter Effect
    createExciterEffect(effectId, params = {}) {
        const defaults = {
            amount: 0.3,
            frequency: 3000,
            harmonics: 2
        };

        const settings = { ...defaults, ...params };

        const splitter = this.audioContext.createGain();
        const highpass = this.audioContext.createBiquadFilter();
        const waveshaper = this.audioContext.createWaveShaper();
        const exciterGain = this.audioContext.createGain();
        const output = this.audioContext.createGain();

        highpass.type = 'highpass';
        highpass.frequency.value = settings.frequency;
        highpass.Q.value = 0.7;

        exciterGain.gain.value = settings.amount;

        // Create harmonic distortion curve
        const samples = 44100;
        const curve = new Float32Array(samples);

        for (let i = 0; i < samples; i++) {
            const x = (i * 2) / samples - 1;
            curve[i] = Math.sin(x * Math.PI * settings.harmonics) * Math.abs(x);
        }

        waveshaper.curve = curve;

        const effect = {
            id: effectId,
            type: 'exciter',
            input: splitter,
            output: output,
            nodes: { splitter, highpass, waveshaper, exciterGain },
            parameters: settings
        };

        // Connect exciter chain
        splitter.connect(output); // Dry signal
        splitter.connect(highpass);
        highpass.connect(waveshaper);
        waveshaper.connect(exciterGain);
        exciterGain.connect(output);

        return effect;
    }

    // Voice Enhancer Effect
    createEnhancerEffect(effectId, params = {}) {
        const defaults = {
            clarity: 0.5,
            warmth: 0.3,
            presence: 0.4,
            deepness: 0.2
        };

        const settings = { ...defaults, ...params };

        const input = this.audioContext.createGain();
        const output = this.audioContext.createGain();

        // Clarity (high-frequency enhancement)
        const clarityFilter = this.audioContext.createBiquadFilter();
        clarityFilter.type = 'peaking';
        clarityFilter.frequency.value = 6000;
        clarityFilter.Q.value = 2;
        clarityFilter.gain.value = settings.clarity * 6;

        // Warmth (low-mid enhancement)
        const warmthFilter = this.audioContext.createBiquadFilter();
        warmthFilter.type = 'peaking';
        warmthFilter.frequency.value = 250;
        warmthFilter.Q.value = 1;
        warmthFilter.gain.value = settings.warmth * 4;

        // Presence (vocal range)
        const presenceFilter = this.audioContext.createBiquadFilter();
        presenceFilter.type = 'peaking';
        presenceFilter.frequency.value = 1500;
        presenceFilter.Q.value = 0.8;
        presenceFilter.gain.value = settings.presence * 5;

        // Deepness (low-end)
        const deepnessFilter = this.audioContext.createBiquadFilter();
        deepnessFilter.type = 'lowshelf';
        deepnessFilter.frequency.value = 100;
        deepnessFilter.gain.value = settings.deepness * 3;

        // Connect enhancement chain
        input.connect(deepnessFilter);
        deepnessFilter.connect(warmthFilter);
        warmthFilter.connect(presenceFilter);
        presenceFilter.connect(clarityFilter);
        clarityFilter.connect(output);

        const effect = {
            id: effectId,
            type: 'enhancer',
            input: input,
            output: output,
            nodes: { clarityFilter, warmthFilter, presenceFilter, deepnessFilter },
            parameters: settings
        };

        return effect;
    }

    // Robotizer Effect
    createRobotizerEffect(effectId, params = {}) {
        const defaults = {
            pitch: 1.0,
            formant: 1.0,
            robotness: 0.8,
            modulation: 2.0
        };

        const settings = { ...defaults, ...params };

        const processor = this.audioContext.createScriptProcessor(4096, 1, 1);
        const lfo = this.audioContext.createOscillator();
        const lfoGain = this.audioContext.createGain();

        lfo.type = 'square';
        lfo.frequency.value = settings.modulation;
        lfoGain.gain.value = settings.robotness;

        let phase = 0;

        processor.onaudioprocess = (event) => {
            const input = event.inputBuffer.getChannelData(0);
            const output = event.outputBuffer.getChannelData(0);

            for (let i = 0; i < input.length; i++) {
                // Simple pitch shifting approximation with ring modulation
                const modulated = input[i] * (1 + Math.sin(phase * settings.pitch) * settings.robotness);
                output[i] = modulated * settings.formant;
                phase += 0.01;
            }
        };

        lfo.start();

        const effect = {
            id: effectId,
            type: 'robotizer',
            input: processor,
            output: processor,
            nodes: { processor, lfo, lfoGain },
            parameters: settings
        };

        return effect;
    }

    // Generate reverb impulse response
    generateReverbImpulse(roomType, size, damping) {
        const sampleRate = this.audioContext.sampleRate;
        const duration = size * 4; // Up to 4 seconds
        const length = sampleRate * duration;
        const impulse = this.audioContext.createBuffer(2, length, sampleRate);

        const roomCharacteristics = {
            hall: { earlyReflections: 0.3, decay: 0.8, diffusion: 0.9 },
            room: { earlyReflections: 0.6, decay: 0.5, diffusion: 0.7 },
            chamber: { earlyReflections: 0.8, decay: 0.3, diffusion: 0.6 },
            plate: { earlyReflections: 0.1, decay: 0.9, diffusion: 0.95 },
            spring: { earlyReflections: 0.05, decay: 0.7, diffusion: 0.3 }
        };

        const characteristics = roomCharacteristics[roomType] || roomCharacteristics.hall;

        for (let channel = 0; channel < 2; channel++) {
            const channelData = impulse.getChannelData(channel);

            for (let i = 0; i < length; i++) {
                const time = i / sampleRate;
                const decay = Math.pow(1 - time / duration, characteristics.decay + damping);
                const diffusion = Math.random() * 2 - 1;

                // Early reflections
                let sample = 0;
                if (time < characteristics.earlyReflections) {
                    sample = (Math.random() * 2 - 1) * decay * 0.5;
                } else {
                    sample = diffusion * decay * characteristics.diffusion;
                }

                channelData[i] = sample;
            }
        }

        return impulse;
    }

    // Create effect presets
    createEffectPresets() {
        // Voice enhancement presets
        this.presets.set('radio_voice', {
            chain: [
                { type: 'compressor', params: { threshold: -15, ratio: 6, attack: 0.001, release: 0.1 } },
                { type: 'eq', params: { lowGain: -3, midGain: 3, highGain: 2, lowFreq: 200, highFreq: 3000 } },
                { type: 'enhancer', params: { clarity: 0.6, presence: 0.8, warmth: 0.2 } }
            ]
        });

        this.presets.set('podcast_voice', {
            chain: [
                { type: 'noiseGate', params: { threshold: -35, ratio: 8, attack: 0.001, release: 0.05 } },
                { type: 'compressor', params: { threshold: -12, ratio: 3, attack: 0.003, release: 0.25 } },
                { type: 'eq', params: { lowGain: -2, midGain: 1, highGain: 3 } },
                { type: 'enhancer', params: { clarity: 0.4, presence: 0.6, warmth: 0.5 } }
            ]
        });

        this.presets.set('emergency_alert', {
            chain: [
                { type: 'compressor', params: { threshold: -8, ratio: 10, attack: 0.001, release: 0.05 } },
                { type: 'distortion', params: { amount: 15, tone: 2500 } },
                { type: 'eq', params: { lowGain: -5, midGain: 8, highGain: 4 } }
            ]
        });

        this.presets.set('intercom_classic', {
            chain: [
                { type: 'eq', params: { lowGain: -8, midGain: 5, highGain: -3, lowFreq: 300, highFreq: 3000 } },
                { type: 'compressor', params: { threshold: -20, ratio: 8, attack: 0.001, release: 0.2 } },
                { type: 'reverb', params: { roomSize: 0.2, wetness: 0.15, roomType: 'chamber' } }
            ]
        });

        this.presets.set('robot_voice', {
            chain: [
                { type: 'robotizer', params: { pitch: 0.8, robotness: 0.9, modulation: 1.5 } },
                { type: 'bitCrusher', params: { bits: 6, sampleRate: 6000, mix: 0.7 } },
                { type: 'eq', params: { lowGain: -5, midGain: 3, highGain: -2 } }
            ]
        });

        this.presets.set('whisper_enhance', {
            chain: [
                { type: 'compressor', params: { threshold: -25, ratio: 4, attack: 0.01, release: 0.5 } },
                { type: 'eq', params: { lowGain: -1, midGain: 2, highGain: 1 } },
                { type: 'enhancer', params: { clarity: 0.3, warmth: 0.7, presence: 0.4 } }
            ]
        });
    }

    // Apply preset to audio source
    applyPreset(presetName, audioSource) {
        const preset = this.presets.get(presetName);
        if (!preset) {
            throw new Error(`Preset not found: ${presetName}`);
        }

        return this.createEffectChain(preset.chain, audioSource);
    }

    // Create effect chain
    createEffectChain(effectConfigs, audioSource = null) {
        const chainId = `chain_${Date.now()}`;
        const effects = [];
        let currentNode = audioSource;

        effectConfigs.forEach((config, index) => {
            const effect = this.createEffect(config.type, config.params);
            effects.push(effect);

            if (currentNode) {
                currentNode.connect(effect.input);
            }
            currentNode = effect.output;
        });

        const chain = {
            id: chainId,
            effects: effects,
            input: effects.length > 0 ? effects[0].input : null,
            output: currentNode
        };

        this.effectsChain.set(chainId, chain);
        return chain;
    }

    // Update effect parameter
    updateEffectParameter(effectId, paramName, value) {
        for (const [chainId, chain] of this.effectsChain) {
            const effect = chain.effects.find(e => e.id === effectId);
            if (effect) {
                effect.parameters[paramName] = value;
                this.applyEffectParameter(effect, paramName, value);
                return true;
            }
        }
        return false;
    }

    // Apply parameter change to effect
    applyEffectParameter(effect, paramName, value) {
        switch (effect.type) {
            case 'reverb':
                if (paramName === 'wetness') {
                    effect.nodes.wetGain.gain.value = value;
                } else if (paramName === 'dryness') {
                    effect.nodes.dryGain.gain.value = value;
                }
                break;

            case 'eq':
                if (paramName === 'lowGain') {
                    effect.nodes.lowShelf.gain.value = value;
                } else if (paramName === 'midGain') {
                    effect.nodes.midPeak.gain.value = value;
                } else if (paramName === 'highGain') {
                    effect.nodes.highShelf.gain.value = value;
                }
                break;

            case 'compressor':
                if (paramName === 'threshold') {
                    effect.nodes.compressor.threshold.value = value;
                } else if (paramName === 'ratio') {
                    effect.nodes.compressor.ratio.value = value;
                }
                break;

            // Add more parameter mappings as needed
        }
    }

    // Remove effect chain
    removeEffectChain(chainId) {
        const chain = this.effectsChain.get(chainId);
        if (chain) {
            // Disconnect all effects
            chain.effects.forEach(effect => {
                if (effect.input && effect.input.disconnect) {
                    effect.input.disconnect();
                }
                if (effect.output && effect.output.disconnect) {
                    effect.output.disconnect();
                }
            });

            this.effectsChain.delete(chainId);
            return true;
        }
        return false;
    }

    // Get available presets
    getAvailablePresets() {
        return Array.from(this.presets.keys());
    }

    // Get available effects
    getAvailableEffects() {
        return this.availableEffects;
    }

    // Initialize impulse responses for different room types
    initializeImpulseResponses() {
        // This would typically load actual impulse response files
        // For now, we're generating them procedurally
        console.log('Built-in effects processor initialized with procedural impulse responses');
    }
}

// Initialize effects processor
window.builtinEffectsProcessor = null;

// Export for use in other modules
if (typeof module !== 'undefined' && module.exports) {
    module.exports = BuiltinEffectsProcessor;
}