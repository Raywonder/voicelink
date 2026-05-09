<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$settings = vl_login_settings();

vl_login_response(200, [
    'ok' => true,
    'success' => true,
    'officialAuthorityUrl' => rtrim((string) ($settings['official_authority_url'] ?? 'https://devine-creations.com'), '/'),
    'masterApiUrl' => rtrim((string) ($settings['voicelink_api_url'] ?? 'https://voicelink.dev/api'), '/'),
    'fallbackGatewayUrl' => rtrim((string) ($settings['fallback_gateway_url'] ?? 'https://voicelinkapp.app/api'), '/'),
    'mainServerUrl' => rtrim((string) ($settings['voicelink_main_url'] ?? 'https://voicelinkapp.app'), '/'),
    'communityServerUrl' => rtrim((string) ($settings['voicelink_community_url'] ?? 'https://community.voicelinkapp.app'), '/'),
    'localBridge' => [
        'enabled' => strtolower((string) ($settings['allow_remote_bridge'] ?? '')) !== 'off',
        'sharedSecretConfigured' => trim((string) ($settings['bridge_shared_secret'] ?? '')) !== '',
        'checkLoginPath' => '/modules/addons/voicelink_login/api/check-login.php',
        'licenseCheckPath' => '/modules/addons/voicelink_login/api/license-check.php',
    ],
]);
