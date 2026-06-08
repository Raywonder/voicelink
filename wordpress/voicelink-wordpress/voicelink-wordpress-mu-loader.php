<?php
/**
 * Plugin Name: VoiceLink WordPress MU Loader
 * Description: Loads the standard VoiceLink plugin from the plugins directory when the site uses a constrained plugin activation model.
 */

if (!defined('ABSPATH')) {
    exit;
}

$voicelink_plugin = trailingslashit(WP_PLUGIN_DIR) . 'voicelink-wordpress/voicelink-wordpress.php';

if (file_exists($voicelink_plugin)) {
    require_once $voicelink_plugin;
}
