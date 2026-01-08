/**
 * VoiceLink Local Documentation Search
 * Provides real-time search functionality across all documentation pages
 */

class DocumentationSearch {
    constructor() {
        this.searchInput = document.getElementById('search-input');
        this.searchResults = document.getElementById('search-results');
        this.searchIndex = [];
        this.isLoaded = false;

        // Documentation index with all pages and their content
        this.documentationPages = [
            // Getting Started
            {
                title: 'Getting Started Guide',
                url: 'getting-started.html',
                category: 'Quick Start',
                description: 'Complete guide to setting up and using VoiceLink Local for the first time',
                keywords: ['setup', 'installation', 'first time', 'beginner', 'start', 'download', 'install']
            },
            {
                title: 'Server Installation',
                url: 'server-installation.html',
                category: 'Server Setup',
                description: 'How to install and configure VoiceLink Local server on various platforms',
                keywords: ['server', 'install', 'setup', 'linux', 'windows', 'mac', 'vps', 'dedicated', 'hosting']
            },
            {
                title: 'Desktop Installation',
                url: 'desktop-installation.html',
                category: 'Installation',
                description: 'Installing VoiceLink Local desktop applications',
                keywords: ['desktop', 'app', 'install', 'download', 'portable', 'dmg', 'exe', 'appimage']
            },

            // Core Features
            {
                title: 'Voice Chat Basics',
                url: 'voice-chat.html',
                category: 'Core Features',
                description: 'Basic voice communication features and controls',
                keywords: ['voice', 'chat', 'microphone', 'speak', 'talk', 'mute', 'unmute', 'push to talk', 'ptt']
            },
            {
                title: 'Room Management',
                url: 'room-management.html',
                category: 'Core Features',
                description: 'Creating, joining, and managing chat rooms',
                keywords: ['room', 'create', 'join', 'leave', 'public', 'private', 'password', 'manage', 'host']
            },
            {
                title: 'Room Types and Timing',
                url: 'room-types.html',
                category: 'Room Management',
                description: 'Different room types: public, private, timed rooms (1 hour, 2 hour, 6 hour, 30 day, 69 day, lifetime)',
                keywords: ['room types', 'timed rooms', 'temporary', 'permanent', 'lifetime', 'expire', 'duration', '1 hour', '2 hour', '6 hour', '30 day', '69 day']
            },
            {
                title: 'Joining and Leaving Rooms',
                url: 'joining-rooms.html',
                category: 'Room Management',
                description: 'How to join rooms, leave rooms, and return later',
                keywords: ['join', 'leave', 'room id', 'password', 'reconnect', 'return', 'bookmark']
            },

            // Audio Features
            {
                title: '3D Spatial Audio',
                url: 'spatial-audio.html',
                category: 'Audio Features',
                description: 'Positioning users in 3D space for immersive voice experience',
                keywords: ['3d audio', 'spatial', 'positioning', 'immersive', 'surround', 'directional', 'location']
            },
            {
                title: 'Audio Settings',
                url: 'audio-settings.html',
                category: 'Audio Features',
                description: 'Configuring microphone, speakers, and audio quality',
                keywords: ['audio', 'settings', 'microphone', 'speakers', 'quality', 'volume', 'gain', 'echo', 'noise']
            },
            {
                title: 'Audio Ducking',
                url: 'audio-ducking.html',
                category: 'Audio Features',
                description: 'Automatic volume reduction and feedback prevention',
                keywords: ['ducking', 'volume', 'automatic', 'feedback', 'prevention', 'reduction', 'db', 'levels']
            },
            {
                title: 'Multi-Input Manager',
                url: 'multi-input.html',
                category: 'Audio Features',
                description: 'Managing multiple audio sources and inputs',
                keywords: ['multi input', 'multiple', 'sources', 'inputs', 'mixer', 'routing', 'channels']
            },
            {
                title: 'Built-in Audio Effects',
                url: 'audio-effects.html',
                category: 'Audio Features',
                description: 'Voice effects and audio processing options',
                keywords: ['effects', 'voice', 'processing', 'reverb', 'echo', 'filters', 'enhancement']
            },

            // Media & Streaming
            {
                title: 'Media Streaming Overview',
                url: 'media-streaming.html',
                category: 'Media & Streaming',
                description: 'Playing music and media in voice channels',
                keywords: ['media', 'streaming', 'music', 'audio', 'playback', 'share', 'broadcast']
            },
            {
                title: 'Jellyfin Integration',
                url: 'jellyfin-integration.html',
                category: 'Media & Streaming',
                description: 'Connecting to and using Jellyfin media servers',
                keywords: ['jellyfin', 'media server', 'library', 'connect', 'authentication', 'streaming', 'movies', 'music']
            },
            {
                title: 'Live Stream Sources',
                url: 'live-streaming.html',
                category: 'Media & Streaming',
                description: 'Icecast, Shoutcast, and internet radio streaming',
                keywords: ['live streams', 'icecast', 'shoutcast', 'radio', 'internet radio', 'broadcast', 'url']
            },
            {
                title: 'PA System Controls',
                url: 'pa-system.html',
                category: 'Media & Streaming',
                description: 'Public announcement and broadcasting features',
                keywords: ['pa system', 'public announcement', 'broadcast', 'announcement', 'all users', 'admin']
            },

            // Communication
            {
                title: 'Text Chat',
                url: 'text-chat.html',
                category: 'Communication',
                description: 'Sending messages and using chat features',
                keywords: ['text chat', 'messages', 'typing', 'send', 'chat', 'conversation']
            },
            {
                title: 'Direct Messages',
                url: 'direct-messages.html',
                category: 'Communication',
                description: 'Private messaging between users',
                keywords: ['direct message', 'dm', 'private', 'whisper', 'personal', 'one on one']
            },
            {
                title: 'TTS Announcements',
                url: 'tts-announcements.html',
                category: 'Communication',
                description: 'Text-to-speech announcements and notifications',
                keywords: ['tts', 'text to speech', 'announcements', 'notifications', 'voice', 'spoken']
            },
            {
                title: 'User Context Menus',
                url: 'context-menus.html',
                category: 'Communication',
                description: 'Right-click actions and keyboard shortcuts for user interactions',
                keywords: ['context menu', 'right click', 'user menu', 'actions', 'shortcuts', 'keyboard', 'shift m', 'applications key']
            },

            // User Management
            {
                title: 'User Profiles and Status',
                url: 'user-management.html',
                category: 'User Management',
                description: 'Managing user profiles, status, and permissions',
                keywords: ['user', 'profile', 'status', 'permissions', 'avatar', 'nickname', 'display name']
            },
            {
                title: 'User Settings',
                url: 'user-settings.html',
                category: 'User Management',
                description: 'Personal preferences and profile configuration',
                keywords: ['settings', 'preferences', 'personal', 'profile', 'configuration', 'global', 'server', 'room']
            },

            // Authentication & Security
            {
                title: 'Authentication Overview',
                url: 'authentication.html',
                category: 'Security',
                description: 'All supported authentication methods and setup',
                keywords: ['authentication', 'login', 'security', 'password', '2fa', 'two factor', 'auth']
            },
            {
                title: 'iOS 2FA Setup',
                url: 'ios-2fa.html',
                category: 'Security',
                description: 'Setting up two-factor authentication on iOS devices',
                keywords: ['ios', '2fa', 'two factor', 'authentication', 'iphone', 'ipad', 'face id', 'touch id', 'apple']
            },
            {
                title: 'Third-Party 2FA',
                url: 'third-party-2fa.html',
                category: 'Security',
                description: 'Using external 2FA apps and services',
                keywords: ['third party', '2fa', 'authenticator', 'google', 'microsoft', 'authy', 'totp', 'external']
            },
            {
                title: 'Messaging Security',
                url: 'messaging-security.html',
                category: 'Security',
                description: 'Secure messaging features and encryption',
                keywords: ['security', 'encryption', 'secure', 'messaging', 'private', 'protected', 'safe']
            },

            // Platform Specific
            {
                title: 'iOS Browser Support',
                url: 'ios-browser.html',
                category: 'Platform Support',
                description: 'Using VoiceLink Local in Safari and Chrome on iOS',
                keywords: ['ios', 'safari', 'chrome', 'iphone', 'ipad', 'browser', 'mobile', 'touch']
            },
            {
                title: 'Browser Compatibility',
                url: 'browser-support.html',
                category: 'Platform Support',
                description: 'Supported browsers and requirements',
                keywords: ['browser', 'compatibility', 'chrome', 'firefox', 'safari', 'edge', 'requirements']
            },
            {
                title: 'Server Deployment',
                url: 'server-deployment.html',
                category: 'Platform Support',
                description: 'Deploying on dedicated servers and VPS',
                keywords: ['server', 'deployment', 'vps', 'dedicated', 'hosting', 'linux', 'ubuntu', 'debian', 'centos']
            },

            // Accessibility
            {
                title: 'Accessibility Features',
                url: 'accessibility.html',
                category: 'Accessibility',
                description: 'Screen readers, keyboard navigation, and VoiceOver support',
                keywords: ['accessibility', 'screen reader', 'voiceover', 'keyboard', 'navigation', 'aria', 'disability']
            },

            // Troubleshooting
            {
                title: 'Audio Troubleshooting',
                url: 'audio-troubleshooting.html',
                category: 'Troubleshooting',
                description: 'Fixing microphone, speaker, and audio quality issues',
                keywords: ['troubleshooting', 'audio', 'microphone', 'not working', 'echo', 'quality', 'fix', 'problem']
            },
            {
                title: 'Connection Issues',
                url: 'connection-troubleshooting.html',
                category: 'Troubleshooting',
                description: 'Resolving network and connection problems',
                keywords: ['connection', 'network', 'troubleshooting', 'disconnect', 'cannot connect', 'lag', 'latency']
            },
            {
                title: 'Performance Issues',
                url: 'performance-troubleshooting.html',
                category: 'Troubleshooting',
                description: 'Fixing lag, high CPU usage, and memory problems',
                keywords: ['performance', 'lag', 'cpu', 'memory', 'slow', 'freezing', 'optimization']
            },
            {
                title: 'iOS Specific Issues',
                url: 'ios-troubleshooting.html',
                category: 'Troubleshooting',
                description: 'Troubleshooting Safari and Chrome browser problems on iOS',
                keywords: ['ios', 'troubleshooting', 'safari', 'chrome', 'iphone', 'ipad', 'browser', 'mobile']
            },

            // FAQ and Support
            {
                title: 'Frequently Asked Questions',
                url: 'faq.html',
                category: 'Support',
                description: 'Common questions and answers about VoiceLink Local',
                keywords: ['faq', 'questions', 'answers', 'common', 'help', 'frequently asked']
            },
            {
                title: 'Contact Support',
                url: 'contact.html',
                category: 'Support',
                description: 'Getting help and contacting support',
                keywords: ['contact', 'support', 'help', 'email', 'bug report', 'assistance']
            }
        ];

        this.init();
    }

