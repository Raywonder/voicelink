<?php
if (!defined("WHMCS")) {
    die("This file cannot be accessed directly");
}

function voicelink_login_config() {
    return [
        "name" => "VoiceLink Login Bridge",
        "description" => "Provides the required VoiceLink WHMCS login connector and optional local WHMCS bridge endpoints for server installs.",
        "version" => "0.1.3",
        "author" => "Devine Creations",
        "fields" => [
            "voicelink_api_url" => [
                "FriendlyName" => "VoiceLink Master API URL",
                "Type" => "text",
                "Size" => "80",
                "Default" => "https://voicelink.dev/api",
                "Description" => "Canonical VoiceLink control-plane API used for WHMCS login and account sync.",
            ],
            "official_authority_url" => [
                "FriendlyName" => "Official VoiceLink WHMCS Authority",
                "Type" => "text",
                "Size" => "80",
                "Default" => "https://devine-creations.com",
                "Description" => "Required default authority for VoiceLink paid/licensed client accounts. Local WHMCS bridges are additional, not replacements.",
            ],
            "local_whmcs_root" => [
                "FriendlyName" => "Local WHMCS Root",
                "Type" => "text",
                "Size" => "80",
                "Default" => "",
                "Description" => "Optional. Leave blank to auto-detect configuration.php and init.php in common WHM/cPanel locations.",
            ],
            "voicelink_main_url" => [
                "FriendlyName" => "VoiceLink Main Server URL",
                "Type" => "text",
                "Size" => "80",
                "Default" => "https://voicelinkapp.app",
                "Description" => "Official main VoiceLink server shown after WHMCS client login.",
            ],
            "voicelink_community_url" => [
                "FriendlyName" => "VoiceLink Community Server URL",
                "Type" => "text",
                "Size" => "80",
                "Default" => "https://community.voicelinkapp.app",
                "Description" => "Official community VoiceLink server shown after WHMCS client login.",
            ],
            "fallback_gateway_url" => [
                "FriendlyName" => "Fallback Gateway URL",
                "Type" => "text",
                "Size" => "80",
                "Default" => "https://voicelinkapp.app/api",
                "Description" => "Secondary VoiceLink API fallback when the master API is temporarily unavailable.",
            ],
            "bridge_shared_secret" => [
                "FriendlyName" => "Local Bridge Shared Secret",
                "Type" => "password",
                "Size" => "80",
                "Default" => "",
                "Description" => "Required for server-to-WHMCS local bridge checks. Leave blank to disable remote credential and license checks.",
            ],
            "allow_remote_bridge" => [
                "FriendlyName" => "Allow Remote Bridge Checks",
                "Type" => "yesno",
                "Default" => "on",
                "Description" => "Allow VoiceLink servers and desktop clients to verify this WHMCS install through the module API when the shared secret is provided.",
            ],
        ],
    ];
}

function voicelink_login_activate() {
    return ["status" => "success", "description" => "VoiceLink Login Bridge activated."];
}

function voicelink_login_deactivate() {
    return ["status" => "success", "description" => "VoiceLink Login Bridge deactivated."];
}

function voicelink_login_output($vars) {
    $apiUrl = htmlspecialchars((string) ($vars["voicelink_api_url"] ?? "https://voicelink.dev/api"), ENT_QUOTES, "UTF-8");
    $authorityUrl = htmlspecialchars((string) ($vars["official_authority_url"] ?? "https://devine-creations.com"), ENT_QUOTES, "UTF-8");
    $localRoot = htmlspecialchars((string) ($vars["local_whmcs_root"] ?? ""), ENT_QUOTES, "UTF-8");
    $mainUrl = htmlspecialchars((string) ($vars["voicelink_main_url"] ?? "https://voicelinkapp.app"), ENT_QUOTES, "UTF-8");
    $communityUrl = htmlspecialchars((string) ($vars["voicelink_community_url"] ?? "https://community.voicelinkapp.app"), ENT_QUOTES, "UTF-8");

    echo "<h2>VoiceLink Login Bridge</h2>";
    echo "<p>WHMCS login bridge is installed. VoiceLink client login uses the official authority by default, while a local WHMCS install can be linked when it is detected on this server.</p>";
    echo "<ul>";
    echo "<li>Master API: <code>{$apiUrl}</code></li>";
    echo "<li>Official authority: <code>{$authorityUrl}</code></li>";
    echo "<li>Local WHMCS root: <code>" . ($localRoot !== "" ? $localRoot : "auto-detect") . "</code></li>";
    echo "<li>Main server: <a href=\"{$mainUrl}\" target=\"_blank\" rel=\"noopener\">{$mainUrl}</a></li>";
    echo "<li>Community server: <a href=\"{$communityUrl}\" target=\"_blank\" rel=\"noopener\">{$communityUrl}</a></li>";
    echo "</ul>";
}
