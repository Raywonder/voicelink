#!/usr/bin/env node
/**
 * VoiceLink Documentation Generator
 * Uses Ollama to generate documentation for all features
 * Creates HTML pages for public (guest) and authenticated sections
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

// Configuration
const OLLAMA_HOST = process.env.OLLAMA_HOST || 'http://localhost:11434';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL || 'llama3.2';
const DOCS_DIR = path.join(__dirname, '../../docs');
const PUBLIC_DOCS_DIR = path.join(DOCS_DIR, 'public');
const AUTH_DOCS_DIR = path.join(DOCS_DIR, 'authenticated');

// Feature categories for documentation
const FEATURE_CATEGORIES = {
    public: [
        { id: 'getting-started', title: 'Getting Started', icon: 'rocket' },
        { id: 'joining-rooms', title: 'Joining Rooms', icon: 'door-open' },
        { id: 'audio-settings', title: 'Audio Settings', icon: 'volume-up' },
        { id: 'spatial-audio', title: '3D Spatial Audio', icon: 'headphones' },
        { id: 'federation', title: 'Federated Rooms', icon: 'network' },
        { id: 'mobile-ios', title: 'iOS & Mobile Usage', icon: 'mobile' }
    ],
    authenticated: [
        { id: 'admin-panel', title: 'Admin Panel', icon: 'cog' },
        { id: 'room-management', title: 'Room Management', icon: 'users' },
        { id: 'jellyfin-setup', title: 'Jellyfin Integration', icon: 'music' },
        { id: 'payment-config', title: 'Payment Configuration', icon: 'credit-card' },
        { id: 'ecripto-wallet', title: 'Ecripto Wallet', icon: 'wallet' },
        { id: 'federation-admin', title: 'Federation Settings', icon: 'server' },
        { id: 'node-operator', title: 'Node Operator Setup', icon: 'node' },
        { id: 'backup-restore', title: 'Backup & Restore', icon: 'database' },
        { id: 'api-reference', title: 'API Reference', icon: 'code' }
    ]
};

// Documentation templates
const DOC_PROMPTS = {
    'getting-started': `Write a getting started guide for VoiceLink voice chat application. Cover:
- What VoiceLink is (decentralized voice chat)
- How to access via web browser
- Creating a username
- Joining your first room
- Basic controls (mute, volume)
Keep it friendly and beginner-focused. Format as HTML content (no full page, just body content).`,

    'joining-rooms': `Write documentation for joining rooms in VoiceLink. Cover:
- Browsing available rooms
- Federated rooms from other servers
- Room capacity and user counts
- Private vs public rooms
- Quick join shortcuts
Format as HTML content.`,

    'audio-settings': `Document the audio settings in VoiceLink. Cover:
- Microphone selection
- Speaker/output selection
- Volume controls
- Echo cancellation
- Noise suppression
- Push-to-talk setup
Format as HTML content.`,

    'spatial-audio': `Explain 3D spatial audio in VoiceLink. Cover:
- What spatial audio is (HRTF-based 3D positioning)
- How voices are positioned in virtual space
- Room acoustics simulation
- Headphone recommendations
- iOS/Safari specific considerations
Format as HTML content.`,

    'admin-panel': `Document the VoiceLink admin panel. Cover:
- Accessing admin settings
- Server configuration options
- User management
- Room moderation tools
- Viewing server statistics
Format as HTML content.`,

    'jellyfin-setup': `Document Jellyfin media server integration. Cover:
- Enabling the Jellyfin bot
- Connecting to Jellyfin server
- Configuring API keys
- Setting up ambient music
- Per-room music settings
- Suspending the bot (24h, week, month)
- Complete removal with backup
Format as HTML content.`,

    'payment-config': `Document payment configuration for VoiceLink admins. Cover:
- Enabling payment collection
- Configuring Stripe
- Setting up PayPal
- Cryptocurrency payments (Ecripto)
- Manual payment approval
- Room access tiers (day, week, month passes)
- Donation settings
Format as HTML content.`,

    'ecripto-wallet': `Document Ecripto wallet integration. Cover:
- What Ecripto is
- Connecting your wallet
- Wallet permissions and data access
- Minting rooms
- Access passes and tiers
- Disconnecting (options for minted rooms)
Format as HTML content.`,

    'federation-admin': `Document federation settings for server admins. Cover:
- Enabling federation
- Federation modes (standalone, hub, spoke, mesh)
- Room approval queue
- Federation tiers (none, standard, promoted)
- Hold time before auto-approval
- Trusted servers list
Format as HTML content.`,

    'node-operator': `Document node operator setup for Ecripto. Cover:
- What node operators are
- Federation priority benefits
- Registering as a node operator
- Node types (validator, archive, relay)
- Priority scoring system
- Trusted node management
Format as HTML content.`,

    'backup-restore': `Document backup and restore procedures. Cover:
- Automatic backups
- Manual backup creation
- Backup locations and sizes
- Restoring from backup
- Jellyfin-specific backups
- Room data persistence
Format as HTML content.`,

    'mobile-ios': `Document iOS and mobile usage. Cover:
- Browser compatibility (Safari, Chrome)
- iOS audio unlock requirement
- Headphones recommendation
- Echo prevention
- Stereo and 3D audio on mobile
- Touch controls
Format as HTML content.`,

    'api-reference': `Create an API reference for VoiceLink. List main endpoints:
- /api/rooms - Room management
- /api/federation - Federation control
- /api/jellyfin - Jellyfin management
- /api/payments - Payment configuration
- /api/ecripto - Wallet integration
- /api/config - Server configuration
Include brief descriptions and example requests. Format as HTML.`
};

class DocsGenerator {
    constructor() {
        this.generatedDocs = new Map();
    }

    async init() {
        // Create docs directories
        [DOCS_DIR, PUBLIC_DOCS_DIR, AUTH_DOCS_DIR].forEach(dir => {
            if (!fs.existsSync(dir)) {
                fs.mkdirSync(dir, { recursive: true });
            }
        });

        console.log('Documentation directories created');
    }

    async callOllama(prompt) {
        return new Promise((resolve, reject) => {
            const url = new URL(`${OLLAMA_HOST}/api/generate`);
            const client = url.protocol === 'https:' ? https : http;

            const data = JSON.stringify({
                model: OLLAMA_MODEL,
                prompt: prompt,
                stream: false,
                options: {
                    temperature: 0.7,
                    top_p: 0.9
                }
            });

            const options = {
                hostname: url.hostname,
                port: url.port || (url.protocol === 'https:' ? 443 : 11434),
                path: '/api/generate',
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(data)
                }
            };

            const req = client.request(options, (res) => {
                let body = '';
                res.on('data', chunk => body += chunk);
                res.on('end', () => {
                    try {
                        const result = JSON.parse(body);
                        resolve(result.response || '');
                    } catch (e) {
                        reject(new Error('Failed to parse Ollama response'));
                    }
                });
            });

            req.on('error', reject);
            req.setTimeout(120000, () => {
                req.destroy();
                reject(new Error('Ollama request timeout'));
            });

            req.write(data);
            req.end();
        });
    }

    wrapInHTMLPage(title, content, isAuthenticated = false) {
        const navLinks = isAuthenticated
            ? FEATURE_CATEGORIES.authenticated.map(f =>
                `<a href="${f.id}.html" class="nav-link">${f.title}</a>`).join('\n')
            : FEATURE_CATEGORIES.public.map(f =>
                `<a href="${f.id}.html" class="nav-link">${f.title}</a>`).join('\n');

        return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${title} - VoiceLink Documentation</title>
    <style>
        :root {
            --primary: #6364FF;
            --secondary: #563ACC;
            --bg: #1a1a2e;
            --surface: #16213e;
            --text: #eee;
            --text-secondary: #aaa;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg);
            color: var(--text);
            line-height: 1.6;
        }
        .container {
            display: flex;
            min-height: 100vh;
        }
        .sidebar {
            width: 280px;
            background: var(--surface);
            padding: 20px;
            border-right: 1px solid rgba(255,255,255,0.1);
            position: fixed;
            height: 100vh;
            overflow-y: auto;
        }
        .logo {
            font-size: 24px;
            font-weight: bold;
            color: var(--primary);
            margin-bottom: 30px;
        }
        .nav-link {
            display: block;
            padding: 10px 15px;
            color: var(--text-secondary);
            text-decoration: none;
            border-radius: 8px;
            margin-bottom: 5px;
            transition: all 0.2s;
        }
        .nav-link:hover, .nav-link.active {
            background: rgba(99, 100, 255, 0.2);
            color: var(--primary);
        }
        .content {
            flex: 1;
            margin-left: 280px;
            padding: 40px;
            max-width: 900px;
        }
        h1 { color: var(--primary); margin-bottom: 20px; }
        h2 { color: var(--text); margin: 30px 0 15px; border-bottom: 1px solid rgba(255,255,255,0.1); padding-bottom: 10px; }
        h3 { color: var(--text-secondary); margin: 20px 0 10px; }
        p { margin-bottom: 15px; }
        code {
            background: rgba(99, 100, 255, 0.2);
            padding: 2px 8px;
            border-radius: 4px;
            font-family: 'SF Mono', Monaco, monospace;
        }
        pre {
            background: var(--surface);
            padding: 20px;
            border-radius: 8px;
            overflow-x: auto;
            margin: 15px 0;
        }
        ul, ol { margin: 15px 0 15px 30px; }
        li { margin-bottom: 8px; }
        .auth-badge {
            display: ${isAuthenticated ? 'inline-block' : 'none'};
            background: var(--secondary);
            color: white;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            margin-left: 10px;
        }
        @media (max-width: 768px) {
            .sidebar { display: none; }
            .content { margin-left: 0; padding: 20px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <nav class="sidebar">
            <div class="logo">VoiceLink Docs</div>
            ${navLinks}
            ${!isAuthenticated ? '<hr style="margin: 20px 0; border-color: rgba(255,255,255,0.1)"><a href="../authenticated/admin-panel.html" class="nav-link">Admin Documentation</a>' : '<hr style="margin: 20px 0; border-color: rgba(255,255,255,0.1)"><a href="../public/getting-started.html" class="nav-link">Public Docs</a>'}
        </nav>
        <main class="content">
            <h1>${title}<span class="auth-badge">Admin</span></h1>
            ${content}
        </main>
    </div>
</body>
</html>`;
    }

    async generateDoc(docId, prompt, outputDir) {
        console.log(`Generating: ${docId}...`);

        try {
            const content = await this.callOllama(prompt);

            // Clean up the content (remove markdown artifacts if present)
            let cleanContent = content
                .replace(/```html/g, '')
                .replace(/```/g, '')
                .trim();

            // Wrap in full HTML page
            const title = [...FEATURE_CATEGORIES.public, ...FEATURE_CATEGORIES.authenticated]
                .find(f => f.id === docId)?.title || docId;

            const isAuth = outputDir.includes('authenticated');
            const fullPage = this.wrapInHTMLPage(title, cleanContent, isAuth);

            // Save the file
            const outputPath = path.join(outputDir, `${docId}.html`);
            fs.writeFileSync(outputPath, fullPage, 'utf8');

            this.generatedDocs.set(docId, outputPath);
            console.log(`  Created: ${outputPath}`);

            return outputPath;
        } catch (error) {
            console.error(`  Failed to generate ${docId}:`, error.message);
            return null;
        }
    }

    async generateAllDocs() {
        console.log('Starting documentation generation with Ollama...\n');

        // Generate public docs
        console.log('=== Public Documentation ===');
        for (const feature of FEATURE_CATEGORIES.public) {
            const prompt = DOC_PROMPTS[feature.id] || `Write documentation for ${feature.title} in VoiceLink voice chat.`;
            await this.generateDoc(feature.id, prompt, PUBLIC_DOCS_DIR);
        }

        // Generate authenticated docs
        console.log('\n=== Admin Documentation ===');
        for (const feature of FEATURE_CATEGORIES.authenticated) {
            const prompt = DOC_PROMPTS[feature.id] || `Write admin documentation for ${feature.title} in VoiceLink voice chat.`;
            await this.generateDoc(feature.id, prompt, AUTH_DOCS_DIR);
        }

        // Generate index pages
        await this.generateIndexPages();

        console.log('\n=== Documentation Generation Complete ===');
        console.log(`Generated ${this.generatedDocs.size} documentation pages`);
        console.log(`Public docs: ${PUBLIC_DOCS_DIR}`);
        console.log(`Admin docs: ${AUTH_DOCS_DIR}`);
    }

    async generateIndexPages() {
        // Public index
        const publicIndex = this.wrapInHTMLPage('Documentation', `
            <p>Welcome to VoiceLink documentation. Choose a topic to get started.</p>
            <div style="display: grid; gap: 15px; margin-top: 30px;">
                ${FEATURE_CATEGORIES.public.map(f => `
                    <a href="${f.id}.html" style="background: var(--surface); padding: 20px; border-radius: 12px; text-decoration: none; color: inherit; display: block;">
                        <h3 style="color: var(--primary); margin-bottom: 5px;">${f.title}</h3>
                        <p style="color: var(--text-secondary); margin: 0; font-size: 14px;">Learn about ${f.title.toLowerCase()}</p>
                    </a>
                `).join('')}
            </div>
        `, false);
        fs.writeFileSync(path.join(PUBLIC_DOCS_DIR, 'index.html'), publicIndex, 'utf8');

        // Admin index
        const authIndex = this.wrapInHTMLPage('Admin Documentation', `
            <p>Administrator documentation for VoiceLink server management.</p>
            <div style="display: grid; gap: 15px; margin-top: 30px;">
                ${FEATURE_CATEGORIES.authenticated.map(f => `
                    <a href="${f.id}.html" style="background: var(--surface); padding: 20px; border-radius: 12px; text-decoration: none; color: inherit; display: block;">
                        <h3 style="color: var(--primary); margin-bottom: 5px;">${f.title}</h3>
                        <p style="color: var(--text-secondary); margin: 0; font-size: 14px;">Configure ${f.title.toLowerCase()}</p>
                    </a>
                `).join('')}
            </div>
        `, true);
        fs.writeFileSync(path.join(AUTH_DOCS_DIR, 'index.html'), authIndex, 'utf8');
    }
}

// Run generator
async function main() {
    const generator = new DocsGenerator();
    await generator.init();

    // Check if Ollama is available
    try {
        const testPrompt = 'Say "OK" if you can read this.';
        const response = await generator.callOllama(testPrompt);
        console.log('Ollama connection successful\n');
    } catch (error) {
        console.error('Error: Cannot connect to Ollama at', OLLAMA_HOST);
        console.error('Make sure Ollama is running: ollama serve');
        console.error('Or set OLLAMA_HOST environment variable');
        process.exit(1);
    }

    await generator.generateAllDocs();
}

main().catch(console.error);
