class RoleMapper {
    static envList(name, fallback = '') {
        return String(process.env[name] || fallback)
            .split(',')
            .map((v) => v.trim().toLowerCase())
            .filter(Boolean);
    }

    static applyAutoLinkPolicy(input = {}, mappedRoles = new Set()) {
        const provider = this.normalizeProvider(input.provider || input.authProvider || input.source);
        const username = String(input.userName || input.username || input.userId || '').trim().toLowerCase();
        const email = String(input.email || input.userEmail || '').trim().toLowerCase();
        const groups = this.toArray(input.groups).map((g) => g.toLowerCase());

        const defaultAdminUsers = 'raywonder,pedin,adonis1111';
        const adminUsers = new Set([
            ...this.envList('VOICELINK_ADMIN_USERS', defaultAdminUsers),
            ...this.envList('VOICELINK_MASTODON_ADMIN_USERS', defaultAdminUsers),
            ...this.envList('VOICELINK_AUTHELIA_ADMIN_USERS', defaultAdminUsers)
        ]);
        const modUsers = new Set(this.envList('VOICELINK_MOD_USERS', process.env.VOICELINK_MASTODON_MOD_USERS || ''));
        const adminEmails = new Set(this.envList('VOICELINK_ADMIN_EMAILS', ''));
        const modEmails = new Set(this.envList('VOICELINK_MOD_EMAILS', ''));
        const adminGroups = new Set(this.envList('VOICELINK_ADMIN_GROUPS', 'admins,admin,wheel,sudo'));
        const modGroups = new Set(this.envList('VOICELINK_MOD_GROUPS', 'moderators,mods,staff'));

        const isAdminByUser = username && adminUsers.has(username);
        const isAdminByEmail = email && adminEmails.has(email);
        const isAdminByGroup = groups.some((g) => adminGroups.has(g));

        const isModByUser = username && modUsers.has(username);
        const isModByEmail = email && modEmails.has(email);
        const isModByGroup = groups.some((g) => modGroups.has(g));

        if (isAdminByUser || isAdminByEmail || isAdminByGroup) {
            mappedRoles.add('server_admin');
        } else if (isModByUser || isModByEmail || isModByGroup) {
            mappedRoles.add('room_moderator');
        }

        // Provider-specific strict allowlists
        if (provider === 'mastodon') {
            const mastodonAdmins = new Set(this.envList('VOICELINK_MASTODON_ADMIN_USERS', defaultAdminUsers));
            if (username && mastodonAdmins.has(username)) {
                mappedRoles.add('server_admin');
            }
        }
    }

    static normalizeProvider(provider) {
        const p = String(provider || 'unknown').trim().toLowerCase();
        if (['mastodon', 'mattermost', 'wordpress', 'composr', 'whmcs'].includes(p)) return p;
        return 'unknown';
    }

    static toArray(value) {
        if (!value) return [];
        if (Array.isArray(value)) return value.map((v) => String(v).trim()).filter(Boolean);
        return String(value)
            .split(',')
            .map((v) => v.trim())
            .filter(Boolean);
    }

    static mapExternalRole(provider, role) {
        const r = String(role || '').trim().toLowerCase();
        if (!r) return null;

        const commonAdmin = ['admin', 'administrator', 'owner', 'superadmin', 'root', 'sysop'];
        const commonMod = ['moderator', 'mod', 'manager', 'staff', 'operator'];
        const commonTrusted = ['trusted', 'vip', 'sponsor', 'contributor', 'editor'];

        if (commonAdmin.includes(r)) return 'server_admin';
        if (commonMod.includes(r)) return 'room_moderator';
        if (commonTrusted.includes(r)) return 'trusted_member';

        if (provider === 'mastodon') {
            if (r.includes('instance_admin')) return 'server_admin';
            if (r.includes('instance_moderator')) return 'room_moderator';
        }

        if (provider === 'mattermost') {
            if (r === 'system_admin') return 'server_admin';
            if (r === 'team_admin') return 'room_admin';
            if (r === 'channel_admin') return 'room_admin';
            if (r === 'channel_user') return 'member';
            if (r === 'guest') return 'guest';
        }

        if (provider === 'wordpress') {
            if (r === 'administrator') return 'server_admin';
            if (r === 'editor') return 'trusted_member';
            if (r === 'author') return 'member';
            if (r === 'contributor') return 'member';
            if (r === 'subscriber') return 'member';
        }

        if (provider === 'composr') {
            if (r.includes('super_moderator')) return 'server_admin';
            if (r.includes('moderator')) return 'room_moderator';
            if (r.includes('member')) return 'member';
        }

        if (provider === 'whmcs') {
            if (r.includes('full_admin') || r.includes('system_admin')) return 'server_admin';
            if (r.includes('support_manager') || r.includes('support_admin')) return 'room_moderator';
            if (r.includes('client_admin') || r.includes('reseller')) return 'trusted_member';
            if (r.includes('client')) return 'member';
        }

        return null;
    }

