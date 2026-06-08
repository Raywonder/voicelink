<?php
declare(strict_types=1);

require_once __DIR__ . '/lib/VoiceLinkWhmcsBridge.php';

function voicelinkwhmcs_config(): array
{
    $defaults = voicelinkwhmcs_default_settings();
    return [
        'name' => 'VoiceLink WHMCS Bridge',
        'description' => 'Adds VoiceLink dashboard controls, downloads, docs, and support links to WHMCS while reusing the main VoiceLink admin settings API.',
        'version' => '1.0.0',
        'author' => 'Devine Creations / VoiceLink',
        'fields' => [
            'endpoint' => [
                'FriendlyName' => 'VoiceLink API Base URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['endpoint'],
                'Description' => 'HTTPS VoiceLink server base used for admin settings sync.',
            ],
            'admin_key' => [
                'FriendlyName' => 'VoiceLink Admin Key',
                'Type' => 'password',
                'Size' => '50',
                'Default' => $defaults['admin_key'],
                'Description' => 'Matches VOICELINK_ADMIN_KEY on the VoiceLink server.',
            ],
            'portal_url' => [
                'FriendlyName' => 'WHMCS Portal URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['portal_url'],
                'Description' => 'Client area or account dashboard URL.',
            ],
            'downloads_url' => [
                'FriendlyName' => 'VoiceLink Downloads URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['downloads_url'],
                'Description' => 'Public downloads page to surface in WHMCS.',
            ],
            'docs_url' => [
                'FriendlyName' => 'VoiceLink Docs URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['docs_url'],
                'Description' => 'Public documentation landing page.',
            ],
            'support_url' => [
                'FriendlyName' => 'VoiceLink Support URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['support_url'],
                'Description' => 'Support page or live support entry point.',
            ],
            'main_server_url' => [
                'FriendlyName' => 'VoiceLink Main Server URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['main_server_url'],
                'Description' => 'Official main VoiceLink server shown in WHMCS client logins.',
            ],
            'community_server_url' => [
                'FriendlyName' => 'VoiceLink Community Server URL',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['community_server_url'],
                'Description' => 'Official community VoiceLink server shown in WHMCS client logins.',
            ],
            'server_directory_url' => [
                'FriendlyName' => 'VoiceLink Server Directory API',
                'Type' => 'text',
                'Size' => '70',
                'Default' => $defaults['server_directory_url'],
                'Description' => 'Public discovery API used to match client-owned domains to VoiceLink servers.',
            ],
        ],
    ];
}

function voicelinkwhmcs_activate(): array
{
    return ['status' => 'success', 'description' => 'VoiceLink WHMCS dashboard hooks are ready.'];
}

function voicelinkwhmcs_deactivate(): array
{
    return ['status' => 'success', 'description' => 'VoiceLink WHMCS dashboard hooks were disabled.'];
}

function voicelinkwhmcs_output(array $vars): void
{
    $result = voicelinkwhmcs_fetch_download_delivery($vars);
    $message = $result['message'];
    $messageType = $result['ok'] ? 'successbox' : 'warningbox';

    if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['voicelink_action'] ?? '') === 'save_download_delivery') {
        check_token('WHMCS.admin.default');
        $save = voicelinkwhmcs_save_download_delivery($vars, $_POST);
        $message = $save['message'];
        $messageType = $save['ok'] ? 'successbox' : 'errorbox';
        $result = voicelinkwhmcs_fetch_download_delivery($vars);
    }

    $settings = $result['settings'];
    $downloadsUrl = htmlspecialchars((string) ($vars['downloads_url'] ?? voicelinkwhmcs_default_settings()['downloads_url']), ENT_QUOTES, 'UTF-8');
    $docsUrl = htmlspecialchars((string) ($vars['docs_url'] ?? voicelinkwhmcs_default_settings()['docs_url']), ENT_QUOTES, 'UTF-8');
    $supportUrl = htmlspecialchars((string) ($vars['support_url'] ?? voicelinkwhmcs_default_settings()['support_url']), ENT_QUOTES, 'UTF-8');

    echo '<div class="voicelink-whmcs-admin" style="max-width:980px;">';
    if ($message) {
        echo '<div class="' . $messageType . '"><p>' . htmlspecialchars($message, ENT_QUOTES, 'UTF-8') . '</p></div>';
    }

    echo '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px;margin:18px 0 24px;">';
    echo '<a href="' . $downloadsUrl . '" target="_blank" rel="noopener" style="display:block;padding:18px;border-radius:14px;background:#0f172a;color:#fff;text-decoration:none;"><strong style="display:block;">Downloads</strong><span style="display:block;margin-top:6px;color:#cbd5e1;">Open the current VoiceLink downloads page.</span></a>';
    echo '<a href="' . $docsUrl . '" target="_blank" rel="noopener" style="display:block;padding:18px;border-radius:14px;background:#123d32;color:#fff;text-decoration:none;"><strong style="display:block;">Documentation</strong><span style="display:block;margin-top:6px;color:#d1fae5;">Open the current VoiceLink docs hub.</span></a>';
    echo '<a href="' . $supportUrl . '" target="_blank" rel="noopener" style="display:block;padding:18px;border-radius:14px;background:#3b0764;color:#fff;text-decoration:none;"><strong style="display:block;">Support</strong><span style="display:block;margin-top:6px;color:#e9d5ff;">Open VoiceLink support and live help.</span></a>';
    echo '</div>';

    echo '<form method="post">';
    echo generate_token('WHMCS.admin.default');
    echo '<input type="hidden" name="voicelink_action" value="save_download_delivery">';
    echo '<h2>Download Delivery</h2>';
    echo '<p style="max-width:70ch;color:#475569;">These toggles write to the active VoiceLink server through the existing admin settings API, so WHMCS, the VoiceLink admin client, and the public download pages stay aligned.</p>';
    echo voicelinkwhmcs_checkbox_row('enableDirectDownloads', 'Allow direct downloads', 'Leave standard download buttons active on public pages and client-facing pages.', (bool) $settings['enableDirectDownloads']);
    echo voicelinkwhmcs_checkbox_row('enableDownloadLinkEmail', 'Allow email download links', 'Let users request installer links by email from the existing VoiceLink mail sender.', (bool) $settings['enableDownloadLinkEmail']);
    echo voicelinkwhmcs_checkbox_row('enableTestFlightEmail', 'Allow TestFlight email requests', 'Send the current iOS TestFlight invite by email instead of exposing the raw link.', (bool) $settings['enableTestFlightEmail']);
    echo voicelinkwhmcs_checkbox_row('requireHumanVerification', 'Require human confirmation', 'Keep the checkbox-based human check enabled before link requests are accepted.', (bool) $settings['requireHumanVerification']);
    echo voicelinkwhmcs_checkbox_row('logSourceContext', 'Log source context', 'Store request source metadata such as install ID, channel, and linked account IDs.', (bool) $settings['logSourceContext']);
    echo voicelinkwhmcs_checkbox_row('notifyAdminOnEmailRequests', 'Notify admins on link requests', 'Send a notification email to the configured VoiceLink admin recipient when requests are made.', (bool) $settings['notifyAdminOnEmailRequests']);
    echo '<p><button type="submit" class="btn btn-primary">Save VoiceLink Settings</button></p>';
    echo '</form>';
    echo '</div>';
}

