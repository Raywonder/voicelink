'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const source = fs.readFileSync(
    path.join(__dirname, '..', 'server', 'routes', 'local-server.js'),
    'utf8'
);
const socketSection = source.slice(source.indexOf('    setupSocketHandlers() {'));

assert.match(socketSection, /this\.emitSocketBotModerationEvent\(/);
assert.match(socketSection, /this\.inspectSocketModerationMessage\(/);
assert.doesNotMatch(socketSection, /(?<![\w.])emitBotModerationEvent\(/);
assert.doesNotMatch(socketSection, /(?<![\w.])inspectModerationMessage\(/);

console.log('Socket moderation handlers use class-scoped helpers.');
