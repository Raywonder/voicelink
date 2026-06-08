<?php
declare(strict_types=1);

function voicelinkwhmcs_default_settings(): array
{
    return [
        'endpoint' => 'https://voicelink.dev',
        'admin_key' => '',
        'portal_url' => 'https://devine-creations.com/clientarea.php',
        'downloads_url' => 'https://voicelinkapp.app/downloads.html',
        'docs_url' => 'https://voicelinkapp.app/docs/index.html',
        'support_url' => 'https://voicelinkapp.app/docs/contact.html#live-chat',
        'main_server_url' => 'https://voicelinkapp.app',
        'community_server_url' => 'https://community.voicelinkapp.app',
        'server_directory_url' => 'https://voicelink.dev/api/discovery/servers',
    ];
}

function voicelinkwhmcs_normalize_base(string $base): string
{
    $trimmed = trim($base);
    if ($trimmed === '') {
        $trimmed = voicelinkwhmcs_default_settings()['endpoint'];
    }
    if (!preg_match('#^https?://#i', $trimmed)) {
        $trimmed = 'https://' . $trimmed;
    }
    return rtrim($trimmed, '/');
}

function voicelinkwhmcs_admin_request(string $method, string $url, string $adminKey, ?array $payload = null): array
{
    $headers = [
        'Accept: application/json',
        'X-Admin-Key: ' . trim($adminKey),
    ];
    $context = [
        'http' => [
            'method' => strtoupper($method),
            'timeout' => 12,
            'ignore_errors' => true,
            'header' => implode("\r\n", $headers),
        ],
    ];

    if ($payload !== null) {
        $json = json_encode($payload, JSON_UNESCAPED_SLASHES);
        $context['http']['content'] = $json === false ? '{}' : $json;
        $context['http']['header'] .= "\r\nContent-Type: application/json";
    }

    $result = @file_get_contents($url, false, stream_context_create($context));
    $statusCode = 0;
    foreach ($http_response_header ?? [] as $header) {
        if (preg_match('#^HTTP/\S+\s+(\d{3})#', $header, $matches) === 1) {
            $statusCode = (int) $matches[1];
            break;
        }
    }

    $decoded = is_string($result) && $result !== '' ? json_decode($result, true) : null;
    return [
        'ok' => $statusCode >= 200 && $statusCode < 300,
        'status' => $statusCode,
        'data' => is_array($decoded) ? $decoded : null,
        'raw' => is_string($result) ? $result : '',
    ];
}

function voicelinkwhmcs_public_json_request(string $url): array
{
    $context = [
        'http' => [
            'method' => 'GET',
            'timeout' => 8,
            'ignore_errors' => true,
            'header' => "Accept: application/json\r\n",
        ],
    ];

    $result = @file_get_contents($url, false, stream_context_create($context));
    $statusCode = 0;
    foreach ($http_response_header ?? [] as $header) {
        if (preg_match('#^HTTP/\S+\s+(\d{3})#', $header, $matches) === 1) {
            $statusCode = (int) $matches[1];
            break;
        }
    }

    $decoded = is_string($result) && $result !== '' ? json_decode($result, true) : null;
    return [
        'ok' => $statusCode >= 200 && $statusCode < 300,
        'status' => $statusCode,
        'data' => is_array($decoded) ? $decoded : null,
    ];
}

function voicelinkwhmcs_url_host(string $url): string
{
    $host = parse_url($url, PHP_URL_HOST);
    return is_string($host) ? strtolower($host) : '';
}

function voicelinkwhmcs_client_domains(int $clientId): array
{
    if ($clientId <= 0 || !class_exists('\\WHMCS\\Database\\Capsule')) {
        return [];
    }

    try {
        $rows = \WHMCS\Database\Capsule::table('tbldomains')
            ->where('userid', $clientId)
            ->whereIn('status', ['Active', 'Pending', 'Pending Transfer'])
            ->pluck('domain');
    } catch (\Throwable $error) {
        return [];
    }

    $domains = [];
    foreach ($rows as $domain) {
        $normalized = strtolower(trim((string) $domain));
        if ($normalized !== '') {
            $domains[$normalized] = true;
        }
    }
    return array_keys($domains);
}

function voicelinkwhmcs_static_server_catalog(array $config): array
{
    return [
        [
            'name' => 'VoiceLink Main',
            'url' => (string) ($config['main_server_url'] ?? 'https://voicelinkapp.app'),
            'summary' => 'Official VoiceLink server for sign-in, downloads, status, and general rooms.',
            'scope' => 'official',
        ],
        [
            'name' => 'VoiceLink Community',
            'url' => (string) ($config['community_server_url'] ?? 'https://community.voicelinkapp.app'),
            'summary' => 'Official VoiceLink community server.',
            'scope' => 'official',
        ],
        [
            'name' => 'Devine Creations VoiceLink',
            'url' => 'https://devine-creations.com/voicelink',
            'summary' => 'Domain-owned VoiceLink server for devine-creations.com.',
            'scope' => 'domain',
            'domains' => ['devine-creations.com'],
        ],
        [
            'name' => 'DevineCreations.net VoiceLink',
            'url' => 'https://devinecreations.net/voicelink',
            'summary' => 'Domain-owned VoiceLink server for devinecreations.net.',
            'scope' => 'domain',
            'domains' => ['devinecreations.net'],
        ],
    ];
}

