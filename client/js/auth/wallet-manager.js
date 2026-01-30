/**
 * VoiceLink Ecripto Wallet Manager
 *
 * Handles wallet connection, disconnection, and authentication
 * with the Ecripto network for room minting and access passes.
 */

class WalletManager {
    constructor(app) {
        this.app = app;
        this.connected = false;
        this.walletAddress = null;
        this.walletProvider = null;
        this.linkedAccount = null; // Email or Mastodon account linked to this wallet

        // Cached data
        this.mintedRooms = [];
        this.accessPasses = [];
        this.tokenBalances = [];

        // Connection state
        this.connectionPending = false;
        this.disconnectionPending = false;

        // Load saved state
        this.loadSavedState();

        // Initialize UI handlers
        this.initUIHandlers();
    }

    /**
     * Load saved wallet state from localStorage
     */
    loadSavedState() {
        try {
            const saved = localStorage.getItem('voicelink_wallet_state');
            if (saved) {
                const state = JSON.parse(saved);
                this.walletAddress = state.walletAddress;
                this.linkedAccount = state.linkedAccount;
                this.connected = false; // Always require reconnect for security

                // Show reconnect prompt if previously connected
                if (this.walletAddress) {
                    this.showReconnectPrompt();
                }
            }
        } catch (e) {
            console.error('[WalletManager] Error loading saved state:', e);
        }
    }

    /**
     * Save wallet state to localStorage
     */
    saveState() {
        try {
            const state = {
                walletAddress: this.walletAddress,
                linkedAccount: this.linkedAccount,
                lastConnected: new Date().toISOString()
            };
            localStorage.setItem('voicelink_wallet_state', JSON.stringify(state));
        } catch (e) {
            console.error('[WalletManager] Error saving state:', e);
        }
    }

    /**
     * Clear saved wallet state
     */
    clearState() {
        localStorage.removeItem('voicelink_wallet_state');
        this.walletAddress = null;
        this.linkedAccount = null;
        this.connected = false;
        this.mintedRooms = [];
        this.accessPasses = [];
    }

    /**
     * Initialize UI event handlers
     */
    initUIHandlers() {
        // Connect wallet button
        document.getElementById('connect-ecripto-wallet-btn')?.addEventListener('click', () => {
            this.showPermissionModal();
        });

        // Approve wallet connection
        document.getElementById('approve-wallet-connection')?.addEventListener('click', () => {
            this.connectWallet();
        });

        // Deny wallet connection
        document.getElementById('deny-wallet-connection')?.addEventListener('click', () => {
            this.hidePermissionModal();
        });

        // See more details button
        document.getElementById('see-permission-details')?.addEventListener('click', () => {
            this.showDetailedPermissions();
        });

        // Disconnect wallet button
        document.getElementById('disconnect-wallet-btn')?.addEventListener('click', () => {
            this.showDisconnectModal();
        });

        // Confirm disconnect
        document.getElementById('confirm-disconnect-wallet')?.addEventListener('click', () => {
            this.disconnectWallet();
        });

        // Cancel disconnect
        document.getElementById('cancel-disconnect-wallet')?.addEventListener('click', () => {
            this.hideDisconnectModal();
        });

        // Link wallet button (from link account section)
        document.getElementById('link-wallet-btn')?.addEventListener('click', () => {
            this.showPermissionModal();
        });

        // Connect wallet for payment
        document.getElementById('connect-wallet-for-payment')?.addEventListener('click', () => {
            this.showPermissionModal();
        });

        // Payment method tabs
        document.querySelectorAll('.payment-tab').forEach(tab => {
            tab.addEventListener('click', (e) => {
                this.switchPaymentMethod(e.target.dataset.method);
            });
        });

        // Access tier selection
        document.querySelectorAll('input[name="access-tier"]').forEach(radio => {
            radio.addEventListener('change', () => {
                this.updatePurchaseSummary();
            });
        });

        // Confirm purchase
        document.getElementById('confirm-purchase')?.addEventListener('click', () => {
            this.processPurchase();
        });

        // Cancel purchase
        document.getElementById('cancel-purchase')?.addEventListener('click', () => {
            this.hidePurchaseModal();
        });
    }

