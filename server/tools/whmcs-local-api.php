<?php
declare(strict_types=1);

if ($argc < 3) {
    fwrite(STDERR, "Usage: php whmcs-local-api.php <configuration.php> <payload-json>\n");
    exit(1);
}

$configPath = (string) $argv[1];
$payloadJson = (string) $argv[2];

if (!is_file($configPath)) {
    echo json_encode([
        'result' => 'error',
        'message' => 'WHMCS configuration.php not found'
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(0);
}

$siteRoot = dirname($configPath);
$initPath = $siteRoot . '/init.php';

if (!is_file($initPath)) {
    echo json_encode([
        'result' => 'error',
        'message' => 'WHMCS init.php not found'
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(0);
}

$payload = json_decode($payloadJson, true);
if (!is_array($payload)) {
    echo json_encode([
        'result' => 'error',
        'message' => 'Invalid JSON payload'
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(0);
}

$action = trim((string) ($payload['action'] ?? ''));
$params = $payload['params'] ?? [];
if ($action === '') {
    echo json_encode([
        'result' => 'error',
        'message' => 'WHMCS action is required'
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(0);
}

if (!is_array($params)) {
    $params = [];
}

try {
    require_once $initPath;

    if (!function_exists('localAPI')) {
        throw new RuntimeException('WHMCS localAPI is unavailable');
    }

    $result = localAPI($action, $params);
    if (!is_array($result)) {
        $result = [
            'result' => 'error',
            'message' => 'WHMCS localAPI returned an invalid response'
        ];
    }

    echo json_encode($result, JSON_UNESCAPED_SLASHES) . PHP_EOL;
} catch (Throwable $error) {
    echo json_encode([
        'result' => 'error',
        'message' => $error->getMessage()
    ], JSON_UNESCAPED_SLASHES) . PHP_EOL;
}
