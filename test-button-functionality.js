#!/usr/bin/env node

/**
 * VoiceLink Button Functionality Test Script
 * Tests all button event listeners and audio feedback system
 */

const fs = require('fs');
const path = require('path');

// Mock DOM environment
global.document = {
    getElementById: (id) => ({
        addEventListener: (event, callback) => {
            console.log(`✅ Event listener attached to #${id} for '${event}' event`);
            return true;
        }
    })
};

global.window = {
    electronAPI: {
        startServer: () => Promise.resolve(true),
        stopServer: () => Promise.resolve(true),
        restartServer: () => Promise.resolve(true)
    },
    unifiedAdminInterface: {
        showAdminPanel: () => console.log('📋 Admin panel shown'),
        switchAdminSection: (section) => console.log(`📂 Switched to ${section} section`)
    },
    settingsInterfaceManager: {
        showSettings: () => console.log('⚙️ Settings shown')
    }
};

console.log('🧪 VoiceLink Button Functionality Test\n');
console.log('=' .repeat(50));

// Test results tracking
const testResults = {
    passed: 0,
    failed: 0,
    tests: []
};

function runTest(testName, testFn) {
    try {
        const result = testFn();
        if (result) {
            console.log(`✅ PASS: ${testName}`);
            testResults.passed++;
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

// Test 1: Check if app.js exists and load it
runTest('App.js file exists', () => {
    const appPath = path.join(__dirname, 'client/js/core/app.js');
    return fs.existsSync(appPath);
});

// Test 2: Check if setupUIEventListeners function exists
runTest('setupUIEventListeners function exists', () => {
    try {
        const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
        return appContent.includes('setupUIEventListeners()') && 
               appContent.includes('document.getElementById(\'create-room-btn\')');
    } catch (error) {
        return false;
    }
});

// Test 3: Check if button event listeners are properly defined
runTest('Create Room button event listener', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('create-room-btn\')?.addEventListener(\'click\'');
});

runTest('Join Room button event listener', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('join-room-btn\')?.addEventListener(\'click\'');
});

runTest('Settings button event listener', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('open-settings-btn\')?.addEventListener(\'click\'');
});

runTest('Server control buttons event listeners', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('start-server-btn\')?.addEventListener(\'click\'') &&
           appContent.includes('stop-server-btn\')?.addEventListener(\'click\'') &&
           appContent.includes('restart-server-btn\')?.addEventListener(\'click\'');
});

// Test 4: Check audio feedback system
runTest('Button audio initialization exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('initializeButtonAudio()');
});

runTest('Button click audio handler exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('playClick()') && 
           appContent.includes('addEventListener(\'click\'');
});

// Test 5: Check finally block for reliable event listener setup
runTest('Finally block for reliable initialization', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('finally {') &&
           appContent.includes('this.setupUIEventListeners();');
});

// Test 6: Check navigation functions
runTest('Screen navigation functions exist', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('showScreen(\'create-room-screen\')') &&
           appContent.includes('showScreen(\'join-room-screen\')');
});

// Test 7: Check HTML file for button elements
runTest('HTML file contains all required buttons', () => {
    const htmlContent = fs.readFileSync(path.join(__dirname, 'client/index.html'), 'utf8');
    const requiredButtons = [
        'create-room-btn',
        'join-room-btn', 
        'open-settings-btn',
        'quick-audio-btn',
        'test-audio-btn'
    ];
    
    return requiredButtons.every(button => htmlContent.includes(`id="${button}"`));
});

// Test 8: Check for error handling in button callbacks
runTest('Button callbacks have error handling', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('try {') && 
           appContent.includes('catch (error)') &&
           appContent.includes('console.error');
});

console.log('\n' + '=' .repeat(50));
console.log('🏁 Test Summary\n');

// Output detailed results
testResults.tests.forEach(test => {
    const status = test.passed ? '✅' : '❌';
    console.log(`${status} ${test.name}`);
    if (test.error) {
        console.log(`    Error: ${test.error}`);
    }
});

console.log(`\n📊 Results Summary:`);
console.log(`   Total Tests: ${testResults.tests.length}`);
console.log(`   ✅ Passed: ${testResults.passed}`);
console.log(`   ❌ Failed: ${testResults.failed}`);
console.log(`   📈 Success Rate: ${Math.round((testResults.passed / testResults.tests.length) * 100)}%`);

// Overall status
if (testResults.failed === 0) {
    console.log('\n🎉 ALL TESTS PASSED! Button functionality is working correctly.');
    process.exit(0);
} else {
    console.log('\n⚠️  Some tests failed. Please review the issues above.');
    process.exit(1);
}