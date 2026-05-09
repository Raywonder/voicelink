<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$settings = vl_login_settings();
vl_login_require_bridge_secret($settings);

$payload = vl_login_payload();
$identity = trim((string) ($payload['identity'] ?? $payload['email'] ?? $payload['username'] ?? ''));

if ($identity === '') {
    vl_login_response(400, [
        'ok' => false,
        'success' => false,
        'error' => 'Email or username is required.',
    ]);
}

try {
    $client = vl_login_find_client($identity);
    if (!$client || empty($client['email'])) {
        vl_login_response(404, [
            'ok' => false,
            'success' => false,
            'error' => 'Client account was not found.',
        ]);
    }

    $clientId = (int) ($client['id'] ?? $client['userid'] ?? 0);
    $services = vl_login_client_services($clientId);
    $summary = vl_login_service_summary($services);
    $licensed = $summary['activeServices'] > 0;

    vl_login_response(200, [
        'ok' => true,
        'success' => true,
        'client_id' => $clientId,
        'email' => (string) $client['email'],
        'licensed' => $licensed,
        'status' => $licensed ? 'active' : 'no_active_services',
        'entitlements' => [
            'activeServices' => $summary['activeServices'],
            'servicesCount' => $summary['servicesCount'],
            'licenseTier' => $licensed ? 'client' : 'guest',
        ],
    ]);
} catch (Throwable $error) {
    error_log('[VoiceLinkLoginBridge] license-check failed: ' . $error->getMessage());
    vl_login_response(500, [
        'ok' => false,
        'success' => false,
        'error' => 'VoiceLink license bridge is temporarily unavailable.',
    ]);
}
