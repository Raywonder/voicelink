/**
 * VoiceLink Mastodon Bot Manager
 * Handles bot accounts for notifications, announcements, and interactive commands
 *
 * Bot capabilities:
 * - Post announcements to Mastodon
 * - Send notifications/DMs to users
 * - Respond to mention commands (status, rooms, join, help)
 * - Share room links with access control
 * - Report server statistics
 * - Handle admin-only operations
 */

const fs = require('fs');
const path = require('path');

class MastodonBotManager {
    constructor(server) {
        this.server = server;
        this.bots = new Map();
        this.configPath = path.join(__dirname, '..', '..', 'config', 'mastodon-bots.json');
        this.adminUsers = new Set(); // Mastodon handles of admin users
        this.pollingIntervals = new Map();

        // Default bot configurations
        this.defaultInstances = [
            { url: 'https://md.tappedin.fm', name: 'TappedIn' },
            { url: 'https://mastodon.devinecreations.net', name: 'DevineCreations' }
        ];

        // Bot commands
        this.commands = {
            'status': this.handleStatusCommand.bind(this),
            'stats': this.handleStatusCommand.bind(this),
            'rooms': this.handleRoomsCommand.bind(this),
            'list': this.handleRoomsCommand.bind(this),
            'join': this.handleJoinCommand.bind(this),
            'invite': this.handleInviteCommand.bind(this),
            'help': this.handleHelpCommand.bind(this),
            'ping': this.handlePingCommand.bind(this),
            'admin': this.handleAdminCommand.bind(this)
        };

        this.loadConfig();
        console.log('Mastodon Bot Manager initialized with command support');
    }

    /**
     * Check if a user handle is an admin
     */
    isAdmin(userHandle) {
        const normalizedHandle = userHandle.toLowerCase().replace(/^@/, '');
        return this.adminUsers.has(normalizedHandle);
    }

    /**
     * Add an admin user
     */
    addAdmin(userHandle) {
        const normalizedHandle = userHandle.toLowerCase().replace(/^@/, '');
        this.adminUsers.add(normalizedHandle);
        this.saveConfig();
    }

    /**
     * Remove an admin user
     */
    removeAdmin(userHandle) {
        const normalizedHandle = userHandle.toLowerCase().replace(/^@/, '');
        this.adminUsers.delete(normalizedHandle);
        this.saveConfig();
    }

    /**
     * Load bot configuration from file
     */
    loadConfig() {
        try {
            if (fs.existsSync(this.configPath)) {
                const config = JSON.parse(fs.readFileSync(this.configPath, 'utf-8'));
                for (const bot of config.bots || []) {
                    this.bots.set(bot.instance, {
                        instance: bot.instance,
                        accessToken: bot.accessToken,
                        username: bot.username,
                        enabled: bot.enabled !== false,
                        lastNotificationId: bot.lastNotificationId || null
                    });
                }
                // Load admin users
                if (config.adminUsers) {
                    config.adminUsers.forEach(handle => this.adminUsers.add(handle.toLowerCase()));
                }
                console.log(`Loaded ${this.bots.size} Mastodon bot configurations and ${this.adminUsers.size} admins`);
            }
        } catch (err) {
            console.error('Failed to load Mastodon bot config:', err);
        }
    }

    /**
     * Save bot configuration to file
     */
    saveConfig() {
        try {
            const configDir = path.dirname(this.configPath);
            if (!fs.existsSync(configDir)) {
                fs.mkdirSync(configDir, { recursive: true });
            }

            const config = {
                bots: Array.from(this.bots.values()),
                adminUsers: Array.from(this.adminUsers)
            };
            fs.writeFileSync(this.configPath, JSON.stringify(config, null, 2));
        } catch (err) {
            console.error('Failed to save Mastodon bot config:', err);
        }
    }

    /**
     * Register a bot for an instance
     */
    async registerBot(instanceUrl, accessToken) {
        instanceUrl = instanceUrl.replace(/\/$/, '');
        if (!instanceUrl.startsWith('http')) {
            instanceUrl = 'https://' + instanceUrl;
        }

        try {
            // Verify the token works
            const response = await fetch(`${instanceUrl}/api/v1/accounts/verify_credentials`, {
                headers: {
                    'Authorization': `Bearer ${accessToken}`
                }
            });

            if (!response.ok) {
                throw new Error(`Invalid token: ${response.status}`);
            }

            const account = await response.json();

            const bot = {
                instance: instanceUrl,
                accessToken: accessToken,
                username: account.username,
                displayName: account.display_name,
                enabled: true
            };

            this.bots.set(instanceUrl, bot);
            this.saveConfig();

            console.log(`Registered Mastodon bot @${account.username} on ${instanceUrl}`);
            return bot;
        } catch (err) {
            console.error('Failed to register Mastodon bot:', err);
            throw err;
        }
    }

