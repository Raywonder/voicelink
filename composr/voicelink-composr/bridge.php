<?php
/**
 * VoiceLink Composr Bridge
 *
 * Intended to live inside a real Composr tree, typically under
 * sources_custom/voicelink/bridge.php or another custom addon path.
 *
 * This bridge does not take over the site root. It exposes enough member,
 * role, and ownership context for VoiceLink to:
 * - link existing Composr members to VoiceLink identities
 * - map Composr roles to VoiceLink roles
 * - attach a newly deployed VoiceLink server to an existing owner identity
 */

if (!defined('VOICELINK_COMPOSR_BRIDGE')) {
    define('VOICELINK_COMPOSR_BRIDGE', true);
}

function voicelink_composr_bridge_response($payload, $status = 200) {
    if (!headers_sent()) {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
    }
    echo json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

function voicelink_composr_detect_context() {
    $has_member_api = function_exists('get_member') && isset($GLOBALS['FORUM_DRIVER']);
    $member_id = $has_member_api ? intval(get_member()) : null;
    $is_logged_in = $has_member_api && ($member_id !== null) && ($member_id > 0);

    $username = null;
    $email = null;
    $display_name = null;
    $roles = array();
    $primary_role = 'user';

    if ($is_logged_in) {
        if (method_exists($GLOBALS['FORUM_DRIVER'], 'get_username')) {
            $username = $GLOBALS['FORUM_DRIVER']->get_username($member_id, true);
            $display_name = $GLOBALS['FORUM_DRIVER']->get_username($member_id, false);
        }
        if (method_exists($GLOBALS['FORUM_DRIVER'], 'get_member_row_field')) {
            $email = $GLOBALS['FORUM_DRIVER']->get_member_row_field($member_id, 'm_email_address');
        }
        if (method_exists($GLOBALS['FORUM_DRIVER'], 'is_super_admin') && $GLOBALS['FORUM_DRIVER']->is_super_admin($member_id)) {
            $roles[] = 'super_admin';
            $primary_role = 'owner';
        } elseif (method_exists($GLOBALS['FORUM_DRIVER'], 'is_staff') && $GLOBALS['FORUM_DRIVER']->is_staff($member_id)) {
            $roles[] = 'staff';
            $primary_role = 'admin';
        } else {
            $roles[] = 'member';
        }
    }

    $site_host = isset($_SERVER['HTTP_HOST']) ? strtolower((string) $_SERVER['HTTP_HOST']) : null;
    $aliases = array();
    if (!empty($email)) {
        $aliases[] = strtolower($email);
        $domain = substr(strrchr($email, '@'), 1);
        if (!empty($domain)) {
            $aliases[] = '*@' . strtolower($domain);
        }
    }
    if (!empty($username)) {
        $aliases[] = strtolower($username);
    }
    if (!empty($site_host)) {
        $aliases[] = $site_host;
        $aliases[] = '*.' . $site_host;
    }

    return array(
        'success' => true,
        'provider' => 'composr',
        'composrContextDetected' => $has_member_api,
        'siteHost' => $site_host,
        'installPath' => __FILE__,
        'member' => array(
            'loggedIn' => $is_logged_in,
            'id' => $member_id,
            'username' => $username,
            'email' => $email,
            'displayName' => $display_name ?: $username,
            'roles' => array_values(array_unique(array_filter($roles))),
            'primaryRole' => $primary_role,
        ),
        'voiceLink' => array(
            'role' => $primary_role,
            'identityAliases' => array_values(array_unique(array_filter($aliases))),
            'sharedIdentityHint' => !empty($email) ? strtolower($email) : (!empty($username) ? strtolower($username) : null),
            'notes' => array(
                'Use this bridge to link existing Composr members into the same VoiceLink identity when email or ownership already matches another server.',
                'Deploy beside the CMS and preserve the site root by default.',
                'Map Composr staff or super-admins to elevated VoiceLink management roles on the owned server.'
            )
        )
    );
}

voicelink_composr_bridge_response(voicelink_composr_detect_context());
