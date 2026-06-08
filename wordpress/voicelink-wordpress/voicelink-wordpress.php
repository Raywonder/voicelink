<?php
/**
 * Plugin Name: VoiceLink for WordPress
 * Plugin URI: https://voicelink.devinecreations.net/
 * Description: Embed VoiceLink in WordPress, create the standard VoiceLink pages, and expose WordPress account data for linked VoiceLink authentication and deployment.
 * Version: 1.0.0
 * Author: Devine Creations
 * Author URI: https://devine-creations.com/
 * Text Domain: voicelink-wordpress
 */

if (!defined('ABSPATH')) {
    exit;
}

define('VOICELINK_WP_VERSION', '1.0.0');
define('VOICELINK_WP_OPTION', 'voicelink_wp_settings');
define('VOICELINK_WP_PAGE_OPTION', 'voicelink_wp_pages');

function voicelink_wp_plugin_file_present($relative_path) {
    return file_exists(trailingslashit(WP_PLUGIN_DIR) . ltrim($relative_path, '/'));
}

function voicelink_wp_is_plugin_active_safe($plugin_file) {
    if (!function_exists('is_plugin_active')) {
        require_once ABSPATH . 'wp-admin/includes/plugin.php';
    }
    return function_exists('is_plugin_active') ? is_plugin_active($plugin_file) : false;
}

function voicelink_wp_known_helper_plugins() {
    return array(
        'activitypub' => array(
            'file' => 'activitypub/activitypub.php',
            'category' => 'federation',
            'label' => 'ActivityPub'
        ),
        'enable_mastodon_apps' => array(
            'file' => 'enable-mastodon-apps/enable-mastodon-apps.php',
            'category' => 'federation',
            'label' => 'Enable Mastodon Apps'
        ),
        'mastodon_login' => array(
            'file' => 'mastodon-login/mastodon-login.php',
            'category' => 'auth',
            'label' => 'Mastodon Login'
        ),
        'mastodon_oauth2' => array(
            'file' => 'mastodon-oauth2/mastodon-oauth2.php',
            'category' => 'auth',
            'label' => 'Mastodon OAuth2'
        ),
        'oauth2_provider' => array(
            'file' => 'oauth2-provider/oauth2-provider.php',
            'category' => 'auth',
            'label' => 'OAuth2 Provider'
        ),
        'tappedin_oauth2_provider' => array(
            'file' => 'tappedin-oauth2-provider/tappedin-oauth2-provider.php',
            'category' => 'auth',
            'label' => 'TappedIn OAuth2 Provider'
        ),
        'whmcs_bridge' => array(
            'file' => 'whmcs-bridge/whmcs-bridge.php',
            'category' => 'billing',
            'label' => 'WHMCS Bridge'
        ),
        'wordfence' => array(
            'file' => 'wordfence/wordfence.php',
            'category' => 'security',
            'label' => 'Wordfence'
        ),
        'wp_mail_smtp' => array(
            'file' => 'wp-mail-smtp/wp_mail_smtp.php',
            'category' => 'email',
            'label' => 'WP Mail SMTP'
        ),
        'updraftplus' => array(
            'file' => 'updraftplus/updraftplus.php',
            'category' => 'backup',
            'label' => 'UpdraftPlus'
        ),
    );
}

function voicelink_wp_helper_plugin_inventory() {
    $inventory = array();
    foreach (voicelink_wp_known_helper_plugins() as $key => $plugin) {
        $plugin_file = $plugin['file'];
        $inventory[$key] = array(
            'label' => $plugin['label'],
            'category' => $plugin['category'],
            'file' => $plugin_file,
            'installed' => voicelink_wp_plugin_file_present($plugin_file),
            'active' => voicelink_wp_is_plugin_active_safe($plugin_file),
        );
    }
    return $inventory;
}

function voicelink_wp_auth_diagnostics() {
    $wordfence_plugin = 'wordfence/wordfence.php';
    $wordfence_present = voicelink_wp_plugin_file_present($wordfence_plugin);
    $wordfence_active = $wordfence_present && voicelink_wp_is_plugin_active_safe($wordfence_plugin);
    $waf_bootstrap = trailingslashit(ABSPATH) . 'wordfence-waf.php';
    $application_passwords_available = function_exists('wp_is_application_passwords_available')
        ? wp_is_application_passwords_available()
        : false;
    $application_passwords_user_available = function_exists('wp_is_application_passwords_available_for_user') && is_user_logged_in()
        ? wp_is_application_passwords_available_for_user(wp_get_current_user())
        : $application_passwords_available;

    return array(
        'restApiUrl' => get_rest_url(),
        'applicationPasswordsAvailable' => $application_passwords_available,
        'applicationPasswordsAvailableForCurrentUser' => $application_passwords_user_available,
        'restNonceAvailable' => is_user_logged_in() ? wp_create_nonce('wp_rest') : null,
        'xmlRpcEnabled' => apply_filters('xmlrpc_enabled', true),
        'wordfence' => array(
            'installed' => $wordfence_present,
            'active' => $wordfence_active,
            'wafBootstrapPresent' => file_exists($waf_bootstrap),
        ),
        'helperPlugins' => voicelink_wp_helper_plugin_inventory(),
    );
}

