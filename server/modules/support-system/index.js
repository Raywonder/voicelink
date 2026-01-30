/**
 * VoiceLink Support System Module
 *
 * Built-in support features for VoiceLink servers:
 * - Support ticket system with priorities
 * - Live chat support queue
 * - Knowledge base integration
 * - Support agent management
 * - Email notifications
 * - Support analytics
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Ticket statuses
const TICKET_STATUS = {
    OPEN: 'open',
    IN_PROGRESS: 'in_progress',
    WAITING_USER: 'waiting_user',
    WAITING_SUPPORT: 'waiting_support',
    RESOLVED: 'resolved',
    CLOSED: 'closed'
};

// Ticket priorities
const TICKET_PRIORITY = {
    LOW: 'low',
    MEDIUM: 'medium',
    HIGH: 'high',
    URGENT: 'urgent'
};

// Default categories
const DEFAULT_CATEGORIES = [
    { id: 'technical', name: 'Technical Support', icon: '🔧' },
    { id: 'billing', name: 'Billing & Payments', icon: '💳' },
    { id: 'feature-request', name: 'Feature Request', icon: '💡' },
    { id: 'bug-report', name: 'Bug Report', icon: '🐛' },
    { id: 'account', name: 'Account Issues', icon: '👤' },
    { id: 'general', name: 'General Inquiry', icon: '❓' }
];

class SupportTicketSystem {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/support');
        this.ticketsDir = path.join(this.dataDir, 'tickets');
        this.emailTransport = options.emailTransport;

        // In-memory indexes for fast lookups
        this.ticketIndex = new Map();
        this.userTickets = new Map();
        this.agentTickets = new Map();

        // Initialize directories
        [this.dataDir, this.ticketsDir].forEach(dir => {
            if (!fs.existsSync(dir)) {
                fs.mkdirSync(dir, { recursive: true });
            }
        });

        // Load ticket index
        this.loadTicketIndex();
    }

    loadTicketIndex() {
        const indexFile = path.join(this.dataDir, 'ticket-index.json');
        try {
            if (fs.existsSync(indexFile)) {
                const data = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
                data.tickets?.forEach(t => {
                    this.ticketIndex.set(t.id, t);
                    this.indexByUser(t.userId, t.id);
                    if (t.assignedTo) this.indexByAgent(t.assignedTo, t.id);
                });
            }
        } catch (e) {
            console.error('[Support] Error loading ticket index:', e.message);
        }
    }

    saveTicketIndex() {
        const indexFile = path.join(this.dataDir, 'ticket-index.json');
        const data = {
            lastUpdated: Date.now(),
            tickets: Array.from(this.ticketIndex.values())
        };
        fs.writeFileSync(indexFile, JSON.stringify(data, null, 2));
    }

    indexByUser(userId, ticketId) {
        if (!this.userTickets.has(userId)) {
            this.userTickets.set(userId, new Set());
        }
        this.userTickets.get(userId).add(ticketId);
    }

    indexByAgent(agentId, ticketId) {
        if (!this.agentTickets.has(agentId)) {
            this.agentTickets.set(agentId, new Set());
        }
        this.agentTickets.get(agentId).add(ticketId);
    }

    generateTicketId() {
        const date = new Date();
        const dateStr = `${date.getFullYear()}${String(date.getMonth() + 1).padStart(2, '0')}${String(date.getDate()).padStart(2, '0')}`;
        const random = crypto.randomBytes(3).toString('hex').toUpperCase();
        return `TKT-${dateStr}-${random}`;
    }

    /**
     * Create a new support ticket
     */
    async createTicket(data) {
        const {
            userId,
            userName,
            userEmail,
            subject,
            description,
            category = 'general',
            priority = TICKET_PRIORITY.MEDIUM,
            attachments = []
        } = data;

        const ticketId = this.generateTicketId();
        const now = Date.now();

        const ticket = {
            id: ticketId,
            userId,
            userName,
            userEmail,
            subject,
            description,
            category,
            priority,
            status: TICKET_STATUS.OPEN,
            assignedTo: null,
            attachments,
            messages: [{
                id: `msg-${now}`,
                type: 'initial',
                from: 'user',
                userId,
                userName,
                content: description,
                timestamp: now
            }],
            createdAt: now,
            updatedAt: now,
            resolvedAt: null,
            closedAt: null,
            firstResponseAt: null,
            rating: null,
            feedback: null
        };

        // Save ticket file
        const ticketFile = path.join(this.ticketsDir, `${ticketId}.json`);
        fs.writeFileSync(ticketFile, JSON.stringify(ticket, null, 2));

        // Update index
        const indexEntry = {
            id: ticketId,
            userId,
            userName,
            subject,
            category,
            priority,
            status: ticket.status,
            assignedTo: null,
            createdAt: now,
            updatedAt: now
        };
        this.ticketIndex.set(ticketId, indexEntry);
        this.indexByUser(userId, ticketId);
        this.saveTicketIndex();

        // Auto-assign if configured
        if (this.config.tickets?.autoAssign) {
            await this.autoAssignTicket(ticketId);
        }

        // Send email notification
        if (this.config.notifications?.emailOnNewTicket && userEmail) {
            await this.sendTicketCreatedEmail(ticket);
        }

        console.log(`[Support] Created ticket ${ticketId}: ${subject}`);
        return { success: true, ticketId, ticket };
    }

    /**
     * Get ticket by ID
     */
    getTicket(ticketId) {
        const ticketFile = path.join(this.ticketsDir, `${ticketId}.json`);
        try {
            if (fs.existsSync(ticketFile)) {
                return JSON.parse(fs.readFileSync(ticketFile, 'utf8'));
            }
        } catch (e) {
            console.error(`[Support] Error loading ticket ${ticketId}:`, e.message);
        }
        return null;
    }

    /**
     * Update ticket
     */
    saveTicket(ticket) {
        const ticketFile = path.join(this.ticketsDir, `${ticket.id}.json`);
        ticket.updatedAt = Date.now();
        fs.writeFileSync(ticketFile, JSON.stringify(ticket, null, 2));

        // Update index
        const indexEntry = this.ticketIndex.get(ticket.id);
        if (indexEntry) {
            indexEntry.status = ticket.status;
            indexEntry.priority = ticket.priority;
            indexEntry.assignedTo = ticket.assignedTo;
            indexEntry.updatedAt = ticket.updatedAt;
            this.saveTicketIndex();
        }
    }

    /**
     * Add reply to ticket
     */
    async addReply(ticketId, data) {
        const { userId, userName, content, isAgent = false, attachments = [] } = data;
        const ticket = this.getTicket(ticketId);

        if (!ticket) {
            return { success: false, error: 'Ticket not found' };
        }

        const now = Date.now();
        const message = {
            id: `msg-${now}`,
            type: 'reply',
            from: isAgent ? 'agent' : 'user',
            userId,
            userName,
            content,
            attachments,
            timestamp: now
        };

        ticket.messages.push(message);

        // Update status based on who replied
        if (isAgent) {
            if (!ticket.firstResponseAt) {
                ticket.firstResponseAt = now;
            }
            ticket.status = TICKET_STATUS.WAITING_USER;
        } else {
            ticket.status = TICKET_STATUS.WAITING_SUPPORT;
        }

        this.saveTicket(ticket);

        // Send email notification
        if (this.config.notifications?.emailOnReply) {
            if (isAgent && ticket.userEmail) {
                await this.sendReplyNotificationEmail(ticket, message);
            }
        }

        return { success: true, message };
    }

    /**
     * Assign ticket to agent
     */
    assignTicket(ticketId, agentId, agentName) {
        const ticket = this.getTicket(ticketId);
        if (!ticket) {
            return { success: false, error: 'Ticket not found' };
        }

        // Remove from previous agent's list
        if (ticket.assignedTo) {
            this.agentTickets.get(ticket.assignedTo)?.delete(ticketId);
        }

        ticket.assignedTo = agentId;
        ticket.status = TICKET_STATUS.IN_PROGRESS;
        ticket.messages.push({
            id: `msg-${Date.now()}`,
            type: 'system',
            content: `Ticket assigned to ${agentName}`,
            timestamp: Date.now()
        });

        this.saveTicket(ticket);
        this.indexByAgent(agentId, ticketId);

        return { success: true };
    }

    /**
     * Auto-assign ticket to available agent
     */
    async autoAssignTicket(ticketId) {
        // Get agents with least open tickets
        const agents = this.getAgents();
        if (agents.length === 0) return;

        // Sort by ticket count (ascending)
        agents.sort((a, b) => {
            const aCount = this.agentTickets.get(a.id)?.size || 0;
            const bCount = this.agentTickets.get(b.id)?.size || 0;
            return aCount - bCount;
        });

        const selectedAgent = agents[0];
        this.assignTicket(ticketId, selectedAgent.id, selectedAgent.name);
    }

    /**
     * Update ticket status
     */
    updateStatus(ticketId, status, note = null) {
        const ticket = this.getTicket(ticketId);
        if (!ticket) {
            return { success: false, error: 'Ticket not found' };
        }

        ticket.status = status;

        if (status === TICKET_STATUS.RESOLVED) {
            ticket.resolvedAt = Date.now();
        } else if (status === TICKET_STATUS.CLOSED) {
            ticket.closedAt = Date.now();
        }

        if (note) {
            ticket.messages.push({
                id: `msg-${Date.now()}`,
                type: 'system',
                content: note,
                timestamp: Date.now()
            });
        }

        this.saveTicket(ticket);

        // Send closure notification
        if (status === TICKET_STATUS.CLOSED && this.config.notifications?.emailOnClose && ticket.userEmail) {
            this.sendTicketClosedEmail(ticket);
        }

        return { success: true };
    }

    /**
     * Update ticket priority
     */
    updatePriority(ticketId, priority) {
        const ticket = this.getTicket(ticketId);
        if (!ticket) {
            return { success: false, error: 'Ticket not found' };
        }

        ticket.priority = priority;
        ticket.messages.push({
            id: `msg-${Date.now()}`,
            type: 'system',
            content: `Priority changed to ${priority}`,
            timestamp: Date.now()
        });

        this.saveTicket(ticket);
        return { success: true };
    }

    /**
     * Add rating to closed ticket
     */
    addRating(ticketId, rating, feedback = null) {
        const ticket = this.getTicket(ticketId);
        if (!ticket) {
            return { success: false, error: 'Ticket not found' };
        }

        if (ticket.status !== TICKET_STATUS.CLOSED && ticket.status !== TICKET_STATUS.RESOLVED) {
            return { success: false, error: 'Ticket must be closed to rate' };
        }

        ticket.rating = rating;
        ticket.feedback = feedback;
        this.saveTicket(ticket);

        return { success: true };
    }

    /**
     * Get tickets for user
     */
    getUserTickets(userId, options = {}) {
        const { status = null, limit = 50, offset = 0 } = options;
        const ticketIds = this.userTickets.get(userId) || new Set();

        let tickets = Array.from(ticketIds)
            .map(id => this.ticketIndex.get(id))
            .filter(Boolean);

        if (status) {
            tickets = tickets.filter(t => t.status === status);
        }

        tickets.sort((a, b) => b.updatedAt - a.updatedAt);
        return tickets.slice(offset, offset + limit);
    }

    /**
     * Get tickets for agent
     */
    getAgentTickets(agentId, options = {}) {
        const { status = null, limit = 50, offset = 0 } = options;
        const ticketIds = this.agentTickets.get(agentId) || new Set();

        let tickets = Array.from(ticketIds)
            .map(id => this.ticketIndex.get(id))
            .filter(Boolean);

        if (status) {
            tickets = tickets.filter(t => t.status === status);
        }

        tickets.sort((a, b) => b.updatedAt - a.updatedAt);
        return tickets.slice(offset, offset + limit);
    }

    /**
     * Get all tickets (admin)
     */
    getAllTickets(options = {}) {
        const { status = null, priority = null, category = null, limit = 100, offset = 0 } = options;

        let tickets = Array.from(this.ticketIndex.values());

        if (status) {
            tickets = tickets.filter(t => t.status === status);
        }
        if (priority) {
            tickets = tickets.filter(t => t.priority === priority);
        }
        if (category) {
            tickets = tickets.filter(t => t.category === category);
        }

        tickets.sort((a, b) => {
            // Sort by priority first (urgent > high > medium > low)
            const priorityOrder = { urgent: 0, high: 1, medium: 2, low: 3 };
            const priorityDiff = (priorityOrder[a.priority] || 2) - (priorityOrder[b.priority] || 2);
            if (priorityDiff !== 0) return priorityDiff;

            // Then by update time
            return b.updatedAt - a.updatedAt;
        });

        return {
            total: tickets.length,
            tickets: tickets.slice(offset, offset + limit)
        };
    }

    /**
     * Get ticket statistics
     */
    getStatistics() {
        const tickets = Array.from(this.ticketIndex.values());
        const now = Date.now();
        const dayMs = 24 * 60 * 60 * 1000;

        const stats = {
            total: tickets.length,
            byStatus: {},
            byPriority: {},
            byCategory: {},
            last24h: 0,
            last7d: 0,
            avgFirstResponse: 0,
            avgResolution: 0,
            avgRating: 0,
            ratedCount: 0
        };

        // Initialize counters
        Object.values(TICKET_STATUS).forEach(s => stats.byStatus[s] = 0);
        Object.values(TICKET_PRIORITY).forEach(p => stats.byPriority[p] = 0);
        DEFAULT_CATEGORIES.forEach(c => stats.byCategory[c.id] = 0);

        let totalFirstResponse = 0;
        let firstResponseCount = 0;
        let totalResolution = 0;
        let resolutionCount = 0;
        let totalRating = 0;

        for (const ticket of tickets) {
            stats.byStatus[ticket.status] = (stats.byStatus[ticket.status] || 0) + 1;
            stats.byPriority[ticket.priority] = (stats.byPriority[ticket.priority] || 0) + 1;
            stats.byCategory[ticket.category] = (stats.byCategory[ticket.category] || 0) + 1;

            if (ticket.createdAt > now - dayMs) stats.last24h++;
            if (ticket.createdAt > now - (7 * dayMs)) stats.last7d++;

            // Load full ticket for response times and ratings
            const fullTicket = this.getTicket(ticket.id);
            if (fullTicket) {
                if (fullTicket.firstResponseAt && fullTicket.createdAt) {
                    totalFirstResponse += (fullTicket.firstResponseAt - fullTicket.createdAt);
                    firstResponseCount++;
                }
                if (fullTicket.resolvedAt && fullTicket.createdAt) {
                    totalResolution += (fullTicket.resolvedAt - fullTicket.createdAt);
                    resolutionCount++;
                }
                if (fullTicket.rating) {
                    totalRating += fullTicket.rating;
                    stats.ratedCount++;
                }
            }
        }

        stats.avgFirstResponse = firstResponseCount > 0
            ? Math.round(totalFirstResponse / firstResponseCount / 60000) // minutes
            : 0;
        stats.avgResolution = resolutionCount > 0
            ? Math.round(totalResolution / resolutionCount / 3600000) // hours
            : 0;
        stats.avgRating = stats.ratedCount > 0
            ? Math.round((totalRating / stats.ratedCount) * 10) / 10
            : 0;

        return stats;
    }

    /**
     * Get categories
     */
    getCategories() {
        return this.config.tickets?.categories
            ? this.config.tickets.categories.map(c => DEFAULT_CATEGORIES.find(dc => dc.id === c) || { id: c, name: c, icon: '📋' })
            : DEFAULT_CATEGORIES;
    }

    /**
     * Get agents
     */
    getAgents() {
        const agentsFile = path.join(this.dataDir, 'agents.json');
        try {
            if (fs.existsSync(agentsFile)) {
                return JSON.parse(fs.readFileSync(agentsFile, 'utf8'));
            }
        } catch (e) { /* file doesn't exist */ }
        return [];
    }

    /**
     * Add agent
     */
    addAgent(agent) {
        const agents = this.getAgents();
        agents.push({
            id: agent.id,
            name: agent.name,
            email: agent.email,
            role: agent.role || 'agent',
            addedAt: Date.now()
        });
        fs.writeFileSync(path.join(this.dataDir, 'agents.json'), JSON.stringify(agents, null, 2));
        return { success: true };
    }

    /**
     * Remove agent
     */
    removeAgent(agentId) {
        const agents = this.getAgents().filter(a => a.id !== agentId);
        fs.writeFileSync(path.join(this.dataDir, 'agents.json'), JSON.stringify(agents, null, 2));

        // Unassign tickets
        const ticketIds = this.agentTickets.get(agentId);
        if (ticketIds) {
            for (const ticketId of ticketIds) {
                const ticket = this.getTicket(ticketId);
                if (ticket) {
                    ticket.assignedTo = null;
                    this.saveTicket(ticket);
                }
            }
            this.agentTickets.delete(agentId);
        }

        return { success: true };
    }

    // Email notification methods
    async sendTicketCreatedEmail(ticket) {
        if (!this.emailTransport) {
            console.log(`[Support] Would email ${ticket.userEmail}: Ticket ${ticket.id} created`);
            return;
        }

        const html = `
<!DOCTYPE html>
<html>
<head><style>body{font-family:sans-serif;background:#f5f5f5;padding:20px}.container{max-width:600px;margin:auto;background:white;border-radius:8px;padding:30px}.header{color:#6364FF;margin-bottom:20px}.ticket-id{background:#f0f0ff;padding:10px;border-radius:4px;font-family:monospace}</style></head>
<body>
<div class="container">
    <h2 class="header">Support Ticket Created</h2>
    <p>Hello ${ticket.userName},</p>
    <p>Your support ticket has been created:</p>
    <div class="ticket-id">
        <strong>Ticket ID:</strong> ${ticket.id}<br>
        <strong>Subject:</strong> ${ticket.subject}<br>
        <strong>Priority:</strong> ${ticket.priority}
    </div>
    <p>We'll respond to your ticket as soon as possible.</p>
    <p>Best regards,<br>VoiceLink Support</p>
</div>
</body>
</html>`;

        try {
            await this.emailTransport.sendMail({
                from: this.config.email?.fromAddress || 'noreply@voicelink.local',
                to: ticket.userEmail,
                subject: `[${ticket.id}] Ticket Created: ${ticket.subject}`,
                html
            });
        } catch (e) {
            console.error('[Support] Email send error:', e.message);
        }
    }

    async sendReplyNotificationEmail(ticket, message) {
        if (!this.emailTransport) {
            console.log(`[Support] Would email ${ticket.userEmail}: Reply on ${ticket.id}`);
            return;
        }

        const html = `
<!DOCTYPE html>
<html>
<head><style>body{font-family:sans-serif;background:#f5f5f5;padding:20px}.container{max-width:600px;margin:auto;background:white;border-radius:8px;padding:30px}.reply{background:#f9f9f9;padding:15px;border-left:3px solid #6364FF;margin:15px 0}</style></head>
<body>
<div class="container">
    <h2>New Reply on Ticket ${ticket.id}</h2>
    <p><strong>Subject:</strong> ${ticket.subject}</p>
    <div class="reply">
        <p><strong>${message.userName}</strong> replied:</p>
        <p>${message.content}</p>
    </div>
    <p>Log in to view and respond to this ticket.</p>
</div>
</body>
</html>`;

        try {
            await this.emailTransport.sendMail({
                from: this.config.email?.fromAddress || 'noreply@voicelink.local',
                to: ticket.userEmail,
                subject: `[${ticket.id}] New Reply: ${ticket.subject}`,
                html
            });
        } catch (e) {
            console.error('[Support] Email send error:', e.message);
        }
    }

    async sendTicketClosedEmail(ticket) {
        if (!this.emailTransport) {
            console.log(`[Support] Would email ${ticket.userEmail}: Ticket ${ticket.id} closed`);
            return;
        }

        const html = `
<!DOCTYPE html>
<html>
<head><style>body{font-family:sans-serif;background:#f5f5f5;padding:20px}.container{max-width:600px;margin:auto;background:white;border-radius:8px;padding:30px}.rating{margin:20px 0}</style></head>
<body>
<div class="container">
    <h2>Ticket Closed: ${ticket.id}</h2>
    <p>Hello ${ticket.userName},</p>
    <p>Your support ticket "<strong>${ticket.subject}</strong>" has been closed.</p>
    <div class="rating">
        <p>We'd love to hear your feedback! Please rate your experience:</p>
        <p>⭐⭐⭐⭐⭐</p>
    </div>
    <p>Thank you for using VoiceLink Support.</p>
</div>
</body>
</html>`;

        try {
            await this.emailTransport.sendMail({
                from: this.config.email?.fromAddress || 'noreply@voicelink.local',
                to: ticket.userEmail,
                subject: `[${ticket.id}] Ticket Closed: ${ticket.subject}`,
                html
            });
        } catch (e) {
            console.error('[Support] Email send error:', e.message);
        }
    }
}

