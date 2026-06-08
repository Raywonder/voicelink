<?php
declare(strict_types=1);

use WHMCS\Database\Capsule;

require_once __DIR__ . '/../../../../init.php';

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');

function vl_login_response(int $status, array $payload): void
{
    http_response_code($status);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

function vl_login_header(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    return trim((string) ($_SERVER[$key] ?? ''));
}

function vl_login_payload(): array
{
    $payload = json_decode((string) file_get_contents('php://input'), true);
    return is_array($payload) ? $payload : $_POST;
}

function vl_login_settings(): array
{
    $defaults = [
        'voicelink_api_url' => 'https://voicelink.dev/api',
        'official_authority_url' => 'https://devine-creations.com',
        'voicelink_main_url' => 'https://voicelinkapp.app',
        'voicelink_community_url' => 'https://community.voicelinkapp.app',
        'fallback_gateway_url' => 'https://voicelinkapp.app/api',
        'bridge_shared_secret' => '',
        'allow_remote_bridge' => 'on',
    ];

    if (!class_exists(Capsule::class)) {
        return $defaults;
    }

    try {
        $rows = Capsule::table('tbladdonmodules')
            ->where('module', 'voicelink_login')
            ->get(['setting', 'value']);
        foreach ($rows as $row) {
            $setting = (string) ($row->setting ?? '');
            if ($setting !== '') {
                $defaults[$setting] = (string) ($row->value ?? '');
            }
        }
    } catch (Throwable $ignored) {
    }

    return $defaults;
}

function vl_login_require_bridge_secret(array $settings): void
{
    $enabled = strtolower((string) ($settings['allow_remote_bridge'] ?? '')) !== 'off';
    $expected = trim((string) ($settings['bridge_shared_secret'] ?? ''));
    $provided = vl_login_header('x-voicelink-shared-secret');
    if (!$enabled || $expected === '' || !hash_equals($expected, $provided)) {
        vl_login_response(403, [
            'ok' => false,
            'success' => false,
            'error' => 'VoiceLink bridge access is not approved.',
        ]);
    }
}

function vl_login_find_client(string $identity): ?array
{
    $value = strtolower(trim($identity));
    if ($value === '' || !class_exists(Capsule::class)) {
        return null;
    }

    try {
        $query = Capsule::table('tblclients')
            ->whereRaw('LOWER(email) = ?', [$value]);
        if (!filter_var($value, FILTER_VALIDATE_EMAIL)) {
            $query->orWhereRaw('LOWER(SUBSTRING_INDEX(email, "@", 1)) = ?', [$value])
                ->orWhereRaw('LOWER(CONCAT(firstname, lastname)) = ?', [$value])
                ->orWhereRaw('LOWER(companyname) = ?', [$value]);
        }
        $client = $query->first();
        if ($client) {
            return (array) $client;
        }
    } catch (Throwable $ignored) {
    }

    if (!filter_var($value, FILTER_VALIDATE_EMAIL)) {
        try {
            $hosting = Capsule::table('tblhosting')
                ->join('tblclients', 'tblclients.id', '=', 'tblhosting.userid')
                ->whereRaw('LOWER(tblhosting.username) = ?', [$value])
                ->select('tblclients.*')
                ->first();
            if ($hosting) {
                return (array) $hosting;
            }
        } catch (Throwable $ignored) {
        }
    }

    return null;
}

function vl_login_validate_client_password(string $email, string $password, string $twoFactorCode = ''): array
{
    $params = [
        'email' => $email,
        'password2' => $password,
    ];
    if ($twoFactorCode !== '') {
        $params['twofa'] = $twoFactorCode;
    }
    return localAPI('ValidateLogin', $params);
}

function vl_login_client_services(int $clientId): array
{
    if ($clientId <= 0) {
        return [];
    }
    $products = localAPI('GetClientsProducts', ['clientid' => $clientId]);
    $services = $products['products']['product'] ?? [];
    return is_array($services) ? $services : [];
}

function vl_login_service_summary(array $services): array
{
    $active = 0;
    foreach ($services as $service) {
        $status = strtolower((string) ($service['status'] ?? $service['domainstatus'] ?? ''));
        if ($status === 'active') {
            $active++;
        }
    }
    return [
        'activeServices' => $active,
        'servicesCount' => count($services),
    ];
}
