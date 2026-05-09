const express = require('express');
const router = express.Router();

router.post('/api/install/register', (req, res) => res.json({ ok: true, action: 'register' }));
router.post('/api/install/validate-license', (req, res) => res.json({ ok: true, action: 'validate-license' }));
router.get('/api/install/status', (req, res) => res.json({ ok: true, action: 'status' }));
router.get('/.well-known/voicelink.json', (req, res) => res.json({ service: 'VoiceLink', discoveryVersion: '1' }));

module.exports = router;