function voicelink_wp_primary_role($roles) {
    $roles = is_array($roles) ? $roles : array();
    $priority = array('administrator', 'editor', 'author', 'contributor', 'subscriber');
    foreach ($priority as $role) {
        if (in_array($role, $roles, true)) {
            return $role;
        }
    }
    return !empty($roles) ? reset($roles) : 'subscriber';
}

function voicelink_wp_map_role_to_voicelink($roles) {
    $primary = voicelink_wp_primary_role($roles);
    $map = array(
        'administrator' => 'owner',
        'editor' => 'admin',
        'author' => 'moderator',
        'contributor' => 'member',
        'subscriber' => 'user',
        'shop_manager' => 'admin',
        'customer' => 'user',
    );
    return isset($map[$primary]) ? $map[$primary] : 'user';
}

function voicelink_wp_identity_aliases($user) {
    $aliases = array();
    if ($user instanceof WP_User) {
        if (!empty($user->user_email)) {
            $aliases[] = strtolower($user->user_email);
            $email_domain = substr(strrchr($user->user_email, '@'), 1);
            if (!empty($email_domain)) {
                $aliases[] = '*@' . strtolower($email_domain);
            }
        }
        if (!empty($user->user_login)) {
            $aliases[] = strtolower($user->user_login);
        }
    }
    $host = wp_parse_url(home_url('/'), PHP_URL_HOST);
    if (!empty($host)) {
        $host = strtolower($host);
        $aliases[] = $host;
        $aliases[] = '*.' . $host;
    }
    return array_values(array_unique(array_filter($aliases)));
}

function voicelink_wp_default_settings() {
    return array(
        'app_url' => 'https://voicelink.devinecreations.net/client/',
        'downloads_url' => 'https://voicelink.devinecreations.net/downloads-enhanced.html',
        'docs_url' => 'https://voicelink.devinecreations.net/docs/',
        'main_api' => 'https://voicelink.devinecreations.net',
        'community_api' => 'https://node2.voicelink.devinecreations.net',
        'embed_mode' => 'iframe',
        'auto_create_pages' => 1,
        'show_header_links' => 1,
        'allow_root_path_mode' => 0,
    );
}

function voicelink_wp_get_settings() {
    return wp_parse_args(get_option(VOICELINK_WP_OPTION, array()), voicelink_wp_default_settings());
}

function voicelink_wp_activate() {
    if (!get_option(VOICELINK_WP_OPTION)) {
        add_option(VOICELINK_WP_OPTION, voicelink_wp_default_settings());
    }

    $settings = voicelink_wp_get_settings();
    if (!empty($settings['auto_create_pages'])) {
        voicelink_wp_create_default_pages();
    }
}
register_activation_hook(__FILE__, 'voicelink_wp_activate');

function voicelink_wp_create_default_pages() {
    $definitions = array(
        'app' => array(
            'title' => 'VoiceLink',
            'slug' => 'voicelink',
            'shortcode' => '[voicelink_app]',
        ),
        'downloads' => array(
            'title' => 'VoiceLink Downloads',
            'slug' => 'voicelink-downloads',
            'shortcode' => '[voicelink_downloads]',
        ),
        'server_setup' => array(
            'title' => 'VoiceLink Server Setup',
            'slug' => 'voicelink-server-setup',
            'shortcode' => '[voicelink_server_setup]',
        ),
        'help' => array(
            'title' => 'VoiceLink Help',
            'slug' => 'voicelink-help',
            'shortcode' => '[voicelink_docs]',
        ),
    );

    $page_map = get_option(VOICELINK_WP_PAGE_OPTION, array());

    foreach ($definitions as $key => $definition) {
        $page_id = isset($page_map[$key]) ? intval($page_map[$key]) : 0;
        if ($page_id && get_post($page_id)) {
            continue;
        }

        $existing = get_page_by_path($definition['slug']);
        if ($existing instanceof WP_Post) {
            $page_map[$key] = $existing->ID;
            continue;
        }

        $created = wp_insert_post(array(
            'post_title' => $definition['title'],
            'post_name' => $definition['slug'],
            'post_status' => 'publish',
            'post_type' => 'page',
            'post_content' => $definition['shortcode'],
        ));

        if (!is_wp_error($created) && $created) {
            $page_map[$key] = $created;
        }
    }

    update_option(VOICELINK_WP_PAGE_OPTION, $page_map);
}

