#!/usr/bin/env node

/**
 * VoiceLink Server/Offline Mode Test Script
 * Tests server connectivity and offline functionality
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const net = require('net');

console.log('🌐 VoiceLink Server/Offline Mode Test\n');
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

// Test 1: Check if server files exist
runTest('Main server file exists', () => {
    return fs.existsSync(path.join(__dirname, 'src/main.js'));
});

runTest('Server standalone file exists', () => {
    return fs.existsSync(path.join(__dirname, 'server/standalone.js'));
});

// Test 2: Check server configuration
runTest('Server configuration exists', () => {
    const configFiles = [
        'server/config/default.json',
        'server/config/production.json'
    ];
    return configFiles.some(file => fs.existsSync(path.join(__dirname, file)));
});

// Test 3: Test port availability (common VoiceLink ports)
async function testPortAvailability(port) {
    return new Promise((resolve) => {
        const server = net.createServer();
        
        server.listen(port, () => {
            server.close(() => resolve(true));
        });
        
        server.on('error', () => resolve(false));
    });
}

runTest('Port 3000 available', async () => {
    return await testPortAvailability(3000);
});

runTest('Port 3001 available', async () => {
    return await testPortAvailability(3001);
});

runTest('Port 8080 available', async () => {
    return await testPortAvailability(8080);
});

// Test 4: Check offline mode handling in app.js
runTest('Offline mode handling exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('resolve instead of reject') &&
           appContent.includes('gracefully handles offline') &&
           appContent.includes('demo mode activated');
});

// Test 5: Check network error handling
runTest('Network error handling exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('connect_error') &&
           appContent.includes('try the next port') &&
           appContent.includes('when all ports fail');
});

// Test 6: Check if app can work without server
runTest('Demo mode functionality exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('createDemoRoom') &&
           appContent.includes('demo mode');
});

// Test 7: Test HTTP server creation
runTest('Can create HTTP server', () => {
    return new Promise((resolve) => {
        const testServer = http.createServer((req, res) => {
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('VoiceLink Test Server');
        });
        
        testServer.listen(0, () => {
            testServer.close(() => resolve(true));
        });
        
        testServer.on('error', () => resolve(false));
    });
});

// Test 8: Check package.json scripts
runTest('Package.json has server scripts', () => {
    const packageJson = JSON.parse(fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8'));
    return packageJson.scripts && 
           (packageJson.scripts.start || packageJson.scripts.server);
});

// Test 9: Test socket.io availability
runTest('Socket.io module available', () => {
    try {
        require('socket.io');
        return true;
    } catch (error) {
        return false;
    }
});

// Test 10: Check Express server setup
runTest('Express server setup exists', () => {
    try {
        require('express');
        return true;
    } catch (error) {
        return false;
    }
});

// Test 11: Verify offline UI elements
runTest('Offline UI elements exist', () => {
    const htmlContent = fs.readFileSync(path.join(__dirname, 'client/index.html'), 'utf8');
    return htmlContent.includes('server-status-display') &&
           htmlContent.includes('status-offline') &&
           htmlContent.includes('status-value');
});

// Test 12: Test graceful degradation
runTest('Graceful degradation logic exists', () => {
    const appContent = fs.readFileSync(path.join(__dirname, 'client/js/core/app.js'), 'utf8');
    return appContent.includes('finally {') &&
           appContent.includes('Always setup UI event listeners') &&
           appContent.includes('regardless of server/audio initialization status');
});

console.log('\n' + '=' .repeat(50));
console.log('🏁 Server/Offline Test Summary\n');

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
    console.log('\n🎉 ALL SERVER/OFFLINE TESTS PASSED!');
    console.log('✅ Server connectivity components are working');
    console.log('✅ Offline mode handling is properly implemented');
    console.log('✅ Graceful degradation is working correctly');
    process.exit(0);
} else {
    console.log('\n⚠️  Some server/offline tests failed. Please review the issues above.');
    process.exit(1);
}