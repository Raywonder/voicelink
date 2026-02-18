/**
 * Legacy compatibility shim.
 *
 * Keep old entrypoint paths working, but always run the canonical
 * implementation from source/routes/local-server.js so old code paths
 * cannot diverge from current VoiceLink behavior.
 */
module.exports = require('../../routes/local-server');
