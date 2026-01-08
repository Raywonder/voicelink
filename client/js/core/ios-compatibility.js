/**
 * iOS Browser Compatibility Layer
 * Handles iOS-specific browser behaviors and limitations
 */

class iOSCompatibility {
    constructor() {
        this.isIOS = this.detectIOS();
        this.isSafari = this.detectSafari();
        this.isChrome = this.detectChrome();
        this.audioContext = null;
        this.unlocked = false;
        this.touchEvents = [];

        this.init();
    }

    init() {
        if (this.isIOS) {
            console.log('iOS device detected - applying compatibility fixes');
            this.applyIOSFixes();
            this.setupAudioUnlocking();
            this.setupTouchOptimizations();
            this.setupViewportHandling();
            this.setupKeyboardHandling();
        }
    }

    detectIOS() {
        return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
               (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    }

    detectSafari() {
        return /^((?!chrome|android).)*safari/i.test(navigator.userAgent);
    }

    detectChrome() {
        return /Chrome/.test(navigator.userAgent) && /Google Inc/.test(navigator.vendor);
    }

    applyIOSFixes() {
        // Prevent zoom on double tap
        this.preventDoubleTabZoom();

        // Fix viewport scrolling
        this.fixViewportScrolling();

        // Handle safe areas
        this.handleSafeAreas();

        // Fix input focus issues
        this.fixInputFocusIssues();

        // Handle orientation changes
        this.handleOrientationChanges();
    }

    preventDoubleTabZoom() {
        let lastTouchEnd = 0;
        document.addEventListener('touchend', (event) => {
            const now = (new Date()).getTime();
            if (now - lastTouchEnd <= 300) {
                event.preventDefault();
            }
            lastTouchEnd = now;
        }, false);
    }

    fixViewportScrolling() {
        // Prevent body scrolling when touching certain elements
        const preventScrollElements = [
            '.spatial-canvas',
            '.audio-visualization',
            '.volume-slider',
            '.context-menu'
        ];

        preventScrollElements.forEach(selector => {
            document.addEventListener('touchmove', (e) => {
                if (e.target.closest(selector)) {
                    e.preventDefault();
                }
            }, { passive: false });
        });

        // Fix rubber band scrolling
        document.body.addEventListener('touchmove', (e) => {
            if (e.target === document.body) {
                e.preventDefault();
            }
        }, { passive: false });
    }

    handleSafeAreas() {
        // Add CSS custom properties for safe areas
        const style = document.createElement('style');
        style.textContent = `
            :root {
                --safe-area-inset-top: env(safe-area-inset-top);
                --safe-area-inset-right: env(safe-area-inset-right);
                --safe-area-inset-bottom: env(safe-area-inset-bottom);
                --safe-area-inset-left: env(safe-area-inset-left);
            }

            /* Apply safe area padding to main containers */
            #app {
                padding-top: var(--safe-area-inset-top);
                padding-left: var(--safe-area-inset-left);
                padding-right: var(--safe-area-inset-right);
                padding-bottom: var(--safe-area-inset-bottom);
            }

            /* Adjust for notch in voice chat screen */
            #voice-chat-screen .chat-header {
                padding-top: calc(1rem + var(--safe-area-inset-top));
            }

            /* Adjust bottom controls for home indicator */
            .audio-controls {
                padding-bottom: calc(1rem + var(--safe-area-inset-bottom));
            }

            /* Context menu adjustments */
            .context-menu {
                max-height: calc(100vh - var(--safe-area-inset-top) - var(--safe-area-inset-bottom) - 2rem);
            }
        `;
        document.head.appendChild(style);
    }

    fixInputFocusIssues() {
        // Scroll to input when focused to prevent keyboard overlap
        const inputs = document.querySelectorAll('input, textarea, select');

        inputs.forEach(input => {
            input.addEventListener('focus', () => {
                setTimeout(() => {
                    input.scrollIntoView({
                        behavior: 'smooth',
                        block: 'center'
                    });
                }, 300); // Wait for keyboard animation
            });
        });

        // Handle viewport resize for keyboard
        let initialViewportHeight = window.innerHeight;

        window.addEventListener('resize', () => {
            const currentHeight = window.innerHeight;
            const heightDiff = initialViewportHeight - currentHeight;

            if (heightDiff > 150) { // Keyboard is likely visible
                document.body.classList.add('keyboard-visible');
            } else {
                document.body.classList.remove('keyboard-visible');
            }
        });

        // Add CSS for keyboard visibility
        const keyboardStyle = document.createElement('style');
        keyboardStyle.textContent = `
            .keyboard-visible {
                height: 100vh;
                overflow: hidden;
            }

            .keyboard-visible .voice-chat-screen {
                height: 100vh;
                overflow-y: auto;
            }
        `;
        document.head.appendChild(keyboardStyle);
    }

    handleOrientationChanges() {
        window.addEventListener('orientationchange', () => {
            // Delay to allow orientation change to complete
            setTimeout(() => {
                // Trigger resize event to recalculate layouts
                window.dispatchEvent(new Event('resize'));

                // Re-position any open modals or context menus
                if (window.userContextMenu && window.userContextMenu.isVisible) {
                    window.userContextMenu.hideMenu();
                }

                // Refresh spatial audio canvas if visible
                if (window.spatialAudio) {
                    window.spatialAudio.handleResize();
                }
            }, 500);
        });
    }

    setupAudioUnlocking() {
        // iOS requires user interaction to play audio
        this.createAudioUnlockOverlay();
        this.setupAudioContextUnlocking();
    }

    createAudioUnlockOverlay() {
        if (this.unlocked) return;

        const overlay = document.createElement('div');
        overlay.id = 'ios-audio-unlock';
        overlay.className = 'ios-unlock-overlay';
        overlay.innerHTML = `
            <div class="unlock-content">
                <div class="unlock-icon">🎵</div>
                <h2>Enable Audio</h2>
                <p>Tap to enable audio and microphone access for voice chat.</p>
                <button class="unlock-button">Enable Audio</button>
            </div>
        `;

        // Add styles
        const style = document.createElement('style');
        style.textContent = `
            .ios-unlock-overlay {
                position: fixed;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                background: rgba(0, 0, 0, 0.9);
                z-index: 999999;
                display: flex;
                align-items: center;
                justify-content: center;
                color: white;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            }

            .unlock-content {
                text-align: center;
                padding: 2rem;
                max-width: 350px;
            }

            .unlock-icon {
                font-size: 4rem;
                margin-bottom: 1rem;
            }

            .unlock-content h2 {
                margin-bottom: 1rem;
                font-size: 1.5rem;
            }

            .unlock-content p {
                margin-bottom: 2rem;
                opacity: 0.8;
                line-height: 1.4;
            }

            .unlock-button {
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
                border: none;
                padding: 1rem 2rem;
                border-radius: 2rem;
                font-size: 1.1rem;
                font-weight: 600;
                cursor: pointer;
                transition: transform 0.2s ease;
            }

            .unlock-button:active {
                transform: scale(0.95);
            }
        `;
        document.head.appendChild(style);

        overlay.querySelector('.unlock-button').addEventListener('click', () => {
            this.unlockAudio();
            overlay.remove();
        });

        document.body.appendChild(overlay);
    }

    setupAudioContextUnlocking() {
        // Multiple ways to unlock audio
        const unlockEvents = ['touchstart', 'touchend', 'mousedown', 'keydown'];

        const unlockAudio = () => {
            if (this.unlocked) return;

            this.unlockAudio();

            // Remove event listeners after first unlock
            unlockEvents.forEach(event => {
                document.removeEventListener(event, unlockAudio);
            });
        };

        unlockEvents.forEach(event => {
            document.addEventListener(event, unlockAudio, { once: true });
        });
    }

    async unlockAudio() {
        if (this.unlocked) return;

        try {
            // Create or resume audio context
            if (window.audioEngine && window.audioEngine.audioContext) {
                await window.audioEngine.audioContext.resume();
            } else {
                // Create minimal audio context to unlock
                const AudioContext = window.AudioContext || window.webkitAudioContext;
                this.audioContext = new AudioContext();

                // Play silent sound to unlock
                const buffer = this.audioContext.createBuffer(1, 1, 22050);
                const source = this.audioContext.createBufferSource();
                source.buffer = buffer;
                source.connect(this.audioContext.destination);
                source.start(0);
            }

            this.unlocked = true;
            console.log('iOS audio unlocked');

            // Notify the app that audio is ready
            window.dispatchEvent(new CustomEvent('audioUnlocked'));

            // Remove unlock overlay if it exists
            const overlay = document.getElementById('ios-audio-unlock');
            if (overlay) {
                overlay.remove();
            }

        } catch (error) {
            console.error('Failed to unlock iOS audio:', error);
        }
    }

    setupTouchOptimizations() {
        // Improve touch responsiveness
        this.optimizeTouchTargets();
        this.setupTouchGestures();
        this.handleTouchFeedback();
    }

    optimizeTouchTargets() {
        // Ensure minimum touch target size (44px)
        const style = document.createElement('style');
        style.textContent = `
            @media (max-width: 768px) {
                button, .btn, .control-btn, .menu-item {
                    min-height: 44px;
                    min-width: 44px;
                    padding: 0.75rem 1rem;
                }

                .user-item {
                    min-height: 44px;
                    padding: 0.75rem;
                }

                .volume-slider, input[type="range"] {
                    min-height: 44px;
                }

                /* Larger touch areas for spatial audio controls */
                .spatial-canvas .user-position {
                    min-width: 44px;
                    min-height: 44px;
                }
            }
        `;
        document.head.appendChild(style);
    }

    setupTouchGestures() {
        // Handle swipe gestures for navigation
        let startX, startY, currentX, currentY;

        document.addEventListener('touchstart', (e) => {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
        });

        document.addEventListener('touchmove', (e) => {
            if (!startX || !startY) return;

            currentX = e.touches[0].clientX;
            currentY = e.touches[0].clientY;
        });

        document.addEventListener('touchend', (e) => {
            if (!startX || !startY || !currentX || !currentY) return;

            const diffX = startX - currentX;
            const diffY = startY - currentY;

            // Swipe threshold
            if (Math.abs(diffX) > 50 || Math.abs(diffY) > 50) {
                // Handle swipe gestures
                if (Math.abs(diffX) > Math.abs(diffY)) {
                    // Horizontal swipe
                    if (diffX > 0) {
                        // Swipe left - could be used for navigation
                        this.handleSwipeLeft();
                    } else {
                        // Swipe right
                        this.handleSwipeRight();
                    }
                }
            }

            // Reset
            startX = startY = currentX = currentY = null;
        });
    }

    handleSwipeLeft() {
        // Could be used to show/hide panels
        console.log('Swipe left detected');
    }

    handleSwipeRight() {
        // Could be used to go back or show menu
        console.log('Swipe right detected');
    }

    handleTouchFeedback() {
        // Add visual feedback for touch interactions
        const style = document.createElement('style');
        style.textContent = `
            .touch-feedback {
                background-color: rgba(255, 255, 255, 0.1) !important;
            }

            button:active, .btn:active, .control-btn:active {
                transform: scale(0.95);
                transition: transform 0.1s ease;
            }
        `;
        document.head.appendChild(style);

        // Add touch feedback class on touch
        document.addEventListener('touchstart', (e) => {
            const target = e.target.closest('button, .btn, .control-btn, .menu-item');
            if (target) {
                target.classList.add('touch-feedback');
            }
        });

        document.addEventListener('touchend', (e) => {
            const target = e.target.closest('button, .btn, .control-btn, .menu-item');
            if (target) {
                setTimeout(() => {
                    target.classList.remove('touch-feedback');
                }, 150);
            }
        });
    }

    setupViewportHandling() {
        // Set viewport meta tag for iOS
        let viewport = document.querySelector('meta[name="viewport"]');
        if (!viewport) {
            viewport = document.createElement('meta');
            viewport.name = 'viewport';
            document.head.appendChild(viewport);
        }

        viewport.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover';

        // Handle status bar styling
        this.setupStatusBar();
    }

    setupStatusBar() {
        // Status bar styling for iOS
        let statusBarMeta = document.querySelector('meta[name="apple-mobile-web-app-status-bar-style"]');
        if (!statusBarMeta) {
            statusBarMeta = document.createElement('meta');
            statusBarMeta.name = 'apple-mobile-web-app-status-bar-style';
            statusBarMeta.content = 'black-translucent';
            document.head.appendChild(statusBarMeta);
        }

        // App title
        let titleMeta = document.querySelector('meta[name="apple-mobile-web-app-title"]');
        if (!titleMeta) {
            titleMeta = document.createElement('meta');
            titleMeta.name = 'apple-mobile-web-app-title';
            titleMeta.content = 'VoiceLink Local';
            document.head.appendChild(titleMeta);
        }

        // Web app capable
        let capableMeta = document.querySelector('meta[name="apple-mobile-web-app-capable"]');
        if (!capableMeta) {
            capableMeta = document.createElement('meta');
            capableMeta.name = 'apple-mobile-web-app-capable';
            capableMeta.content = 'yes';
            document.head.appendChild(capableMeta);
        }
    }

    setupKeyboardHandling() {
        // Handle virtual keyboard on iOS
        const originalHeight = window.innerHeight;

        window.addEventListener('resize', () => {
            const newHeight = window.innerHeight;
            const heightDiff = originalHeight - newHeight;

            if (heightDiff > 150) {
                // Virtual keyboard is likely showing
                document.body.classList.add('virtual-keyboard-visible');

                // Scroll active input into view
                const activeElement = document.activeElement;
                if (activeElement && (activeElement.tagName === 'INPUT' || activeElement.tagName === 'TEXTAREA')) {
                    setTimeout(() => {
                        activeElement.scrollIntoView({
                            behavior: 'smooth',
                            block: 'center'
                        });
                    }, 300);
                }
            } else {
                document.body.classList.remove('virtual-keyboard-visible');
            }
        });

        // Style adjustments for virtual keyboard
        const keyboardStyle = document.createElement('style');
        keyboardStyle.textContent = `
            .virtual-keyboard-visible {
                height: 100vh;
            }

            .virtual-keyboard-visible .voice-chat-screen {
                padding-bottom: 0;
            }

            .virtual-keyboard-visible .chat-input-container {
                position: fixed;
                bottom: 0;
                left: 0;
                right: 0;
                background: rgba(40, 44, 52, 0.95);
                backdrop-filter: blur(20px);
                padding: 1rem;
                z-index: 1000;
            }
        `;
        document.head.appendChild(keyboardStyle);
    }

    // Utility methods for other parts of the app
    isAudioUnlocked() {
        return this.unlocked;
    }

    requiresAudioUnlock() {
        return this.isIOS && !this.unlocked;
    }

    getDeviceInfo() {
        return {
            isIOS: this.isIOS,
            isSafari: this.isSafari,
            isChrome: this.isChrome,
            userAgent: navigator.userAgent,
            platform: navigator.platform,
            maxTouchPoints: navigator.maxTouchPoints
        };
    }

    // Cleanup
    destroy() {
        if (this.audioContext) {
            this.audioContext.close();
        }
    }
}

// Export for use in other modules
window.iOSCompatibility = iOSCompatibility;