    static rankRole(role) {
        const order = {
            server_owner: 100,
            server_admin: 90,
            room_admin: 75,
            room_moderator: 60,
            trusted_member: 45,
            member: 30,
            guest: 10
        };
        return order[role] || 0;
    }

    static derivePermissions(roles) {
        const set = new Set(roles);
        const perms = new Set(['room.view', 'room.join']);

        if (set.has('member') || set.has('trusted_member') || set.has('room_moderator') || set.has('room_admin') || set.has('server_admin') || set.has('server_owner')) {
            perms.add('room.chat');
            perms.add('room.audio.send');
            perms.add('room.audio.receive');
        }

        if (set.has('trusted_member') || set.has('room_moderator') || set.has('room_admin') || set.has('server_admin') || set.has('server_owner')) {
            perms.add('room.preview');
            perms.add('room.invite');
        }

        if (set.has('room_moderator') || set.has('room_admin') || set.has('server_admin') || set.has('server_owner')) {
            perms.add('room.moderate');
            perms.add('room.user_controls');
        }

        if (set.has('room_admin') || set.has('server_admin') || set.has('server_owner')) {
            perms.add('room.lock');
            perms.add('room.media.manage');
        }

        if (set.has('server_admin') || set.has('server_owner')) {
            perms.add('admin.panel');
            perms.add('scheduler.manage');
            perms.add('whmcs.manage');
        }

        return Array.from(perms);
    }

    static normalizeIdentity(input = {}) {
        const provider = this.normalizeProvider(input.provider || input.authProvider || input.source);
        const externalRoles = [
            ...this.toArray(input.roles),
            ...this.toArray(input.groups),
            ...this.toArray(input.role),
            ...this.toArray(input.wpRoles),
            ...this.toArray(input.mmRoles),
            ...this.toArray(input.whmcsRoles),
            ...this.toArray(input.composrGroups),
            ...this.toArray(input.mastodonRoles)
        ];

        const mapped = new Set();
        for (const externalRole of externalRoles) {
            const mappedRole = this.mapExternalRole(provider, externalRole);
            if (mappedRole) mapped.add(mappedRole);
        }

        if (input.isOwner) mapped.add('server_owner');
        if (input.isAdmin) mapped.add('server_admin');
        if (input.isModerator) mapped.add('room_moderator');
        this.applyAutoLinkPolicy(input, mapped);

        if (mapped.size === 0) {
            mapped.add(input.isAuthenticated ? 'member' : 'guest');
        }

        const voicelinkRoles = Array.from(mapped).sort((a, b) => this.rankRole(b) - this.rankRole(a));
        const primaryRole = voicelinkRoles[0] || 'guest';

        return {
            provider,
            externalRoles,
            voicelinkRoles,
            primaryRole,
            permissions: this.derivePermissions(voicelinkRoles),
            isAdmin: voicelinkRoles.includes('server_admin') || voicelinkRoles.includes('server_owner'),
            isModerator: voicelinkRoles.includes('room_moderator') || voicelinkRoles.includes('room_admin')
        };
    }
}

module.exports = RoleMapper;