// Live Chat Support Queue
class LiveChatSupport {
    constructor(options = {}) {
        this.config = options.config || {};
        this.io = options.io; // Socket.io instance
        this.chatQueue = []; // Users waiting for support
        this.activeSessions = new Map(); // Active chat sessions
        this.agents = new Map(); // Online agents
    }

    /**
     * User joins support queue
     */
    joinQueue(userId, userName, issue) {
        const maxQueue = this.config.liveChat?.maxQueueSize || 10;

        if (this.chatQueue.length >= maxQueue) {
            return {
                success: false,
                error: 'Support queue is full. Please try again later or submit a ticket.'
            };
        }

        const queueEntry = {
            id: crypto.randomBytes(8).toString('hex'),
            userId,
            userName,
            issue,
            joinedAt: Date.now(),
            position: this.chatQueue.length + 1
        };

        this.chatQueue.push(queueEntry);
        this.notifyAgentsOfQueue();

        return {
            success: true,
            queueId: queueEntry.id,
            position: queueEntry.position,
            estimatedWait: this.estimateWaitTime()
        };
    }

    /**
     * User leaves queue
     */
    leaveQueue(queueId) {
        this.chatQueue = this.chatQueue.filter(q => q.id !== queueId);
        this.updateQueuePositions();
    }

