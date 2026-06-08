<?php
declare(strict_types=1);

if ($argc < 4) {
    fwrite(STDERR, "Usage: php whmcs-admin-auth.php <identity> <password> <configuration.php>\n");
    exit(1);
}

$identity = trim((string) $argv[1]);
$password = (string) $argv[2];
$configPath = (string) $argv[3];

$fail = static function (string $message = 'Invalid WHMCS admin credentials'): void {
    echo json_encode(['success' => false, 'message' => $message], JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(0);
};

if ($identity === '' || $password === '') {
    $fail();
}

if (!is_file($configPath)) {
    $fail('WHMCS configuration.php not found');
}

$siteRoot = dirname($configPath);
$initPath = $siteRoot . '/init.php';
if (!is_file($initPath)) {
    $fail('WHMCS init.php not found');
}

try {
    require_once $initPath;

    if (!class_exists('\\WHMCS\\Database\\Capsule')) {
        throw new RuntimeException('WHMCS database layer is unavailable');
    }

    $admin = \WHMCS\Database\Capsule::table('tbladmins')
        ->where(function ($query) use ($identity) {
            $query->where('username', $identity)
                ->orWhere('email', $identity);
        })
        ->first();

    if (!$admin) {
        $fail();
    }

    $stored = (string) ($admin->password ?? '');
    $valid = false;
    if ($stored !== '') {
        $valid = password_verify($password, $stored);
        if (!$valid && preg_match('/^[a-f0-9]{32}$/i', $stored) === 1) {
            $valid = hash_equals(strtolower($stored), md5($password));
        }
    }

    if (!$valid) {
        $fail();
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

    echo json_encode([
        'success' => true,
        'admin' => [
            'id' => (int) ($admin->id ?? 0),
            'username' => (string) ($admin->username ?? ''),
            'email' => (string) ($admin->email ?? ''),
            'roleId' => $roleId,
            'roleName' => $roleName,
            'disabled' => (int) ($admin->disabled ?? 0) === 1
        ]
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
} catch (Throwable $error) {
    echo json_encode([
        'success' => false,
        'message' => $error->getMessage()
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
}
