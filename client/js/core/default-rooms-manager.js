/**
 * VoiceLink Local - Default Rooms Manager
 * Manages preset room templates and auto-generation for different environments
 */

class DefaultRoomsManager {
    constructor() {
        this.serverConfig = null;
        this.defaultRoomsEnabled = true;
        this.generatedRooms = new Map();
        this.roomTemplates = new Map();

        this.init();
    }

    init() {
        this.loadRoomTemplates();
        this.loadServerConfig();
        this.setupEventListeners();
    }

    setupEventListeners() {
        // Listen for server connection
        window.addEventListener('serverConnected', (event) => {
            this.handleServerConnection(event.detail);
        });

        // Listen for server configuration updates
        window.addEventListener('serverConfigUpdated', (event) => {
            this.handleServerConfigUpdate(event.detail);
        });
    }

    loadRoomTemplates() {
        // Coffee Shop Templates
        this.roomTemplates.set('coffee-shop', {
            category: 'Coffee Shops',
            icon: '☕',
            description: 'Cozy coffee shop atmosphere for casual conversations',
            templates: [
                {
                    name: 'The Daily Grind',
                    description: 'A bustling neighborhood coffee shop with the perfect background hum',
                    maxUsers: 15,
                    privacyLevel: 'public',
                    duration: null, // lifetime
                    ambientSound: 'coffee-shop-ambient.wav',
                    spatialConfig: {
                        reverb: 'small-room',
                        atmosphere: 'cozy'
                    },
                    tags: ['casual', 'social', 'background-noise']
                },
                {
                    name: 'Quiet Corner Café',
                    description: 'A peaceful corner for focused conversations and study groups',
                    maxUsers: 8,
                    privacyLevel: 'public',
                    duration: null,
                    ambientSound: 'quiet-cafe-ambient.wav',
                    spatialConfig: {
                        reverb: 'small-room',
                        atmosphere: 'intimate'
                    },
                    tags: ['quiet', 'study', 'focus']
                },
                {
                    name: 'Espresso Express',
                    description: 'Fast-paced coffee shop for quick catch-ups and business chats',
                    maxUsers: 12,
                    privacyLevel: 'public',
                    duration: 14400000, // 4 hours
                    ambientSound: 'busy-cafe-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'energetic'
                    },
                    tags: ['business', 'quick', 'networking']
                }
            ]
        });

        // Library Templates
        this.roomTemplates.set('library', {
            category: 'Libraries',
            icon: '📚',
            description: 'Quiet library environments for study and research collaboration',
            templates: [
                {
                    name: 'Main Study Hall',
                    description: 'Large, quiet study space for collaborative learning',
                    maxUsers: 25,
                    privacyLevel: 'public',
                    duration: null,
                    ambientSound: 'library-ambient.wav',
                    spatialConfig: {
                        reverb: 'large-room',
                        atmosphere: 'academic'
                    },
                    tags: ['study', 'quiet', 'academic', 'collaboration']
                },
                {
                    name: 'Silent Reading Room',
                    description: 'Ultra-quiet space for focused individual work',
                    maxUsers: 6,
                    privacyLevel: 'public',
                    duration: null,
                    ambientSound: 'silent-library-ambient.wav',
                    spatialConfig: {
                        reverb: 'cathedral',
                        atmosphere: 'silent'
                    },
                    tags: ['silent', 'focus', 'individual']
                },
                {
                    name: 'Group Study Room',
                    description: 'Private study room for team projects and discussions',
                    maxUsers: 8,
                    privacyLevel: 'private',
                    duration: 10800000, // 3 hours
                    ambientSound: 'study-room-ambient.wav',
                    spatialConfig: {
                        reverb: 'small-room',
                        atmosphere: 'collaborative'
                    },
                    tags: ['private', 'group-work', 'projects']
                }
            ]
        });

