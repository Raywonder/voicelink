<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');

function vl_response(int $status, array $payload): void
{
    http_response_code($status);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

function vl_header(string $name): string
{
    $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
    return trim((string) ($_SERVER[$key] ?? ''));
}

function vl_secret(): string
{
    $secretFile = '/home/devinecr/.voicelink-auth-secret';
    if (is_readable($secretFile)) {
        return trim((string) file_get_contents($secretFile));
    }
    return '';
}

$expectedSecret = vl_secret();
$providedSecret = vl_header('x-voicelink-shared-secret');
if ($expectedSecret === '' || !hash_equals($expectedSecret, $providedSecret)) {
    vl_response(403, [
        'success' => false,
        'error' => 'VoiceLink authority access is not approved.'
    ]);
}

$siteRoot = dirname(__DIR__, 4);
$initPath = $siteRoot . '/init.php';
if (!is_file($initPath)) {
    vl_response(503, [
        'success' => false,
        'error' => 'WHMCS is not available right now.'
    ]);
}

$payload = json_decode((string) file_get_contents('php://input'), true);
if (!is_array($payload)) {
    $payload = $_POST;
}

$identity = trim((string) ($payload['identity'] ?? $payload['email'] ?? $payload['username'] ?? ''));
$email = trim((string) ($payload['email'] ?? ''));
$username = trim((string) ($payload['username'] ?? ''));
$password = (string) ($payload['password'] ?? $payload['password2'] ?? '');
$twoFactorCode = trim((string) ($payload['twoFactorCode'] ?? $payload['twofa'] ?? ''));
$portalSite = trim((string) ($payload['portalSite'] ?? 'devine-creations.com'));

if ($email === '' && filter_var($identity, FILTER_VALIDATE_EMAIL)) {
    $email = $identity;
}

if ($identity === '' && $email === '' && $username !== '') {
    $identity = $username;
}

if (($identity === '' && $email === '') || $password === '') {
    vl_response(400, [
        'success' => false,
        'error' => 'Email or username and password are required.'
    ]);
}

try {
    require_once $initPath;

    if (!function_exists('localAPI')) {
        throw new RuntimeException('WHMCS local API is unavailable.');
    }

    $authenticateAdmin = static function (string $value, string $candidatePassword): ?array {
        $loginIdentity = trim($value);
        if ($loginIdentity === '' || $candidatePassword === '' || !class_exists('\\WHMCS\\Database\\Capsule')) {
            return null;
        }

        try {
            $admin = \WHMCS\Database\Capsule::table('tbladmins')
                ->where(function ($query) use ($loginIdentity) {
                    $query->where('username', $loginIdentity)
                        ->orWhere('email', $loginIdentity);
                })
                ->first();
        } catch (Throwable $ignored) {
            return null;
        }

        if (!$admin || (int) ($admin->disabled ?? 0) === 1) {
            return null;
        }

        $stored = (string) ($admin->password ?? '');
        $valid = $stored !== '' && password_verify($candidatePassword, $stored);
        if (!$valid && preg_match('/^[a-f0-9]{32}$/i', $stored) === 1) {
            $valid = hash_equals(strtolower($stored), md5($candidatePassword));
        }
        if (!$valid) {
            return null;
        }

        $roleId = (int) ($admin->roleid ?? 0);
        $roleName = '';
        if ($roleId > 0) {
            try {
                $role = \WHMCS\Database\Capsule::table('tbladminroles')
                    ->where('id', $roleId)
                    ->first();
                $roleName = (string) ($role->name ?? '');
            } catch (Throwable $ignored) {
                $roleName = '';
            }
        }

        $normalizedRoleName = strtolower($roleName);
        $role = str_contains($normalizedRoleName, 'owner')
            ? 'owner'
            : ((str_contains($normalizedRoleName, 'support') || str_contains($normalizedRoleName, 'staff') || ($roleId > 0 && $roleId !== 1)) ? 'staff' : 'admin');

        return [
            'id' => (int) ($admin->id ?? 0),
            'username' => (string) ($admin->username ?? ''),
            'email' => (string) ($admin->email ?? ''),
            'roleId' => $roleId,
            'roleName' => $roleName,
            'role' => $role,
        ];
    };

    $resolveUsernameToClient = static function (string $value): ?array {
        $username = strtolower(trim($value));
        if ($username === '' || filter_var($username, FILTER_VALIDATE_EMAIL)) {
            return null;
        }

        if (!class_exists('\\WHMCS\\Database\\Capsule')) {
            return null;
        }

        try {
            $client = \WHMCS\Database\Capsule::table('tblclients')
                ->whereRaw('LOWER(email) = ?', [$username])
                ->orWhereRaw('LOWER(SUBSTRING_INDEX(email, "@", 1)) = ?', [$username])
                ->orWhereRaw('LOWER(CONCAT(firstname, lastname)) = ?', [$username])
                ->orWhereRaw('LOWER(companyname) = ?', [$username])
                ->first();
            if ($client && !empty($client->email)) {
                return ['email' => (string) $client->email, 'client' => (array) $client];
            }
        } catch (Throwable $ignored) {
        }

        try {
            $hosting = \WHMCS\Database\Capsule::table('tblhosting')
                ->join('tblclients', 'tblclients.id', '=', 'tblhosting.userid')
                ->whereRaw('LOWER(tblhosting.username) = ?', [$username])
                ->select('tblclients.*')
                ->first();
            if ($hosting && !empty($hosting->email)) {
                return ['email' => (string) $hosting->email, 'client' => (array) $hosting];
            }
        } catch (Throwable $ignored) {
        }

        try {
            $customField = \WHMCS\Database\Capsule::table('tblcustomfieldsvalues')
                ->join('tblcustomfields', 'tblcustomfields.id', '=', 'tblcustomfieldsvalues.fieldid')
                ->join('tblclients', 'tblclients.id', '=', 'tblcustomfieldsvalues.relid')
                ->whereRaw('LOWER(tblcustomfieldsvalues.value) = ?', [$username])
                ->where(function ($query) {
                    $query->whereRaw('LOWER(tblcustomfields.fieldname) LIKE ?', ['%username%'])
                        ->orWhereRaw('LOWER(tblcustomfields.fieldname) LIKE ?', ['%login%']);
                })
                ->select('tblclients.*')
                ->first();
            if ($customField && !empty($customField->email)) {
                return ['email' => (string) $customField->email, 'client' => (array) $customField];
            }
        } catch (Throwable $ignored) {
        }

        return null;
    };

    $admin = $authenticateAdmin($identity !== '' ? $identity : $email, $password);
    if ($admin) {
        $displayName = $admin['username'] !== '' ? $admin['username'] : ($admin['email'] !== '' ? $admin['email'] : 'WHMCS Admin');
        $permissions = $admin['role'] === 'staff'
            ? ['admin', 'staff', 'client']
            : ['admin', 'owner', 'staff', 'client'];

        vl_response(200, [
            'success' => true,
            'portalUrl' => 'https://devine-creations.com/clientarea.php',
            'adminUrl' => 'https://devine-creations.com/admin',
            'user' => [
                'id' => 'whmcs-admin:' . $admin['id'],
                'whmcsAdminId' => $admin['id'],
                'email' => $admin['email'],
                'username' => $admin['username'],
                'displayName' => $displayName,
                'fullHandle' => $admin['username'],
                'role' => $admin['role'],
                'permissions' => $permissions,
                'isAdmin' => $admin['role'] !== 'staff',
                'isModerator' => true,
                'authProvider' => 'whmcs_admin',
                'portalSite' => $portalSite,
                'entitlements' => [
                    'licenseTier' => $admin['role'] === 'owner' ? 'owner' : 'admin',
                    'serverOwnerLicense' => true,
                    'serverSlots' => 10,
                    'hostingControlPanelLinked' => true,
                    'hostingRoles' => array_values(array_filter([$admin['roleName'], $admin['role']])),
                    'licenses' => [
                        'user' => [
                            'type' => 'admin',
                            'installsAllowed' => 10,
                            'devicesAllowed' => null,
                        ],
                        'server' => [
                            'type' => 'server_owner',
                            'installsAllowed' => 10,
                            'serversAllowed' => 10,
                        ],
                    ],
                ],
            ],
        ]);
    }

    $resolvedUsernameClient = null;
    if ($email === '' && $identity !== '') {
        $resolvedUsernameClient = $resolveUsernameToClient($identity);
        if ($resolvedUsernameClient && !empty($resolvedUsernameClient['email'])) {
            $email = (string) $resolvedUsernameClient['email'];
        }
    }

    if ($email === '') {
        vl_response(401, [
            'success' => false,
            'error' => 'Invalid email or username or password.'
        ]);
    }

    $clientLookup = $resolvedUsernameClient && !empty($resolvedUsernameClient['client'])
        ? ['client' => $resolvedUsernameClient['client']]
        : localAPI('GetClientsDetails', ['email' => $email]);
    $client = $clientLookup['client'] ?? $clientLookup['clientdetails'] ?? null;

    $loginParams = [
        'email' => $email,
        'password2' => $password,
    ];
    if ($twoFactorCode !== '') {
        $loginParams['twofa'] = $twoFactorCode;
    }

    $login = localAPI('ValidateLogin', $loginParams);
    if (($login['result'] ?? '') !== 'success') {
        $message = strtolower((string) ($login['message'] ?? $login['error'] ?? ''));
        if (strpos($message, 'two') !== false && strpos($message, 'factor') !== false) {
            vl_response(401, [
                'success' => false,
                'requires2FA' => true,
                'message' => 'Two-factor authentication code required.'
            ]);
        }
        vl_response(401, [
            'success' => false,
            'error' => 'Invalid email or password.'
        ]);
    }

    if (!$client) {
        $clientLookup = localAPI('GetClientsDetails', ['email' => $email]);
        $client = $clientLookup['client'] ?? $clientLookup['clientdetails'] ?? null;
    }
    if (!$client) {
        vl_response(404, [
            'success' => false,
            'error' => 'Client account was not found.'
        ]);
    }

    $clientId = (int) ($client['id'] ?? $client['userid'] ?? 0);
    $services = [];
    if ($clientId > 0) {
        $products = localAPI('GetClientsProducts', ['clientid' => $clientId]);
        $services = $products['products']['product'] ?? [];
        if (!is_array($services)) {
            $services = [];
        }
    }

    $displayName = trim(implode(' ', array_filter([
        (string) ($client['firstname'] ?? ''),
        (string) ($client['lastname'] ?? ''),
    ])));
    if ($displayName === '') {
        $displayName = (string) ($client['companyname'] ?? $email);
    }

    $activeServices = 0;
    foreach ($services as $service) {
        $status = strtolower((string) ($service['status'] ?? $service['domainstatus'] ?? ''));
        if ($status === 'active') {
            $activeServices++;
        }
    }

    vl_response(200, [
        'success' => true,
        'portalUrl' => 'https://devine-creations.com/clientarea.php',
        'user' => [
            'id' => 'whmcs:' . $clientId,
            'whmcsClientId' => $clientId,
            'email' => (string) ($client['email'] ?? $email),
            'username' => (string) ($client['email'] ?? $email),
            'displayName' => $displayName,
            'fullHandle' => (string) ($client['email'] ?? $email),
            'role' => $activeServices > 0 ? 'user' : 'guest',
            'permissions' => ['client'],
            'isAdmin' => false,
            'isModerator' => false,
            'authProvider' => 'whmcs',
            'portalSite' => $portalSite,
            'entitlements' => [
                'activeServices' => $activeServices,
                'servicesCount' => count($services),
            ],
        ],
    ]);
} catch (Throwable $error) {
    error_log('[VoiceLinkAuthority] WHMCS login failed: ' . $error->getMessage());
    vl_response(500, [
        'success' => false,
        'error' => 'WHMCS sign-in is temporarily unavailable.'
    ]);
}
