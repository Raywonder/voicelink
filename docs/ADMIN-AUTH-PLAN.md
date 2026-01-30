# VoiceLink Admin Authentication System

## Overview

Dual authentication system supporting both local email/password accounts and Mastodon OAuth, with account linking capabilities.

## Authentication Methods

### 1. Email/Password Authentication
- Local accounts stored server-side
- For users without Mastodon accounts
- Password hashed with bcrypt
- Email verification optional but recommended

### 2. Mastodon OAuth Authentication
- Federated authentication via any Mastodon-compatible instance
- Roles synced from Mastodon (Admin, Moderator, User)
- Supports: Mastodon, Pleroma, Akkoma, Misskey, GoToSocial

### 3. Account Linking
- Users can link email account to Mastodon account
- Either method can be used to login
- If one fails, fallback to the other
- Roles merged from both sources (highest privilege wins)

## Role Hierarchy

| Role | Permissions |
|------|-------------|
| Owner | Full system access, can manage admins |
| Admin | Server settings, user management, room control |
| Moderator | Room management, user moderation, kick/ban |
| User | Create rooms, join rooms, basic features |
| Guest | Join public rooms only, limited features |

## Database Schema (Server-Side)

```javascript
// users collection
{
  id: "uuid",
  email: "user@example.com",
  passwordHash: "bcrypt_hash",
  displayName: "Display Name",
  avatar: "url",
  role: "admin|moderator|user",
  mastodonLinked: {
    instance: "mastodon.social",
    accountId: "12345",
    username: "user",
    accessToken: "encrypted_token"
  },
  createdAt: "timestamp",
  lastLogin: "timestamp",
  emailVerified: true,
  settings: { ... }
}
```

## Client-Side Implementation

### Login Modal UI

```
+------------------------------------------+
|           VoiceLink Login                |
+------------------------------------------+
|                                          |
|  [Tab: Email] [Tab: Mastodon]            |
|                                          |
|  --- Email Login ---                     |
|  Email: [_______________________]        |
|  Password: [___________________]         |
|  [ ] Remember me                         |
|                                          |
|  [Login] [Create Account]                |
|                                          |
|  --- Or continue with ---                |
|  [🐘 Login with Mastodon]                |
|                                          |
|  Forgot password?                        |
+------------------------------------------+
```

### Admin Panel Access

1. User logs in via email/password OR Mastodon
2. Server checks user role
3. If admin/moderator: Show admin panel button
4. Admin panel shows role-appropriate controls

## API Endpoints (Server)

```
POST /api/auth/register     - Create email account
POST /api/auth/login        - Email/password login
POST /api/auth/logout       - End session
POST /api/auth/verify-email - Verify email address
POST /api/auth/forgot       - Request password reset
POST /api/auth/reset        - Reset password with token

POST /api/auth/mastodon/callback  - Mastodon OAuth callback
POST /api/auth/link-mastodon      - Link Mastodon to existing account
DELETE /api/auth/unlink-mastodon  - Unlink Mastodon account

GET  /api/auth/me           - Get current user info
PUT  /api/auth/me           - Update user profile
```

## Implementation Files

### New Files to Create:
1. `client/js/auth/email-auth.js` - Email/password authentication
2. `client/js/auth/auth-manager.js` - Unified auth manager
3. `client/js/ui/login-modal.js` - Login/Register UI
4. `server/routes/auth.js` - Auth API endpoints
5. `server/models/user.js` - User model

### Files to Modify:
1. `client/js/core/app.js` - Integrate new auth system
2. `client/index.html` - Add login modal HTML
3. `client/css/style.css` - Login modal styles

## Security Considerations

- Passwords: bcrypt with cost factor 12
- Sessions: JWT tokens with 7-day expiry
- CSRF: State parameter for OAuth
- Rate limiting: 5 login attempts per minute
- Email verification: Required for password reset
- Account lockout: After 10 failed attempts

## Migration Path

1. Existing Mastodon users keep their accounts
2. New email registration available
3. Users can link existing Mastodon to new email
4. Graceful fallback if Mastodon unavailable

## Admin Roles from auth.devinecreations.net

If integrating with a central auth server:
- Sync admin list from auth.devinecreations.net
- Check user email against admin registry
- Override local role if user is in central admin list

## Implementation Priority

1. **Phase 1**: Login modal UI with tabs
2. **Phase 2**: Email/password backend
3. **Phase 3**: Account linking
4. **Phase 4**: Central admin registry sync
