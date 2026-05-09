<?php
declare(strict_types=1);

/**
 * VoiceLink WHMCS PayPal callback compatibility endpoint.
 *
 * This file is meant to be deployed to:
 *   modules/gateways/callback/paypal.php
 *
 * Goals:
 * - Return a clean 200 response when visited directly in a browser.
 * - Bootstrap WHMCS when available so callback traffic can be handed to the
 *   installed gateway stack instead of failing with an opaque 406/empty page.
 * - Preserve the raw callback payload for later inspection when the WHMCS
 *   runtime or gateway helpers are unavailable.
 */

$callbackDir = __DIR__;
$siteRoot = dirname($callbackDir, 4);
$initPath = $siteRoot . '/init.php';
$attachmentsDir = $siteRoot . '/attachments/voicelink';
$logFile = $attachmentsDir . '/paypal-callback.log';

if (!is_dir($attachmentsDir)) {
    @mkdir($attachmentsDir, 0775, true);
}

$requestMethod = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
$contentType = (string) ($_SERVER['CONTENT_TYPE'] ?? '');
$rawPayload = file_get_contents('php://input') ?: '';

$writeLog = static function (string $message) use ($logFile): void {
    $line = sprintf("[%s] %s\n", gmdate('c'), $message);
    @file_put_contents($logFile, $line, FILE_APPEND);
};

if ($requestMethod !== 'POST') {
    http_response_code(200);
    header('Content-Type: text/plain; charset=utf-8');
    echo "VoiceLink PayPal callback endpoint is reachable.\n";
    echo "This endpoint is intended for PayPal server-to-server callbacks and WHMCS gateway handling.\n";
    echo "Direct browser access is allowed for verification only.\n";
    exit;
}

if (is_file($initPath)) {
    require_once $initPath;

    $gatewayFunctions = $siteRoot . '/includes/gatewayfunctions.php';
    $invoiceFunctions = $siteRoot . '/includes/invoicefunctions.php';

    if (is_file($gatewayFunctions)) {
        require_once $gatewayFunctions;
    }
    if (is_file($invoiceFunctions)) {
        require_once $invoiceFunctions;
    }

    if (function_exists('logTransaction')) {
        logTransaction('paypal', [
            'method' => $requestMethod,
            'content_type' => $contentType,
            'payload' => $rawPayload,
            'post' => $_POST,
        ], 'VoiceLink callback received');
    } else {
        $writeLog('WHMCS loaded but logTransaction() was unavailable.');
    }

    http_response_code(200);
    header('Content-Type: text/plain; charset=utf-8');
    echo "OK\n";
    exit;
}

$writeLog(sprintf(
    'Callback received without WHMCS bootstrap. Method=%s Content-Type=%s Payload=%s',
    $requestMethod,
    $contentType,
    $rawPayload === '' ? '<empty>' : $rawPayload
));

http_response_code(202);
header('Content-Type: text/plain; charset=utf-8');
echo "PayPal callback captured, but WHMCS bootstrap was not available on this deployment.\n";
