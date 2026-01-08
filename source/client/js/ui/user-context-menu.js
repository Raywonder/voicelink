/**
 * User Context Menu Manager
 * Handles context menus for users in channels with accessibility support
 */

class UserContextMenu {
    constructor() {
        this.activeMenu = null;
        this.selectedUser = null;
        this.menuContainer = null;
        this.isVisible = false;

        // Menu actions available for users
        this.menuActions = {
            profile: {
                label: 'View Profile',
                icon: '👤',
                shortcut: 'P',
                action: (userId) => this.viewUserProfile(userId)
            },
            directMessage: {
                label: 'Send Direct Message',
                icon: '💬',
                shortcut: 'M',
                action: (userId) => this.sendDirectMessage(userId)
            },
            mute: {
                label: 'Mute User',
                icon: '🔇',
                shortcut: 'U',
                action: (userId) => this.toggleUserMute(userId)
            },
            volume: {
                label: 'Adjust Volume',
                icon: '🔊',
                shortcut: 'V',
                action: (userId) => this.adjustUserVolume(userId)
            },
            spatialPosition: {
                label: 'Set 3D Position',
                icon: '🎯',
                shortcut: 'S',
                action: (userId) => this.setSpatialPosition(userId)
            },
            audioRouting: {
                label: 'Audio Routing',
                icon: '🎛️',
                shortcut: 'R',
                action: (userId) => this.configureAudioRouting(userId)
            },
            userInfo: {
                label: 'User Information',
                icon: 'ℹ️',
                shortcut: 'I',
                action: (userId) => this.showUserInfo(userId)
            },
            separator1: { type: 'separator' },
            kick: {
                label: 'Kick User',
                icon: '👢',
                shortcut: 'K',
                action: (userId) => this.kickUser(userId),
                requiresPermission: 'moderator'
            },
            ban: {
                label: 'Ban User',
                icon: '🚫',
                shortcut: 'B',
                action: (userId) => this.banUser(userId),
                requiresPermission: 'moderator'
            },
            separator2: { type: 'separator' },
            reportUser: {
                label: 'Report User',
                icon: '⚠️',
                shortcut: 'Shift+R',
                action: (userId) => this.reportUser(userId)
            }
        };

        this.init();
    }

    init() {
        this.createMenuContainer();
        this.setupEventListeners();
        this.setupKeyboardShortcuts();
        this.setupAccessibility();

        console.log('User Context Menu initialized');
    }

    createMenuContainer() {
        this.menuContainer = document.createElement('div');
        this.menuContainer.id = 'user-context-menu';
        this.menuContainer.className = 'context-menu hidden';
        this.menuContainer.setAttribute('role', 'menu');
        this.menuContainer.setAttribute('aria-label', 'User Actions Menu');

        document.body.appendChild(this.menuContainer);
    }

