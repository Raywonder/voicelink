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

const mediaUploadRoot = process.env.VOICELINK_MEDIA_UPLOAD_ROOT
    ? path.resolve(process.env.VOICELINK_MEDIA_UPLOAD_ROOT)
    : path.join(__dirname, '../../data/media/users');

if (!fs.existsSync(mediaUploadRoot)) {
    fs.mkdirSync(mediaUploadRoot, { recursive: true, mode: 0o755 });
}

const audioExts = new Set(['.mp3', '.wav', '.flac', '.ogg', '.m4a', '.aac', '.opus', '.webm']);
const videoExts = new Set(['.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v']);

function sanitizeSegment(value, fallback = 'unknown') {
    const cleaned = String(value || '')
        .trim()
        .replace(/[^a-zA-Z0-9_.-]/g, '_')
        .replace(/^_+|_+$/g, '');
    return cleaned || fallback;
}

function detectMediaKind(fileName, contentType) {
    const ext = path.extname(String(fileName || '')).toLowerCase();
    const type = String(contentType || '').toLowerCase();
    if (audioExts.has(ext) || type.startsWith('audio/')) return 'audio';
    if (videoExts.has(ext) || type.startsWith('video/')) return 'video';
    return null;
}

function enforceReadOnly(filePath) {
    try {
        fs.chmodSync(filePath, 0o644);
    } catch (error) {
        console.warn('[FileTransfer] chmod failed for file:', filePath, error.message);
    }
}

function ensureReadOnlyDir(dirPath) {
    try {
        fs.mkdirSync(dirPath, { recursive: true, mode: 0o755 });
    } catch (error) {
        console.warn('[FileTransfer] mkdir failed for directory:', dirPath, error.message);
    }
    try {
        fs.chmodSync(dirPath, 0o755);
    } catch (error) {
        console.warn('[FileTransfer] chmod failed for directory:', dirPath, error.message);
    }
}

// P2P file receive endpoint (raw body for direct transfers)
router.post('/receive', express.raw({ type: '*/*', limit: '2gb' }), (req, res) => {
    try {
        const senderId = sanitizeSegment(req.headers['x-sender-id'], 'anonymous');
        const filename = req.headers['x-filename'] || 'unknown_file';
        const safeName = sanitizeSegment(filename, 'unknown_file');

        if (!req.body || req.body.length === 0) {
            return res.status(400).json({ error: 'No file data provided' });
        }

        // Create user directory
        const userDir = path.join(uploadDir, senderId);
        ensureReadOnlyDir(userDir);

        // Save file
        const timestamp = Date.now();
        const filePath = path.join(userDir, timestamp + '_' + safeName);

        fs.writeFileSync(filePath, req.body);
        enforceReadOnly(filePath);

        let mediaPath = null;
        const mediaKind = detectMediaKind(filename, req.headers['content-type']);
        if (mediaKind) {
            // Store a read-only media copy in per-user media path for library use.
            const mediaDir = path.join(mediaUploadRoot, senderId, mediaKind);
            ensureReadOnlyDir(mediaDir);
            mediaPath = path.join(mediaDir, timestamp + '_' + safeName);
            fs.copyFileSync(filePath, mediaPath);
            enforceReadOnly(mediaPath);
        }

        console.log('[FileTransfer] Received file from ' + senderId + ': ' + filename + ' (' + req.body.length + ' bytes)');

        // Emit event for connected clients
        if (req.app.get('io')) {
            req.app.get('io').emit('file-received', {
                senderId,
                filename,
                size: req.body.length,
                path: filePath,
                mediaPath,
                timestamp: Date.now()
            });
        }

        res.json({
            success: true,
            message: 'File received successfully',
            filename,
            size: req.body.length,
            mediaPath
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
    const http = require('http');
    const https = require('https');

    const configured = (process.env.VOICELINK_COPYPARTY_STATUS_URL
        || process.env.VOICELINK_COPYPARTY_URL
        || '')
        .toString()
        .trim()
        .replace(/\/+$/, '');

    const candidates = [];
    if (configured) {
        candidates.push(`${configured}/?j`);
    }
    candidates.push('http://127.0.0.1:3924/?j');
    candidates.push('http://127.0.0.1:3923/?j');
    candidates.push('http://64.20.46.178:3923/?j');

    const probe = (urlString) => new Promise((resolve, reject) => {
        try {
            const url = new URL(urlString);
            const transport = url.protocol === 'https:' ? https : http;
            const request = transport.request(
                {
                    hostname: url.hostname,
                    port: url.port || (url.protocol === 'https:' ? 443 : 80),
                    path: url.pathname + url.search,
                    method: 'GET',
                    timeout: 5000
                },
                (response) => {
                    let data = '';
                    response.on('data', (chunk) => { data += chunk; });
                    response.on('end', () => {
                        if (response.statusCode >= 500) {
                            return reject(new Error(`HTTP `));
                        }
                        try {
                            const json = JSON.parse(data);
                            resolve({
                                connected: true,
                                url: urlString,
                                shares: json.vols?.length || 0
                            });
                        } catch {
                            resolve({
                                connected: true,
                                url: urlString,
                                shares: 0
                            });
                        }
                    });
                }
            );
            request.on('error', reject);
            request.on('timeout', () => {
                request.destroy(new Error('Connection timeout'));
            });
            request.end();
        } catch (error) {
            reject(error);
        }
    });

    const errors = [];
    for (const target of candidates) {
        try {
            const result = await probe(target);
            return res.json(result);
        } catch (error) {
            errors.push(`${target}: ${error.message}`);
        }
    }

    return res.json({
        connected: false,
        error: errors[errors.length - 1] || 'All probes failed',
        tried: candidates
    });
});

module.exports = router;
