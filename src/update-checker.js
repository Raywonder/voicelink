/**
 * VoiceLink Local Update Checker
 * Checks for new versions using electron-updater with fallback to manual check
 */

const { app, dialog, shell } = require('electron');
const https = require('https');
const semver = require('./semver-lite');

// Try to load electron-updater (may not be available in all environments)
let autoUpdater = null;
try {
    autoUpdater = require('electron-updater').autoUpdater;
    autoUpdater.autoDownload = false; // We'll handle download prompts manually
    autoUpdater.autoInstallOnAppQuit = true;
} catch (e) {
    console.log('electron-updater not available, using manual update check');
}

class UpdateChecker {
    constructor() {
        this.currentVersion = app.getVersion();
        this.updateCheckUrls = [
            // Primary URLs - will try these patterns in order
            'https://raywonderis.me/updates/voicelink-local/version.json',
            'https://raywonderis.me/downloads/voicelink-local/version.json',
            'https://devinecreations.net/voicelink-downloads/version.json',
            'https://devinecreations.net/downloads/voicelink-local/version.json'
        ];
        this.lastCheckTime = 0;
        this.checkInterval = 24 * 60 * 60 * 1000; // 24 hours
        this.isChecking = false;
        this.downloadProgress = 0;
        this.isDownloading = false;

        // Setup electron-updater events if available
        if (autoUpdater) {
            this.setupAutoUpdater();
        }
    }

    /**
     * Setup electron-updater event handlers
     */
    setupAutoUpdater() {
        autoUpdater.on('checking-for-update', () => {
            console.log('Checking for updates via electron-updater...');
        });

        autoUpdater.on('update-available', (info) => {
            console.log('Update available:', info.version);
            this.showAutoUpdateDialog(info);
        });

        autoUpdater.on('update-not-available', () => {
            console.log('No updates available');
        });

        autoUpdater.on('download-progress', (progressObj) => {
            this.downloadProgress = progressObj.percent;
            console.log(`Download progress: ${Math.round(progressObj.percent)}%`);
        });

        autoUpdater.on('update-downloaded', (info) => {
            console.log('Update downloaded:', info.version);
            this.showInstallDialog(info);
        });

        autoUpdater.on('error', (err) => {
            console.log('Auto-updater error:', err.message);
            // Fall back to manual check
            this.checkForUpdatesAuto();
        });
    }

    /**
     * Show dialog when auto-update is available
     */
    showAutoUpdateDialog(info) {
        dialog.showMessageBox({
            type: 'info',
            title: 'VoiceLink Local - Update Available',
            message: `New version ${info.version} is available!`,
            detail: `Current version: ${this.currentVersion}\nNew version: ${info.version}\n\nWould you like to download and install this update?`,
            buttons: ['Download & Install', 'Later'],
            defaultId: 0
        }).then((result) => {
            if (result.response === 0) {
                this.isDownloading = true;
                autoUpdater.downloadUpdate();
            }
        });
    }

    /**
     * Show dialog when update is downloaded and ready to install
     */
    showInstallDialog(info) {
        this.isDownloading = false;
        dialog.showMessageBox({
            type: 'info',
            title: 'VoiceLink Local - Update Ready',
            message: `Version ${info.version} has been downloaded`,
            detail: 'The update will be installed when you restart the application. Would you like to restart now?',
            buttons: ['Restart Now', 'Later'],
            defaultId: 0
        }).then((result) => {
            if (result.response === 0) {
                autoUpdater.quitAndInstall(false, true);
            }
        });
    }

    /**
     * Check for updates using electron-updater (preferred) or manual check (fallback)
     */
    async checkForUpdatesWithAutoUpdater() {
        if (autoUpdater) {
            try {
                await autoUpdater.checkForUpdates();
            } catch (e) {
                console.log('electron-updater check failed, using manual:', e.message);
                await this.checkForUpdatesAuto();
            }
        } else {
            await this.checkForUpdatesAuto();
        }
    }

    /**
     * Check for updates automatically (silent unless update found)
     */
    async checkForUpdatesAuto() {
        const now = Date.now();
        if (now - this.lastCheckTime < this.checkInterval) {
            return; // Too soon since last check
        }

        try {
            const updateInfo = await this.fetchLatestVersion();
            if (updateInfo && this.isNewerVersion(updateInfo.version)) {
                this.showUpdateDialog(updateInfo, false);
            }
            this.lastCheckTime = now;
        } catch (error) {
            console.log('Auto update check failed (this is normal):', error.message);
        }
    }

