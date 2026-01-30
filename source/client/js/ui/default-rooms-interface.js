/**
 * VoiceLink Local - Default Rooms Management Interface
 * UI for server owners to configure and manage default room templates
 */

class DefaultRoomsInterface {
    constructor() {
        this.defaultRoomsManager = window.defaultRoomsManager;
        this.isOpen = false;
        this.modalElement = null;

        this.init();
    }

    init() {
        this.createManagementInterface();
        this.setupEventListeners();
    }

    setupEventListeners() {
        // Listen for default rooms generation events
        window.addEventListener('defaultRoomsGenerated', (event) => {
            this.handleRoomsGenerated(event.detail);
        });

        // Listen for server config updates
        window.addEventListener('serverConfigUpdated', (event) => {
            this.updateInterfaceState();
        });
    }

    createManagementInterface() {
        // Add default rooms management button to main menu
        this.addManagementButton();

        // Create the management modal
        this.createManagementModal();
    }

    addManagementButton() {
        const settingsSection = document.querySelector('.menu-section:has(#comprehensive-settings-btn)');
        if (!settingsSection) return;

        const button = document.createElement('button');
        button.id = 'default-rooms-manager-btn';
        button.className = 'settings-btn';
        button.innerHTML = '🏢 Default Rooms Manager';
        button.title = 'Manage auto-generated default rooms';

        button.addEventListener('click', () => {
            this.openManagementModal();
        });

        // Insert after comprehensive settings button
        const comprehensiveBtn = document.getElementById('comprehensive-settings-btn');
        if (comprehensiveBtn) {
            comprehensiveBtn.parentNode.insertBefore(button, comprehensiveBtn.nextSibling);
        } else {
            settingsSection.appendChild(button);
        }
    }

    createManagementModal() {
        const modal = document.createElement('dialog');
        modal.id = 'default-rooms-modal';
        modal.className = 'default-rooms-modal';

        modal.innerHTML = `
            <div class="modal-content">
                <div class="modal-header">
                    <h2>🏢 Default Rooms Manager</h2>
                    <button class="close-btn" onclick="this.closest('dialog').close()">&times;</button>
                </div>

                <div class="modal-body">
                    <div class="config-section">
                        <div class="section-header">
                            <h3>General Settings</h3>
                            <div class="section-actions">
                                <button id="regenerate-all-btn" class="action-btn regenerate-btn">
                                    🔄 Regenerate All Rooms
                                </button>
                                <button id="clear-all-btn" class="action-btn danger-btn">
                                    🗑️ Clear All Default Rooms
                                </button>
                            </div>
                        </div>

                        <div class="general-settings">
                            <label class="setting-toggle">
                                <input type="checkbox" id="enable-default-rooms">
                                <span class="toggle-slider"></span>
                                <span class="toggle-label">Enable Default Rooms</span>
                            </label>
                            <p class="setting-description">
                                Automatically generate themed rooms when the server starts
                            </p>

                            <label class="setting-toggle">
                                <input type="checkbox" id="auto-generate-rooms">
                                <span class="toggle-slider"></span>
                                <span class="toggle-label">Auto-Generate on Startup</span>
                            </label>
                            <p class="setting-description">
                                Create default rooms automatically when the server connects
                            </p>

                            <div class="setting-group">
                                <label for="max-default-rooms">Maximum Default Rooms:</label>
                                <input type="number" id="max-default-rooms" min="5" max="50" value="15">
                                <span class="setting-note">Total limit across all categories</span>
                            </div>
                        </div>
                    </div>

                    <div class="categories-section">
                        <h3>Room Categories</h3>
                        <div id="categories-list" class="categories-list">
                            <!-- Categories will be populated here -->
                        </div>
                    </div>

                    <div class="templates-section">
                        <h3>Room Templates</h3>
                        <div class="template-viewer">
                            <div class="category-selector">
                                <select id="template-category-select">
                                    <option value="">Select a category to view templates</option>
                                </select>
                            </div>
                            <div id="templates-list" class="templates-list">
                                <!-- Templates will be populated here -->
                            </div>
                        </div>
                    </div>

                    <div class="status-section">
                        <h3>Current Status</h3>
                        <div class="status-info">
                            <div class="status-item">
                                <span class="status-label">Generated Rooms:</span>
                                <span id="generated-count" class="status-value">0</span>
                            </div>
                            <div class="status-item">
                                <span class="status-label">Active Categories:</span>
                                <span id="active-categories" class="status-value">0</span>
                            </div>
                            <div class="status-item">
                                <span class="status-label">Last Generated:</span>
                                <span id="last-generated" class="status-value">Never</span>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="modal-footer">
                    <button class="btn-secondary" onclick="this.closest('dialog').close()">Cancel</button>
                    <button id="save-config-btn" class="btn-primary">Save Configuration</button>
                </div>
            </div>
        `;

        document.body.appendChild(modal);
        this.modalElement = modal;

        // Setup modal event listeners
        this.setupModalEventListeners();
    }

