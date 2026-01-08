/**
 * VoiceLink Local - Robust Settings Manager
 * Multi-layered settings persistence with automatic backup/restore
 */

const { app } = require('electron');
const fs = require('fs').promises;
const path = require('path');

class RobustSettingsManager {
    constructor() {
        this.settings = {};
        this.settingsPath = this.getSettingsPath();
        this.backupPath = this.getBackupPath();
        this.emergencyPath = this.getEmergencyPath();

        // Auto-save interval (save changes every 5 seconds)
        this.autoSaveInterval = null;
        this.hasUnsavedChanges = false;
        this.isInitialized = false;
        this.uninitializedWarningCount = 0;

        this.init();
    }

    /**
     * Get platform-specific settings paths
     */
    getSettingsPath() {
        const userDataPath = app.getPath('userData');
        return path.join(userDataPath, 'voicelink-settings.json');
    }

    getBackupPath() {
        const userDataPath = app.getPath('userData');
        return path.join(userDataPath, 'voicelink-settings-backup.json');
    }

    getEmergencyPath() {
        const userDataPath = app.getPath('userData');
        return path.join(userDataPath, 'voicelink-settings-emergency.json');
    }

    /**
     * Initialize settings manager
     */
    async init() {
        try {
            // Ensure user data directory exists
            const userDataPath = app.getPath('userData');
            await fs.mkdir(userDataPath, { recursive: true });

            // Load settings with fallback chain
            await this.loadSettings();

            // Start auto-save system
            this.startAutoSave();

            // Setup app quit handler
            this.setupQuitHandler();

            this.isInitialized = true;
            console.log('Robust settings manager initialized successfully');
        } catch (error) {
            console.error('Failed to initialize settings manager:', error);
            // Use default settings if everything fails
            this.settings = this.getDefaultSettings();
            this.isInitialized = true;
        }
    }

    /**
     * Load settings with multiple fallback options
     */
    async loadSettings() {
        // Try primary settings file first
        try {
            const data = await fs.readFile(this.settingsPath, 'utf8');
            this.settings = JSON.parse(data);
            console.log('Loaded settings from primary file');

            // Create backup of successful load
            await this.createBackup();
            return;
        } catch (error) {
            console.warn('Primary settings file failed, trying backup:', error.message);
        }

        // Try backup file
        try {
            const data = await fs.readFile(this.backupPath, 'utf8');
            this.settings = JSON.parse(data);
            console.log('Loaded settings from backup file');

            // Restore primary file from backup
            await this.saveSettings();
            return;
        } catch (error) {
            console.warn('Backup settings file failed, trying emergency:', error.message);
        }

        // Try emergency file
        try {
            const data = await fs.readFile(this.emergencyPath, 'utf8');
            this.settings = JSON.parse(data);
            console.log('Loaded settings from emergency file');

            // Restore primary and backup files
            await this.saveSettings();
            await this.createBackup();
            return;
        } catch (error) {
            console.warn('Emergency settings file failed, using defaults:', error.message);
        }

        // Use defaults if all files fail
        this.settings = this.getDefaultSettings();
        console.log('Using default settings');

        // Create initial files
        await this.saveSettings();
        await this.createBackup();
        await this.createEmergencyBackup();
    }

    /**
     * Get default settings
     */
    getDefaultSettings() {
        return {
            // Audio settings
            inputVolume: 1.0,
            outputVolume: 1.0,
            noiseSuppression: true,
            echoCancellation: true,
            autoGainControl: true,
            selectedInputDevice: 'default',
            selectedOutputDevice: 'default',

            // UI settings
            startMinimized: false,
            hideToTrayOnClose: true,
            keepInMenubar: true,
            theme: 'system',

            // Update settings
            autoUpdateCheck: true,
            lastUpdateCheck: 0,

            // Audio effects
            enableEffects: false,
            selectedPreset: 'none',
            customEffects: {},

            // 3D Audio
            spatialAudioEnabled: true,
            hrtfEnabled: true,
            roomModel: 'medium-room',

            // PA System
            pushToTalkKeys: ['ctrl'],
            announcementVolume: 0.8,

            // Server settings
            serverPort: 3000,
            autoStartServer: true,

            // Privacy
            allowAnalytics: false,

            // Advanced
            debugMode: false,
            logLevel: 'info',

            // Timestamps
            createdAt: Date.now(),
            lastModified: Date.now(),
            version: app.getVersion()
        };
    }

    /**
     * Get a setting value with fallback
     */
    get(key, defaultValue = null) {
        if (!this.isInitialized) {
            this.uninitializedWarningCount++;
            // Only show warning every 10th call to reduce noise
            if (this.uninitializedWarningCount === 1 || this.uninitializedWarningCount % 10 === 0) {
                console.warn(`Settings manager not initialized, using default (${this.uninitializedWarningCount} calls)`);
            }
            return defaultValue;
        }

        // Support nested keys like 'audio.inputVolume'
        const keys = key.split('.');
        let value = this.settings;

        for (const k of keys) {
            if (value && typeof value === 'object' && k in value) {
                value = value[k];
            } else {
                return defaultValue;
            }
        }

        return value;
    }

