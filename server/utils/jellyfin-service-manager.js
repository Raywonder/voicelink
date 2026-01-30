/**
 * Jellyfin Service Manager
 * 
 * Manages Jellyfin media server processes with automatic monitoring,
 * restart capabilities, and integration with VoiceLink API.
 */

const { spawn, exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const EventEmitter = require('events');

class JellyfinServiceManager extends EventEmitter {
    constructor() {
        super();
        this.processes = new Map(); // processName -> process info
        this.config = {
            checkInterval: 30000, // 30 seconds
            restartDelay: 5000, // 5 seconds
            maxRestartAttempts: 3,
            restartWindow: 300000, // 5 minutes
            logFile: '/home/devinecr/logs/jellyfin-manager.log'
        };
        this.restartCounters = new Map(); // processName -> { count, lastAttempt }
        this.monitoringInterval = null;
        this.ensureLogDirectory();
    }

    /**
     * Ensure log directory exists
     */
    ensureLogDirectory() {
        const logDir = path.dirname(this.config.logFile);
        if (!fs.existsSync(logDir)) {
            fs.mkdirSync(logDir, { recursive: true });
        }
    }

    /**
     * Write log message
     */
    log(message) {
        const timestamp = new Date().toISOString();
        const logMessage = `[${timestamp}] ${message}\n`;
        console.log(`[JellyfinManager] ${message}`);
        fs.appendFileSync(this.config.logFile, logMessage);
    }

    /**
     * Start monitoring Jellyfin processes
     */
    startMonitoring() {
        if (this.monitoringInterval) return;
        
        this.monitoringInterval = setInterval(() => {
            this.checkAllProcesses();
        }, this.config.checkInterval);
        
        this.log('Started Jellyfin process monitoring');
    }

    /**
     * Stop monitoring
     */
    stopMonitoring() {
        if (this.monitoringInterval) {
            clearInterval(this.monitoringInterval);
            this.monitoringInterval = null;
            this.log('Stopped Jellyfin process monitoring');
        }
    }

    /**
     * Discover Jellyfin processes on the system
     */
    async discoverProcesses() {
        return new Promise((resolve) => {
            exec('ps aux | grep -i jellyfin | grep -v grep', (error, stdout, stderr) => {
                const processes = [];
                if (stdout) {
                    const lines = stdout.trim().split('\n');
                    lines.forEach(line => {
                        const parts = line.trim().split(/\s+/);
                        if (parts.length >= 11) {
                            const pid = parts[1];
                            const user = parts[0];
                            const command = parts.slice(10).join(' ');
                            
                            // Extract process name and port
                            let processName = 'jellyfin-default';
                            let port = 8096;
                            
                            if (command.includes('--published-server-url')) {
                                const portMatch = command.match(/:(\d+)/);
                                if (portMatch) port = parseInt(portMatch[1]);
                            }
                            
                            if (user === 'tappedin') {
                                processName = 'jellyfin-tappedin';
                            } else if (user === 'dom') {
                                processName = 'jellyfin-dom';
                            } else if (user === 'devinecr') {
                                processName = 'jellyfin-devinecr';
                            }

                            processes.push({
                                name: processName,
                                pid: parseInt(pid),
                                user: user,
                                command: command,
                                port: port,
                                status: 'running',
                                managed: false
                            });
                        }
                    });
                }
                resolve(processes);
            });
        });
    }

    /**
     * Get all known processes (discovered + managed)
     */
    async getAllProcesses() {
        const discovered = await this.discoverProcesses();
        const all = [...discovered];

        // Add managed processes info
        this.processes.forEach((managedInfo, name) => {
            const existing = all.find(p => p.name === name);
            if (existing) {
                existing.managed = true;
                existing.config = managedInfo.config;
            } else {
                all.push({
                    name: name,
                    pid: null,
                    user: managedInfo.config?.user || 'unknown',
                    command: managedInfo.config?.command || '',
                    port: managedInfo.config?.port || 8096,
                    status: 'stopped',
                    managed: true,
                    config: managedInfo.config
                });
            }
        });

        return all;
    }

    /**
     * Register a Jellyfin process for management
     */
    registerProcess(name, config) {
        this.processes.set(name, {
            config: {
                user: config.user || 'devinecr',
                command: config.command || '/home/tappedin/apps/jellyfin/jellyfin/jellyfin --datadir /home/tappedin/apps/jellyfin/config --cachedir /home/tappedin/apps/jellyfin/cache --webdir /home/tappedin/apps/jellyfin/jellyfin/jellyfin-web --published-server-url http://127.0.0.1:9096 --service --nowebclient=false',
                port: config.port || 9096,
                workingDirectory: config.workingDirectory || '/home/tappedin/apps/jellyfin',
                ...config
            },
            startedAt: null,
            pid: null,
            status: 'stopped'
        });
        
        this.log(`Registered process: ${name}`);
        this.emit('processRegistered', name, config);
    }

    /**
     * Start a specific Jellyfin process
     */
    async startProcess(name) {
        const processInfo = this.processes.get(name);
        if (!processInfo) {
            throw new Error(`Process ${name} not registered`);
        }

        // Check restart limits
        const counter = this.restartCounters.get(name) || { count: 0, lastAttempt: 0 };
        const now = Date.now();
        
        if (now - counter.lastAttempt < this.config.restartWindow) {
            if (counter.count >= this.config.maxRestartAttempts) {
                this.log(`Max restart attempts reached for ${name}. Skipping restart.`);
                return false;
            }
        } else {
            // Reset counter if window passed
            counter.count = 0;
        }

        // Check if process is already running
        const existingProcesses = await this.discoverProcesses();
        const existing = existingProcesses.find(p => p.name === name || p.port === processInfo.config.port);
        
        if (existing) {
            this.log(`Process ${name} is already running (PID: ${existing.pid})`);
            processInfo.pid = existing.pid;
            processInfo.status = 'running';
            processInfo.startedAt = new Date();
            return true;
        }

        return new Promise((resolve, reject) => {
            this.log(`Starting process: ${name}`);

            const args = processInfo.config.command.split(' ');
            const command = args.shift();

            const child = spawn(command, args, {
                user: processInfo.config.user,
                cwd: processInfo.config.workingDirectory,
                detached: true,
                stdio: ['ignore', 'ignore', 'ignore']
            });

            child.unref();

            // Wait a moment to check if process started successfully
            setTimeout(async () => {
                const runningProcesses = await this.discoverProcesses();
                const started = runningProcesses.find(p => p.pid === child.pid);
                
                if (started) {
                    processInfo.pid = child.pid;
                    processInfo.status = 'running';
                    processInfo.startedAt = new Date();
                    
                    // Update restart counter
                    counter.count++;
                    counter.lastAttempt = now;
                    this.restartCounters.set(name, counter);
                    
                    this.log(`Successfully started ${name} (PID: ${child.pid})`);
                    this.emit('processStarted', name, child.pid);
                    resolve(true);
                } else {
                    this.log(`Failed to start ${name}`);
                    this.emit('processStartFailed', name);
                    resolve(false);
                }
            }, 2000);
        });
    }

    /**
     * Stop a specific Jellyfin process
     */
    async stopProcess(name, graceful = true) {
        const processInfo = this.processes.get(name);
        if (!processInfo) {
            throw new Error(`Process ${name} not registered`);
        }

        const processes = await this.discoverProcesses();
        const running = processes.find(p => p.name === name || p.port === processInfo.config.port);
        
        if (!running) {
            this.log(`Process ${name} is not running`);
            return true;
        }

        return new Promise((resolve) => {
            this.log(`Stopping process: ${name} (PID: ${running.pid})`);

            if (graceful) {
                exec(`kill -TERM ${running.pid}`, async (error) => {
                    // Wait a moment for graceful shutdown
                    setTimeout(async () => {
                        const stillRunning = await this.discoverProcesses();
                        const exists = stillRunning.find(p => p.pid === running.pid);
                        
                        if (exists) {
                            // Force kill if still running
                            exec(`kill -KILL ${running.pid}`, () => {
                                this.log(`Force killed ${name}`);
                                resolve(true);
                            });
                        } else {
                            this.log(`Gracefully stopped ${name}`);
                            resolve(true);
                        }
                    }, 5000);
                });
            } else {
                exec(`kill -KILL ${running.pid}`, () => {
                    this.log(`Force killed ${name}`);
                    resolve(true);
                });
            }
        });
    }

    /**
     * Restart a specific Jellyfin process
     */
    async restartProcess(name) {
        this.log(`Restarting process: ${name}`);
        await this.stopProcess(name);
        setTimeout(async () => {
            await this.startProcess(name);
        }, this.config.restartDelay);
    }

    /**
     * Check all registered processes and restart if needed
     */
    async checkAllProcesses() {
        const processes = await this.discoverProcesses();
        
        for (const [name, processInfo] of this.processes) {
            const isRunning = processes.some(p => 
                p.name === name || 
                (processInfo.config.port && p.port === processInfo.config.port)
            );

            if (!isRunning && processInfo.status === 'running') {
                this.log(`Detected stopped process: ${name}. Attempting restart...`);
                const started = await this.startProcess(name);
                if (started) {
                    this.emit('processAutoRestarted', name);
                } else {
                    this.emit('processRestartFailed', name);
                }
            } else if (isRunning) {
                const runningProcess = processes.find(p => 
                    p.name === name || 
                    (processInfo.config.port && p.port === processInfo.config.port)
                );
                processInfo.pid = runningProcess.pid;
                processInfo.status = 'running';
            }
        }
    }

    /**
     * Get process status
     */
    async getProcessStatus(name) {
        const processInfo = this.processes.get(name);
        if (!processInfo) {
            return null;
        }

        const processes = await this.discoverProcesses();
        const running = processes.find(p => 
            p.name === name || 
            (processInfo.config.port && p.port === processInfo.config.port)
        );

        return {
            name: name,
            config: processInfo.config,
            status: running ? 'running' : 'stopped',
            pid: running ? running.pid : null,
            startedAt: processInfo.startedAt,
            managed: true
        };
    }

    /**
     * Cleanup
     */
    cleanup() {
        this.stopMonitoring();
        this.processes.clear();
        this.restartCounters.clear();
    }
}

module.exports = JellyfinServiceManager;