    init() {
        if (this.searchInput) {
            this.setupSearch();
        }
        this.buildSearchIndex();
    }

    setupSearch() {
        // Real-time search as user types
        this.searchInput.addEventListener('input', (e) => {
            const query = e.target.value.trim();
            if (query.length >= 2) {
                this.performSearch(query);
            } else {
                this.clearResults();
            }
        });

        // Handle keyboard navigation
        this.searchInput.addEventListener('keydown', (e) => {
            if (e.key === 'ArrowDown') {
                e.preventDefault();
                this.navigateResults('down');
            } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                this.navigateResults('up');
            } else if (e.key === 'Enter') {
                e.preventDefault();
                this.selectResult();
            } else if (e.key === 'Escape') {
                this.clearResults();
                this.searchInput.blur();
            }
        });

        // Clear results when clicking outside
        document.addEventListener('click', (e) => {
            if (!e.target.closest('.search-container')) {
                this.clearResults();
            }
        });
    }

    buildSearchIndex() {
        // Create searchable index from documentation pages
        this.searchIndex = this.documentationPages.map(page => {
            const searchableText = [
                page.title,
                page.description,
                page.category,
                ...page.keywords
            ].join(' ').toLowerCase();

            return {
                ...page,
                searchableText
            };
        });

        this.isLoaded = true;
    }

    performSearch(query) {
        if (!this.isLoaded) {
            return;
        }

        const queryLower = query.toLowerCase();
        const queryWords = queryLower.split(/\s+/).filter(word => word.length > 1);

        // Score each page based on relevance
        const results = this.searchIndex.map(page => {
            let score = 0;

            // Exact title match gets highest score
            if (page.title.toLowerCase().includes(queryLower)) {
                score += 100;
            }

            // Exact keyword match
            for (const keyword of page.keywords) {
                if (keyword.toLowerCase() === queryLower) {
                    score += 80;
                } else if (keyword.toLowerCase().includes(queryLower)) {
                    score += 60;
                }
            }

            // Partial matches in description
            if (page.description.toLowerCase().includes(queryLower)) {
                score += 50;
            }

            // Word-by-word scoring
            for (const word of queryWords) {
                if (page.searchableText.includes(word)) {
                    score += 20;
                }
            }

            // Category match
            if (page.category.toLowerCase().includes(queryLower)) {
                score += 30;
            }

            return { ...page, score };
        })
        .filter(page => page.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, 8); // Limit to top 8 results

        this.displayResults(results, query);
    }

    displayResults(results, query) {
        if (results.length === 0) {
            this.searchResults.innerHTML = `
                <div class="search-result">
                    <h4>No results found</h4>
                    <p>No documentation found for "${query}". Try different keywords or check our <a href="faq.html">FAQ</a>.</p>
                </div>
            `;
            return;
        }

        const resultsHTML = results.map((result, index) => {
            const highlightedTitle = this.highlightMatch(result.title, query);
            const highlightedDescription = this.highlightMatch(result.description, query);

            return `
                <div class="search-result" data-index="${index}" data-url="${result.url}">
                    <a href="${result.url}">
                        <h4>${highlightedTitle}</h4>
                        <p><span class="category">${result.category}</span> - ${highlightedDescription}</p>
                    </a>
                </div>
            `;
        }).join('');

        this.searchResults.innerHTML = resultsHTML;

        // Add click handlers
        this.searchResults.querySelectorAll('.search-result').forEach(result => {
            result.addEventListener('click', (e) => {
                if (!e.target.closest('a')) {
                    const url = result.dataset.url;
                    window.location.href = url;
                }
            });
        });
    }

    highlightMatch(text, query) {
        if (!query) return text;

        const queryWords = query.split(/\s+/).filter(word => word.length > 1);
        let highlightedText = text;

        for (const word of queryWords) {
            const regex = new RegExp(`(${this.escapeRegex(word)})`, 'gi');
            highlightedText = highlightedText.replace(regex, '<mark>$1</mark>');
        }

        return highlightedText;
    }

    escapeRegex(string) {
        return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    navigateResults(direction) {
        const results = this.searchResults.querySelectorAll('.search-result');
        if (results.length === 0) return;

        const currentSelected = this.searchResults.querySelector('.search-result.selected');
        let newIndex = 0;

        if (currentSelected) {
            const currentIndex = parseInt(currentSelected.dataset.index);
            currentSelected.classList.remove('selected');

            if (direction === 'down') {
                newIndex = (currentIndex + 1) % results.length;
            } else {
                newIndex = currentIndex === 0 ? results.length - 1 : currentIndex - 1;
            }
        }

        const newSelected = results[newIndex];
        newSelected.classList.add('selected');
        newSelected.scrollIntoView({ block: 'nearest' });
    }

    selectResult() {
        const selected = this.searchResults.querySelector('.search-result.selected');
        if (selected) {
            const url = selected.dataset.url;
            window.location.href = url;
        } else {
            // If no result is selected, select the first one
            const firstResult = this.searchResults.querySelector('.search-result');
            if (firstResult) {
                const url = firstResult.dataset.url;
                window.location.href = url;
            }
        }
    }

    clearResults() {
        this.searchResults.innerHTML = '';
    }

    // Public method to search for specific terms (can be called from other pages)
    searchFor(query) {
        if (this.searchInput) {
            this.searchInput.value = query;
            this.performSearch(query);
            this.searchInput.focus();
        }
    }
}

// Initialize search when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.docsSearch = new DocumentationSearch();
});

// Export for use in other scripts
window.DocumentationSearch = DocumentationSearch;