function voicelink_wp_admin_menu() {
    add_options_page(
        'VoiceLink for WordPress',
        'VoiceLink',
        'manage_options',
        'voicelink-wordpress',
        'voicelink_wp_render_settings_page'
    );
}
add_action('admin_menu', 'voicelink_wp_admin_menu');

function voicelink_wp_register_settings() {
    register_setting('voicelink_wp_settings_group', VOICELINK_WP_OPTION, 'voicelink_wp_sanitize_settings');
}
add_action('admin_init', 'voicelink_wp_register_settings');

function voicelink_wp_sanitize_settings($input) {
    $defaults = voicelink_wp_default_settings();
    $output = array();

    $output['app_url'] = esc_url_raw($input['app_url'] ?? $defaults['app_url']);
    $output['downloads_url'] = esc_url_raw($input['downloads_url'] ?? $defaults['downloads_url']);
    $output['docs_url'] = esc_url_raw($input['docs_url'] ?? $defaults['docs_url']);
    $output['main_api'] = esc_url_raw($input['main_api'] ?? $defaults['main_api']);
    $output['community_api'] = esc_url_raw($input['community_api'] ?? $defaults['community_api']);
    $output['embed_mode'] = in_array(($input['embed_mode'] ?? ''), array('iframe', 'link'), true) ? $input['embed_mode'] : $defaults['embed_mode'];
    $output['auto_create_pages'] = empty($input['auto_create_pages']) ? 0 : 1;
    $output['show_header_links'] = empty($input['show_header_links']) ? 0 : 1;
    $output['allow_root_path_mode'] = empty($input['allow_root_path_mode']) ? 0 : 1;

    return $output;
}

function voicelink_wp_render_settings_page() {
    if (!current_user_can('manage_options')) {
        return;
    }

    $settings = voicelink_wp_get_settings();
    $pages = get_option(VOICELINK_WP_PAGE_OPTION, array());
    ?>
    <div class="wrap">
        <h1>VoiceLink for WordPress</h1>
        <p>Use this plugin when you want to add VoiceLink to an existing WordPress site without replacing the full website root.</p>

        <form method="post" action="options.php">
            <?php settings_fields('voicelink_wp_settings_group'); ?>
            <table class="form-table" role="presentation">
                <tr>
                    <th scope="row"><label for="voicelink_app_url">VoiceLink App URL</label></th>
                    <td><input name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[app_url]" id="voicelink_app_url" type="url" class="regular-text" value="<?php echo esc_attr($settings['app_url']); ?>"></td>
                </tr>
                <tr>
                    <th scope="row"><label for="voicelink_downloads_url">Downloads URL</label></th>
                    <td><input name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[downloads_url]" id="voicelink_downloads_url" type="url" class="regular-text" value="<?php echo esc_attr($settings['downloads_url']); ?>"></td>
                </tr>
                <tr>
                    <th scope="row"><label for="voicelink_docs_url">Docs URL</label></th>
                    <td><input name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[docs_url]" id="voicelink_docs_url" type="url" class="regular-text" value="<?php echo esc_attr($settings['docs_url']); ?>"></td>
                </tr>
                <tr>
                    <th scope="row"><label for="voicelink_main_api">Main API</label></th>
                    <td><input name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[main_api]" id="voicelink_main_api" type="url" class="regular-text" value="<?php echo esc_attr($settings['main_api']); ?>"></td>
                </tr>
                <tr>
                    <th scope="row"><label for="voicelink_community_api">Community API</label></th>
                    <td><input name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[community_api]" id="voicelink_community_api" type="url" class="regular-text" value="<?php echo esc_attr($settings['community_api']); ?>"></td>
                </tr>
                <tr>
                    <th scope="row"><label for="voicelink_embed_mode">Embed Mode</label></th>
                    <td>
                        <select name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[embed_mode]" id="voicelink_embed_mode">
                            <option value="iframe" <?php selected($settings['embed_mode'], 'iframe'); ?>>Embedded iframe</option>
                            <option value="link" <?php selected($settings['embed_mode'], 'link'); ?>>Open full VoiceLink page</option>
                        </select>
                        <p class="description">Use iframe mode for an integrated page. Use link mode when the full app should open separately.</p>
                    </td>
                </tr>
                <tr>
                    <th scope="row">Deployment Behavior</th>
                    <td>
                        <label><input type="checkbox" name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[auto_create_pages]" value="1" <?php checked($settings['auto_create_pages'], 1); ?>> Create and maintain the default VoiceLink pages</label><br>
                        <label><input type="checkbox" name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[show_header_links]" value="1" <?php checked($settings['show_header_links'], 1); ?>> Show helpful VoiceLink header links above embedded views</label><br>
                        <label><input type="checkbox" name="<?php echo esc_attr(VOICELINK_WP_OPTION); ?>[allow_root_path_mode]" value="1" <?php checked($settings['allow_root_path_mode'], 1); ?>> Allow using the site root for VoiceLink pages when explicitly selected</label>
                    </td>
                </tr>
            </table>
            <?php submit_button('Save VoiceLink Settings'); ?>
        </form>

        <h2>Created Pages</h2>
        <ul>
            <?php foreach ($pages as $key => $page_id) : ?>
                <li>
                    <strong><?php echo esc_html($key); ?>:</strong>
                    <?php if ($page_id && get_post($page_id)) : ?>
                        <a href="<?php echo esc_url(get_permalink($page_id)); ?>"><?php echo esc_html(get_the_title($page_id)); ?></a>
                    <?php else : ?>
                        Not created yet
                    <?php endif; ?>
                </li>
            <?php endforeach; ?>
        </ul>
    </div>
    <?php
}