function voicelinkwhmcs_discovered_servers(array $config): array
{
    $directoryUrl = (string) ($config['server_directory_url'] ?? voicelinkwhmcs_default_settings()['server_directory_url']);
    $response = voicelinkwhmcs_public_json_request($directoryUrl);
    if (!$response['ok'] || !is_array($response['data'])) {
        return [];
    }

    $payload = $response['data'];
    $items = $payload['servers'] ?? $payload['data']['servers'] ?? $payload['data'] ?? $payload;
    if (!is_array($items)) {
        return [];
    }

    $servers = [];
    foreach ($items as $item) {
        if (!is_array($item)) {
            continue;
        }
        $url = (string) ($item['url'] ?? $item['siteUrl'] ?? $item['apiUrl'] ?? '');
        if ($url === '') {
            continue;
        }
        $servers[] = [
            'name' => (string) ($item['name'] ?? $item['displayName'] ?? voicelinkwhmcs_url_host($url) ?: 'VoiceLink Server'),
            'url' => $url,
            'summary' => (string) ($item['description'] ?? $item['summary'] ?? ''),
            'scope' => !empty($item['official']) ? 'official' : 'directory',
            'domains' => array_filter([
                (string) ($item['domain'] ?? ''),
                voicelinkwhmcs_url_host($url),
            ]),
            'authRequired' => $item['authRequired'] ?? null,
            'allowGuests' => $item['allowGuests'] ?? null,
            'verification' => $item['verification']['status'] ?? $item['verificationStatus'] ?? null,
        ];
    }

    return $servers;
}

function voicelinkwhmcs_server_matches_client(array $server, array $clientDomains): bool
{
    if (($server['scope'] ?? '') === 'official') {
        return true;
    }

    $serverDomains = $server['domains'] ?? [];
    $serverHost = voicelinkwhmcs_url_host((string) ($server['url'] ?? ''));
    if ($serverHost !== '') {
        $serverDomains[] = $serverHost;
    }

    foreach ($clientDomains as $clientDomain) {
        foreach ($serverDomains as $serverDomain) {
            $normalizedServerDomain = strtolower(trim((string) $serverDomain));
            if ($normalizedServerDomain === '') {
                continue;
            }
            if ($normalizedServerDomain === $clientDomain || str_ends_with($normalizedServerDomain, '.' . $clientDomain)) {
                return true;
            }
        }
    }

    return false;
}

function voicelinkwhmcs_client_server_links(array $config, int $clientId = 0): array
{
    $clientDomains = voicelinkwhmcs_client_domains($clientId);
    $servers = array_merge(voicelinkwhmcs_static_server_catalog($config), voicelinkwhmcs_discovered_servers($config));
    $links = [];

    foreach ($servers as $server) {
        if (!voicelinkwhmcs_server_matches_client($server, $clientDomains)) {
            continue;
        }

        $url = voicelinkwhmcs_normalize_base((string) ($server['url'] ?? ''));
        if ($url === '') {
            continue;
        }

        $key = strtolower($url);
        $links[$key] = [
            'name' => (string) ($server['name'] ?? 'VoiceLink Server'),
            'url' => $url,
            'summary' => (string) ($server['summary'] ?? ''),
            'scope' => (string) ($server['scope'] ?? 'directory'),
            'authRequired' => $server['authRequired'] ?? null,
            'allowGuests' => $server['allowGuests'] ?? null,
            'verification' => $server['verification'] ?? null,
        ];
    }

    return array_values($links);
}

function voicelinkwhmcs_render_server_links_html(array $servers): string
{
    if (empty($servers)) {
        return '<p style="color:#cbd5e1;">No VoiceLink servers are linked to this WHMCS account yet. Use the official server links above or contact support to attach a domain-owned server.</p>';
    }

    $rows = '';
    foreach ($servers as $server) {
        $name = htmlspecialchars((string) ($server['name'] ?? 'VoiceLink Server'), ENT_QUOTES, 'UTF-8');
        $url = htmlspecialchars((string) ($server['url'] ?? ''), ENT_QUOTES, 'UTF-8');
        $summary = htmlspecialchars((string) ($server['summary'] ?? ''), ENT_QUOTES, 'UTF-8');
        $scope = htmlspecialchars((string) ($server['scope'] ?? 'server'), ENT_QUOTES, 'UTF-8');
        $auth = ($server['authRequired'] ?? null) === true ? 'Sign-in required' : (($server['allowGuests'] ?? null) === true ? 'Guest access available' : 'Use server policy');
        $auth = htmlspecialchars($auth, ENT_QUOTES, 'UTF-8');
        $verification = htmlspecialchars((string) ($server['verification'] ?? 'configured'), ENT_QUOTES, 'UTF-8');

        $rows .= <<<HTML
<tr>
  <th scope="row"><a href="{$url}" target="_blank" rel="noopener" style="color:#bfdbfe;">{$name}</a></th>
  <td>{$scope}</td>
  <td>{$auth}</td>
  <td>{$verification}</td>
  <td>{$summary}</td>
</tr>
HTML;
    }

    return <<<HTML
<div style="margin-top:18px;overflow-x:auto;">
  <table style="width:100%;border-collapse:collapse;color:#e5eefb;">
    <caption style="text-align:left;color:#cbd5e1;margin-bottom:8px;">VoiceLink servers available from this WHMCS login</caption>
    <thead>
      <tr>
        <th scope="col" style="text-align:left;border-bottom:1px solid #334155;padding:8px;">Server</th>
        <th scope="col" style="text-align:left;border-bottom:1px solid #334155;padding:8px;">Scope</th>
        <th scope="col" style="text-align:left;border-bottom:1px solid #334155;padding:8px;">Access</th>
        <th scope="col" style="text-align:left;border-bottom:1px solid #334155;padding:8px;">Status</th>
        <th scope="col" style="text-align:left;border-bottom:1px solid #334155;padding:8px;">Notes</th>
      </tr>
    </thead>
    <tbody>{$rows}</tbody>
  </table>
</div>
HTML;
}