    /**
     * Agent picks up next chat
     */
    pickupChat(agentId) {
        if (this.chatQueue.length === 0) {
            return { success: false, error: 'Queue is empty' };
        }

        const queueEntry = this.chatQueue.shift();
        const sessionId = crypto.randomBytes(8).toString('hex');

        const session = {
            id: sessionId,
            userId: queueEntry.userId,
            userName: queueEntry.userName,
            agentId,
            issue: queueEntry.issue,
            startedAt: Date.now(),
            messages: []
        };

        this.activeSessions.set(sessionId, session);
        this.updateQueuePositions();

        return { success: true, session };
    }

    /**
     * Send chat message
     */
    sendMessage(sessionId, fromId, content) {
        const session = this.activeSessions.get(sessionId);
        if (!session) {
            return { success: false, error: 'Session not found' };
        }

        const message = {
            id: `msg-${Date.now()}`,
            fromId,
            content,
            timestamp: Date.now()
        };

        session.messages.push(message);

        // Emit to both parties via socket.io
        if (this.io) {
            this.io.to(`chat:${sessionId}`).emit('chat:message', message);
        }

        return { success: true, message };
    }

    /**
     * End chat session
     */
    endSession(sessionId, reason = 'completed') {
        const session = this.activeSessions.get(sessionId);
        if (session) {
            session.endedAt = Date.now();
            session.endReason = reason;

            // Save transcript
            this.saveChatTranscript(session);

            this.activeSessions.delete(sessionId);
        }

        return { success: true };
    }