    /**
     * Show the wallet permission modal
     */
    showPermissionModal() {
        const modal = document.getElementById('wallet-permission-modal');
        if (modal) {
            modal.style.display = 'flex';
            // Reset to basic view
            const detailsSection = document.getElementById('detailed-permissions');
            if (detailsSection) {
                detailsSection.style.display = 'none';
            }
        }
    }

    /**
     * Hide the wallet permission modal
     */
    hidePermissionModal() {
        const modal = document.getElementById('wallet-permission-modal');
        if (modal) {
            modal.style.display = 'none';
        }
    }

    /**
     * Show detailed permission information
     */
    showDetailedPermissions() {
        const detailsSection = document.getElementById('detailed-permissions');
        if (detailsSection) {
            detailsSection.style.display = 'block';
        }

        const seeMoreBtn = document.getElementById('see-permission-details');
        if (seeMoreBtn) {
            seeMoreBtn.style.display = 'none';
        }
    }

    /**
     * Show reconnect prompt for previously connected wallet
     */
    showReconnectPrompt() {
        const shortAddress = this.formatAddress(this.walletAddress);
        console.log('[WalletManager] Previously connected wallet: ' + shortAddress);

        // Update UI to show reconnect option using safe DOM methods
        const connectBtn = document.getElementById('connect-ecripto-wallet-btn');
        if (connectBtn) {
            // Clear existing content
            connectBtn.textContent = '';
            // Create icon span
            const icon = document.createElement('span');
            icon.className = 'wallet-icon';
            icon.textContent = '\uD83D\uDD17'; // Link emoji
            connectBtn.appendChild(icon);
            // Add text
            connectBtn.appendChild(document.createTextNode(' Reconnect ' + shortAddress));
        }
    }

    /**
     * Connect to Ecripto wallet
     */
    async connectWallet() {
        if (this.connectionPending) return;
        this.connectionPending = true;

        try {
            this.hidePermissionModal();
            this.app.showNotification('Connecting to Ecripto wallet...', 'info');

            // Check for Ecripto wallet provider
            if (typeof window.ecripto !== 'undefined') {
                // Native Ecripto wallet
                await this.connectEcriptoWallet();
            } else if (typeof window.ethereum !== 'undefined') {
                // Fallback to Ethereum-compatible wallet (MetaMask, etc.)
                await this.connectEthereumWallet();
            } else {
                // No wallet found - show install prompt
                this.showWalletInstallPrompt();
                return;
            }

            // Successfully connected
            this.connected = true;
            this.saveState();
            this.updateWalletUI();

            // Fetch user's minted rooms and access passes
            await this.fetchUserAssets();

            // Verify with server
            await this.verifyWithServer();

            this.app.showNotification('Wallet connected successfully!', 'success');

            // Link to existing account if logged in
            if (this.app.currentUser && !this.linkedAccount) {
                await this.linkToAccount();
            }

        } catch (error) {
            console.error('[WalletManager] Connection error:', error);
            this.app.showNotification('Failed to connect wallet: ' + error.message, 'error');
        } finally {
            this.connectionPending = false;
        }
    }

    /**
     * Connect to native Ecripto wallet
     */
    async connectEcriptoWallet() {
        // Request account access
        const accounts = await window.ecripto.request({ method: 'ecripto_requestAccounts' });

        if (accounts.length === 0) {
            throw new Error('No accounts found');
        }

        this.walletAddress = accounts[0];
        this.walletProvider = 'ecripto';

        // Get network info
        const network = await window.ecripto.request({ method: 'ecripto_chainId' });
        console.log('[WalletManager] Connected to Ecripto network: ' + network);

        // Listen for account changes
        window.ecripto.on('accountsChanged', (accounts) => {
            if (accounts.length === 0) {
                this.handleWalletDisconnected();
            } else {
                this.walletAddress = accounts[0];
                this.updateWalletUI();
            }
        });
    }

