=== VoiceLink for WordPress ===
Contributors: devinecreations
Tags: voicelink, voice chat, community, federation, audio
Requires at least: 6.0
Tested up to: 6.8
Requires PHP: 7.4
Stable tag: 1.0.0
License: GPLv2 or later
License URI: https://www.gnu.org/licenses/gpl-2.0.html

Embed VoiceLink in WordPress, create standard VoiceLink pages, and link WordPress account data to VoiceLink deployment and authentication flows.

== Description ==

VoiceLink for WordPress is for sites that want to add VoiceLink without replacing an existing website.

Use it when you want to:

* keep the current WordPress home page, theme, and content
* add a VoiceLink page for rooms and live chat
* add Downloads, Help, and Server Setup pages automatically
* let site owners deploy or link a VoiceLink server from the same account used on the site
* expose a small REST bridge so VoiceLink can understand the current WordPress user and site owner context

== Installation ==

1. Upload the `voicelink-wordpress` folder to `/wp-content/plugins/`
2. Activate the plugin in WordPress
3. Open `Settings > VoiceLink`
4. Confirm the VoiceLink URLs and page-creation options
5. Visit the created pages:
   * `/voicelink`
   * `/voicelink-downloads`
   * `/voicelink-server-setup`
   * `/voicelink-help`

== Shortcodes ==

* `[voicelink_app]`
* `[voicelink_downloads]`
* `[voicelink_docs]`
* `[voicelink_server_setup]`

== Notes ==

This plugin is meant for side-by-side deployment. It does not replace the WordPress site root unless an administrator intentionally chooses a root-path strategy elsewhere in the deployment flow.
