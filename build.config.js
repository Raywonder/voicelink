/**
 * VoiceLink Local Build Configuration
 * Handles development and production builds
 */

const path = require('path');
const fs = require('fs');

const buildConfig = {
    // Development configuration
    development: {
        mode: 'development',
        target: 'electron-main',
        devtool: 'inline-source-map',

        // Source directories
        srcDir: path.resolve(__dirname, 'client'),
        serverDir: path.resolve(__dirname, 'server'),

        // Output directories
        buildDir: path.resolve(__dirname, 'build/dev'),
        distDir: path.resolve(__dirname, 'dist/dev'),

        // Electron configuration
        electron: {
            main: 'src/main.js',
            preload: 'client/js/preload.js',
            window: {
                width: 1400,
                height: 900,
                webPreferences: {
                    nodeIntegration: false,
                    contextIsolation: true,
                    enableRemoteModule: false,
                    sandbox: false
                }
            }
        },

        // Server configuration
        server: {
            port: 3001,
            host: 'localhost',
            cors: {
                origin: '*',
                methods: ['GET', 'POST', 'PUT', 'DELETE'],
                allowedHeaders: ['Content-Type', 'Authorization']
            }
        },

        // Audio configuration
        audio: {
            sampleRate: 48000,
            bufferSize: 256,
            channels: 64,
            enableSpatialAudio: true,
            enableVSTStreaming: true
        },

        // Security configuration
        security: {
            encryptionLevel: 'medium',
            requireTwoFactor: false,
            enableKeychain: true,
            enableBiometric: true
        }
    },

    // Production configuration
    production: {
        mode: 'production',
        target: 'electron-main',
        devtool: 'source-map',

        // Source directories
        srcDir: path.resolve(__dirname, 'client'),
        serverDir: path.resolve(__dirname, 'server'),

        // Output directories
        buildDir: path.resolve(__dirname, 'build/prod'),
        distDir: path.resolve(__dirname, 'dist/prod'),

        // Electron configuration
        electron: {
            main: 'src/main.js',
            preload: 'client/js/preload.js',
            window: {
                width: 1400,
                height: 900,
                webPreferences: {
                    nodeIntegration: false,
                    contextIsolation: true,
                    enableRemoteModule: false,
                    sandbox: true
                }
            }
        },

        // Server configuration
        server: {
            port: 3001,
            host: '0.0.0.0',
            cors: {
                origin: false, // Disable CORS in production
                credentials: true
            }
        },

        // Audio configuration
        audio: {
            sampleRate: 48000,
            bufferSize: 128,
            channels: 64,
            enableSpatialAudio: true,
            enableVSTStreaming: true
        },

        // Security configuration
        security: {
            encryptionLevel: 'high',
            requireTwoFactor: true,
            enableKeychain: true,
            enableBiometric: true
        }
    },

    // Testing configuration
    testing: {
        mode: 'test',
        target: 'electron-renderer',

        // Test directories
        testDir: path.resolve(__dirname, 'tests'),
        unitTestDir: path.resolve(__dirname, 'tests/unit'),
        integrationTestDir: path.resolve(__dirname, 'tests/integration'),
        e2eTestDir: path.resolve(__dirname, 'tests/e2e'),

        // Coverage configuration
        coverage: {
            enabled: true,
            threshold: {
                global: {
                    branches: 80,
                    functions: 80,
                    lines: 80,
                    statements: 80
                }
            }
        },

        // Test audio configuration
        audio: {
            mockDevices: true,
            enableRealAudio: false,
            testSampleRate: 44100,
            testBufferSize: 512
        }
    }
};

