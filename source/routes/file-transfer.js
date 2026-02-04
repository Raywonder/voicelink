/**
 * File Transfer Routes for VoiceLink
 * Handles P2P file transfers over Headscale/Tailscale network
 */

const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');

// Configure upload directory
const uploadDir = path.join(__dirname, '../../data/transfers');
if (!fs.existsSync(uploadDir)) {
    fs.mkdirSync(uploadDir, { recursive: true });
}

// P2P file receive endpoint (raw body for direct transfers)
router.post('/receive', express.raw({ type: '*/*', limit: '2gb' }), (req, res) => {
    try {
        const senderId = req.headers['x-sender-id'] || 'anonymous';
        const filename = req.headers['x-filename'] || 'unknown_file';

        if (!req.body || req.body.length === 0) {
            return res.status(400).json({ error: 'No file data provided' });
        }

        // Create user directory
        const userDir = path.join(uploadDir, senderId);
        if (!fs.existsSync(userDir)) {
            fs.mkdirSync(userDir, { recursive: true });
        }

        // Save file
        const timestamp = Date.now();
        const safeName = filename.replace(/[^a-zA-Z0-9.-]/g, '_');
        const filePath = path.join(userDir, timestamp + '_' + safeName);

        fs.writeFileSync(filePath, req.body);

        console.log('[FileTransfer] Received file from ' + senderId + ': ' + filename + ' (' + req.body.length + ' bytes)');

        // Emit event for connected clients
        if (req.app.get('io')) {
            req.app.get('io').emit('file-received', {
                senderId,
                filename,
                size: req.body.length,
                path: filePath,
                timestamp: Date.now()
            });
        }

        res.json({
            success: true,
            message: 'File received successfully',
            filename,
            size: req.body.length
        });
    } catch (error) {
        console.error('[FileTransfer] Error:', error);
        res.status(500).json({ error: error.message });
    }
});

// List received files
router.get('/received', (req, res) => {
    try {
        const files = [];
        if (fs.existsSync(uploadDir)) {
            const userDirs = fs.readdirSync(uploadDir);
            for (const userDir of userDirs) {
                const userPath = path.join(uploadDir, userDir);
                if (fs.statSync(userPath).isDirectory()) {
                    const userFiles = fs.readdirSync(userPath);
                    for (const file of userFiles) {
                        const filePath = path.join(userPath, file);
                        const stats = fs.statSync(filePath);
                        files.push({
                            name: file,
                            sender: userDir,
                            size: stats.size,
                            receivedAt: stats.mtime
                        });
                    }
                }
            }
        }
        res.json({ files: files.sort((a, b) => new Date(b.receivedAt) - new Date(a.receivedAt)) });
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Download a received file
router.get('/download/:sender/:filename', (req, res) => {
    try {
        const filePath = path.join(uploadDir, req.params.sender, req.params.filename);
        if (!fs.existsSync(filePath)) {
            return res.status(404).json({ error: 'File not found' });
        }
        res.download(filePath);
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// Delete a received file
router.delete('/delete/:sender/:filename', (req, res) => {
    try {
        const filePath = path.join(uploadDir, req.params.sender, req.params.filename);
        if (fs.existsSync(filePath)) {
            fs.unlinkSync(filePath);
            res.json({ success: true });
        } else {
            res.status(404).json({ error: 'File not found' });
        }
    } catch (error) {
        res.status(500).json({ error: error.message });
    }
});

// CopyParty status check
router.get('/copyparty/status', async (req, res) => {
    try {
        const http = require('http');
        const options = {
            hostname: '64.20.46.178',
            port: 3923,
            path: '/?j',
            method: 'GET',
            timeout: 5000
        };

        const request = http.request(options, (response) => {
            let data = '';
            response.on('data', chunk => data += chunk);
            response.on('end', () => {
                try {
                    const json = JSON.parse(data);
                    res.json({ connected: true, shares: json.vols?.length || 0 });
                } catch {
                    res.json({ connected: true, shares: 0 });
                }
            });
        });

        request.on('error', (error) => {
            res.json({ connected: false, error: error.message });
        });

        request.on('timeout', () => {
            request.destroy();
            res.json({ connected: false, error: 'Connection timeout' });
        });

        request.end();
    } catch (error) {
        res.json({ connected: false, error: error.message });
    }
});

module.exports = router;
