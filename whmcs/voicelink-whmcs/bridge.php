<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

$siteRoot = dirname(__DIR__, 3);
$configurationPath = $siteRoot . '/configuration.php';
$clientAreaPath = $siteRoot . '/clientarea.php';
$adminPath = $siteRoot . '/admin';

$data = [
    'provider' => 'whmcs',
    'detected' => file_exists($configurationPath) && file_exists($clientAreaPath),
    'siteRoot' => $siteRoot,
    'configurationPath' => $configurationPath,
    'adminPath' => $adminPath,
    'identityAliases' => [],
    'voiceLink' => [
        'role' => 'user'
    ]
];

if (file_exists($configurationPath)) {
    $config = @file_get_contents($configurationPath) ?: '';
    $patterns = [
        'db_name' => "/\\$db_name\\s*=\\s*'([^']+)'/",
        'db_username' => "/\\$db_username\\s*=\\s*'([^']+)'/",
        'db_host' => "/\\$db_host\\s*=\\s*'([^']+)'/",
        'license' => "/\\$license\\s*=\\s*'([^']+)'/"
    ];
    foreach ($patterns as $key => $pattern) {
        if (preg_match($pattern, $config, $matches) === 1) {
            $data['configuration'][$key] = $matches[1];
        }
    }
}

$host = $_SERVER['HTTP_HOST'] ?? '';
if ($host !== '') {
    $normalizedHost = strtolower(trim((string) $host));
    $data['identityAliases'][] = $normalizedHost;
    $parts = explode('.', $normalizedHost);
    if (count($parts) > 2) {
        $data['identityAliases'][] = implode('.', array_slice($parts, -2));
    }
}

$data['integrationHints'] = [
    'clientPortal' => file_exists($clientAreaPath),
    'adminArea' => is_dir($adminPath),
    'databaseManagers' => ['whmcs', 'cpanel', 'manual'],
    'preserveSiteRootByDefault' => true
];

echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
