#!/usr/bin/env node
// agent-relay.js — Relay daemon bridging local agent log files with the remote dashboard via WebSocket.
//
// Usage: node scripts/agent-relay.js --ticket OXDEV-1234 [--dashboard ws://host:port/ws]
//
// Watches memory/tickets/<KEY>/stage-logs/*.jsonl for new lines and streams them
// to the remote dashboard. Receives commands from the dashboard and writes them
// to memory/tickets/<KEY>/inbox.json.

"use strict";

const fs = require("fs");
const path = require("path");
const { EventEmitter } = require("events");

// ---------------------------------------------------------------------------
// Resolve ws from E2E framework node_modules
// ---------------------------------------------------------------------------
const frameworkPath = process.env.E2E_FRAMEWORK_PATH || "";
let WebSocket;
try {
    WebSocket = require(path.join(frameworkPath, "node_modules", "ws"));
} catch {
    try {
        WebSocket = require("ws");
    } catch {
        console.error("[relay] FATAL: Cannot find 'ws' module. Set E2E_FRAMEWORK_PATH or install ws locally.");
        process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Parse CLI arguments (no external deps)
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
let ticketKey = "";
let dashboardUrl = "";

for (let i = 0; i < args.length; i++) {
    if (args[i] === "--ticket" && args[i + 1]) {
        ticketKey = args[++i];
    } else if (args[i] === "--dashboard" && args[i + 1]) {
        dashboardUrl = args[++i];
    }
}

if (!ticketKey) {
    console.error("Usage: node agent-relay.js --ticket OXDEV-1234 [--dashboard ws://host:port/ws]");
    process.exit(1);
}

// Validate ticket key format
if (!/^[A-Z0-9][-A-Za-z0-9]{1,50}$/.test(ticketKey)) {
    console.error(`[relay] Invalid ticket key format: ${ticketKey}`);
    process.exit(1);
}

if (!dashboardUrl) {
    const base = process.env.DASHBOARD_URL || "http://52.51.14.138:3459";
    dashboardUrl = base.replace(/^http/, "ws").replace(/\/$/, "") + "/ws";
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------
const projectRoot = path.resolve(__dirname, "..");
// Discovery scan keys: PR-toSTG-*, RFE-*, BUG-*, TASK-*, DIS-*, MR-*
const isDiscoveryScan = /^(PR-toSTG-|RFE-|BUG-|TASK-|DIS-|MR-|QA-)/.test(ticketKey);
const ticketDir = isDiscoveryScan
    ? path.join(projectRoot, "memory", "discovery", "scans", ticketKey)
    : path.join(projectRoot, "memory", "tickets", ticketKey);
const stageLogsDir = path.join(ticketDir, "stage-logs");
const inboxPath = path.join(ticketDir, "inbox.json");
const pidPath = path.join(ticketDir, "relay.pid");

// Ensure directories exist
fs.mkdirSync(stageLogsDir, { recursive: true });

// Write PID file
fs.writeFileSync(pidPath, String(process.pid), "utf8");

const log = (msg) => console.error(`[relay ${ticketKey}] ${msg}`);

// ---------------------------------------------------------------------------
// File offset tracking — only send new lines since last read
// ---------------------------------------------------------------------------
const fileOffsets = new Map(); // filePath -> byte offset

function readNewLines(filePath) {
    let fd;
    try {
        const stat = fs.statSync(filePath);
        const currentOffset = fileOffsets.get(filePath) || 0;
        if (stat.size <= currentOffset) return [];

        fd = fs.openSync(filePath, "r");
        const buf = Buffer.alloc(stat.size - currentOffset);
        fs.readSync(fd, buf, 0, buf.length, currentOffset);
        fs.closeSync(fd);
        fd = null;

        fileOffsets.set(filePath, stat.size);

        const text = buf.toString("utf8");
        const lines = text.split("\n").filter((l) => l.trim());
        const parsed = [];
        for (const line of lines) {
            try {
                parsed.push(JSON.parse(line));
            } catch {
                // Skip malformed lines
            }
        }
        return parsed;
    } catch {
        if (fd) try { fs.closeSync(fd); } catch {}
        return [];
    }
}

// ---------------------------------------------------------------------------
// Inbox management — write commands received from dashboard
// ---------------------------------------------------------------------------
function writeToInbox(command) {
    let inbox = { commands: [] };
    try {
        if (fs.existsSync(inboxPath)) {
            inbox = JSON.parse(fs.readFileSync(inboxPath, "utf8"));
            if (!Array.isArray(inbox.commands)) inbox.commands = [];
        }
    } catch {
        inbox = { commands: [] };
    }

    // Dedup by command id
    if (command.id && inbox.commands.some((c) => c.id === command.id)) {
        return;
    }

    inbox.commands.push(command);
    fs.writeFileSync(inboxPath, JSON.stringify(inbox, null, 2), "utf8");
    log(`Wrote command ${command.id || "?"} (${command.commandType || "?"}) to inbox`);

    // Also write feedback/hints directly to plain-text files for faster agent pickup
    const cmdType = command.commandType || command.type || "";
    const message = (command.payload && (command.payload.message || command.payload.hint)) || "";
    if (message) {
        const ticketDir = path.dirname(inboxPath);
        if (cmdType === "feedback") {
            const feedbackPath = path.join(ticketDir, "user-feedback.md");
            const entry = `\n### [${new Date().toISOString()}] Dashboard User\n${message}\n`;
            fs.appendFileSync(feedbackPath, entry, "utf8");
            log(`Appended feedback to user-feedback.md`);
        } else if (cmdType === "add_hint" || cmdType === "hint") {
            const hintsPath = path.join(ticketDir, "hints.md");
            const entry = `\n- ${message} (${new Date().toISOString()})\n`;
            fs.appendFileSync(hintsPath, entry, "utf8");
            log(`Appended hint to hints.md`);
        }
    }
}

// ---------------------------------------------------------------------------
// WebSocket connection with auto-reconnect
// ---------------------------------------------------------------------------
let ws = null;
let reconnectDelay = 1000;
const MAX_RECONNECT_DELAY = 30000;
let heartbeatInterval = null;
let shuttingDown = false;

function connect() {
    if (shuttingDown) return;

    log(`Connecting to ${dashboardUrl}`);
    ws = new WebSocket(dashboardUrl);

    ws.on("open", () => {
        log("Connected");
        reconnectDelay = 1000; // Reset backoff

        // Send hello
        wsSend({
            type: "relay_hello",
            ticketKey: ticketKey,
            pid: process.pid,
            timestamp: new Date().toISOString(),
        });

        // Flush any pending log lines immediately
        flushAllLogs();

        // Start heartbeat
        clearInterval(heartbeatInterval);
        heartbeatInterval = setInterval(() => {
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.ping();
            }
        }, 30000);
    });

    ws.on("message", (data) => {
        try {
            const msg = JSON.parse(data.toString());
            if (msg.type === "command") {
                writeToInbox(msg);
            }
        } catch {
            log("Received non-JSON message, ignoring");
        }
    });

    ws.on("close", () => {
        log("Disconnected");
        clearInterval(heartbeatInterval);
        scheduleReconnect();
    });

    ws.on("error", (err) => {
        log(`WS error: ${err.message}`);
        // close event will fire after this, triggering reconnect
    });
}

function scheduleReconnect() {
    if (shuttingDown) return;
    log(`Reconnecting in ${reconnectDelay / 1000}s`);
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
}

function wsSend(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        try {
            ws.send(JSON.stringify(obj));
        } catch (err) {
            log(`Send error: ${err.message}`);
        }
    }
}

// ---------------------------------------------------------------------------
// File watching — watch stage-logs directory for *.jsonl changes
// ---------------------------------------------------------------------------
const watchers = new Map(); // filePath -> fs.FSWatcher
let dirWatcher = null;

function watchFile(filePath) {
    if (watchers.has(filePath)) return;

    // Initialize offset to current file size so we only send new lines
    // (unless we haven't seen this file before — then start from 0 to catch up)
    if (!fileOffsets.has(filePath)) {
        fileOffsets.set(filePath, 0);
    }

    try {
        const watcher = fs.watch(filePath, () => {
            const logs = readNewLines(filePath);
            if (logs.length > 0) {
                wsSend({
                    type: "log_batch",
                    ticketKey: ticketKey,
                    stage: path.basename(filePath, ".jsonl"),
                    logs: logs,
                });
            }
        });
        watchers.set(filePath, watcher);
        log(`Watching ${path.basename(filePath)}`);
    } catch (err) {
        log(`Cannot watch ${filePath}: ${err.message}`);
    }
}

function scanForJsonlFiles() {
    try {
        const entries = fs.readdirSync(stageLogsDir);
        for (const entry of entries) {
            if (entry.endsWith(".jsonl")) {
                watchFile(path.join(stageLogsDir, entry));
            }
        }
    } catch {
        // Directory may not exist yet
    }
}

function flushAllLogs() {
    try {
        const entries = fs.readdirSync(stageLogsDir);
        for (const entry of entries) {
            if (entry.endsWith(".jsonl")) {
                const filePath = path.join(stageLogsDir, entry);
                const logs = readNewLines(filePath);
                if (logs.length > 0) {
                    wsSend({
                        type: "log_batch",
                        ticketKey: ticketKey,
                        stage: path.basename(filePath, ".jsonl"),
                        logs: logs,
                    });
                }
            }
        }
    } catch {
        // Ignore
    }
}

// ---------------------------------------------------------------------------
// Stage report watching — pick up stage-report-*.json signal files
// ---------------------------------------------------------------------------
const reportDir = path.dirname(stageLogsDir); // memory/tickets/<KEY>/

function watchStageReports() {
    const reportPattern = /^stage-report-\d+\.json$/;
    try {
        fs.watch(reportDir, (eventType, filename) => {
            if (!filename || !reportPattern.test(filename)) return;
            const filePath = path.join(reportDir, filename);
            try {
                if (!fs.existsSync(filePath)) return;
                const content = fs.readFileSync(filePath, "utf8");
                const report = JSON.parse(content);
                // Send stage report via WS
                wsSend({
                    type: "stage_report",
                    ticketKey: ticketKey,
                    ...report,
                    timestamp: report.timestamp || new Date().toISOString(),
                });
                log(`Sent stage report: ${report.stage} ${report.status}`);
                // Delete the signal file after sending
                try { fs.unlinkSync(filePath); } catch {}
            } catch (err) {
                log(`Error processing stage report ${filename}: ${err.message}`);
            }
        });
    } catch {
        // Directory may not exist yet; retry
        setTimeout(watchStageReports, 5000);
    }
}

// Watch directory for new .jsonl files
function watchDirectory() {
    try {
        dirWatcher = fs.watch(stageLogsDir, (eventType, filename) => {
            if (filename && filename.endsWith(".jsonl")) {
                const filePath = path.join(stageLogsDir, filename);
                if (fs.existsSync(filePath)) {
                    watchFile(filePath);
                }
            }
        });
    } catch {
        // Directory may not exist yet; retry after a delay
        setTimeout(watchDirectory, 5000);
    }
}

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------
function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    log(`Shutting down (${signal})`);

    clearInterval(heartbeatInterval);

    // Close file watchers
    for (const [, watcher] of watchers) {
        try { watcher.close(); } catch {}
    }
    watchers.clear();
    if (dirWatcher) {
        try { dirWatcher.close(); } catch {}
    }

    // Close WebSocket
    if (ws) {
        try { ws.close(1000, "relay shutdown"); } catch {}
    }

    // Remove PID file
    try { fs.unlinkSync(pidPath); } catch {}

    log("Stopped");
    process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// Note: Parent PID monitoring disabled. Claude Code runs each Bash command
// in a separate subprocess, so process.ppid changes between invocations.
// Relay cleanup is handled by:
// 1. start.sh EXIT trap (kills relay via PID file)
// 2. SKILL.md finalize phase (kills relay via PID file)
// 3. Server-side WS ping/pong (detects stale connections within 40s)

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
log(`Starting relay for ${ticketKey}`);
log(`Dashboard: ${dashboardUrl}`);
log(`Logs dir: ${stageLogsDir}`);
log(`PID: ${process.pid}`);

scanForJsonlFiles();
watchDirectory();
watchStageReports();
connect();
