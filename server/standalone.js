#!/usr/bin/env node
/**
 * VoiceLink Local - Standalone Server
 * Run without Electron for use with native Swift client
 */

// Set port before requiring the server
process.env.PORT = process.env.PORT || 4004;

console.log('Starting VoiceLink Local Server (Standalone Mode)...');
console.log(`Port: ${process.env.PORT}`);

// This will auto-start the server
require('./routes/local-server');
