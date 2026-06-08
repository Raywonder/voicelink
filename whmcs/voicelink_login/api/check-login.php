<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$settings = vl_login_settings();
vl_login_require_bridge_secret($settings);

$payload = vl_login_payload();
$identity = trim((string) ($payload['identity'] ?? $payload['email'] ?? $payload['username'] ?? ''));
$password = (string) ($payload['password'] ?? $payload['password2'] ?? '');
$twoFactorCode = trim((string) ($payload['twoFactorCode'] ?? $payload['twofa'] ?? ''));

if ($identity === '' || $password === '') {
    vl_login_response(400, [
        'ok' => false,
        'success' => false,
        'error' => 'Email or username and password are required.',
    ]);
}

try {
    $client = vl_login_find_client($identity);
    if (!$client || empty($client['email'])) {
        vl_login_response(401, [
            'ok' => false,
            'success' => false,
            'error' => 'Invalid email or username or password.',
        ]);
    }

    $login = vl_login_validate_client_password((string) $client['email'], $password, $twoFactorCode);
    if (($login['result'] ?? '') !== 'success') {
        $message = strtolower((string) ($login['message'] ?? $login['error'] ?? ''));
        if (str_contains($message, 'two') && str_contains($message, 'factor')) {
            vl_login_response(401, [
                'ok' => false,
                'success' => false,
                'requires2FA' => true,
                'message' => 'Two-factor authentication code required.',
            ]);
        }
        vl_login_response(401, [
            'ok' => false,
            'success' => false,
            'error' => 'Invalid email or password.',
        ]);
    }

    $clientId = (int) ($client['id'] ?? $client['userid'] ?? 0);
    $services = vl_login_client_services($clientId);
    $summary = vl_login_service_summary($services);
    $displayName = trim(implode(' ', array_filter([
        (string) ($client['firstname'] ?? ''),
        (string) ($client['lastname'] ?? ''),
    ]))) ?: (string) ($client['companyname'] ?? $client['email']);

    vl_login_response(200, [
        'ok' => true,
        'success' => true,
        'client_id' => $clientId,
        'email' => (string) $client['email'],
        'firstname' => (string) ($client['firstname'] ?? ''),
        'lastname' => (string) ($client['lastname'] ?? ''),
        'displayName' => $displayName,
        'services_count' => $summary['servicesCount'],
        'active_services' => $summary['activeServices'],
        'voice_link_login_ready' => true,
    ]);
} catch (Throwable $error) {
    error_log('[VoiceLinkLoginBridge] check-login failed: ' . $error->getMessage());
    vl_login_response(500, [
        'ok' => false,
        'success' => false,
        'error' => 'VoiceLink login bridge is temporarily unavailable.',
    ]);
}
