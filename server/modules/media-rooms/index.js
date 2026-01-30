/**
 * VoiceLink Media Rooms Module
 *
 * Features:
 * - Movie/TV show rooms with auto-play
 * - Hidden player controls for non-admin/moderator
 * - Trailer/intro playback between content
 * - Audio Description Library integration
 */

const fs = require('fs');
const path = require('path');

class MediaRoomsModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/media-rooms');
        this.server = options.server;

        // Room type configurations
        this.roomTypes = {
            'movie': {
                name: 'Movie Room',
                autoPlay: true,
                controlsHiddenFromGuests: true,
                playIntrosBetween: true,
                audioDescriptionEnabled: true,
                allowedControls: {
                    guest: [],
                    member: ['volume'],
                    moderator: ['play', 'pause', 'seek', 'volume', 'queue'],
                    admin: ['play', 'pause', 'seek', 'volume', 'queue', 'settings', 'audioDescription']
                }
            },
            'tvshow': {
                name: 'TV Show Room',
                autoPlay: true,
                controlsHiddenFromGuests: true,
                playIntrosBetween: true,
                audioDescriptionEnabled: true,
                allowedControls: {
                    guest: [],
                    member: ['volume'],
                    moderator: ['play', 'pause', 'seek', 'volume', 'queue', 'nextEpisode'],
                    admin: ['play', 'pause', 'seek', 'volume', 'queue', 'nextEpisode', 'settings', 'audioDescription']
                }
            },
            'music': {
                name: 'Music Room',
                autoPlay: true,
                controlsHiddenFromGuests: false,
                playIntrosBetween: false,
                audioDescriptionEnabled: false,
                allowedControls: {
                    guest: ['volume'],
                    member: ['play', 'pause', 'skip', 'volume', 'queue'],
                    moderator: ['play', 'pause', 'skip', 'volume', 'queue', 'settings'],
                    admin: ['play', 'pause', 'skip', 'volume', 'queue', 'settings']
                }
            },
            'radio': {
                name: 'Radio Room',
                autoPlay: true,
                controlsHiddenFromGuests: true,
                playIntrosBetween: false,
                audioDescriptionEnabled: false,
                allowedControls: {
                    guest: ['volume'],
                    member: ['volume'],
                    moderator: ['volume', 'station'],
                    admin: ['volume', 'station', 'settings']
                }
            },
            'standard': {
                name: 'Standard Room',
                autoPlay: false,
                controlsHiddenFromGuests: false,
                playIntrosBetween: false,
                audioDescriptionEnabled: false,
                allowedControls: {
                    guest: ['play', 'pause', 'volume'],
                    member: ['play', 'pause', 'seek', 'volume', 'queue'],
                    moderator: ['play', 'pause', 'seek', 'volume', 'queue', 'settings'],
                    admin: ['play', 'pause', 'seek', 'volume', 'queue', 'settings']
                }
            }
        };

        // Media paths - check multiple locations
        this.mediaPaths = [
            '/home/dom/apps/media',
            '/home/devinecr/apps/media'
        ];
        // Check both lowercase and capitalized folder names
        this.introsPath = this.config.introsPath || this.findMediaPath('Intros') || this.findMediaPath('intros');
        this.trailersPath = this.config.trailersPath || this.findMediaPath('trailers') || this.findMediaPath('Trailers');
        this.audioDescriptionPath = this.config.audioDescriptionPath || this.findMediaPath('AudioDescribedContent') || this.findMediaPath('audio-descriptions');

        // Room media state
        this.roomMediaState = new Map(); // roomId -> { currentMedia, queue, audioDescTrack, lastIntro }

        // Initialize
        if (!fs.existsSync(this.dataDir)) {
            fs.mkdirSync(this.dataDir, { recursive: true });
        }
        this.loadState();
        this.loadRoomTypesConfig(); // Load admin-configured settings
    }

    /**
     * Find media path from available locations
     */
    findMediaPath(subdir) {
        for (const basePath of this.mediaPaths) {
            const fullPath = path.join(basePath, subdir);
            if (fs.existsSync(fullPath)) {
                return fullPath;
            }
        }
        // Return first path as default
        return path.join(this.mediaPaths[0], subdir);
    }

    /**
     * Get all media paths for a subdir (combines from all locations)
     * Checks both lowercase and capitalized versions
     */
    getAllMediaPaths(subdir) {
        const paths = [];
        const variants = [subdir, subdir.toLowerCase(), subdir.charAt(0).toUpperCase() + subdir.slice(1)];

        for (const basePath of this.mediaPaths) {
            for (const variant of variants) {
                const fullPath = path.join(basePath, variant);
                if (fs.existsSync(fullPath) && !paths.includes(fullPath)) {
                    paths.push(fullPath);
                }
            }
        }
        return paths;
    }

    loadState() {
        const stateFile = path.join(this.dataDir, 'media-rooms-state.json');
        try {
            if (fs.existsSync(stateFile)) {
                const data = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
                if (data.roomMediaState) {
                    Object.entries(data.roomMediaState).forEach(([roomId, state]) => {
                        this.roomMediaState.set(roomId, state);
                    });
                }
            }
        } catch (e) {
            console.error('[MediaRooms] Error loading state:', e.message);
        }
    }

    saveState() {
        const stateFile = path.join(this.dataDir, 'media-rooms-state.json');
        const data = {
            lastUpdated: Date.now(),
            roomMediaState: Object.fromEntries(this.roomMediaState)
        };
        fs.writeFileSync(stateFile, JSON.stringify(data, null, 2));
    }

    /**
     * Get room type configuration
     */
    getRoomType(type) {
        return this.roomTypes[type] || this.roomTypes.standard;
    }

    /**
     * Check if user can access a control
     */
    canAccessControl(roomType, userRole, control) {
        const typeConfig = this.getRoomType(roomType);
        const allowedControls = typeConfig.allowedControls[userRole] || [];
        return allowedControls.includes(control);
    }

    /**
     * Get allowed controls for user in room
     */
    getAllowedControls(roomType, userRole) {
        const typeConfig = this.getRoomType(roomType);
        return typeConfig.allowedControls[userRole] || [];
    }

    /**
     * Get visible UI elements for user
     */
    getVisibleUI(roomType, userRole) {
        const typeConfig = this.getRoomType(roomType);
        const controls = this.getAllowedControls(roomType, userRole);

        return {
            showPlayPause: controls.includes('play') || controls.includes('pause'),
            showSeek: controls.includes('seek'),
            showVolume: controls.includes('volume'),
            showQueue: controls.includes('queue'),
            showSettings: controls.includes('settings'),
            showNextEpisode: controls.includes('nextEpisode'),
            showAudioDescription: controls.includes('audioDescription'),
            showStation: controls.includes('station'),
            controlsHidden: typeConfig.controlsHiddenFromGuests && userRole === 'guest'
        };
    }

    /**
     * Get available intros from all media paths
     */
    getIntros() {
        const intros = [];
        try {
            const introPaths = this.getAllMediaPaths('intros');
            for (const introPath of introPaths) {
                const files = fs.readdirSync(introPath);
                files.filter(f => /\.(mp4|webm|mkv|avi|mp3|m4a)$/i.test(f))
                    .forEach(f => {
                        intros.push({
                            name: path.basename(f, path.extname(f)),
                            path: path.join(introPath, f),
                            type: /\.(mp3|m4a)$/i.test(f) ? 'audio' : 'video',
                            source: introPath
                        });
                    });
            }
        } catch (e) {
            console.error('[MediaRooms] Error reading intros:', e.message);
        }
        return intros;
    }

    /**
     * Get available trailers from all media paths
     */
    getTrailers() {
        const trailers = [];
        try {
            const trailerPaths = this.getAllMediaPaths('trailers');
            for (const trailerPath of trailerPaths) {
                const files = fs.readdirSync(trailerPath);
                files.filter(f => /\.(mp4|webm|mkv|avi)$/i.test(f))
                    .forEach(f => {
                        trailers.push({
                            name: path.basename(f, path.extname(f)),
                            path: path.join(trailerPath, f),
                            source: trailerPath
                        });
                    });
            }
        } catch (e) {
            console.error('[MediaRooms] Error reading trailers:', e.message);
        }
        return trailers;
    }

    /**
     * Get random intro
     */
    getRandomIntro() {
        const intros = this.getIntros();
        if (intros.length === 0) return null;
        return intros[Math.floor(Math.random() * intros.length)];
    }

    /**
     * Get random trailer
     */
    getRandomTrailer() {
        const trailers = this.getTrailers();
        if (trailers.length === 0) return null;
        return trailers[Math.floor(Math.random() * trailers.length)];
    }

    /**
     * Get audio description tracks for a media item from all paths
     */
    getAudioDescriptions(mediaId) {
        const descriptions = [];
        try {
            const adPaths = this.getAllMediaPaths('audio-descriptions');
            for (const adPath of adPaths) {
                const mediaPath = path.join(adPath, mediaId);
                if (fs.existsSync(mediaPath)) {
                    const files = fs.readdirSync(mediaPath);
                    files.filter(f => /\.(mp3|m4a|aac|ogg)$/i.test(f))
                        .forEach(f => {
                            descriptions.push({
                                name: path.basename(f, path.extname(f)),
                                path: path.join(mediaPath, f),
                                language: this.detectLanguage(f),
                                source: adPath
                            });
                        });
                }
            }
        } catch (e) {
            console.error('[MediaRooms] Error reading audio descriptions:', e.message);
        }
        return descriptions;
    }

    /**
     * Get admin configuration for a room type (for admin panel)
     */
    getAdminConfig(roomType) {
        const typeConfig = this.getRoomType(roomType);
        return {
            type: roomType,
            ...typeConfig,
            configurable: {
                autoPlay: { type: 'boolean', label: 'Auto-play media', default: typeConfig.autoPlay },
                controlsHiddenFromGuests: { type: 'boolean', label: 'Hide controls from guests', default: typeConfig.controlsHiddenFromGuests },
                playIntrosBetween: { type: 'boolean', label: 'Play intros/trailers between content', default: typeConfig.playIntrosBetween },
                audioDescriptionEnabled: { type: 'boolean', label: 'Enable audio descriptions', default: typeConfig.audioDescriptionEnabled },
                allowedControls: { type: 'permissions', label: 'Control permissions by role', default: typeConfig.allowedControls }
            }
        };
    }

    /**
     * Update room type configuration (from admin panel)
     */
    updateRoomTypeConfig(roomType, updates) {
        if (!this.roomTypes[roomType]) {
            return { success: false, error: 'Unknown room type' };
        }

        // Update configurable settings
        if (updates.autoPlay !== undefined) this.roomTypes[roomType].autoPlay = updates.autoPlay;
        if (updates.controlsHiddenFromGuests !== undefined) this.roomTypes[roomType].controlsHiddenFromGuests = updates.controlsHiddenFromGuests;
        if (updates.playIntrosBetween !== undefined) this.roomTypes[roomType].playIntrosBetween = updates.playIntrosBetween;
        if (updates.audioDescriptionEnabled !== undefined) this.roomTypes[roomType].audioDescriptionEnabled = updates.audioDescriptionEnabled;
        if (updates.allowedControls) this.roomTypes[roomType].allowedControls = updates.allowedControls;

        // Save to config file
        this.saveRoomTypesConfig();

        return { success: true, config: this.roomTypes[roomType] };
    }

    /**
     * Save room types configuration
     */
    saveRoomTypesConfig() {
        const configFile = path.join(this.dataDir, 'room-types-config.json');
        fs.writeFileSync(configFile, JSON.stringify(this.roomTypes, null, 2));
    }

    /**
     * Load custom room types configuration
     */
    loadRoomTypesConfig() {
        const configFile = path.join(this.dataDir, 'room-types-config.json');
        try {
            if (fs.existsSync(configFile)) {
                const customConfig = JSON.parse(fs.readFileSync(configFile, 'utf8'));
                // Merge with defaults
                Object.keys(customConfig).forEach(type => {
                    if (this.roomTypes[type]) {
                        Object.assign(this.roomTypes[type], customConfig[type]);
                    }
                });
            }
        } catch (e) {
            console.error('[MediaRooms] Error loading room types config:', e.message);
        }
    }

    /**
     * Detect language from filename
     */
    detectLanguage(filename) {
        const langCodes = {
            'en': 'English', 'es': 'Spanish', 'fr': 'French', 'de': 'German',
            'it': 'Italian', 'pt': 'Portuguese', 'ja': 'Japanese', 'ko': 'Korean',
            'zh': 'Chinese', 'ru': 'Russian', 'ar': 'Arabic', 'hi': 'Hindi'
        };

        const match = filename.match(/[-_.]([a-z]{2})[-_.]/i);
        if (match) {
            return langCodes[match[1].toLowerCase()] || match[1].toUpperCase();
        }
        return 'Unknown';
    }

    /**
     * Set room media configuration
     */
    setRoomMediaConfig(roomId, config) {
        const state = this.roomMediaState.get(roomId) || {
            type: 'standard',
            autoPlay: false,
            currentMedia: null,
            queue: [],
            audioDescTrack: null,
            lastIntro: null
        };

        Object.assign(state, config);
        this.roomMediaState.set(roomId, state);
        this.saveState();

        return state;
    }

    /**
     * Get room media configuration
     */
    getRoomMediaConfig(roomId) {
        return this.roomMediaState.get(roomId) || {
            type: 'standard',
            autoPlay: false,
            currentMedia: null,
            queue: [],
            audioDescTrack: null,
            lastIntro: null
        };
    }

    /**
     * Handle media end - play intro/trailer before next item
     */
    async onMediaEnd(roomId, callback) {
        const state = this.roomMediaState.get(roomId);
        if (!state) return null;

        const typeConfig = this.getRoomType(state.type);

        // Check if we should play an intro/trailer
        if (typeConfig.playIntrosBetween && state.queue.length > 0) {
            // Alternate between intro and trailer
            const playTrailer = Math.random() > 0.5;
            const interstitial = playTrailer ? this.getRandomTrailer() : this.getRandomIntro();

            if (interstitial) {
                state.lastIntro = interstitial;
                this.roomMediaState.set(roomId, state);
                this.saveState();

                // Callback to play interstitial
                if (callback) {
                    callback({
                        type: 'interstitial',
                        media: interstitial,
                        nextItem: state.queue[0]
                    });
                }

                return interstitial;
            }
        }

        // No interstitial, proceed to next item
        return null;
    }

    /**
     * Get next queue item
     */
    getNextQueueItem(roomId) {
        const state = this.roomMediaState.get(roomId);
        if (!state || state.queue.length === 0) return null;

        const nextItem = state.queue.shift();
        state.currentMedia = nextItem;
        this.roomMediaState.set(roomId, state);
        this.saveState();

        return nextItem;
    }

    /**
     * Add item to queue
     */
    addToQueue(roomId, item) {
        const state = this.roomMediaState.get(roomId) || {
            type: 'standard',
            queue: []
        };

        state.queue.push(item);
        this.roomMediaState.set(roomId, state);
        this.saveState();

        return state.queue;
    }

    /**
     * Enable audio description for room
     */
    enableAudioDescription(roomId, mediaId, trackPath) {
        const state = this.roomMediaState.get(roomId);
        if (!state) return false;

        state.audioDescTrack = {
            mediaId,
            path: trackPath,
            enabled: true,
            startedAt: Date.now()
        };

        this.roomMediaState.set(roomId, state);
        this.saveState();

        return true;
    }

    /**
     * Disable audio description
     */
    disableAudioDescription(roomId) {
        const state = this.roomMediaState.get(roomId);
        if (!state) return false;

        state.audioDescTrack = null;
        this.roomMediaState.set(roomId, state);
        this.saveState();

        return true;
    }

    /**
     * Get all room types
     */
    getAllRoomTypes() {
        return Object.entries(this.roomTypes).map(([id, config]) => ({
            id,
            ...config
        }));
    }

    /**
     * Create a movie room
     */
    createMovieRoom(name, description, options = {}) {
        return {
            name,
            description,
            type: 'movie',
            mediaConfig: {
                type: 'movie',
                autoPlay: true,
                controlsHiddenFromGuests: true,
                playIntrosBetween: true,
                audioDescriptionEnabled: options.audioDescriptionEnabled !== false,
                jellyfinLibrary: options.jellyfinLibrary || null
            }
        };
    }

    /**
     * Create a TV show room
     */
    createTVShowRoom(name, description, options = {}) {
        return {
            name,
            description,
            type: 'tvshow',
            mediaConfig: {
                type: 'tvshow',
                autoPlay: true,
                controlsHiddenFromGuests: true,
                playIntrosBetween: true,
                audioDescriptionEnabled: options.audioDescriptionEnabled !== false,
                jellyfinLibrary: options.jellyfinLibrary || null,
                showId: options.showId || null
            }
        };
    }

    // ==========================================
    // Now Playing & Playback Modes
    // ==========================================

    /**
     * Get what's currently playing in a room
     * Returns title, description, duration, current position
     */
    getNowPlaying(roomId) {
        const state = this.roomMediaState.get(roomId);
        if (!state || !state.currentMedia) {
            return {
                playing: false,
                message: 'Nothing is currently playing'
            };
        }

        const media = state.currentMedia;
        const startedAt = state.playbackStartedAt || Date.now();
        const currentPosition = Date.now() - startedAt;
        const duration = media.duration || 0;
        const remaining = Math.max(0, duration - currentPosition);

        return {
            playing: true,
            title: media.title || media.name || 'Unknown',
            description: media.description || media.overview || '',
            duration: duration,
            durationFormatted: this.formatDuration(duration),
            currentPosition: currentPosition,
            positionFormatted: this.formatDuration(currentPosition),
            remaining: remaining,
            remainingFormatted: this.formatDuration(remaining),
            progress: duration > 0 ? Math.min(100, (currentPosition / duration) * 100) : 0,
            thumbnail: media.thumbnail || media.poster || null,
            type: media.type || state.type,
            playbackMode: state.playbackMode || 'scheduled',
            audioDescriptionEnabled: state.audioDescTrack?.enabled || false,
            metadata: {
                year: media.year,
                rating: media.rating,
                genre: media.genre,
                runtime: media.runtime
            }
        };
    }

    /**
     * Format duration in ms to human readable
     */
    formatDuration(ms) {
        if (!ms || ms < 0) return '0:00';
        const totalSeconds = Math.floor(ms / 1000);
        const hours = Math.floor(totalSeconds / 3600);
        const minutes = Math.floor((totalSeconds % 3600) / 60);
        const seconds = totalSeconds % 60;

        if (hours > 0) {
            return `${hours}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
        }
        return `${minutes}:${seconds.toString().padStart(2, '0')}`;
    }

    /**
     * Set playback mode for room
     * 'scheduled' - Plays like TV (real-time, join in progress)
     * 'on-demand' - User controls playback (personal rooms)
     */
    setPlaybackMode(roomId, mode, options = {}) {
        const state = this.roomMediaState.get(roomId) || {};

        state.playbackMode = mode;
        state.allowOnDemand = options.allowOnDemand || false;

        if (mode === 'scheduled') {
            state.scheduleConfig = {
                // Loop playlist continuously
                loop: options.loop !== false,
                // Start from beginning at specific time each day
                dailyResetTime: options.dailyResetTime || null,
                // Shuffle between content
                shuffle: options.shuffle || false
            };
        }

        this.roomMediaState.set(roomId, state);
        this.saveState();

        return state;
    }

    /**
     * Start scheduled playback for a room
     * Media plays continuously like a TV channel
     */
    startScheduledPlayback(roomId, playlist, options = {}) {
        const state = this.roomMediaState.get(roomId) || {};

        // Calculate where we should be in the playlist based on real time
        const totalDuration = playlist.reduce((sum, item) => sum + (item.duration || 0), 0);
        const now = Date.now();

        // Use day start as reference point or custom start time
        const dayStart = options.scheduleStart || new Date().setHours(0, 0, 0, 0);
        const elapsed = (now - dayStart) % totalDuration;

        // Find current item and position
        let accumulatedTime = 0;
        let currentIndex = 0;
        let positionInMedia = 0;

        for (let i = 0; i < playlist.length; i++) {
            const itemDuration = playlist[i].duration || 0;
            if (accumulatedTime + itemDuration > elapsed) {
                currentIndex = i;
                positionInMedia = elapsed - accumulatedTime;
                break;
            }
            accumulatedTime += itemDuration;
        }

        state.playbackMode = 'scheduled';
        state.currentMedia = playlist[currentIndex];
        state.playbackStartedAt = now - positionInMedia;
        state.playlist = playlist;
        state.playlistIndex = currentIndex;
        state.scheduleStart = dayStart;
        state.allowOnDemand = false;

        this.roomMediaState.set(roomId, state);
        this.saveState();

        return {
            currentMedia: playlist[currentIndex],
            position: positionInMedia,
            positionFormatted: this.formatDuration(positionInMedia),
            nextUp: playlist[(currentIndex + 1) % playlist.length],
            playlistIndex: currentIndex,
            totalItems: playlist.length
        };
    }

    /**
     * Check if room allows on-demand playback
     */
    allowsOnDemand(roomId) {
        const state = this.roomMediaState.get(roomId);
        if (!state) return true; // Default to allowing for new rooms

        // Personal rooms always allow on-demand
        if (state.isPersonalRoom) return true;

        return state.allowOnDemand === true;
    }

    /**
     * Set current media with full details for display
     */
    setCurrentMedia(roomId, media) {
        const state = this.roomMediaState.get(roomId) || {};

        // Calculate duration - prefer direct duration, fall back to Jellyfin runTimeTicks
        let duration = media.duration || 0;
        if (!duration && media.runTimeTicks) {
            duration = Math.floor(media.runTimeTicks / 10000); // Jellyfin ticks to ms
        }

        // Handle thumbnail - use provided or build Jellyfin URL
        let thumbnail = media.thumbnail || media.poster || null;
        if (!thumbnail && media.primaryImageTag && media.serverUrl) {
            thumbnail = `${media.serverUrl}/Items/${media.id}/Images/Primary`;
        }

        state.currentMedia = {
            id: media.id,
            title: media.title || media.name,
            description: media.description || media.overview || '',
            duration: duration,
            thumbnail: thumbnail,
            poster: media.poster,
            type: media.type || 'video',
            year: media.productionYear || media.year,
            rating: media.officialRating || media.rating,
            genre: media.genres?.join(', ') || media.genre,
            runtime: media.runtime
        };
        state.playbackStartedAt = Date.now();

        this.roomMediaState.set(roomId, state);
        this.saveState();

        // Broadcast to room
        if (this.server?.io) {
            this.server.io.to(roomId).emit('now-playing', this.getNowPlaying(roomId));
        }

        return state.currentMedia;
    }

    /**
     * Get room info for joining user (includes now playing)
     */
    getRoomMediaInfo(roomId) {
        const state = this.roomMediaState.get(roomId);
        const typeConfig = this.getRoomType(state?.type || 'standard');

        return {
            roomType: state?.type || 'standard',
            roomTypeName: typeConfig.name,
            nowPlaying: this.getNowPlaying(roomId),
            playbackMode: state?.playbackMode || 'scheduled',
            allowOnDemand: this.allowsOnDemand(roomId),
            queueLength: state?.queue?.length || 0,
            audioDescriptionAvailable: typeConfig.audioDescriptionEnabled,
            audioDescriptionEnabled: state?.audioDescTrack?.enabled || false,
            controlsConfig: {
                hiddenFromGuests: typeConfig.controlsHiddenFromGuests,
                autoPlay: typeConfig.autoPlay
            }
        };
    }
}

module.exports = { MediaRoomsModule };
