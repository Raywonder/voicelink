<?php
declare(strict_types=1);

require_once __DIR__ . '/lib/VoiceLinkWhmcsBridge.php';

if (!function_exists('voicelinkwhmcs_hook_config')) {
    function voicelinkwhmcs_hook_config(): array
    {
        $defaults = voicelinkwhmcs_default_settings();
        return array_merge($defaults, [
            'downloads_label' => 'VoiceLink Downloads',
            'docs_label' => 'VoiceLink Docs',
            'support_label' => 'VoiceLink Support',
        ]);
    }
}

if (!function_exists('voicelinkwhmcs_render_client_links_html')) {
    function voicelinkwhmcs_render_client_links_html(array $config, string $title = 'VoiceLink', string $summary = '', int $clientId = 0): string
    {
        $downloadsUrl = htmlspecialchars((string) ($config['downloads_url'] ?? ''), ENT_QUOTES, 'UTF-8');
        $docsUrl = htmlspecialchars((string) ($config['docs_url'] ?? ''), ENT_QUOTES, 'UTF-8');
        $supportUrl = htmlspecialchars((string) ($config['support_url'] ?? ''), ENT_QUOTES, 'UTF-8');
        $mainServerUrl = htmlspecialchars((string) ($config['main_server_url'] ?? 'https://voicelinkapp.app'), ENT_QUOTES, 'UTF-8');
        $communityServerUrl = htmlspecialchars((string) ($config['community_server_url'] ?? 'https://community.voicelinkapp.app'), ENT_QUOTES, 'UTF-8');
        $heading = htmlspecialchars($title, ENT_QUOTES, 'UTF-8');
        $body = htmlspecialchars($summary !== '' ? $summary : 'Open VoiceLink downloads, docs, and support from your account area.', ENT_QUOTES, 'UTF-8');
        $serverLinks = voicelinkwhmcs_render_server_links_html(voicelinkwhmcs_client_server_links($config, $clientId));

        return <<<HTML
<section aria-labelledby="voicelink-client-links-heading" id="voicelink-whmcs-downloads-card" style="margin:18px 0;padding:18px;border-radius:14px;background:#0f172a;color:#fff;">
  <h2 id="voicelink-client-links-heading" style="margin-top:0;">{$heading}</h2>
  <p style="color:#cbd5e1;max-width:68ch;">{$body}</p>
  <p style="display:flex;gap:12px;flex-wrap:wrap;margin:0;">
    <a href="{$mainServerUrl}" target="_blank" rel="noopener" style="color:#bfdbfe;">VoiceLink Main Server</a>
    <a href="{$communityServerUrl}" target="_blank" rel="noopener" style="color:#bfdbfe;">VoiceLink Community Server</a>
    <a href="{$downloadsUrl}" target="_blank" rel="noopener" style="color:#93c5fd;">VoiceLink Downloads</a>
    <a href="{$docsUrl}" target="_blank" rel="noopener" style="color:#93c5fd;">VoiceLink Docs</a>
    <a href="{$supportUrl}" target="_blank" rel="noopener" style="color:#93c5fd;">VoiceLink Support</a>
  </p>
  {$serverLinks}
</section>
HTML;
    }
}

if (!function_exists('voicelinkwhmcs_render_downloads_injector')) {
    function voicelinkwhmcs_render_downloads_injector(array $config): string
    {
        $html = voicelinkwhmcs_render_client_links_html(
            $config,
            'VoiceLink Downloads',
            'VoiceLink installers, download-link email options, docs, and support stay available from your WHMCS downloads area.'
        );
        $json = json_encode($html, JSON_UNESCAPED_SLASHES | JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_AMP | JSON_HEX_QUOT);

        return <<<HTML
<script>
document.addEventListener('DOMContentLoaded', function () {
  var params = new URLSearchParams(window.location.search || '');
  var path = (window.location.pathname || '').toLowerCase();
  var isDownloadsPage = path.indexOf('downloads') !== -1 || params.get('action') === 'downloads';
  if (!isDownloadsPage || document.getElementById('voicelink-whmcs-downloads-card')) {
    return;
  }

  var targets = [
    '.downloads',
    '.download-list',
    '.client-home-panels',
    '#main-body .container',
    '#content-area',
    '.main-content',
    '.container'
  ];
  var target = null;
  for (var i = 0; i < targets.length; i += 1) {
    target = document.querySelector(targets[i]);
    if (target) break;
  }
  if (!target) {
    return;
  }

  var wrapper = document.createElement('div');
  wrapper.innerHTML = {$json};
  if (wrapper.firstElementChild) {
    target.insertBefore(wrapper.firstElementChild, target.firstChild);
  }
});
</script>
HTML;
    }
}

add_hook('AdminHomepage', 1, function () {
    $config = voicelinkwhmcs_hook_config();
    $settings = voicelinkwhmcs_fetch_download_delivery([
        'endpoint' => $config['endpoint'],
        'admin_key' => $config['admin_key'],
    ]);
    $downloadDelivery = $settings['settings'];

    echo '<section aria-labelledby="voicelink-admin-home-heading" style="margin:20px 0;padding:18px;border-radius:14px;background:#0f172a;color:#fff;">';
    echo '<h2 id="voicelink-admin-home-heading" style="margin-top:0;">VoiceLink Admin Snapshot</h2>';
    echo '<p style="color:#cbd5e1;max-width:72ch;">VoiceLink download delivery stays synced here through the same server settings API used by the desktop and web admin clients.</p>';
    echo '<ul style="margin:0 0 14px 18px;">';
    echo '<li>Direct downloads: ' . ($downloadDelivery['enableDirectDownloads'] ? 'Enabled' : 'Disabled') . '</li>';
    echo '<li>Email download links: ' . ($downloadDelivery['enableDownloadLinkEmail'] ? 'Enabled' : 'Disabled') . '</li>';
    echo '<li>TestFlight email requests: ' . ($downloadDelivery['enableTestFlightEmail'] ? 'Enabled' : 'Disabled') . '</li>';
    echo '</ul>';
    echo '<p style="margin-bottom:0;"><a href="addonmodules.php?module=voicelinkwhmcs" style="color:#93c5fd;">Open VoiceLink dashboard controls</a></p>';
    echo '</section>';
});

add_hook('ClientAreaHomepage', 1, function () {
    $config = voicelinkwhmcs_hook_config();
    $clientId = isset($_SESSION['uid']) ? (int) $_SESSION['uid'] : 0;
    return [
        'voicelink_client_home_html' => voicelinkwhmcs_render_client_links_html(
            $config,
            'VoiceLink',
            'Use the current VoiceLink servers, downloads, docs, and support pages from your client dashboard.',
            $clientId
        )
    ];
});

add_hook('ClientAreaFooterOutput', 1, function () {
    return voicelinkwhmcs_render_downloads_injector(voicelinkwhmcs_hook_config());
});