function voicelink_wp_render_embed($mode, $title, $description, $url) {
    $settings = voicelink_wp_get_settings();
    ob_start();
    ?>
    <section class="voicelink-wordpress-shell">
        <?php if (!empty($settings['show_header_links'])) : ?>
            <header class="voicelink-wordpress-header">
                <h2><?php echo esc_html($title); ?></h2>
                <p><?php echo esc_html($description); ?></p>
            </header>
        <?php endif; ?>

        <?php if ($mode === 'link') : ?>
            <p><a href="<?php echo esc_url($url); ?>">Open <?php echo esc_html($title); ?></a></p>
        <?php else : ?>
            <iframe
                src="<?php echo esc_url($url); ?>"
                title="<?php echo esc_attr($title); ?>"
                style="width: 100%; min-height: 720px; border: 0; border-radius: 12px;"
                loading="lazy"
                referrerpolicy="strict-origin-when-cross-origin"></iframe>
        <?php endif; ?>
    </section>
    <?php
    return ob_get_clean();
}

function voicelink_wp_shortcode_app() {
    $settings = voicelink_wp_get_settings();
    return voicelink_wp_render_embed(
        $settings['embed_mode'],
        'VoiceLink',
        'Use VoiceLink directly inside WordPress when you want your community to join rooms, chat, or move between connected servers without leaving your site.',
        $settings['app_url']
    );
}
add_shortcode('voicelink_app', 'voicelink_wp_shortcode_app');

function voicelink_wp_shortcode_downloads() {
    $settings = voicelink_wp_get_settings();
    return voicelink_wp_render_embed(
        'link',
        'VoiceLink Downloads',
        'Use this page when members need the matching desktop, server, or mobile builds for the same VoiceLink network they use on the site.',
        $settings['downloads_url']
    );
}
add_shortcode('voicelink_downloads', 'voicelink_wp_shortcode_downloads');

function voicelink_wp_shortcode_docs() {
    $settings = voicelink_wp_get_settings();
    return voicelink_wp_render_embed(
        'link',
        'VoiceLink Help',
        'Use the docs when someone needs onboarding steps, room-management guidance, or deployment help tied to your WordPress-hosted VoiceLink setup.',
        $settings['docs_url']
    );
}
add_shortcode('voicelink_docs', 'voicelink_wp_shortcode_docs');

function voicelink_wp_shortcode_server_setup() {
    $settings = voicelink_wp_get_settings();
    $setup_url = add_query_arg(array('setup_server' => '1'), trailingslashit($settings['app_url']));
    return voicelink_wp_render_embed(
        $settings['embed_mode'],
        'VoiceLink Server Setup',
        'Use this flow when a site owner wants to deploy a new VoiceLink server, link it to the main API, and connect it to the same account used on this WordPress site.',
        $setup_url
    );
}
add_shortcode('voicelink_server_setup', 'voicelink_wp_shortcode_server_setup');