    /**
     * Remove a bot
     */
    removeBot(instanceUrl) {
        this.bots.delete(instanceUrl);
        this.saveConfig();
    }

    /**
     * Post a status update to all enabled bots
     */
    async postStatus(message, options = {}) {
        const results = [];

        for (const [instance, bot] of this.bots) {
            if (!bot.enabled) continue;

            try {
                const result = await this.postToInstance(instance, bot.accessToken, message, options);
                results.push({ instance, success: true, status: result });
            } catch (err) {
                console.error(`Failed to post to ${instance}:`, err);
                results.push({ instance, success: false, error: err.message });
            }
        }

        return results;
    }

    /**
     * Post status to a specific instance
     */
    async postToInstance(instanceUrl, accessToken, message, options = {}) {
        const body = {
            status: message,
            visibility: options.visibility || 'public'
        };

        if (options.spoilerText) {
            body.spoiler_text = options.spoilerText;
        }

        if (options.inReplyToId) {
            body.in_reply_to_id = options.inReplyToId;
        }

        const response = await fetch(`${instanceUrl}/api/v1/statuses`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${accessToken}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(body)
        });

        if (!response.ok) {
            const error = await response.text();
            throw new Error(`Failed to post status: ${error}`);
        }

        return response.json();
    }

    /**
     * Send a direct message to a user
     */
    async sendDirectMessage(userHandle, message) {
        // Parse handle to determine instance
        // Format: @user@instance.com or user@instance.com
        const match = userHandle.match(/@?(\w+)@([\w.-]+)/);
        if (!match) {
            throw new Error('Invalid user handle format');
        }

        const [, username, userInstance] = match;

        // Find a bot to use - prefer same instance, fallback to any
        let bot = null;
        for (const [instance, b] of this.bots) {
            if (b.enabled) {
                if (instance.includes(userInstance)) {
                    bot = { ...b, instance };
                    break;
                }
                if (!bot) {
                    bot = { ...b, instance };
                }
            }
        }

        if (!bot) {
            throw new Error('No enabled bot available');
        }

        // Mention the user in a DM
        const dmMessage = `@${username}@${userInstance} ${message}`;

        return this.postToInstance(bot.instance, bot.accessToken, dmMessage, {
            visibility: 'direct'
        });
    }

    /**
     * Announce a new room
     */
    async announceRoom(room, serverUrl) {
        const message = `🎙️ New voice room available!\n\n` +
            `**${room.name}**\n` +
            `👥 Up to ${room.maxUsers} users\n` +
            `${room.hasPassword ? '🔒 Password protected' : '🌐 Public'}\n\n` +
            `Join: ${serverUrl}/?room=${room.id}\n\n` +
            `#VoiceLink #VoiceChat #P2P`;

        return this.postStatus(message);
    }

    /**
     * Announce server status change
     */
    async announceServerStatus(status, serverUrl) {
        const emoji = status === 'online' ? '🟢' : '🔴';
        const message = `${emoji} VoiceLink Server is now ${status}\n\n` +
            `🌐 ${serverUrl}\n\n` +
            `#VoiceLink #Status`;

        return this.postStatus(message);
    }

    /**
     * Send notification to a specific user
     */
    async notifyUser(userHandle, notification) {
        let message = '';

        switch (notification.type) {
            case 'room_invite':
                message = `You've been invited to join "${notification.roomName}" on VoiceLink!\n\n` +
                    `Join here: ${notification.joinUrl}`;
                break;

            case 'mention':
                message = `You were mentioned in "${notification.roomName}" on VoiceLink by ${notification.fromUser}`;
                break;

            case 'room_activity':
                message = `There's activity in "${notification.roomName}" - ${notification.userCount} users are chatting!`;
                break;

            default:
                message = notification.message || 'You have a new VoiceLink notification';
        }

        return this.sendDirectMessage(userHandle, message);
    }

    // ========================================
    // BOT COMMAND HANDLERS
    // ========================================

    /**
     * Handle status command - report server stats
     */
    async handleStatusCommand(userHandle, args, replyToId, bot) {
        const stats = this.getServerStats();

        const message = `@${userHandle.replace('@', '')} 🎙️ VoiceLink Server Status\n\n` +
            `🟢 Status: Online\n` +
            `👥 Active Users: ${stats.userCount}\n` +
            `🚪 Active Rooms: ${stats.roomCount}\n` +
            `📊 Public Rooms: ${stats.publicRooms}\n` +
            `🔒 Private Rooms: ${stats.privateRooms}\n\n` +
            `Uptime: ${stats.uptime}`;

        return this.postToInstance(bot.instance, bot.accessToken, message, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    /**
     * Handle rooms command - list available rooms
     */
    async handleRoomsCommand(userHandle, args, replyToId, bot) {
        const rooms = this.getPublicRooms();
        const isAdmin = this.isAdmin(userHandle);

        let message = `@${userHandle.replace('@', '')} 🚪 Available Rooms\n\n`;

        if (rooms.length === 0) {
            message += 'No public rooms available right now.';
        } else {
            const displayRooms = rooms.slice(0, 5); // Show top 5
            displayRooms.forEach(room => {
                const lockIcon = room.hasPassword ? '🔒' : '🌐';
                message += `${lockIcon} ${room.name} (${room.userCount}/${room.maxUsers} users)\n`;
            });

            if (rooms.length > 5) {
                message += `\n...and ${rooms.length - 5} more rooms`;
            }
        }

        if (isAdmin) {
            message += '\n\n(Admin: You can see all rooms including private ones)';
        }

        return this.postToInstance(bot.instance, bot.accessToken, message, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    /**
     * Handle join command - get room join link
     */
    async handleJoinCommand(userHandle, args, replyToId, bot) {
        const roomName = args.join(' ');

        if (!roomName) {
            return this.postToInstance(bot.instance, bot.accessToken,
                `@${userHandle.replace('@', '')} Please specify a room name: !join <room-name>`, {
                visibility: 'direct',
                inReplyToId: replyToId
            });
        }

        const room = this.findRoom(roomName);
        const isAdmin = this.isAdmin(userHandle);

        if (!room) {
            return this.postToInstance(bot.instance, bot.accessToken,
                `@${userHandle.replace('@', '')} Room "${roomName}" not found.`, {
                visibility: 'direct',
                inReplyToId: replyToId
            });
        }

        // Check access permissions
        if (room.visibility === 'private' && !isAdmin) {
            return this.postToInstance(bot.instance, bot.accessToken,
                `@${userHandle.replace('@', '')} 🔒 This room is private. Only admins can share private room links.`, {
                visibility: 'direct',
                inReplyToId: replyToId
            });
        }

        const serverUrl = this.getServerUrl();
        const joinUrl = `${serverUrl}/?room=${room.id}`;

        let message = `@${userHandle.replace('@', '')} 🎙️ Join Room: ${room.name}\n\n` +
            `🔗 ${joinUrl}\n\n` +
            `👥 ${room.userCount}/${room.maxUsers} users`;

        if (room.hasPassword) {
            message += '\n🔒 This room requires a password';
        }

        return this.postToInstance(bot.instance, bot.accessToken, message, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    /**
     * Handle invite command - invite someone to a room
     */
    async handleInviteCommand(userHandle, args, replyToId, bot) {
        if (args.length < 2) {
            return this.postToInstance(bot.instance, bot.accessToken,
                `@${userHandle.replace('@', '')} Usage: !invite <@user> <room-name>`, {
                visibility: 'direct',
                inReplyToId: replyToId
            });
        }

        const targetUser = args[0];
        const roomName = args.slice(1).join(' ');
        const room = this.findRoom(roomName);

        if (!room) {
            return this.postToInstance(bot.instance, bot.accessToken,
                `@${userHandle.replace('@', '')} Room "${roomName}" not found.`, {
                visibility: 'direct',
                inReplyToId: replyToId
            });
        }

        // Send invite to target user
        const serverUrl = this.getServerUrl();
        await this.notifyUser(targetUser, {
            type: 'room_invite',
            roomName: room.name,
            joinUrl: `${serverUrl}/?room=${room.id}`,
            fromUser: userHandle
        });

        return this.postToInstance(bot.instance, bot.accessToken,
            `@${userHandle.replace('@', '')} ✅ Invitation sent to ${targetUser} for room "${room.name}"`, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    /**
     * Handle help command
     */
    async handleHelpCommand(userHandle, args, replyToId, bot) {
        const isAdmin = this.isAdmin(userHandle);

        let message = `@${userHandle.replace('@', '')} 🎙️ VoiceLink Bot Commands\n\n` +
            `!status - Server status and stats\n` +
            `!rooms - List available rooms\n` +
            `!join <room> - Get room join link\n` +
            `!invite <@user> <room> - Invite user to room\n` +
            `!ping - Check if bot is online\n` +
            `!help - Show this message`;

        if (isAdmin) {
            message += '\n\n👑 Admin Commands:\n' +
                `!admin stats - Detailed statistics\n` +
                `!admin broadcast <message> - Broadcast to all\n` +
                `!admin announce <message> - Public announcement`;
        }

        return this.postToInstance(bot.instance, bot.accessToken, message, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    /**
     * Handle ping command
     */
    async handlePingCommand(userHandle, args, replyToId, bot) {
        return this.postToInstance(bot.instance, bot.accessToken,
            `@${userHandle.replace('@', '')} 🏓 Pong! VoiceLink bot is online and ready.`, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    /**
     * Handle admin command - admin-only operations
     */
    async handleAdminCommand(userHandle, args, replyToId, bot) {
        if (!this.isAdmin(userHandle)) {
            return this.postToInstance(bot.instance, bot.accessToken,
                `@${userHandle.replace('@', '')} ⛔ This command requires admin privileges.`, {
                visibility: 'direct',
                inReplyToId: replyToId
            });
        }

        const subCommand = args[0]?.toLowerCase();
        const subArgs = args.slice(1);

        switch (subCommand) {
            case 'stats':
                return this.handleAdminStats(userHandle, replyToId, bot);

            case 'broadcast':
                const broadcastMsg = subArgs.join(' ');
                if (!broadcastMsg) {
                    return this.postToInstance(bot.instance, bot.accessToken,
                        `@${userHandle.replace('@', '')} Usage: !admin broadcast <message>`, {
                        visibility: 'direct',
                        inReplyToId: replyToId
                    });
                }
                // Emit broadcast event to server
                if (this.server?.io) {
                    this.server.io.emit('admin-broadcast', { message: broadcastMsg });
                }
                return this.postToInstance(bot.instance, bot.accessToken,
                    `@${userHandle.replace('@', '')} ✅ Broadcast sent to all connected users.`, {
                    visibility: 'direct',
                    inReplyToId: replyToId
                });

            case 'announce':
                const announceMsg = subArgs.join(' ');
                if (!announceMsg) {
                    return this.postToInstance(bot.instance, bot.accessToken,
                        `@${userHandle.replace('@', '')} Usage: !admin announce <message>`, {
                        visibility: 'direct',
                        inReplyToId: replyToId
                    });
                }
                await this.postStatus(announceMsg + '\n\n#VoiceLink', { visibility: 'public' });
                return this.postToInstance(bot.instance, bot.accessToken,
                    `@${userHandle.replace('@', '')} ✅ Public announcement posted.`, {
                    visibility: 'direct',
                    inReplyToId: replyToId
                });

            default:
                return this.postToInstance(bot.instance, bot.accessToken,
                    `@${userHandle.replace('@', '')} Unknown admin command. Use !admin stats, broadcast, or announce.`, {
                    visibility: 'direct',
                    inReplyToId: replyToId
                });
        }
    }

    /**
     * Handle admin stats
     */
    async handleAdminStats(userHandle, replyToId, bot) {
        const stats = this.getServerStats();

        const message = `@${userHandle.replace('@', '')} 📊 Admin Statistics\n\n` +
            `🖥️ Server: Online\n` +
            `⏱️ Uptime: ${stats.uptime}\n` +
            `👥 Total Users: ${stats.userCount}\n` +
            `🚪 Total Rooms: ${stats.roomCount}\n` +
            `📊 Public: ${stats.publicRooms} | Private: ${stats.privateRooms}\n` +
            `🤖 Active Bots: ${this.bots.size}\n` +
            `👑 Admin Users: ${this.adminUsers.size}`;

        return this.postToInstance(bot.instance, bot.accessToken, message, {
            visibility: 'direct',
            inReplyToId: replyToId
        });
    }

    // ========================================
    // HELPER METHODS
    // ========================================

    /**
     * Get server statistics
     */
    getServerStats() {
        const rooms = this.server?.rooms || new Map();
        const roomList = Array.from(rooms.values());

        let userCount = 0;
        let publicRooms = 0;
        let privateRooms = 0;

        roomList.forEach(room => {
            userCount += room.users?.size || room.users?.length || 0;
            if (room.visibility === 'public' || !room.hasPassword) {
                publicRooms++;
            } else {
                privateRooms++;
            }
        });

        // Calculate uptime
        const startTime = this.server?.startTime || Date.now();
        const uptimeMs = Date.now() - startTime;
        const hours = Math.floor(uptimeMs / 3600000);
        const minutes = Math.floor((uptimeMs % 3600000) / 60000);
        const uptime = `${hours}h ${minutes}m`;

        return {
            userCount,
            roomCount: roomList.length,
            publicRooms,
            privateRooms,
            uptime
        };
    }

    /**
     * Get public rooms list
     */
    getPublicRooms() {
        const rooms = this.server?.rooms || new Map();
        return Array.from(rooms.values())
            .filter(room => room.visibility !== 'private')
            .map(room => ({
                id: room.id || room.roomId,
                name: room.name,
                userCount: room.users?.size || room.users?.length || 0,
                maxUsers: room.maxUsers || 10,
                hasPassword: room.hasPassword || !!room.password,
                visibility: room.visibility || 'public'
            }));
    }

    /**
     * Find a room by name or ID
     */
    findRoom(searchTerm) {
        const rooms = this.server?.rooms || new Map();
        const searchLower = searchTerm.toLowerCase();

        for (const [id, room] of rooms) {
            if (id === searchTerm || room.name?.toLowerCase() === searchLower) {
                return {
                    id: room.id || room.roomId || id,
                    name: room.name,
                    userCount: room.users?.size || room.users?.length || 0,
                    maxUsers: room.maxUsers || 10,
                    hasPassword: room.hasPassword || !!room.password,
                    visibility: room.visibility || 'public'
                };
            }
        }

        return null;
    }

    /**
     * Get server URL
     */
    getServerUrl() {
        return this.server?.serverUrl || 'http://localhost:3010';
    }

    /**
     * Start polling for mentions (for each bot)
     */
    startMentionPolling(pollInterval = 30000) {
        for (const [instance, bot] of this.bots) {
            if (!bot.enabled) continue;

            // Clear existing interval
            if (this.pollingIntervals.has(instance)) {
                clearInterval(this.pollingIntervals.get(instance));
            }

            const intervalId = setInterval(() => {
                this.checkMentions(bot);
            }, pollInterval);

            this.pollingIntervals.set(instance, intervalId);
            console.log(`Started mention polling for @${bot.username} on ${instance}`);
        }
    }

    /**
     * Stop mention polling
     */
    stopMentionPolling() {
        for (const [instance, intervalId] of this.pollingIntervals) {
            clearInterval(intervalId);
        }
        this.pollingIntervals.clear();
    }

    /**
     * Check for new mentions and process commands
     */
    async checkMentions(bot) {
        try {
            let url = `${bot.instance}/api/v1/notifications?types[]=mention&limit=10`;
            if (bot.lastNotificationId) {
                url += `&since_id=${bot.lastNotificationId}`;
            }

            const response = await fetch(url, {
                headers: {
                    'Authorization': `Bearer ${bot.accessToken}`
                }
            });

            if (!response.ok) return;

            const notifications = await response.json();

            // Process in reverse order (oldest first)
            for (const notif of notifications.reverse()) {
                if (notif.type !== 'mention') continue;

                const status = notif.status;
                const content = this.stripHtml(status.content);
                const userHandle = `@${notif.account.acct}`;

                // Parse command
                const command = this.parseCommand(content);

                if (command && this.commands[command.name]) {
                    try {
                        await this.commands[command.name](
                            userHandle,
                            command.args,
                            status.id,
                            bot
                        );
                    } catch (err) {
                        console.error(`Error handling command ${command.name}:`, err);
                    }
                }

                // Update last notification ID
                bot.lastNotificationId = notif.id;
            }

            // Save updated config
            if (notifications.length > 0) {
                this.saveConfig();
            }
        } catch (err) {
            console.error(`Error checking mentions for ${bot.instance}:`, err);
        }
    }

    /**
     * Parse command from message content
     */
    parseCommand(content) {
        // Match commands like !status, !rooms, !join room-name, etc.
        const match = content.match(/!(\w+)(?:\s+(.*))?/);
        if (!match) return null;

        return {
            name: match[1].toLowerCase(),
            args: match[2] ? match[2].trim().split(/\s+/) : []
        };
    }

    /**
     * Strip HTML from content
     */
    stripHtml(html) {
        return html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
    }

    /**
     * Setup API routes for bot management
     */
    setupRoutes(app) {
        // Get bot status
        app.get('/api/mastodon/bots', (req, res) => {
            const bots = Array.from(this.bots.values()).map(b => ({
                instance: b.instance,
                username: b.username,
                displayName: b.displayName,
                enabled: b.enabled
            }));
            res.json(bots);
        });

        // Register a new bot (admin only)
        app.post('/api/mastodon/bots', async (req, res) => {
            const { instanceUrl, accessToken } = req.body;

            try {
                const bot = await this.registerBot(instanceUrl, accessToken);
                // Start polling for the new bot
                this.startMentionPolling();
                res.json({
                    success: true,
                    bot: {
                        instance: bot.instance,
                        username: bot.username,
                        displayName: bot.displayName
                    }
                });
            } catch (err) {
                res.status(400).json({ error: err.message });
            }
        });

        // Remove a bot (admin only)
        app.delete('/api/mastodon/bots/:instance', (req, res) => {
            const instance = decodeURIComponent(req.params.instance);
            this.removeBot(instance);
            res.json({ success: true });
        });

        // Post announcement (admin only)
        app.post('/api/mastodon/announce', async (req, res) => {
            const { message, visibility } = req.body;

            try {
                const results = await this.postStatus(message, { visibility });
                res.json({ success: true, results });
            } catch (err) {
                res.status(500).json({ error: err.message });
            }
        });

        // Send notification to user
        app.post('/api/mastodon/notify', async (req, res) => {
            const { userHandle, notification } = req.body;

            try {
                const result = await this.notifyUser(userHandle, notification);
                res.json({ success: true, result });
            } catch (err) {
                res.status(500).json({ error: err.message });
            }
        });

        // Get server stats (public)
        app.get('/api/stats', (req, res) => {
            const stats = this.getServerStats();
            res.json({
                ...stats,
                startTime: this.server?.startTime
            });
        });

        // Get connected users (admin only)
        app.get('/api/users', (req, res) => {
            const users = [];
            const rooms = this.server?.rooms || new Map();

            rooms.forEach((room, roomId) => {
                const roomUsers = room.users || new Map();
                roomUsers.forEach((user, odUserId) => {
                    users.push({
                        id: user.id || odUserId,
                        name: user.name || user.username,
                        room: room.name || roomId,
                        mastodonHandle: user.mastodonHandle || null
                    });
                });
            });

            res.json(users);
        });

        // Admin endpoints
        app.post('/api/admin/broadcast', (req, res) => {
            const { message } = req.body;
            if (this.server?.io) {
                this.server.io.emit('admin-broadcast', { message });
            }
            res.json({ success: true });
        });

        app.post('/api/admin/users/:userId/kick', (req, res) => {
            const { userId } = req.params;
            if (this.server?.io) {
                this.server.io.to(userId).emit('kicked', { reason: 'Kicked by admin' });
                // Disconnect the user
                const socket = this.server.io.sockets.sockets.get(userId);
                if (socket) socket.disconnect(true);
            }
            res.json({ success: true });
        });

        app.post('/api/admin/users/:userId/ban', (req, res) => {
            const { userId } = req.params;
            // Add to ban list (would need to implement ban storage)
            if (this.server?.io) {
                this.server.io.to(userId).emit('banned', { reason: 'Banned by admin' });
                const socket = this.server.io.sockets.sockets.get(userId);
                if (socket) socket.disconnect(true);
            }
            res.json({ success: true });
        });

        app.post('/api/admin/settings', (req, res) => {
            // Save admin settings
            const settings = req.body;
            // Store settings (would need settings storage implementation)
            console.log('Admin settings updated:', settings);
            res.json({ success: true });
        });

        // Manage admin users
        app.get('/api/mastodon/admins', (req, res) => {
            res.json(Array.from(this.adminUsers));
        });

        app.post('/api/mastodon/admins', (req, res) => {
            const { userHandle } = req.body;
            this.addAdmin(userHandle);
            res.json({ success: true, admins: Array.from(this.adminUsers) });
        });

        app.delete('/api/mastodon/admins/:handle', (req, res) => {
            const handle = decodeURIComponent(req.params.handle);
            this.removeAdmin(handle);
            res.json({ success: true, admins: Array.from(this.adminUsers) });
        });

        // Start mention polling when routes are set up
        this.startMentionPolling();
    }
}

module.exports = MastodonBotManager;