    /**
     * Set a setting value
     */
    set(key, value) {
        if (!this.isInitialized) {
            console.warn('Settings manager not initialized, ignoring set operation');
            return false;
        }

        // Support nested keys
        const keys = key.split('.');
        let current = this.settings;

        for (let i = 0; i < keys.length - 1; i++) {
            const k = keys[i];
            if (!(k in current) || typeof current[k] !== 'object') {
                current[k] = {};
            }
            current = current[k];
        }

        const lastKey = keys[keys.length - 1];
        current[lastKey] = value;

        // Update timestamp
        this.settings.lastModified = Date.now();

        // Mark for auto-save
        this.hasUnsavedChanges = true;

        return true;
    }

    /**
     * Get all settings
     */
    getAll() {
        return { ...this.settings };
    }

    /**
     * Reset to defaults
     */
    async resetToDefaults() {
        this.settings = this.getDefaultSettings();
        this.hasUnsavedChanges = true;
        await this.saveSettings();
        await this.createBackup();
        await this.createEmergencyBackup();
        console.log('Settings reset to defaults');
    }

    /**
     * Save settings to primary file
     */
    async saveSettings() {
        try {
            const data = JSON.stringify(this.settings, null, 2);
            await fs.writeFile(this.settingsPath, data, 'utf8');
            this.hasUnsavedChanges = false;
            console.log('Settings saved successfully');
            return true;
        } catch (error) {
            console.error('Failed to save settings:', error);
            return false;
        }
    }

    /**
     * Create backup file
     */
    async createBackup() {
        try {
            const data = JSON.stringify(this.settings, null, 2);
            await fs.writeFile(this.backupPath, data, 'utf8');
            console.log('Settings backup created');
            return true;
        } catch (error) {
            console.error('Failed to create backup:', error);
            return false;
        }
    }

    /**
     * Create emergency backup (updated less frequently)
     */
    async createEmergencyBackup() {
        try {
            const data = JSON.stringify(this.settings, null, 2);
            await fs.writeFile(this.emergencyPath, data, 'utf8');
            console.log('Emergency backup created');
            return true;
        } catch (error) {
            console.error('Failed to create emergency backup:', error);
            return false;
        }
    }

    /**
     * Start auto-save system
     */
    startAutoSave() {
        // Save every 5 seconds if there are changes
        this.autoSaveInterval = setInterval(async () => {
            if (this.hasUnsavedChanges) {
                await this.saveSettings();

                // Create backup every 10 saves
                const now = Date.now();
                if (now - (this.lastBackup || 0) > 50000) { // 50 seconds
                    await this.createBackup();
                    this.lastBackup = now;
                }

                // Create emergency backup every hour
                if (now - (this.lastEmergencyBackup || 0) > 3600000) { // 1 hour
                    await this.createEmergencyBackup();
                    this.lastEmergencyBackup = now;
                }
            }
        }, 5000);
    }

    /**
     * Setup app quit handler
     */
    setupQuitHandler() {
        // Save on app quit
        app.on('before-quit', async () => {
            console.log('App quitting, saving settings...');

            try {
                // Force save current settings
                await this.saveSettings();

                // Create final backup
                await this.createBackup();

                console.log('Settings saved successfully before quit');
            } catch (error) {
                console.error('Failed to save settings before quit:', error);
            }
        });

        // Also save on window close
        app.on('window-all-closed', async () => {
            if (this.hasUnsavedChanges) {
                await this.saveSettings();
                await this.createBackup();
            }
        });
    }

    /**
     * Force save all settings immediately
     */
    async forceSave() {
        const success = await this.saveSettings();
        if (success) {
            await this.createBackup();
            await this.createEmergencyBackup();
        }
        return success;
    }

    /**
     * Cleanup
     */
    cleanup() {
        if (this.autoSaveInterval) {
            clearInterval(this.autoSaveInterval);
            this.autoSaveInterval = null;
        }
    }

    /**
     * Get settings file status
     */
    async getFileStatus() {
        const status = {};

        try {
            const stat = await fs.stat(this.settingsPath);
            status.primary = {
                exists: true,
                size: stat.size,
                modified: stat.mtime
            };
        } catch {
            status.primary = { exists: false };
        }

        try {
            const stat = await fs.stat(this.backupPath);
            status.backup = {
                exists: true,
                size: stat.size,
                modified: stat.mtime
            };
        } catch {
            status.backup = { exists: false };
        }

        try {
            const stat = await fs.stat(this.emergencyPath);
            status.emergency = {
                exists: true,
                size: stat.size,
                modified: stat.mtime
            };
        } catch {
            status.emergency = { exists: false };
        }

        return status;
    }
}

module.exports = RobustSettingsManager;