    /**
     * Agent comes online
     */
    agentOnline(agentId, agentName) {
        this.agents.set(agentId, {
            id: agentId,
            name: agentName,
            onlineSince: Date.now(),
            status: 'available'
        });
    }

    /**
     * Agent goes offline
     */
    agentOffline(agentId) {
        this.agents.delete(agentId);
    }

    /**
     * Get queue status
     */
    getQueueStatus() {
        return {
            queueLength: this.chatQueue.length,
            activeSessions: this.activeSessions.size,
            onlineAgents: this.agents.size,
            estimatedWait: this.estimateWaitTime()
        };
    }

    updateQueuePositions() {
        this.chatQueue.forEach((entry, index) => {
            entry.position = index + 1;
        });
    }

    estimateWaitTime() {
        const avgSessionMinutes = 10;
        const agentCount = Math.max(1, this.agents.size);
        return Math.ceil((this.chatQueue.length / agentCount) * avgSessionMinutes);
    }

    notifyAgentsOfQueue() {
        if (this.io) {
            this.io.to('support:agents').emit('support:queue-update', {
                queueLength: this.chatQueue.length
            });
        }
    }

    saveChatTranscript(session) {
        // Save to data directory
        const transcriptsDir = path.join(__dirname, '../../../data/support/transcripts');
        if (!fs.existsSync(transcriptsDir)) {
            fs.mkdirSync(transcriptsDir, { recursive: true });
        }

        const filename = `chat-${session.id}-${Date.now()}.json`;
        fs.writeFileSync(
            path.join(transcriptsDir, filename),
            JSON.stringify(session, null, 2)
        );
    }
}