// Build utilities
const buildUtils = {
    // Create build directories
    createDirectories() {
        const configs = [buildConfig.development, buildConfig.production];

        configs.forEach(config => {
            if (!fs.existsSync(config.buildDir)) {
                fs.mkdirSync(config.buildDir, { recursive: true });
            }
            if (!fs.existsSync(config.distDir)) {
                fs.mkdirSync(config.distDir, { recursive: true });
            }
        });

        // Create test directories
        if (!fs.existsSync(buildConfig.testing.testDir)) {
            fs.mkdirSync(buildConfig.testing.testDir, { recursive: true });
        }
    },

    // Copy static assets
    copyAssets(env = 'development') {
        const config = buildConfig[env];
        const assetsDir = path.join(config.srcDir, 'assets');
        const targetDir = path.join(config.buildDir, 'assets');

        if (fs.existsSync(assetsDir)) {
            this.copyRecursive(assetsDir, targetDir);
        }
    },

    // Copy files recursively
    copyRecursive(src, dest) {
        if (!fs.existsSync(dest)) {
            fs.mkdirSync(dest, { recursive: true });
        }

        const files = fs.readdirSync(src);

        files.forEach(file => {
            const srcPath = path.join(src, file);
            const destPath = path.join(dest, file);

            if (fs.statSync(srcPath).isDirectory()) {
                this.copyRecursive(srcPath, destPath);
            } else {
                fs.copyFileSync(srcPath, destPath);
            }
        });
    },

    // Minify JavaScript files
    minifyJS(filePath) {
        // In a real implementation, you would use a minifier like Terser
        const content = fs.readFileSync(filePath, 'utf8');

        // Simple minification (remove comments and extra whitespace)
        const minified = content
            .replace(/\/\*[\s\S]*?\*\//g, '') // Remove block comments
            .replace(/\/\/.*$/gm, '') // Remove line comments
            .replace(/\s+/g, ' ') // Replace multiple whitespace with single space
            .trim();

        return minified;
    },

    // Generate build manifest
    generateManifest(env = 'development') {
        const config = buildConfig[env];
        const manifest = {
            version: require('./package.json').version,
            environment: env,
            buildTime: new Date().toISOString(),
            config: {
                audio: config.audio,
                security: config.security,
                server: config.server
            }
        };

        const manifestPath = path.join(config.buildDir, 'manifest.json');
        fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));

        return manifest;
    }
};

// Build tasks
const buildTasks = {
    // Development build
    async development() {
        console.log('Building for development...');

        buildUtils.createDirectories();
        buildUtils.copyAssets('development');

        const manifest = buildUtils.generateManifest('development');
        console.log('Development build completed:', manifest.buildTime);

        return manifest;
    },

    // Production build
    async production() {
        console.log('Building for production...');

        buildUtils.createDirectories();
        buildUtils.copyAssets('production');

        // Minify JavaScript files in production
        const jsFiles = this.findJSFiles(buildConfig.production.srcDir);
        jsFiles.forEach(file => {
            const minified = buildUtils.minifyJS(file);
            const outputPath = file.replace(buildConfig.production.srcDir, buildConfig.production.buildDir);

            // Ensure output directory exists
            const outputDir = path.dirname(outputPath);
            if (!fs.existsSync(outputDir)) {
                fs.mkdirSync(outputDir, { recursive: true });
            }

            fs.writeFileSync(outputPath, minified);
        });

        const manifest = buildUtils.generateManifest('production');
        console.log('Production build completed:', manifest.buildTime);

        return manifest;
    },

    // Find all JavaScript files
    findJSFiles(dir) {
        const files = [];

        const scanDirectory = (currentDir) => {
            const items = fs.readdirSync(currentDir);

            items.forEach(item => {
                const fullPath = path.join(currentDir, item);
                const stat = fs.statSync(fullPath);

                if (stat.isDirectory()) {
                    scanDirectory(fullPath);
                } else if (path.extname(item) === '.js') {
                    files.push(fullPath);
                }
            });
        };

        scanDirectory(dir);
        return files;
    },

    // Clean build directories
    clean() {
        console.log('Cleaning build directories...');

        const buildDirs = [
            buildConfig.development.buildDir,
            buildConfig.development.distDir,
            buildConfig.production.buildDir,
            buildConfig.production.distDir
        ];

        buildDirs.forEach(dir => {
            if (fs.existsSync(dir)) {
                fs.rmSync(dir, { recursive: true, force: true });
            }
        });

        console.log('Clean completed');
    }
};

module.exports = {
    buildConfig,
    buildUtils,
    buildTasks
};