    setupModalEventListeners() {
        const modal = this.modalElement;

        // General settings
        modal.querySelector('#enable-default-rooms').addEventListener('change', (e) => {
            this.toggleAutoGenerate(e.target.checked);
        });

        modal.querySelector('#auto-generate-rooms').addEventListener('change', (e) => {
            this.updateGeneralSetting('autoGenerate', e.target.checked);
        });

        modal.querySelector('#max-default-rooms').addEventListener('change', (e) => {
            this.updateGeneralSetting('maxDefaultRooms', parseInt(e.target.value));
        });

        // Action buttons
        modal.querySelector('#regenerate-all-btn').addEventListener('click', () => {
            this.regenerateAllRooms();
        });

        modal.querySelector('#clear-all-btn').addEventListener('click', () => {
            this.clearAllDefaultRooms();
        });

        modal.querySelector('#save-config-btn').addEventListener('click', () => {
            this.saveConfiguration();
        });

        // Template category selector
        modal.querySelector('#template-category-select').addEventListener('change', (e) => {
            this.showTemplatesForCategory(e.target.value);
        });
    }

    openManagementModal() {
        if (!this.modalElement) return;

        this.loadCurrentConfiguration();
        this.populateCategories();
        this.populateCategorySelector();
        this.updateStatus();

        this.modalElement.showModal();
        this.isOpen = true;
    }

    loadCurrentConfiguration() {
        const config = this.defaultRoomsManager.serverConfig;
        const modal = this.modalElement;

        // General settings
        modal.querySelector('#enable-default-rooms').checked = config.enabled || false;
        modal.querySelector('#auto-generate-rooms').checked = config.autoGenerate || false;
        modal.querySelector('#max-default-rooms').value = config.maxDefaultRooms || 15;

        // Update dependent controls
        this.toggleAutoGenerate(config.enabled);
    }

    populateCategories() {
        const categoriesList = this.modalElement.querySelector('#categories-list');
        const categories = this.defaultRoomsManager.getAllCategories();

        categoriesList.innerHTML = categories.map(category => `
            <div class="category-item">
                <div class="category-header">
                    <div class="category-info">
                        <span class="category-icon">${category.icon}</span>
                        <div class="category-details">
                            <h4>${category.category}</h4>
                            <p>${category.description}</p>
                        </div>
                    </div>
                    <div class="category-controls">
                        <label class="setting-toggle">
                            <input type="checkbox"
                                   data-category="${category.id}"
                                   data-setting="enabled"
                                   ${category.config.enabled ? 'checked' : ''}>
                            <span class="toggle-slider"></span>
                        </label>
                    </div>
                </div>
                <div class="category-settings">
                    <div class="setting-group">
                        <label>Max Rooms for this category:</label>
                        <input type="number"
                               min="0"
                               max="10"
                               value="${category.config.maxRooms || 0}"
                               data-category="${category.id}"
                               data-setting="maxRooms">
                    </div>
                    <div class="category-stats">
                        <span class="stat">Templates: ${category.templates.length}</span>
                        <span class="stat">Custom: ${category.templates.filter(t => t.isCustom).length}</span>
                    </div>
                </div>
            </div>
        `).join('');

        // Add event listeners for category controls
        categoriesList.addEventListener('change', (e) => {
            if (e.target.dataset.category && e.target.dataset.setting) {
                this.updateCategorySetting(
                    e.target.dataset.category,
                    e.target.dataset.setting,
                    e.target.type === 'checkbox' ? e.target.checked : parseInt(e.target.value)
                );
            }
        });
    }

    populateCategorySelector() {
        const selector = this.modalElement.querySelector('#template-category-select');
        const categories = this.defaultRoomsManager.getAllCategories();

        selector.innerHTML = '<option value="">Select a category to view templates</option>' +
            categories.map(category => `
                <option value="${category.id}">${category.icon} ${category.category}</option>
            `).join('');
    }

