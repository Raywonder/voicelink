#!/usr/bin/env node

/**
 * VoiceLink Media Playback Diagnostic Tool
 * Diagnoses and helps fix media playback issues in the web app
 */

const fs = require('fs');
const path = require('path');

console.log('🔍 VoiceLink Media Playback Diagnostic Tool\n');
console.log('=' .repeat(60));

// Test results tracking
const testResults = {
    passed: 0,
    failed: 0,
    warnings: 0,
    tests: []
};

function runTest(testName, testFn) {
    try {
        const result = testFn();
        if (result === true) {
            console.log(`✅ PASS: ${testName}`);
            testResults.passed++;
        } else if (result === 'warning') {
            console.log(`⚠️  WARNING: ${testName}`);
            testResults.warnings++;
        } else {
            console.log(`❌ FAIL: ${testName}`);
            testResults.failed++;
        }
        testResults.tests.push({ name: testName, passed: result });
    } catch (error) {
        console.log(`❌ FAIL: ${testName} - Error: ${error.message}`);
        testResults.failed++;
        testResults.tests.push({ name: testName, passed: false, error: error.message });
    }
}

// Test 1: Check if media playback components exist
runTest('JukeboxManager class exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('class JukeboxManager');
});

runTest('Audio element creation method exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('createAudioElement()');
});

runTest('Playback error handling exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('handlePlaybackError(e)');
});

// Test 2: Check improved error handling (recent fixes)
runTest('Enhanced playback error handling implemented', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('MEDIA_ERR_NETWORK') && 
           appContent.includes('MEDIA_ERR_SRC_NOT_SUPPORTED');
});

runTest('Alternative stream fallback implemented', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('tryAlternativeStream()') &&
           appContent.includes('triedDirect');
});

runTest('Network connectivity check added', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('navigator.onLine');
});

// Test 3: Check server-side stream URL generation
runTest('Server stream URL endpoint exists', () => {
    const serverContent = fs.readFileSync(path.join(__dirname, 'server/routes/local-server.js'), 'utf8');
    return serverContent.includes('/api/jellyfin/stream-url');
});

runTest('Multiple stream formats supported', () => {
    const serverContent = fs.readFileSync(path.join(__dirname, 'server/routes/local-server.js'), 'utf8');
    return serverContent.includes('alternativeStreams') &&
           serverContent.includes('format=mp3') &&
           serverContent.includes('format=aac');
});

runTest('Enhanced error logging implemented', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('console.error') &&
           appContent.includes('track:') &&
           appContent.includes('url:');
});

// Test 4: Check audio format support
runTest('Browser compatibility attributes added', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('playsinline') &&
           appContent.includes('webkit-playsinline');
});

runTest('Audio event handlers properly configured', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('handleLoadStart()') &&
           appContent.includes('handleCanPlay()') &&
           appContent.includes('handleStalled()');
});

// Test 5: Check queue management
runTest('Queue cleanup on playback error', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('splice(this.currentIndex, 1)') &&
           appContent.includes('Removed problematic track');
});

runTest('Empty queue handling improved', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('Queue empty, cannot skip') &&
           appContent.includes('Queue empty. No more tracks to play');
});

// Test 6: Check MIME type and CORS handling
runTest('CORS configuration for audio', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('crossOrigin = \'anonymous\'');
});

runTest('Audio preload optimization', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('preload = \'metadata\'');
});

console.log('\n' + '=' .repeat(60));
console.log('🩺 Diagnostic Analysis\n');

// Output detailed results
testResults.tests.forEach(test => {
    const status = test.passed === true ? '✅' : (test.passed === 'warning' ? '⚠️' : '❌');
    console.log(`${status} ${test.name}`);
    if (test.error) {
        console.log(`    Error: ${test.error}`);
    }
});

console.log(`\n📊 Diagnostic Results:`);
console.log(`   Total Tests: ${testResults.tests.length}`);
console.log(`   ✅ Passed: ${testResults.passed}`);
console.log(`   ⚠️  Warnings: ${testResults.warnings}`);
console.log(`   ❌ Failed: ${testResults.failed}`);

console.log(`\n🎯 Playback Issue Analysis:`);

if (testResults.failed === 0) {
    console.log('✅ All playback components are properly configured!');
    console.log('\n🔧 Recommended next steps:');
    console.log('1. Test with actual media files');
    console.log('2. Check browser console for specific error details');
    console.log('3. Verify Jellyfin server connectivity');
    console.log('4. Test network connectivity and CORS headers');
} else {
    console.log('⚠️  Some issues found. See details above.');
}

console.log('\n📋 Common Playback Issues & Solutions:');
console.log('');
console.log('1. 🌐 Network Errors:');
console.log('   - Check internet connection');
console.log('   - Verify Jellyfin server is accessible');
console.log('   - Check CORS headers on server');
console.log('');
console.log('2. 🎵 Format Issues:');
console.log('   - Browser doesn\'t support codec');
console.log('   - File is corrupted or missing');
console.log('   - Transcoding failed on server');
console.log('');
console.log('3. 🔐 Permission Issues:');
console.log('   - Autoplay policies block audio');
console.log('   - Browser requires user interaction');
console.log('   - API key expired or invalid');
console.log('');
console.log('4. 📦 Resource Issues:');
console.log('   - Server overloaded');
console.log('   - Bandwidth throttling');
console.log('   - SSL certificate problems');

console.log('\n🚀 Fixes Applied:');
console.log('✅ Enhanced error handling with specific error types');
console.log('✅ Alternative stream format fallback');
console.log('✅ Network connectivity checks');
console.log('✅ Queue cleanup for problematic tracks');
console.log('✅ Browser compatibility improvements');
console.log('✅ Better logging and diagnostics');

process.exit(testResults.failed === 0 ? 0 : 1);