    /**
     * Check for updates manually (show result regardless)
     */
    async checkForUpdatesManual() {
        if (this.isChecking) return;
        this.isChecking = true;

        try {
            const updateInfo = await this.fetchLatestVersion();
            if (updateInfo && this.isNewerVersion(updateInfo.version)) {
                this.showUpdateDialog(updateInfo, true);
            } else {
                dialog.showMessageBox({
                    type: 'info',
                    title: 'VoiceLink Local - Up to Date',
                    message: 'You have the latest version',
                    detail: `Current version: ${this.currentVersion}\nNo updates available at this time.`,
                    buttons: ['OK']
                });
            }
        } catch (error) {
            dialog.showMessageBox({
                type: 'warning',
                title: 'VoiceLink Local - Update Check Failed',
                message: 'Unable to check for updates',
                detail: `Error: ${error.message}\n\nPlease check your internet connection or try again later.`,
                buttons: ['OK']
            });
        } finally {
            this.isChecking = false;
        }
    }

    /**
     * Fetch latest version info from update server
     */
    async fetchLatestVersion() {
        for (const url of this.updateCheckUrls) {
            try {
                console.log(`Checking for updates at: ${url}`);
                const data = await this.httpsGet(url);
                const updateInfo = JSON.parse(data);

                // Validate response format
                if (updateInfo && updateInfo.version && updateInfo.downloads) {
                    console.log(`Found version info: ${updateInfo.version}`);
                    return updateInfo;
                }
            } catch (error) {
                console.log(`Failed to fetch from ${url}:`, error.message);
                continue; // Try next URL
            }
        }
        throw new Error('All update servers unavailable');
    }

    /**
     * Make HTTPS GET request
     */
    httpsGet(url) {
        return new Promise((resolve, reject) => {
            const request = https.get(url, {
                timeout: 10000,
                headers: {
                    'User-Agent': `VoiceLink-Local/${this.currentVersion}`
                }
            }, (response) => {
                if (response.statusCode !== 200) {
                    reject(new Error(`HTTP ${response.statusCode}`));
                    return;
                }

                let data = '';
                response.on('data', chunk => data += chunk);
                response.on('end', () => resolve(data));
            });

            request.on('error', reject);
            request.on('timeout', () => {
                request.destroy();
                reject(new Error('Request timeout'));
            });
        });
    }

    /**
     * Compare version numbers
     */
    isNewerVersion(remoteVersion) {
        try {
            return semver.gt(remoteVersion, this.currentVersion);
        } catch (error) {
            console.error('Version comparison failed:', error);
            return false;
        }
    }

    /**
     * Show update dialog to user
     */
    showUpdateDialog(updateInfo, isManual) {
        const platform = process.platform;
        const arch = process.arch;
        const downloadUrl = this.getDownloadUrl(updateInfo.downloads, platform, arch);

        const messageOptions = {
            type: 'info',
            title: 'VoiceLink Local - Update Available',
            message: `New version ${updateInfo.version} is available!`,
            detail: this.formatUpdateDetails(updateInfo),
            buttons: downloadUrl ? ['Download Update', 'View Release Notes', 'Later'] : ['View Release Notes', 'Later'],
            defaultId: 0
        };

        dialog.showMessageBox(messageOptions).then((result) => {
            if (result.response === 0 && downloadUrl) {
                // Download Update
                shell.openExternal(downloadUrl);
            } else if ((result.response === 1 && downloadUrl) || (result.response === 0 && !downloadUrl)) {
                // View Release Notes
                if (updateInfo.releaseNotes) {
                    shell.openExternal(updateInfo.releaseNotes);
                }
            }
        });
    }

    /**
     * Get appropriate download URL for current platform
     */
    getDownloadUrl(downloads, platform, arch) {
        // Map platform/arch to download keys
        const platformMap = {
            'darwin': arch === 'arm64' ? 'macArm64' : 'macIntel',
            'win32': arch === 'x64' ? 'windowsX64' : 'windowsX86',
            'linux': 'linuxX64'
        };

        const downloadKey = platformMap[platform];
        return downloads[downloadKey] || downloads.universal;
    }

    /**
     * Format update details for display
     */
    formatUpdateDetails(updateInfo) {
        let details = `Current version: ${this.currentVersion}\nNew version: ${updateInfo.version}\n\n`;

        if (updateInfo.releaseDate) {
            details += `Release date: ${updateInfo.releaseDate}\n`;
        }

        if (updateInfo.description) {
            details += `\nWhat's new:\n${updateInfo.description}\n`;
        }

        if (updateInfo.critical) {
            details += '\n⚠️ This is a critical update with important security or stability fixes.';
        }

        return details;
    }

    /**
     * Start automatic update checking
     */
    startAutoCheck() {
        // Check on startup (after 30 seconds delay)
        setTimeout(() => {
            this.checkForUpdatesWithAutoUpdater();
        }, 30000);

        // Then check every 24 hours
        setInterval(() => {
            this.checkForUpdatesWithAutoUpdater();
        }, this.checkInterval);
    }

    /**
     * Get the auto-updater instance for external use
     */
    getAutoUpdater() {
        return autoUpdater;
    }
}

module.exports = UpdateChecker;