    showTemplatesForCategory(categoryId) {
        const templatesList = this.modalElement.querySelector('#templates-list');

        if (!categoryId) {
            templatesList.innerHTML = '<p class="no-selection">Select a category to view its templates</p>';
            return;
        }

        const templates = this.defaultRoomsManager.getTemplatesByCategory(categoryId);

        if (templates.length === 0) {
            templatesList.innerHTML = '<p class="no-templates">No templates available for this category</p>';
            return;
        }

        templatesList.innerHTML = templates.map((template, index) => `
            <div class="template-item ${template.isCustom ? 'custom-template' : ''}">
                <div class="template-header">
                    <h5>${template.name}</h5>
                    ${template.isCustom ? '<span class="custom-badge">Custom</span>' : ''}
                </div>
                <p class="template-description">${template.description}</p>
                <div class="template-details">
                    <div class="template-settings">
                        <span class="setting">👥 Max: ${template.maxUsers}</span>
                        <span class="setting">🔒 ${template.privacyLevel}</span>
                        <span class="setting">⏱️ ${this.formatDuration(template.duration)}</span>
                    </div>
                    <div class="template-tags">
                        ${(template.tags || []).map(tag => `<span class="tag">${tag}</span>`).join('')}
                    </div>
                </div>
                <div class="template-actions">
                    <button class="action-btn preview-btn" data-template="${index}" data-category="${categoryId}">
                        👁️ Preview
                    </button>
                    ${template.isCustom ? `
                        <button class="action-btn edit-btn" data-template="${index}" data-category="${categoryId}">
                            ✏️ Edit
                        </button>
                        <button class="action-btn danger-btn" data-template="${index}" data-category="${categoryId}">
                            🗑️ Delete
                        </button>
                    ` : ''}
                </div>
            </div>
        `).join('');

        // Add event listeners for template actions
        templatesList.addEventListener('click', (e) => {
            if (e.target.classList.contains('preview-btn')) {
                this.previewTemplate(e.target.dataset.category, parseInt(e.target.dataset.template));
            } else if (e.target.classList.contains('edit-btn')) {
                this.editTemplate(e.target.dataset.category, parseInt(e.target.dataset.template));
            } else if (e.target.classList.contains('danger-btn')) {
                this.deleteTemplate(e.target.dataset.category, parseInt(e.target.dataset.template));
            }
        });
    }

    updateStatus() {
        const generatedRooms = this.defaultRoomsManager.getGeneratedRooms();
        const categories = this.defaultRoomsManager.getAllCategories();
        const activeCategories = categories.filter(cat => cat.config.enabled).length;

        this.modalElement.querySelector('#generated-count').textContent = generatedRooms.length;
        this.modalElement.querySelector('#active-categories').textContent = activeCategories;

        const lastGenerated = generatedRooms.reduce((latest, room) => {
            return Math.max(latest, room.createdAt || 0);
        }, 0);

        this.modalElement.querySelector('#last-generated').textContent =
            lastGenerated ? new Date(lastGenerated).toLocaleString() : 'Never';
    }

    // Configuration management
    updateGeneralSetting(setting, value) {
        const updates = {};
        updates[setting] = value;
        this.defaultRoomsManager.updateServerConfig(updates);
    }

    updateCategorySetting(categoryId, setting, value) {
        const config = this.defaultRoomsManager.serverConfig;
        if (!config.categories[categoryId]) {
            config.categories[categoryId] = {};
        }
        config.categories[categoryId][setting] = value;
        this.defaultRoomsManager.updateServerConfig(config);
    }

    toggleAutoGenerate(enabled) {
        const modal = this.modalElement;
        const dependentControls = modal.querySelectorAll('#auto-generate-rooms, #max-default-rooms, .categories-section, .templates-section');

        dependentControls.forEach(control => {
            if (control.tagName === 'INPUT') {
                control.disabled = !enabled;
            } else {
                control.style.opacity = enabled ? '1' : '0.5';
                control.style.pointerEvents = enabled ? 'auto' : 'none';
            }
        });

        this.updateGeneralSetting('enabled', enabled);
    }

    // Actions
    async regenerateAllRooms() {
        if (!confirm('This will remove all existing default rooms and create new ones. Continue?')) {
            return;
        }

        try {
            const button = this.modalElement.querySelector('#regenerate-all-btn');
            button.disabled = true;
            button.textContent = '🔄 Regenerating...';

            await this.defaultRoomsManager.regenerateDefaultRooms();

            this.updateStatus();
            this.showNotification('Default rooms regenerated successfully', 'success');
        } catch (error) {
            console.error('Failed to regenerate rooms:', error);
            this.showNotification('Failed to regenerate rooms: ' + error.message, 'error');
        } finally {
            const button = this.modalElement.querySelector('#regenerate-all-btn');
            button.disabled = false;
            button.textContent = '🔄 Regenerate All Rooms';
        }
    }

    async clearAllDefaultRooms() {
        if (!confirm('This will permanently remove all default rooms. This action cannot be undone. Continue?')) {
            return;
        }

        try {
            const button = this.modalElement.querySelector('#clear-all-btn');
            button.disabled = true;
            button.textContent = '🗑️ Clearing...';

            await this.defaultRoomsManager.removeDefaultRooms();

            this.updateStatus();
            this.showNotification('All default rooms cleared', 'success');
        } catch (error) {
            console.error('Failed to clear rooms:', error);
            this.showNotification('Failed to clear rooms: ' + error.message, 'error');
        } finally {
            const button = this.modalElement.querySelector('#clear-all-btn');
            button.disabled = false;
            button.textContent = '🗑️ Clear All Default Rooms';
        }
    }

