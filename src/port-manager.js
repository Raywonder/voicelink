/**
 * Port Configuration Manager
 * Handles port availability checking and configuration
 */

const net = require('net');
const fs = require('fs');
const path = require('path');
const { app } = require('electron');

class PortManager {
    constructor() {
        this.configPath = path.join(app.getPath('userData'), 'port-config.json');
        this.defaultConfig = {
            localServerPort: 4004,  // Safer default, less likely to conflict
            remoteServerPort: 4005,
            webSocketPort: 4006,
            rtcPorts: {
                min: 10000,
                max: 20000
            },
            lastChecked: null,
            autoDetect: true,
            preferredPortRange: {
                start: 4000,
                end: 4999
            },
            avoidPorts: [3000, 3001, 8080, 8081, 5000, 4200, 9000] // Common conflicting ports
        };
        this.config = this.loadConfig();
    }

    loadConfig() {
        try {
            if (fs.existsSync(this.configPath)) {
                const data = fs.readFileSync(this.configPath, 'utf8');
                return { ...this.defaultConfig, ...JSON.parse(data) };
            }
        } catch (error) {
            console.error('Error loading port config:', error);
        }
        return this.defaultConfig;
    }

    saveConfig() {
        try {
            fs.writeFileSync(this.configPath, JSON.stringify(this.config, null, 2));
            return true;
        } catch (error) {
            console.error('Error saving port config:', error);
            return false;
        }
    }

    async checkPortAvailable(port) {
        return new Promise((resolve) => {
            const server = net.createServer();

            server.once('error', (err) => {
                if (err.code === 'EADDRINUSE') {
                    resolve(false);
                } else {
                    resolve(false);
                }
            });

            server.once('listening', () => {
                server.close(() => {
                    resolve(true);
                });
            });

            server.listen(port, '0.0.0.0');
        });
    }

    async findAvailablePort(startPort, endPort = startPort + 100) {
        for (let port = startPort; port <= endPort; port++) {
            // Skip ports we want to avoid
            if (this.config.avoidPorts && this.config.avoidPorts.includes(port)) {
                continue;
            }

            const isAvailable = await this.checkPortAvailable(port);
            if (isAvailable) {
                return port;
            }
        }
        throw new Error(`No available ports found between ${startPort} and ${endPort}`);
    }

    async findBestAvailablePort() {
        const { start, end } = this.config.preferredPortRange;

        // First try the configured port
        if (await this.checkPortAvailable(this.config.localServerPort)) {
            return this.config.localServerPort;
        }

        // Then scan the preferred range
        try {
            return await this.findAvailablePort(start, end);
        } catch (error) {
            // Fallback to a wider range if preferred range is full
            console.warn('Preferred port range full, scanning wider range...');
            return await this.findAvailablePort(4000, 9999);
        }
    }

    async checkAllPorts() {
        const results = {
            localServer: {
                port: this.config.localServerPort,
                available: await this.checkPortAvailable(this.config.localServerPort)
            },
            remoteServer: {
                port: this.config.remoteServerPort,
                available: await this.checkPortAvailable(this.config.remoteServerPort)
            },
            webSocket: {
                port: this.config.webSocketPort,
                available: await this.checkPortAvailable(this.config.webSocketPort)
            }
        };

        // Find alternatives if ports are taken
        if (!results.localServer.available && this.config.autoDetect) {
            try {
                results.localServer.suggested = await this.findBestAvailablePort();
            } catch (error) {
                console.error('Could not find alternative port for local server:', error);
            }
        }
        if (!results.remoteServer.available && this.config.autoDetect) {
            try {
                results.remoteServer.suggested = await this.findAvailablePort(this.config.remoteServerPort + 1, this.config.remoteServerPort + 100);
            } catch (error) {
                console.error('Could not find alternative port for remote server:', error);
            }
        }
        if (!results.webSocket.available && this.config.autoDetect) {
            try {
                results.webSocket.suggested = await this.findAvailablePort(this.config.webSocketPort + 1, this.config.webSocketPort + 100);
            } catch (error) {
                console.error('Could not find alternative port for WebSocket:', error);
            }
        }

        this.config.lastChecked = Date.now();
        return results;
    }

    async updatePorts(ports) {
        // Validate new ports
        const validation = {};

        if (ports.localServerPort) {
            validation.localServer = await this.checkPortAvailable(ports.localServerPort);
            if (validation.localServer) {
                this.config.localServerPort = ports.localServerPort;
            }
        }

        if (ports.remoteServerPort) {
            validation.remoteServer = await this.checkPortAvailable(ports.remoteServerPort);
            if (validation.remoteServer) {
                this.config.remoteServerPort = ports.remoteServerPort;
            }
        }

        if (ports.webSocketPort) {
            validation.webSocket = await this.checkPortAvailable(ports.webSocketPort);
            if (validation.webSocket) {
                this.config.webSocketPort = ports.webSocketPort;
            }
        }

        if (ports.autoDetect !== undefined) {
            this.config.autoDetect = ports.autoDetect;
        }

        this.saveConfig();
        return validation;
    }

    getConfig() {
        return { ...this.config };
    }

    async getRecommendedPorts() {
        const checkResults = await this.checkAllPorts();
        const recommended = {};

        recommended.localServerPort = checkResults.localServer.available
            ? this.config.localServerPort
            : (checkResults.localServer.suggested || this.config.localServerPort);

        recommended.remoteServerPort = checkResults.remoteServer.available
            ? this.config.remoteServerPort
            : (checkResults.remoteServer.suggested || this.config.remoteServerPort);

        recommended.webSocketPort = checkResults.webSocket.available
            ? this.config.webSocketPort
            : (checkResults.webSocket.suggested || this.config.webSocketPort);

        return recommended;
    }

    async autoConfigurePorts() {
        const recommended = await this.getRecommendedPorts();
        await this.updatePorts(recommended);
        return recommended;
    }

    async validateCustomPort(port) {
        const portNum = parseInt(port);

        if (isNaN(portNum) || portNum < 1024 || portNum > 65535) {
            return {
                valid: false,
                error: 'Port must be between 1024 and 65535'
            };
        }

        if (this.config.avoidPorts.includes(portNum)) {
            return {
                valid: false,
                error: `Port ${portNum} is commonly used by other services (${this.getPortConflictInfo(portNum)})`
            };
        }

        const available = await this.checkPortAvailable(portNum);
        if (!available) {
            return {
                valid: false,
                error: `Port ${portNum} is already in use`
            };
        }

        return { valid: true, port: portNum };
    }

    getPortConflictInfo(port) {
        const conflicts = {
            3000: 'Rails/Node.js dev servers',
            3001: 'Mastodon, Next.js',
            8080: 'HTTP proxy servers',
            8081: 'HTTP alternative',
            5000: 'Flask development server',
            4200: 'Angular CLI dev server',
            9000: 'Various development tools'
        };
        return conflicts[port] || 'other services';
    }

    async scanPortRange(start = 4000, end = 5000, limit = 10) {
        const availablePorts = [];

        for (let port = start; port <= end && availablePorts.length < limit; port++) {
            if (this.config.avoidPorts.includes(port)) continue;

            const available = await this.checkPortAvailable(port);
            if (available) {
                availablePorts.push(port);
            }
        }

        return availablePorts;
    }

    getPortRecommendations() {
        return {
            safe: [4004, 4005, 4006, 4007, 4008],
            development: [4000, 4001, 4002, 4003],
            alternative: [7000, 7001, 7002, 6000, 6001],
            avoid: this.config.avoidPorts
        };
    }
}

module.exports = PortManager;