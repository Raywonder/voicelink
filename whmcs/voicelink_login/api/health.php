<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$settings = vl_login_settings();

vl_login_response(200, [
    'ok' => true,
    'success' => true,
    'service' => 'voicelink_login_bridge',
    'status' => 'ready',
    'remoteBridgeEnabled' => strtolower((string) ($settings['allow_remote_bridge'] ?? '')) !== 'off',
    'sharedSecretConfigured' => trim((string) ($settings['bridge_shared_secret'] ?? '')) !== '',
]);
