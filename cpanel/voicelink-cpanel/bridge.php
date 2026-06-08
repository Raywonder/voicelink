<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

$siteRoot = dirname(__DIR__, 3);
$publicHtml = $siteRoot . '/public_html';
$cpanelRoot = $siteRoot . '/.cpanel';
$sharedRoot = $publicHtml . '/shared/voicelink';

$data = [
    'provider' => 'cpanel',
    'detected' => is_dir($publicHtml) || is_dir($cpanelRoot),
    'siteRoot' => $siteRoot,
    'publicHtml' => $publicHtml,
    'cpanelRoot' => $cpanelRoot,
    'sharedFileRoot' => $sharedRoot,
    'capabilities' => [
        'fileManager' => is_dir($publicHtml),
        'sharedFiles' => true,
        'databaseHooks' => true,
        'ownedDomainDetection' => true
    ]
];

echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