        // Movie Theater Templates
        this.roomTemplates.set('theater', {
            category: 'Movie Theaters',
            icon: '🎬',
            description: 'Cinematic environments for watch parties and entertainment',
            templates: [
                {
                    name: 'Classic Cinema',
                    description: 'Traditional movie theater experience for watch parties',
                    maxUsers: 30,
                    privacyLevel: 'public',
                    duration: 10800000, // 3 hours
                    ambientSound: 'theater-ambient.wav',
                    spatialConfig: {
                        reverb: 'hall',
                        atmosphere: 'cinematic'
                    },
                    tags: ['movies', 'entertainment', 'watch-party']
                },
                {
                    name: 'Private Screening Room',
                    description: 'Intimate theater for small group movie nights',
                    maxUsers: 8,
                    privacyLevel: 'private',
                    duration: 14400000, // 4 hours
                    ambientSound: 'private-theater-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'luxury'
                    },
                    tags: ['private', 'intimate', 'premium']
                },
                {
                    name: 'Drive-In Theater',
                    description: 'Nostalgic drive-in experience for casual viewing',
                    maxUsers: 20,
                    privacyLevel: 'public',
                    duration: 7200000, // 2 hours
                    ambientSound: 'drive-in-ambient.wav',
                    spatialConfig: {
                        reverb: 'none',
                        atmosphere: 'outdoor'
                    },
                    tags: ['nostalgic', 'casual', 'outdoor']
                }
            ]
        });

        // Office/Workspace Templates
        this.roomTemplates.set('workspace', {
            category: 'Workspaces',
            icon: '🏢',
            description: 'Professional environments for business meetings and collaboration',
            templates: [
                {
                    name: 'Conference Room A',
                    description: 'Professional meeting space for business discussions',
                    maxUsers: 12,
                    privacyLevel: 'private',
                    duration: 3600000, // 1 hour
                    ambientSound: 'office-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'professional'
                    },
                    tags: ['business', 'meetings', 'professional']
                },
                {
                    name: 'Open Office Space',
                    description: 'Collaborative workspace for team coordination',
                    maxUsers: 20,
                    privacyLevel: 'public',
                    duration: null,
                    ambientSound: 'open-office-ambient.wav',
                    spatialConfig: {
                        reverb: 'large-room',
                        atmosphere: 'collaborative'
                    },
                    tags: ['collaboration', 'team', 'open']
                },
                {
                    name: 'Executive Boardroom',
                    description: 'High-level meeting space for important discussions',
                    maxUsers: 8,
                    privacyLevel: 'private',
                    duration: 7200000, // 2 hours
                    ambientSound: 'boardroom-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'executive'
                    },
                    tags: ['executive', 'private', 'high-level']
                }
            ]
        });

        // Social/Entertainment Templates
        this.roomTemplates.set('social', {
            category: 'Social Spaces',
            icon: '🎉',
            description: 'Fun social environments for parties and casual hangouts',
            templates: [
                {
                    name: 'The Lounge',
                    description: 'Relaxed social space for casual conversations',
                    maxUsers: 25,
                    privacyLevel: 'public',
                    duration: null,
                    ambientSound: 'lounge-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'social'
                    },
                    tags: ['social', 'casual', 'relaxed']
                },
                {
                    name: 'Game Night Central',
                    description: 'Interactive space for gaming and competitive fun',
                    maxUsers: 16,
                    privacyLevel: 'public',
                    duration: 14400000, // 4 hours
                    ambientSound: 'game-room-ambient.wav',
                    spatialConfig: {
                        reverb: 'small-room',
                        atmosphere: 'energetic'
                    },
                    tags: ['gaming', 'competitive', 'interactive']
                },
                {
                    name: 'Virtual Pub',
                    description: 'Pub atmosphere for socializing and trivia nights',
                    maxUsers: 30,
                    privacyLevel: 'public',
                    duration: null,
                    ambientSound: 'pub-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'lively'
                    },
                    tags: ['pub', 'trivia', 'social-drinking']
                }
            ]
        });

        // Educational Templates
        this.roomTemplates.set('education', {
            category: 'Educational',
            icon: '🎓',
            description: 'Learning environments for classes and educational content',
            templates: [
                {
                    name: 'Lecture Hall',
                    description: 'Large lecture space for educational presentations',
                    maxUsers: 50,
                    privacyLevel: 'public',
                    duration: 5400000, // 1.5 hours
                    ambientSound: 'lecture-hall-ambient.wav',
                    spatialConfig: {
                        reverb: 'hall',
                        atmosphere: 'academic'
                    },
                    tags: ['education', 'lecture', 'presentation']
                },
                {
                    name: 'Tutorial Room',
                    description: 'Small classroom for interactive learning sessions',
                    maxUsers: 12,
                    privacyLevel: 'public',
                    duration: 3600000, // 1 hour
                    ambientSound: 'classroom-ambient.wav',
                    spatialConfig: {
                        reverb: 'small-room',
                        atmosphere: 'interactive'
                    },
                    tags: ['tutorial', 'interactive', 'small-group']
                },
                {
                    name: 'Workshop Space',
                    description: 'Hands-on learning environment for practical sessions',
                    maxUsers: 15,
                    privacyLevel: 'public',
                    duration: 7200000, // 2 hours
                    ambientSound: 'workshop-ambient.wav',
                    spatialConfig: {
                        reverb: 'medium-room',
                        atmosphere: 'hands-on'
                    },
                    tags: ['workshop', 'hands-on', 'practical']
                }
            ]
        });

        console.log('Room templates loaded:', this.roomTemplates.size, 'categories');
    }

    loadServerConfig() {
        try {
            const stored = localStorage.getItem('vlDefaultRoomsConfig');
            if (stored) {
                this.serverConfig = JSON.parse(stored);
            } else {
                // Default configuration
                this.serverConfig = {
                    enabled: true,
                    autoGenerate: true,
                    maxDefaultRooms: 15,
                    categories: {
                        'coffee-shop': { enabled: true, maxRooms: 3 },
                        'library': { enabled: true, maxRooms: 3 },
                        'theater': { enabled: true, maxRooms: 2 },
                        'workspace': { enabled: true, maxRooms: 3 },
                        'social': { enabled: true, maxRooms: 3 },
                        'education': { enabled: true, maxRooms: 2 }
                    },
                    customization: {
                        allowUserCreation: true,
                        allowTemplateModification: true,
                        requireApproval: false
                    }
                };
                this.saveServerConfig();
            }
        } catch (error) {
            console.error('Failed to load default rooms config:', error);
            this.serverConfig = { enabled: false };
        }
    }

    saveServerConfig() {
        try {
            localStorage.setItem('vlDefaultRoomsConfig', JSON.stringify(this.serverConfig));
        } catch (error) {
            console.error('Failed to save default rooms config:', error);
        }
    }

    async handleServerConnection(serverInfo) {
        if (!this.serverConfig?.enabled || !this.serverConfig?.autoGenerate) {
            console.log('Default rooms generation disabled');
            return;
        }

        console.log('Server connected, checking for default rooms...');
        await this.generateDefaultRooms();
    }

    async generateDefaultRooms() {
        if (!this.serverConfig?.enabled) return;

        const existingRooms = await this.getExistingRooms();
        const roomsToGenerate = this.selectRoomsToGenerate(existingRooms);

        console.log(`Generating ${roomsToGenerate.length} default rooms...`);

        for (const roomTemplate of roomsToGenerate) {
            try {
                await this.createRoomFromTemplate(roomTemplate);
                await this.delay(100); // Small delay between room creation
            } catch (error) {
                console.error('Failed to create default room:', roomTemplate.name, error);
            }
        }

        // Notify that default rooms have been generated
        window.dispatchEvent(new CustomEvent('defaultRoomsGenerated', {
            detail: {
                count: roomsToGenerate.length,
                rooms: roomsToGenerate
            }
        }));
    }

    selectRoomsToGenerate(existingRooms) {
        const selectedRooms = [];
        const existingNames = new Set(existingRooms.map(room => room.name));

        for (const [categoryId, categoryConfig] of Object.entries(this.serverConfig.categories)) {
            if (!categoryConfig.enabled) continue;

            const category = this.roomTemplates.get(categoryId);
            if (!category) continue;

            let addedCount = 0;
            for (const template of category.templates) {
                if (addedCount >= categoryConfig.maxRooms) break;
                if (existingNames.has(template.name)) continue;

                selectedRooms.push({
                    ...template,
                    category: category.category,
                    categoryId,
                    icon: category.icon
                });
                addedCount++;
            }
        }

        // Shuffle and limit total rooms
        const shuffled = this.shuffleArray(selectedRooms);
        return shuffled.slice(0, this.serverConfig.maxDefaultRooms);
    }

    async createRoomFromTemplate(template) {
        const roomData = {
            roomId: `default_${template.categoryId}_${Date.now()}_${Math.random().toString(36).substr(2, 6)}`,
            name: template.name,
            description: template.description,
            maxUsers: template.maxUsers,
            duration: template.duration,
            privacyLevel: template.privacyLevel,
            encrypted: window.serverEncryptionManager?.isRoomEncrypted(template.roomId) || false,
            isDefault: true,
            template: {
                category: template.category,
                categoryId: template.categoryId,
                icon: template.icon,
                tags: template.tags,
                ambientSound: template.ambientSound,
                spatialConfig: template.spatialConfig
            }
        };

        // Set room privacy if encryption manager is available
        if (window.serverEncryptionManager) {
            try {
                await window.serverEncryptionManager.setUserRoomPrivacy(
                    roomData.roomId,
                    template.privacyLevel
                );
            } catch (error) {
                console.warn('Failed to set room privacy for default room:', error);
            }
        }

        // Create room via API
        const response = await fetch('/api/rooms', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(roomData)
        });

        if (!response.ok) {
            throw new Error(`Failed to create room: ${response.statusText}`);
        }

        const result = await response.json();
        this.generatedRooms.set(result.roomId, {
            ...roomData,
            ...result,
            createdAt: Date.now()
        });

        console.log(`Created default room: ${template.name} (${template.category})`);
        return result;
    }

    async getExistingRooms() {
        try {
            const response = await fetch('/api/rooms');
            if (response.ok) {
                return await response.json();
            }
        } catch (error) {
            console.error('Failed to fetch existing rooms:', error);
        }
        return [];
    }

    // Server owner configuration methods
    updateServerConfig(updates) {
        this.serverConfig = {
            ...this.serverConfig,
            ...updates
        };
        this.saveServerConfig();

        window.dispatchEvent(new CustomEvent('serverConfigUpdated', {
            detail: this.serverConfig
        }));
    }

    enableCategory(categoryId, enabled = true) {
        if (!this.serverConfig.categories[categoryId]) return false;

        this.serverConfig.categories[categoryId].enabled = enabled;
        this.saveServerConfig();
        return true;
    }

    setCategoryMaxRooms(categoryId, maxRooms) {
        if (!this.serverConfig.categories[categoryId]) return false;

        this.serverConfig.categories[categoryId].maxRooms = Math.max(0, Math.min(10, maxRooms));
        this.saveServerConfig();
        return true;
    }

    // Template management
    getTemplatesByCategory(categoryId) {
        const category = this.roomTemplates.get(categoryId);
        return category ? category.templates : [];
    }

    getAllCategories() {
        const categories = [];
        for (const [id, category] of this.roomTemplates.entries()) {
            categories.push({
                id,
                ...category,
                config: this.serverConfig.categories[id] || { enabled: false, maxRooms: 0 }
            });
        }
        return categories;
    }

    addCustomTemplate(categoryId, template) {
        const category = this.roomTemplates.get(categoryId);
        if (!category) return false;

        // Validate template
        if (!template.name || !template.description) return false;

        category.templates.push({
            ...template,
            isCustom: true,
            createdAt: Date.now()
        });

        return true;
    }

    removeTemplate(categoryId, templateIndex) {
        const category = this.roomTemplates.get(categoryId);
        if (!category || !category.templates[templateIndex]) return false;

        category.templates.splice(templateIndex, 1);
        return true;
    }

    // Room management
    async regenerateDefaultRooms() {
        // Remove existing default rooms
        await this.removeDefaultRooms();

        // Generate new ones
        await this.generateDefaultRooms();
    }

    async removeDefaultRooms() {
        const existingRooms = await this.getExistingRooms();
        const defaultRooms = existingRooms.filter(room => room.isDefault);

        for (const room of defaultRooms) {
            try {
                await fetch(`/api/rooms/${room.roomId}`, {
                    method: 'DELETE'
                });
                this.generatedRooms.delete(room.roomId);
            } catch (error) {
                console.error('Failed to remove default room:', room.name, error);
            }
        }
    }

    getGeneratedRooms() {
        return Array.from(this.generatedRooms.values());
    }

    // Utility methods
    shuffleArray(array) {
        const shuffled = [...array];
        for (let i = shuffled.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]];
        }
        return shuffled;
    }

    delay(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    handleServerConfigUpdate(config) {
        this.serverConfig = config;
        console.log('Default rooms configuration updated');
    }

    // Export/Import functionality
    exportConfiguration() {
        return {
            config: this.serverConfig,
            customTemplates: this.getCustomTemplates(),
            exportedAt: Date.now(),
            version: '1.0.0'
        };
    }

    getCustomTemplates() {
        const customTemplates = {};
        for (const [categoryId, category] of this.roomTemplates.entries()) {
            const custom = category.templates.filter(t => t.isCustom);
            if (custom.length > 0) {
                customTemplates[categoryId] = custom;
            }
        }
        return customTemplates;
    }

    importConfiguration(data) {
        if (data.version !== '1.0.0') {
            throw new Error('Incompatible configuration version');
        }

        if (data.config) {
            this.serverConfig = data.config;
            this.saveServerConfig();
        }

        if (data.customTemplates) {
            for (const [categoryId, templates] of Object.entries(data.customTemplates)) {
                const category = this.roomTemplates.get(categoryId);
                if (category) {
                    category.templates.push(...templates);
                }
            }
        }
    }
}

// Global instance
window.defaultRoomsManager = new DefaultRoomsManager();

// Export for module usage
if (typeof module !== 'undefined' && module.exports) {
    module.exports = DefaultRoomsManager;
}