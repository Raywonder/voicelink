<?php
/**
 * Minimal post-install hook skeleton.
 * Adapt as needed for the actual Installatron runtime variables.
 */

function vl_safe_write($path, $content) {
    $dir = dirname($path);
    if (!is_dir($dir)) {
        mkdir($dir, 0755, true);
    }
    file_put_contents($path, $content);
}

$webroot = getenv('VL_INSTALL_PATH') ?: getcwd();
$domain = getenv('VL_INSTALL_DOMAIN') ?: 'unknown-domain';
$installMode = getenv('VL_INSTALL_MODE') ?: 'root';
$licenseKey = getenv('VL_LICENSE_KEY') ?: '';
$apiUrl = getenv('VL_WHMCS_API_URL') ?: '';
$installId = bin2hex(random_bytes(16));

$wellKnownDir = $webroot . DIRECTORY_SEPARATOR . '.well-known';
if (!is_dir($wellKnownDir)) {
    mkdir($wellKnownDir, 0755, true);
}

// Never touch acme-challenge if present.
$metadata = [
    'installId' => $installId,
    'domain' => $domain,
    'installMode' => $installMode,
    'licenseStatus' => 'pending',
    'publishedAt' => gmdate('c'),
];

vl_safe_write(
    $wellKnownDir . DIRECTORY_SEPARATOR . 'voicelink.json',
    json_encode($metadata, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)
);

// Optional remote registration call.
if ($apiUrl && $licenseKey) {
    $payload = json_encode([
        'installId' => $installId,
        'domain' => $domain,
        'installMode' => $installMode,
        'licenseKey' => $licenseKey,
    ]);

    $ch = curl_init(rtrim($apiUrl, '/') . '/api/install/register');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_POSTFIELDS => $payload,
        CURLOPT_TIMEOUT => 20,
    ]);
    $response = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    vl_safe_write(
        $webroot . DIRECTORY_SEPARATOR . 'storage' . DIRECTORY_SEPARATOR . 'install-registration.json',
        json_encode([
            'httpCode' => $httpCode,
            'response' => $response,
            'requestedAt' => gmdate('c'),
        ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)
    );
}
