/**
 * Build configuration for VoiceLink
 * Handles development and production build modes
 */

const fs = require('fs');
const path = require('path');

// Get configuration from command line
const args = process.argv.slice(2);
const isProduction = args.includes('--production');

module.exports = (env = {production}) => {
    // Production configuration
    if (isProduction) {
        return {
            distPath: '../releases',
            files: [
                'src/**/*',
                'server/**/*', 
                'client/**/*',
                'assets/**/*',
                'build.config.js',
                'README.md',
                'node_modules/**/*'
            ],
            extraMetadata: {
                main: {
                    'electron-version': '38.4.0',
                    'build-date': new Date().toISOString()
                }
            }
        };
    }
    
    // Development configuration
    return {
        distPath: '../releases',
        files: [
            'src/**/*',
            'server/**/*',
            'client/**/*',
            'assets/**/*',
            'build.config.js',
            'README.md'
        ],
        extraMetadata: {
            main: {
                'electron-version': '38.4.0',
                'build-date': new Date().toISOString(),
                'mode': 'development'
            }
        }
    };
};