    saveConfiguration() {
        try {
            // Configuration is saved automatically through updateServerConfig calls
            this.modalElement.close();
            this.showNotification('Configuration saved successfully', 'success');
        } catch (error) {
            console.error('Failed to save configuration:', error);
            this.showNotification('Failed to save configuration: ' + error.message, 'error');
        }
    }

    // Template management
    previewTemplate(categoryId, templateIndex) {
        const templates = this.defaultRoomsManager.getTemplatesByCategory(categoryId);
        const template = templates[templateIndex];

        if (!template) return;

        // Create preview modal
        const previewModal = document.createElement('dialog');
        previewModal.className = 'template-preview-modal';
        previewModal.innerHTML = `
            <div class="modal-content">
                <div class="modal-header">
                    <h3>Template Preview: ${template.name}</h3>
                    <button class="close-btn" onclick="this.closest('dialog').close()">&times;</button>
                </div>
                <div class="modal-body">
                    <div class="preview-content">
                        <p><strong>Description:</strong> ${template.description}</p>
                        <div class="preview-settings">
                            <div class="setting-row">
                                <span>Maximum Users:</span>
                                <span>${template.maxUsers}</span>
                            </div>
                            <div class="setting-row">
                                <span>Privacy Level:</span>
                                <span>${template.privacyLevel}</span>
                            </div>
                            <div class="setting-row">
                                <span>Duration:</span>
                                <span>${this.formatDuration(template.duration)}</span>
                            </div>
                            <div class="setting-row">
                                <span>Ambient Sound:</span>
                                <span>${template.ambientSound || 'None'}</span>
                            </div>
                        </div>
                        <div class="preview-tags">
                            <strong>Tags:</strong>
                            ${(template.tags || []).map(tag => `<span class="tag">${tag}</span>`).join('')}
                        </div>
                    </div>
                </div>
                <div class="modal-footer">
                    <button class="btn-primary" onclick="this.closest('dialog').close()">Close</button>
                </div>
            </div>
        `;

        document.body.appendChild(previewModal);
        previewModal.showModal();

        // Remove modal when closed
        previewModal.addEventListener('close', () => {
            previewModal.remove();
        });
    }

    editTemplate(categoryId, templateIndex) {
        // Implementation for template editing would go here
        this.showNotification('Template editing not yet implemented', 'info');
    }

    deleteTemplate(categoryId, templateIndex) {
        if (!confirm('Are you sure you want to delete this custom template?')) {
            return;
        }

        if (this.defaultRoomsManager.removeTemplate(categoryId, templateIndex)) {
            this.showTemplatesForCategory(categoryId);
            this.showNotification('Template deleted successfully', 'success');
        } else {
            this.showNotification('Failed to delete template', 'error');
        }
    }

    // Event handlers
    handleRoomsGenerated(detail) {
        this.updateStatus();
        this.showNotification(`Generated ${detail.count} default rooms`, 'success');
    }

    updateInterfaceState() {
        if (this.isOpen) {
            this.loadCurrentConfiguration();
            this.updateStatus();
        }
    }

    // Utility methods
    formatDuration(duration) {
        if (!duration) return 'Lifetime';

        const hours = Math.floor(duration / 3600000);
        const minutes = Math.floor((duration % 3600000) / 60000);

        if (hours > 0) {
            return `${hours}h${minutes > 0 ? ` ${minutes}m` : ''}`;
        } else {
            return `${minutes}m`;
        }
    }

    showNotification(message, type = 'info') {
        // Create notification element
        const notification = document.createElement('div');
        notification.className = `notification notification-${type}`;
        notification.textContent = message;

        // Style the notification
        notification.style.cssText = `
            position: fixed;
            top: 20px;
            right: 20px;
            background: ${type === 'success' ? '#4caf50' : type === 'error' ? '#f44336' : '#2196f3'};
            color: white;
            padding: 12px 20px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.3);
            z-index: 10000;
            opacity: 0;
            transform: translateX(100%);
            transition: all 0.3s ease;
        `;

        document.body.appendChild(notification);

        // Animate in
        setTimeout(() => {
            notification.style.opacity = '1';
            notification.style.transform = 'translateX(0)';
        }, 100);

        // Remove after 3 seconds
        setTimeout(() => {
            notification.style.opacity = '0';
            notification.style.transform = 'translateX(100%)';
            setTimeout(() => notification.remove(), 300);
        }, 3000);
    }
}

// Initialize the interface
window.defaultRoomsInterface = new DefaultRoomsInterface();

// Export for module usage
if (typeof module !== 'undefined' && module.exports) {
    module.exports = DefaultRoomsInterface;
}