    /**
     * Connect to Ethereum-compatible wallet (fallback)
     */
    async connectEthereumWallet() {
        // Request account access
        const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });

        if (accounts.length === 0) {
            throw new Error('No accounts found');
        }

        this.walletAddress = accounts[0];
        this.walletProvider = 'ethereum';

        // Listen for account changes
        window.ethereum.on('accountsChanged', (accounts) => {
            if (accounts.length === 0) {
                this.handleWalletDisconnected();
            } else {
                this.walletAddress = accounts[0];
                this.updateWalletUI();
            }
        });
    }

    /**
     * Show wallet installation prompt
     */
    showWalletInstallPrompt() {
        this.app.showNotification(
            'No Ecripto wallet found. Install the Ecripto browser extension to continue.',
            'warning'
        );

        // Could open install page
        // window.open('https://ecripto.io/wallet', '_blank');
    }

    /**
     * Handle wallet disconnected by provider
     */
    handleWalletDisconnected() {
        console.log('[WalletManager] Wallet disconnected by provider');
        this.connected = false;
        this.updateWalletUI();
        this.app.showNotification('Wallet disconnected', 'info');
    }

    /**
     * Show disconnect confirmation modal
     */
    async showDisconnectModal() {
        // Fetch current assets to show in modal
        await this.fetchUserAssets();

        // Update modal with asset counts
        const mintedCount = document.getElementById('minted-rooms-count');
        if (mintedCount) {
            mintedCount.textContent = 'You own ' + this.mintedRooms.length + ' minted room(s)';
        }

        const passesCount = document.getElementById('access-passes-count');
        if (passesCount) {
            const activeCount = this.accessPasses.filter(p => new Date(p.expiresAt) > new Date()).length;
            passesCount.textContent = 'You have ' + activeCount + ' active access pass(es)';
        }

        // Show minted rooms options if user has minted rooms
        const mintedRoomsOptions = document.getElementById('minted-rooms-options');
        if (mintedRoomsOptions) {
            mintedRoomsOptions.style.display = this.mintedRooms.length > 0 ? 'block' : 'none';
        }

        const modal = document.getElementById('wallet-disconnect-modal');
        if (modal) {
            modal.style.display = 'flex';
        }
    }

    /**
     * Hide disconnect modal
     */
    hideDisconnectModal() {
        const modal = document.getElementById('wallet-disconnect-modal');
        if (modal) {
            modal.style.display = 'none';
        }
    }

    /**
     * Disconnect wallet
     */
    async disconnectWallet() {
        if (this.disconnectionPending) return;
        this.disconnectionPending = true;

        try {
            const checkedInput = document.querySelector('input[name="disconnect-action"]:checked');
            const action = checkedInput ? checkedInput.value : 'keep-linked';

            // Get minted rooms action if applicable
            const mintedInput = document.querySelector('input[name="minted-action"]:checked');
            const mintedAction = mintedInput ? mintedInput.value : 'keep-active';

            // Handle minted rooms based on user selection
            if (this.mintedRooms.length > 0) {
                await this.handleMintedRoomsOnDisconnect(mintedAction);
            }

            if (action === 'unlink-fully') {
                // Fully unlink - clear all saved state
                this.clearState();

                // Notify server
                await fetch('/api/ecripto/unlink-wallet', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        walletAddress: this.walletAddress,
                        mintedAction: mintedAction
                    })
                });

                this.app.showNotification('Wallet fully unlinked', 'info');
            } else {
                // Keep linked - just disconnect session
                this.connected = false;
                this.saveState();

                this.app.showNotification('Wallet disconnected. Your account remembers this wallet.', 'info');
            }

            this.hideDisconnectModal();
            this.updateWalletUI();

        } catch (error) {
            console.error('[WalletManager] Disconnect error:', error);
            this.app.showNotification('Error disconnecting wallet', 'error');
        } finally {
            this.disconnectionPending = false;
        }
    }

    /**
     * Handle minted rooms based on user's disconnect preference
     */
    async handleMintedRoomsOnDisconnect(action) {
        try {
            const response = await fetch('/api/ecripto/handle-disconnect', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    walletAddress: this.walletAddress,
                    action: action,
                    roomIds: this.mintedRooms.map(r => r.id || r.roomId),
                    fallbackAccount: this.linkedAccount
                })
            });

            const result = await response.json();

            if (result.success) {
                switch (action) {
                    case 'keep-active':
                        this.app.showNotification('Rooms will stay active. Reconnect to manage them.', 'info');
                        break;
                    case 'mark-inactive':
                        this.app.showNotification('Rooms marked as inactive until you reconnect.', 'info');
                        break;
                    case 'transfer-fallback':
                        this.app.showNotification('Room management transferred to your linked account.', 'info');
                        break;
                    case 'delegate-admin':
                        this.app.showNotification('Rooms delegated to VoiceLink admins.', 'info');
                        break;
                }
            }

            return result;
        } catch (error) {
            console.error('[WalletManager] Error handling minted rooms:', error);
        }
    }

    /**
     * Verify wallet with server
     */
    async verifyWithServer() {
        try {
            // Create signature for verification
            const message = 'VoiceLink wallet verification: ' + Date.now();
            let signature;

            if (this.walletProvider === 'ecripto') {
                signature = await window.ecripto.request({
                    method: 'personal_sign',
                    params: [message, this.walletAddress]
                });
            } else {
                signature = await window.ethereum.request({
                    method: 'personal_sign',
                    params: [message, this.walletAddress]
                });
            }

            // Send to server for verification
            const response = await fetch('/api/ecripto/verify-wallet', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    walletAddress: this.walletAddress,
                    signature,
                    message
                })
            });

            const result = await response.json();

            if (!result.verified) {
                throw new Error('Server verification failed');
            }

            return result;
        } catch (error) {
            console.error('[WalletManager] Server verification error:', error);
            // Continue anyway - verification is optional enhancement
        }
    }

    /**
     * Fetch user's minted rooms and access passes
     */
    async fetchUserAssets() {
        if (!this.walletAddress) return;

        try {
            // Fetch minted rooms
            const roomsResponse = await fetch('/api/rooms/filter?minted=true&mintOwner=' + encodeURIComponent(this.walletAddress));
            const roomsData = await roomsResponse.json();
            this.mintedRooms = roomsData.rooms || [];

            // Fetch access passes (would need wallet-specific endpoint)
            // this.accessPasses = ...

        } catch (error) {
            console.error('[WalletManager] Error fetching assets:', error);
        }
    }

    /**
     * Link wallet to existing VoiceLink account
     */
    async linkToAccount() {
        if (!this.app.currentUser) return;

        try {
            const response = await fetch('/api/auth/link-wallet', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    walletAddress: this.walletAddress,
                    userId: this.app.currentUser.id
                })
            });

            if (response.ok) {
                this.linkedAccount = this.app.currentUser;
                this.saveState();
                this.app.showNotification('Wallet linked to your account', 'success');
            }
        } catch (error) {
            console.error('[WalletManager] Error linking wallet:', error);
        }
    }

    /**
     * Update wallet UI elements using safe DOM methods
     */
    updateWalletUI() {
        const connectBtn = document.getElementById('connect-ecripto-wallet-btn');
        const connectedStatus = document.getElementById('wallet-connected-status');
        const addressDisplay = document.getElementById('wallet-address-short');
        const paymentReady = document.getElementById('wallet-payment-ready');
        const paymentConnect = document.getElementById('wallet-payment-connect');
        const paymentAddress = document.getElementById('payment-wallet-address');

        if (this.connected && this.walletAddress) {
            const shortAddress = this.formatAddress(this.walletAddress);

            // Update login tab
            if (connectBtn) connectBtn.style.display = 'none';
            if (connectedStatus) connectedStatus.style.display = 'block';
            if (addressDisplay) addressDisplay.textContent = shortAddress;

            // Update payment section
            if (paymentReady) paymentReady.style.display = 'block';
            if (paymentConnect) paymentConnect.style.display = 'none';
            if (paymentAddress) paymentAddress.textContent = shortAddress;

        } else {
            // Show connect button with safe DOM manipulation
            if (connectBtn) {
                connectBtn.style.display = 'block';
                connectBtn.textContent = '';

                const icon = document.createElement('span');
                icon.className = 'wallet-icon';
                icon.textContent = '\uD83D\uDD17'; // Link emoji
                connectBtn.appendChild(icon);

                if (this.walletAddress) {
                    connectBtn.appendChild(document.createTextNode(' Reconnect ' + this.formatAddress(this.walletAddress)));
                } else {
                    connectBtn.appendChild(document.createTextNode(' Connect Ecripto Wallet'));
                }
            }
            if (connectedStatus) connectedStatus.style.display = 'none';

            // Update payment section
            if (paymentReady) paymentReady.style.display = 'none';
            if (paymentConnect) paymentConnect.style.display = 'block';
        }
    }

    /**
     * Format wallet address for display
     */
    formatAddress(address) {
        if (!address) return '';
        return address.slice(0, 6) + '...' + address.slice(-4);
    }

    /**
     * Show purchase modal for room access
     */
    showPurchaseModal(room, tiers) {
        const roomName = document.getElementById('purchase-room-name');
        const roomDesc = document.getElementById('purchase-room-description');

        if (roomName) roomName.textContent = room.name;
        if (roomDesc) roomDesc.textContent = room.description || 'Premium room access';

        // Update tier prices
        tiers.forEach(tier => {
            const priceEl = document.getElementById(tier.id + '-pass-price');
            if (priceEl) {
                priceEl.textContent = tier.price ? ('$' + tier.price) : 'Free';
            }
        });

        this.currentPurchaseRoom = room;
        this.currentTiers = tiers;
        this.updatePurchaseSummary();

        const modal = document.getElementById('purchase-access-modal');
        if (modal) {
            modal.style.display = 'flex';
        }
    }

    /**
     * Hide purchase modal
     */
    hidePurchaseModal() {
        const modal = document.getElementById('purchase-access-modal');
        if (modal) {
            modal.style.display = 'none';
        }
        this.currentPurchaseRoom = null;
    }

    /**
     * Switch payment method tab
     */
    switchPaymentMethod(method) {
        // Update tabs
        document.querySelectorAll('.payment-tab').forEach(tab => {
            tab.classList.toggle('active', tab.dataset.method === method);
        });

        // Update sections
        const walletSection = document.getElementById('wallet-payment-section');
        const cardSection = document.getElementById('card-payment-section');

        if (walletSection) walletSection.style.display = method === 'wallet' ? 'block' : 'none';
        if (cardSection) cardSection.style.display = method === 'card' ? 'block' : 'none';

        this.currentPaymentMethod = method;

        // Initialize Stripe if switching to card
        if (method === 'card' && !this.stripeInitialized) {
            this.initStripe();
        }
    }

    /**
     * Update purchase summary
     */
    updatePurchaseSummary() {
        const selectedInput = document.querySelector('input[name="access-tier"]:checked');
        const selectedTier = selectedInput ? selectedInput.value : null;
        const tier = this.currentTiers ? this.currentTiers.find(t => t.id === selectedTier) : null;

        const summaryTier = document.getElementById('summary-tier');
        const summaryTotal = document.getElementById('summary-total');

        if (tier) {
            if (summaryTier) summaryTier.textContent = tier.name;
            if (summaryTotal) summaryTotal.textContent = tier.price ? ('$' + tier.price) : 'Free';
        }
    }

    /**
     * Process the purchase
     */
    async processPurchase() {
        const selectedInput = document.querySelector('input[name="access-tier"]:checked');
        const selectedTier = selectedInput ? selectedInput.value : null;
        const paymentMethod = this.currentPaymentMethod || 'wallet';

        if (!this.currentPurchaseRoom || !selectedTier) {
            this.app.showNotification('Please select an access tier', 'error');
            return;
        }

        try {
            this.app.showNotification('Processing purchase...', 'info');

            if (paymentMethod === 'wallet') {
                await this.processWalletPayment(selectedTier);
            } else {
                await this.processCardPayment(selectedTier);
            }

            this.app.showNotification('Purchase complete! Access granted.', 'success');
            this.hidePurchaseModal();

        } catch (error) {
            console.error('[WalletManager] Purchase error:', error);
            this.app.showNotification('Purchase failed: ' + error.message, 'error');
        }
    }

    /**
     * Process payment via wallet
     */
    async processWalletPayment(tierId) {
        if (!this.connected) {
            throw new Error('Wallet not connected');
        }

        // Call server to create access pass
        const response = await fetch('/api/ecripto/purchase-access', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                roomId: this.currentPurchaseRoom.id,
                tier: tierId,
                walletAddress: this.walletAddress,
                transactionId: 'pending_' + Date.now() // Would be real tx ID
            })
        });

        const result = await response.json();
        if (!result.success) {
            throw new Error(result.error || 'Purchase failed');
        }

        return result;
    }

    /**
     * Process payment via Stripe card
     */
    async processCardPayment(tierId) {
        if (!this.stripe || !this.cardElement) {
            throw new Error('Stripe not initialized');
        }

        // Create payment intent on server
        const response = await fetch('/api/stripe/create-payment-intent', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                roomId: this.currentPurchaseRoom.id,
                tier: tierId
            })
        });

        const data = await response.json();

        // Confirm payment with Stripe
        const result = await this.stripe.confirmCardPayment(data.clientSecret, {
            payment_method: {
                card: this.cardElement
            }
        });

        if (result.error) {
            throw new Error(result.error.message);
        }

        return result.paymentIntent;
    }

    /**
     * Initialize Stripe Elements
     */
    async initStripe() {
        if (this.stripeInitialized) return;

        try {
            // Load Stripe.js if not already loaded
            if (!window.Stripe) {
                await this.loadStripeScript();
            }

            // Get publishable key from server
            const response = await fetch('/api/stripe/config');
            const data = await response.json();

            if (!data.publishableKey) {
                console.warn('[WalletManager] Stripe not configured');
                return;
            }

            this.stripe = Stripe(data.publishableKey);
            const elements = this.stripe.elements();

            this.cardElement = elements.create('card', {
                style: {
                    base: {
                        color: '#e0e0e0',
                        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
                        fontSize: '16px',
                        '::placeholder': {
                            color: '#888'
                        }
                    }
                }
            });

            this.cardElement.mount('#stripe-card-element');
            this.stripeInitialized = true;

        } catch (error) {
            console.error('[WalletManager] Stripe init error:', error);
        }
    }

    /**
     * Load Stripe.js script
     */
    loadStripeScript() {
        return new Promise((resolve, reject) => {
            const script = document.createElement('script');
            script.src = 'https://js.stripe.com/v3/';
            script.onload = resolve;
            script.onerror = reject;
            document.head.appendChild(script);
        });
    }

    /**
     * Mint a room as NFT
     */
    async mintRoom(roomId, price, metadata) {
        if (!this.connected) {
            this.showPermissionModal();
            return;
        }

        try {
            this.app.showNotification('Preparing to mint room...', 'info');

            const response = await fetch('/api/ecripto/mint-room', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    roomId,
                    walletAddress: this.walletAddress,
                    price: price || null,
                    metadata: metadata || {}
                })
            });

            const result = await response.json();

            if (result.success) {
                this.app.showNotification('Room minted successfully!', 'success');
                await this.fetchUserAssets();
            } else {
                throw new Error(result.error);
            }

            return result;
        } catch (error) {
            console.error('[WalletManager] Mint error:', error);
            this.app.showNotification('Failed to mint room: ' + error.message, 'error');
        }
    }

    /**
     * Check if user has access to a room
     */
    async checkRoomAccess(roomId) {
        if (!this.walletAddress) {
            return { hasAccess: false, reason: 'No wallet connected' };
        }

        try {
            const response = await fetch(
                '/api/ecripto/check-access/' + encodeURIComponent(roomId) + '?walletAddress=' + encodeURIComponent(this.walletAddress)
            );
            return await response.json();
        } catch (error) {
            console.error('[WalletManager] Access check error:', error);
            return { hasAccess: false, reason: 'Error checking access' };
        }
    }

    /**
     * Get Ecripto integration status
     */
    async getStatus() {
        try {
            const response = await fetch('/api/ecripto/status');
            return await response.json();
        } catch (error) {
            return { enabled: false };
        }
    }
}

// Export for use in app
if (typeof module !== 'undefined' && module.exports) {
    module.exports = WalletManager;
}