function voicelink_wp_register_rest_routes() {
    register_rest_route('voicelink/v1', '/config', array(
        'methods' => 'GET',
        'permission_callback' => '__return_true',
        'callback' => 'voicelink_wp_rest_config',
    ));

    register_rest_route('voicelink/v1', '/site-owner', array(
        'methods' => 'GET',
        'permission_callback' => function () {
            return current_user_can('manage_options');
        },
        'callback' => 'voicelink_wp_rest_site_owner',
    ));

    register_rest_route('voicelink/v1', '/auth-context', array(
        'methods' => 'GET',
        'permission_callback' => function () {
            return is_user_logged_in();
        },
        'callback' => 'voicelink_wp_rest_auth_context',
    ));

    register_rest_route('voicelink/v1', '/diagnostics', array(
        'methods' => 'GET',
        'permission_callback' => function () {
            return current_user_can('manage_options');
        },
        'callback' => 'voicelink_wp_rest_diagnostics',
    ));
}
add_action('rest_api_init', 'voicelink_wp_register_rest_routes');

function voicelink_wp_rest_config() {
    $settings = voicelink_wp_get_settings();
    $current_user = wp_get_current_user();

    return rest_ensure_response(array(
        'success' => true,
        'siteName' => get_bloginfo('name'),
        'siteUrl' => home_url('/'),
        'voiceLink' => array(
            'appUrl' => $settings['app_url'],
            'downloadsUrl' => $settings['downloads_url'],
            'docsUrl' => $settings['docs_url'],
            'mainApi' => $settings['main_api'],
            'communityApi' => $settings['community_api'],
            'embedMode' => $settings['embed_mode'],
        ),
        'wordpress' => array(
            'loggedIn' => is_user_logged_in(),
            'user' => is_user_logged_in() ? array(
                'id' => $current_user->ID,
                'username' => $current_user->user_login,
                'email' => $current_user->user_email,
                'displayName' => $current_user->display_name,
                'roles' => $current_user->roles,
            ) : null,
            'auth' => voicelink_wp_auth_diagnostics(),
        ),
    ));
}

function voicelink_wp_rest_auth_context() {
    $settings = voicelink_wp_get_settings();
    $current_user = wp_get_current_user();
    $roles = $current_user->roles;
    $site_host = wp_parse_url(home_url('/'), PHP_URL_HOST);

    return rest_ensure_response(array(
        'success' => true,
        'provider' => 'wordpress',
        'siteUrl' => home_url('/'),
        'siteHost' => $site_host,
        'installPath' => ABSPATH,
        'voiceLink' => array(
            'mainApi' => $settings['main_api'],
            'communityApi' => $settings['community_api'],
            'role' => voicelink_wp_map_role_to_voicelink($roles),
            'identityAliases' => voicelink_wp_identity_aliases($current_user),
            'sharedIdentityHint' => !empty($current_user->user_email)
                ? strtolower($current_user->user_email)
                : strtolower($current_user->user_login),
        ),
        'wordpress' => array(
            'user' => array(
                'id' => $current_user->ID,
                'username' => $current_user->user_login,
                'email' => $current_user->user_email,
                'displayName' => $current_user->display_name,
                'roles' => $roles,
                'primaryRole' => voicelink_wp_primary_role($roles),
            ),
            'auth' => voicelink_wp_auth_diagnostics(),
        ),
    ));
}

function voicelink_wp_rest_site_owner() {
    $settings = voicelink_wp_get_settings();
    $plugins_dir = trailingslashit(WP_PLUGIN_DIR);
    $theme = wp_get_theme();

    return rest_ensure_response(array(
        'success' => true,
        'siteUrl' => home_url('/'),
        'pluginDir' => $plugins_dir,
        'pluginFile' => plugin_basename(__FILE__),
        'theme' => array(
            'name' => $theme->get('Name'),
            'stylesheet' => $theme->get_stylesheet(),
        ),
        'wordpress' => array(
            'auth' => voicelink_wp_auth_diagnostics(),
        ),
        'voiceLink' => array(
            'pages' => get_option(VOICELINK_WP_PAGE_OPTION, array()),
            'settings' => $settings,
        ),
    ));
}

function voicelink_wp_rest_diagnostics() {
    global $wp_version;

    return rest_ensure_response(array(
        'success' => true,
        'siteUrl' => home_url('/'),
        'siteHost' => wp_parse_url(home_url('/'), PHP_URL_HOST),
        'installPath' => ABSPATH,
        'wordpress' => array(
            'version' => $wp_version,
            'multisite' => is_multisite(),
            'auth' => voicelink_wp_auth_diagnostics(),
        ),
        'voiceLink' => array(
            'pluginVersion' => VOICELINK_WP_VERSION,
            'settings' => voicelink_wp_get_settings(),
            'pages' => get_option(VOICELINK_WP_PAGE_OPTION, array()),
        ),
    ));
}