// Main Support System Module
class SupportSystemModule {
    constructor(options = {}) {
        this.config = options.config || {};
        this.dataDir = options.dataDir || path.join(__dirname, '../../../data/support');
        this.emailTransport = options.emailTransport;
        this.io = options.io;

        this.tickets = new SupportTicketSystem({
            config: this.config,
            dataDir: this.dataDir,
            emailTransport: this.emailTransport
        });

        this.liveChat = new LiveChatSupport({
            config: this.config,
            io: this.io
        });
    }

    /**
     * Get overall support statistics
     */
    getStatistics() {
        return {
            tickets: this.tickets.getStatistics(),
            liveChat: this.liveChat.getQueueStatus()
        };
    }

    /**
     * Check if support is available
     */
    isAvailable() {
        const chatAvailable = this.config.liveChat?.enabled && this.liveChat.agents.size > 0;
        const ticketsEnabled = this.config.tickets?.enabled !== false;

        return {
            liveChat: chatAvailable,
            tickets: ticketsEnabled,
            offlineMessage: !chatAvailable && this.config.liveChat?.offlineMessage
        };
    }
}

module.exports = {
    SupportSystemModule,
    SupportTicketSystem,
    LiveChatSupport,
    TICKET_STATUS,
    TICKET_PRIORITY,
    DEFAULT_CATEGORIES
};