function voicelinkwhmcs_fetch_download_delivery(array $vars): array
{
    $settings = array_merge(voicelinkwhmcs_default_settings(), [
        'endpoint' => (string) ($vars['endpoint'] ?? ''),
        'admin_key' => (string) ($vars['admin_key'] ?? ''),
    ]);

    $response = voicelinkwhmcs_admin_request(
        'GET',
        voicelinkwhmcs_normalize_base($settings['endpoint']) . '/api/admin/settings',
        $settings['admin_key']
    );

    if (!$response['ok'] || !is_array($response['data'])) {
        return [
            'ok' => false,
            'status' => $response['status'],
            'message' => 'VoiceLink settings could not be loaded from the configured server.',
            'settings' => [
                'enableDirectDownloads' => true,
                'enableDownloadLinkEmail' => true,
                'enableTestFlightEmail' => true,
                'requireHumanVerification' => true,
                'logSourceContext' => true,
                'notifyAdminOnEmailRequests' => true,
            ],
        ];
    }

    $downloadDelivery = $response['data']['securitySettings']['downloadDelivery'] ?? [];
    return [
        'ok' => true,
        'status' => $response['status'],
        'message' => null,
        'settings' => [
            'enableDirectDownloads' => ($downloadDelivery['enableDirectDownloads'] ?? true) !== false,
            'enableDownloadLinkEmail' => ($downloadDelivery['enableDownloadLinkEmail'] ?? true) !== false,
            'enableTestFlightEmail' => ($downloadDelivery['enableTestFlightEmail'] ?? true) !== false,
            'requireHumanVerification' => ($downloadDelivery['requireHumanVerification'] ?? true) !== false,
            'logSourceContext' => ($downloadDelivery['logSourceContext'] ?? true) !== false,
            'notifyAdminOnEmailRequests' => ($downloadDelivery['notifyAdminOnEmailRequests'] ?? true) !== false,
        ],
    ];
}

function voicelinkwhmcs_save_download_delivery(array $vars, array $input): array
{
    $endpoint = voicelinkwhmcs_normalize_base((string) ($vars['endpoint'] ?? ''));
    $adminKey = (string) ($vars['admin_key'] ?? '');
    $payload = [
        'securitySettings' => [
            'downloadDelivery' => [
                'enableDirectDownloads' => !empty($input['enableDirectDownloads']),
                'enableDownloadLinkEmail' => !empty($input['enableDownloadLinkEmail']),
                'enableTestFlightEmail' => !empty($input['enableTestFlightEmail']),
                'requireHumanVerification' => !empty($input['requireHumanVerification']),
                'logSourceContext' => !empty($input['logSourceContext']),
                'notifyAdminOnEmailRequests' => !empty($input['notifyAdminOnEmailRequests']),
            ],
        ],
    ];

    $response = voicelinkwhmcs_admin_request('POST', $endpoint . '/api/admin/settings', $adminKey, $payload);
    return [
        'ok' => $response['ok'],
        'status' => $response['status'],
        'message' => $response['ok']
            ? 'VoiceLink download delivery settings were saved.'
            : 'VoiceLink download delivery settings could not be saved.',
    ];
}

function voicelinkwhmcs_checkbox_row(string $name, string $label, string $description, bool $checked): string
{
    $isChecked = $checked ? ' checked' : '';
    $id = 'voicelink-' . $name;
    return <<<HTML
<label for="{$id}" style="display:block;border:1px solid #dce3ee;border-radius:12px;padding:14px 16px;margin-bottom:12px;background:#fff;">
  <span style="display:flex;align-items:flex-start;gap:12px;">
    <input id="{$id}" name="{$name}" type="checkbox" value="1"{$isChecked} style="margin-top:2px;">
    <span>
      <strong style="display:block;color:#0f172a;">{$label}</strong>
      <span style="display:block;color:#475569;margin-top:4px;">{$description}</span>
    </span>
  </span>
</label>
HTML;
}