function voicelinkwhmcs_clientarea(array $vars): array
{
    $config = array_merge(voicelinkwhmcs_default_settings(), $vars);
    $downloadsUrl = htmlspecialchars((string) ($vars['downloads_url'] ?? voicelinkwhmcs_default_settings()['downloads_url']), ENT_QUOTES, 'UTF-8');
    $docsUrl = htmlspecialchars((string) ($vars['docs_url'] ?? voicelinkwhmcs_default_settings()['docs_url']), ENT_QUOTES, 'UTF-8');
    $supportUrl = htmlspecialchars((string) ($vars['support_url'] ?? voicelinkwhmcs_default_settings()['support_url']), ENT_QUOTES, 'UTF-8');
    $mainServerUrl = htmlspecialchars((string) ($vars['main_server_url'] ?? voicelinkwhmcs_default_settings()['main_server_url']), ENT_QUOTES, 'UTF-8');
    $communityServerUrl = htmlspecialchars((string) ($vars['community_server_url'] ?? voicelinkwhmcs_default_settings()['community_server_url']), ENT_QUOTES, 'UTF-8');
    $clientId = isset($_SESSION['uid']) ? (int) $_SESSION['uid'] : 0;
    $serverLinks = voicelinkwhmcs_render_server_links_html(voicelinkwhmcs_client_server_links($config, $clientId));

    $html = <<<HTML
<section aria-labelledby="voicelink-whmcs-client-heading" style="margin:18px 0;padding:20px;border-radius:16px;background:#0f172a;color:#e5eefb;">
  <h2 id="voicelink-whmcs-client-heading" style="margin-top:0;">VoiceLink Access</h2>
  <p style="max-width:70ch;color:#cbd5e1;">Open servers, downloads, documentation, and support from the same place you manage your VoiceLink services.</p>
  <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px;">
    <a href="{$mainServerUrl}" target="_blank" rel="noopener" style="display:block;padding:16px;border-radius:12px;background:#162033;color:#fff;text-decoration:none;">Open Main Server</a>
    <a href="{$communityServerUrl}" target="_blank" rel="noopener" style="display:block;padding:16px;border-radius:12px;background:#162033;color:#fff;text-decoration:none;">Open Community Server</a>
    <a href="{$downloadsUrl}" target="_blank" rel="noopener" style="display:block;padding:16px;border-radius:12px;background:#162033;color:#fff;text-decoration:none;">Open Downloads</a>
    <a href="{$docsUrl}" target="_blank" rel="noopener" style="display:block;padding:16px;border-radius:12px;background:#17342b;color:#fff;text-decoration:none;">Open Docs</a>
    <a href="{$supportUrl}" target="_blank" rel="noopener" style="display:block;padding:16px;border-radius:12px;background:#30204a;color:#fff;text-decoration:none;">Open Support</a>
  </div>
  {$serverLinks}
</section>
HTML;

    return [
        'pagetitle' => 'VoiceLink',
        'breadcrumb' => ['index.php?m=voicelinkwhmcs' => 'VoiceLink'],
        'templatefile' => 'clienthome',
        'requirelogin' => false,
        'vars' => [
            'voicelinkHtml' => $html,
        ],
    ];
}