    setupEventListeners() {
        // Global click handler to close menu
        document.addEventListener('click', (e) => {
            if (this.isVisible && !this.menuContainer.contains(e.target)) {
                this.hideMenu();
            }
        });

        // Handle escape key
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && this.isVisible) {
                this.hideMenu();
            }
        });

        // Listen for user list updates to attach event listeners
        window.addEventListener('userListUpdated', () => {
            this.attachUserEventListeners();
        });
    }

    setupKeyboardShortcuts() {
        document.addEventListener('keydown', (e) => {
            // Check for context menu trigger (Shift+M for VoiceOver compatibility)
            if (e.shiftKey && e.key === 'M') {
                const focusedUser = document.activeElement.closest('.user-item');
                if (focusedUser) {
                    const userId = focusedUser.dataset.userId;
                    if (userId) {
                        e.preventDefault();
                        this.showMenuForUser(userId, focusedUser);
                    }
                }
            }

            // Windows Application key support
            if (e.key === 'ContextMenu') {
                const focusedUser = document.activeElement.closest('.user-item');
                if (focusedUser) {
                    const userId = focusedUser.dataset.userId;
                    if (userId) {
                        e.preventDefault();
                        this.showMenuForUser(userId, focusedUser);
                    }
                }
            }

            // Handle menu navigation when visible
            if (this.isVisible) {
                this.handleMenuNavigation(e);
            }
        });
    }

    setupAccessibility() {
        // Add ARIA labels and roles to user items
        this.updateUserAccessibility();

        // Listen for user list changes
        const observer = new MutationObserver(() => {
            this.updateUserAccessibility();
        });

        const userList = document.getElementById('user-list');
        if (userList) {
            observer.observe(userList, { childList: true, subtree: true });
        }
    }

    updateUserAccessibility() {
        const userItems = document.querySelectorAll('.user-item');
        userItems.forEach(item => {
            if (!item.hasAttribute('tabindex')) {
                item.setAttribute('tabindex', '0');
                item.setAttribute('role', 'button');
                item.setAttribute('aria-label', `User ${item.dataset.userName || 'Unknown'}`);
                item.setAttribute('aria-describedby', 'context-menu-help');
            }
        });

        // Add help text for screen readers
        if (!document.getElementById('context-menu-help')) {
            const helpText = document.createElement('div');
            helpText.id = 'context-menu-help';
            helpText.className = 'sr-only';
            helpText.textContent = 'Right-click or press Shift+M to open user menu. Use Application key on Windows.';
            document.body.appendChild(helpText);
        }
    }

    attachUserEventListeners() {
        const userItems = document.querySelectorAll('.user-item');

        userItems.forEach(item => {
            if (!item.dataset.contextMenuAttached) {
                // Right-click context menu
                item.addEventListener('contextmenu', (e) => {
                    e.preventDefault();
                    const userId = item.dataset.userId;
                    if (userId) {
                        this.showMenuForUser(userId, item, e.clientX, e.clientY);
                    }
                });

                // Keyboard activation
                item.addEventListener('keydown', (e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        const userId = item.dataset.userId;
                        if (userId) {
                            this.showMenuForUser(userId, item);
                        }
                    }
                });

                item.dataset.contextMenuAttached = 'true';
            }
        });
    }

    showMenuForUser(userId, userElement, x = null, y = null) {
        this.selectedUser = userId;
        this.hideMenu(); // Hide any existing menu

        // Get user data
        const userData = this.getUserData(userId);
        if (!userData) {
            console.warn('User data not found for:', userId);
            return;
        }

        // Build menu HTML
        const menuHTML = this.buildMenuHTML(userData);
        this.menuContainer.innerHTML = menuHTML;

        // Position menu
        if (x !== null && y !== null) {
            this.positionMenuAtCursor(x, y);
        } else {
            this.positionMenuNearElement(userElement);
        }

        // Show menu
        this.menuContainer.classList.remove('hidden');
        this.isVisible = true;

        // Focus first menu item for keyboard navigation
        const firstMenuItem = this.menuContainer.querySelector('.menu-item:not(.separator)');
        if (firstMenuItem) {
            firstMenuItem.focus();
        }

        // Announce to screen readers
        this.announceMenuOpened(userData.name);

        // Setup menu item event listeners
        this.setupMenuItemListeners();
    }

    buildMenuHTML(userData) {
        const userPermissions = this.getUserPermissions();
        let menuHTML = `
            <div class="menu-header">
                <div class="user-avatar">${userData.avatar || '👤'}</div>
                <div class="user-details">
                    <h4>${userData.name}</h4>
                    <span class="user-status">${userData.status}</span>
                </div>
            </div>
        `;

        Object.entries(this.menuActions).forEach(([key, action]) => {
            if (action.type === 'separator') {
                menuHTML += '<div class="menu-separator" role="separator"></div>';
                return;
            }

            // Check permissions
            if (action.requiresPermission && !userPermissions.includes(action.requiresPermission)) {
                return; // Skip this action
            }

            // Check if action is contextually relevant
            if (key === 'mute' && userData.isMuted) {
                action.label = 'Unmute User';
                action.icon = '🔊';
            }

            menuHTML += `
                <div class="menu-item"
                     role="menuitem"
                     tabindex="0"
                     data-action="${key}"
                     data-shortcut="${action.shortcut || ''}"
                     aria-label="${action.label}">
                    <span class="menu-icon">${action.icon}</span>
                    <span class="menu-label">${action.label}</span>
                    ${action.shortcut ? `<span class="menu-shortcut">${action.shortcut}</span>` : ''}
                </div>
            `;
        });

        return menuHTML;
    }

    positionMenuAtCursor(x, y) {
        const rect = this.menuContainer.getBoundingClientRect();
        const viewportWidth = window.innerWidth;
        const viewportHeight = window.innerHeight;

        // Adjust position to keep menu within viewport
        let menuX = x;
        let menuY = y;

        if (x + rect.width > viewportWidth) {
            menuX = x - rect.width;
        }

        if (y + rect.height > viewportHeight) {
            menuY = y - rect.height;
        }

        this.menuContainer.style.left = `${Math.max(0, menuX)}px`;
        this.menuContainer.style.top = `${Math.max(0, menuY)}px`;
        this.menuContainer.style.position = 'fixed';
    }

    positionMenuNearElement(element) {
        const rect = element.getBoundingClientRect();
        const menuRect = this.menuContainer.getBoundingClientRect();

        let x = rect.right + 10;
        let y = rect.top;

        // Adjust if menu would go off-screen
        if (x + menuRect.width > window.innerWidth) {
            x = rect.left - menuRect.width - 10;
        }

        if (y + menuRect.height > window.innerHeight) {
            y = window.innerHeight - menuRect.height - 10;
        }

        this.menuContainer.style.left = `${Math.max(0, x)}px`;
        this.menuContainer.style.top = `${Math.max(0, y)}px`;
        this.menuContainer.style.position = 'fixed';
    }

    setupMenuItemListeners() {
        const menuItems = this.menuContainer.querySelectorAll('.menu-item');

        menuItems.forEach(item => {
            item.addEventListener('click', () => {
                const actionKey = item.dataset.action;
                this.executeAction(actionKey);
            });

            item.addEventListener('keydown', (e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    const actionKey = item.dataset.action;
                    this.executeAction(actionKey);
                }
            });
        });
    }

    handleMenuNavigation(e) {
        const menuItems = Array.from(this.menuContainer.querySelectorAll('.menu-item'));
        const currentIndex = menuItems.indexOf(document.activeElement);

        switch (e.key) {
            case 'ArrowDown':
                e.preventDefault();
                const nextIndex = (currentIndex + 1) % menuItems.length;
                menuItems[nextIndex].focus();
                break;

            case 'ArrowUp':
                e.preventDefault();
                const prevIndex = currentIndex === 0 ? menuItems.length - 1 : currentIndex - 1;
                menuItems[prevIndex].focus();
                break;

            case 'Home':
                e.preventDefault();
                menuItems[0].focus();
                break;

            case 'End':
                e.preventDefault();
                menuItems[menuItems.length - 1].focus();
                break;

            default:
                // Check for shortcut keys
                const shortcutItem = menuItems.find(item => {
                    const shortcut = item.dataset.shortcut;
                    return shortcut && shortcut.toLowerCase() === e.key.toLowerCase();
                });

                if (shortcutItem) {
                    e.preventDefault();
                    const actionKey = shortcutItem.dataset.action;
                    this.executeAction(actionKey);
                }
                break;
        }
    }

    executeAction(actionKey) {
        const action = this.menuActions[actionKey];
        if (action && action.action) {
            action.action(this.selectedUser);
            this.hideMenu();
        }
    }

    hideMenu() {
        if (this.isVisible) {
            this.menuContainer.classList.add('hidden');
            this.isVisible = false;
            this.selectedUser = null;
            this.menuContainer.innerHTML = '';
        }
    }

    // Menu action implementations
    viewUserProfile(userId) {
        const userData = this.getUserData(userId);
        console.log('Viewing profile for:', userData.name);

        // Show user profile modal
        this.showUserProfileModal(userData);
    }

    sendDirectMessage(userId) {
        const userData = this.getUserData(userId);
        console.log('Opening DM with:', userData.name);

        // Open direct message interface
        this.openDirectMessageInterface(userId);
    }

    toggleUserMute(userId) {
        const userData = this.getUserData(userId);
        const newMuteState = !userData.isMuted;

        console.log(`${newMuteState ? 'Muting' : 'Unmuting'} user:`, userData.name);

        // Update user mute state
        this.updateUserMuteState(userId, newMuteState);
    }

    adjustUserVolume(userId) {
        const userData = this.getUserData(userId);
        console.log('Adjusting volume for:', userData.name);

        // Show volume adjustment slider
        this.showVolumeAdjustmentModal(userId);
    }

    setSpatialPosition(userId) {
        const userData = this.getUserData(userId);
        console.log('Setting 3D position for:', userData.name);

        // Open spatial positioning interface
        this.showSpatialPositioningInterface(userId);
    }

    configureAudioRouting(userId) {
        const userData = this.getUserData(userId);
        console.log('Configuring audio routing for:', userData.name);

        // Open audio routing panel
        this.showAudioRoutingPanel(userId);
    }

    showUserInfo(userId) {
        const userData = this.getUserData(userId);
        console.log('Showing info for:', userData.name);

        // Display comprehensive user information
        this.showUserInfoModal(userData);
    }

    kickUser(userId) {
        const userData = this.getUserData(userId);
        console.log('Initiating kick for:', userData.name);

        // Show confirmation dialog
        this.showKickConfirmation(userId);
    }

    banUser(userId) {
        const userData = this.getUserData(userId);
        console.log('Initiating ban for:', userData.name);

        // Show ban confirmation dialog
        this.showBanConfirmation(userId);
    }

    reportUser(userId) {
        const userData = this.getUserData(userId);
        console.log('Reporting user:', userData.name);

        // Open user report interface
        this.showUserReportModal(userId);
    }

    // Helper methods
    getUserData(userId) {
        // Get user data from the global users map or local storage
        if (window.app && window.app.users) {
            return window.app.users.get(userId);
        }

        // Fallback to DOM data
        const userElement = document.querySelector(`[data-user-id="${userId}"]`);
        if (userElement) {
            return {
                id: userId,
                name: userElement.dataset.userName || 'Unknown User',
                status: userElement.dataset.userStatus || 'online',
                avatar: userElement.dataset.userAvatar || '👤',
                isMuted: userElement.dataset.isMuted === 'true'
            };
        }

        return {
            id: userId,
            name: 'Unknown User',
            status: 'unknown',
            avatar: '👤',
            isMuted: false
        };
    }

    getUserPermissions() {
        // Get current user's permissions
        const currentUser = window.app?.currentUser;
        if (currentUser) {
            return currentUser.permissions || [];
        }
        return [];
    }

    announceMenuOpened(userName) {
        // Create announcement for screen readers
        const announcement = document.createElement('div');
        announcement.setAttribute('role', 'status');
        announcement.setAttribute('aria-live', 'polite');
        announcement.className = 'sr-only';
        announcement.textContent = `Context menu opened for ${userName}. Use arrow keys to navigate, Enter to select.`;

        document.body.appendChild(announcement);

        // Remove after announcement
        setTimeout(() => {
            document.body.removeChild(announcement);
        }, 1000);
    }

    // Placeholder modal methods (to be implemented based on existing UI patterns)
    showUserProfileModal(userData) {
        // Implementation would integrate with existing modal system
        console.log('Show user profile modal for:', userData.name);
    }

    openDirectMessageInterface(userId) {
        // Implementation would integrate with existing chat system
        console.log('Open DM interface for user:', userId);
    }

    updateUserMuteState(userId, isMuted) {
        // Implementation would integrate with existing audio system
        console.log(`User ${userId} mute state:`, isMuted);
    }

    showVolumeAdjustmentModal(userId) {
        // Implementation would show volume slider modal
        console.log('Show volume adjustment for user:', userId);
    }

    showSpatialPositioningInterface(userId) {
        // Implementation would integrate with spatial audio system
        console.log('Show spatial positioning for user:', userId);
    }

    showAudioRoutingPanel(userId) {
        // Implementation would integrate with audio routing system
        console.log('Show audio routing panel for user:', userId);
    }

    showUserInfoModal(userData) {
        // Implementation would show comprehensive user info
        console.log('Show user info modal for:', userData.name);
    }

    showKickConfirmation(userId) {
        // Implementation would show kick confirmation dialog
        console.log('Show kick confirmation for user:', userId);
    }

    showBanConfirmation(userId) {
        // Implementation would show ban confirmation dialog
        console.log('Show ban confirmation for user:', userId);
    }

    showUserReportModal(userId) {
        // Implementation would show user report form
        console.log('Show user report modal for user:', userId);
    }

    // Cleanup
    destroy() {
        this.hideMenu();
        if (this.menuContainer) {
            this.menuContainer.remove();
        }
    }
}

// Export for use in other modules
window.UserContextMenu = UserContextMenu;