#!/usr/bin/env node
"use strict";

/**
 * QA Agent Dashboard — Backend Server
 *
 * Express + WebSocket server that provides:
 * - REST API for pipeline management and reporting
 * - WebSocket for real-time log streaming and worker communication
 * - Static file serving for the dashboard SPA
 * - In-memory pipeline state (no external DB required)
 */

const express = require("express");
const http = require("http");
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");
const { spawn } = require("child_process");
const { WebSocketServer } = require("ws");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

const PORT = parseInt(process.env.DASHBOARD_PORT || "3459", 10);
const PROJECT_DIR = path.resolve(__dirname, "..");

// ── In-memory state ─────────────────────────────────────────────────────────

const pipelines = new Map();    // pipelineId -> PipelineRecord
const workers = new Map();      // workerId -> WorkerRecord
const logStreams = new Map();    // pipelineId -> LogEntry[]
const wsClients = new Set();    // all connected WebSocket clients

// ── Middleware ───────────────────────────────────────────────────────────────

app.use(express.json({ limit: "2mb" }));
app.use(express.static(path.join(__dirname, "public")));

// CORS for local dev
app.use((req, res, next) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Headers", "Content-Type, Authorization");
    res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    if (req.method === "OPTIONS") return res.sendStatus(204);
    next();
});

// ── REST API: Pipeline Management ───────────────────────────────────────────

// List all pipelines
app.get("/api/pipelines", (req, res) => {
    const list = Array.from(pipelines.values())
        .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
    res.json({ pipelines: list, total: list.length });
});

// Get single pipeline
app.get("/api/pipelines/:id", (req, res) => {
    const pipeline = pipelines.get(req.params.id);
    if (!pipeline) return res.status(404).json({ error: "Pipeline not found" });
    res.json(pipeline);
});

// Create / trigger a new pipeline
app.post("/api/pipelines", (req, res) => {
    let { pipelineType, ticketKey, flags, discovery, fix } = req.body;

    if (!pipelineType) {
        return res.status(400).json({ error: "pipelineType is required" });
    }

    // Extract ticket key from full URLs
    // e.g. "https://bughunters.atlassian.net/browse/KAN-4" -> "KAN-4"
    // e.g. "https://github.com/org/repo/issues/42" -> "#42"
    if (ticketKey && ticketKey.includes("/")) {
        const jiraMatch = ticketKey.match(/\/browse\/([A-Z][A-Z0-9]+-\d+)/);
        const ghMatch = ticketKey.match(/\/issues\/(\d+)/);
        if (jiraMatch) ticketKey = jiraMatch[1];
        else if (ghMatch) ticketKey = "#" + ghMatch[1];
        // Otherwise keep as-is (could be a URL for other platforms)
    }

    const pipelineId = ticketKey || `pipeline-${Date.now()}`;
    const record = {
        pipelineId,
        pipelineType,
        ticketKey: ticketKey || null,
        flags: flags || {},
        discovery: discovery || {},
        fix: fix || {},
        status: "pending",
        stages: [],
        currentStage: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        completedAt: null,
        error: null,
        prUrl: null,
        testResults: null,
        videoUrl: null,
        diff: null,
        featureDoc: null,
    };

    pipelines.set(pipelineId, record);

    // Try worker first, then direct execution
    const worker = findAvailableWorker();
    if (worker) {
        const workerSecret = process.env.WORKER_SECRET || "";
        const secretHash = workerSecret
            ? crypto.createHash("sha256").update(workerSecret).digest("hex")
            : "";

        sendToClient(worker.ws, {
            type: "trigger_pipeline",
            pipelineId,
            pipelineType,
            ticketKey,
            flags,
            discovery,
            fix,
            workerSecret: secretHash,
        });
        record.status = "dispatched";
    } else {
        // No worker — execute directly via claude CLI
        const skillCmd = buildSkillCommand({ pipelineType, ticketKey, flags, discovery, fix });
        if (skillCmd) {
            record.status = "running";
            spawnDirectPipeline(pipelineId, skillCmd, record);
        } else {
            record.status = "queued";
            record.error = "Could not build command for this pipeline type";
        }
    }

    record.updatedAt = new Date().toISOString();
    broadcast({ type: "pipeline_update", pipeline: record });

    res.status(201).json(record);
});

// Cancel / kill a pipeline
app.delete("/api/pipelines/:id", (req, res) => {
    const pipeline = pipelines.get(req.params.id);
    if (!pipeline) return res.status(404).json({ error: "Pipeline not found" });

    // Send kill to all workers
    for (const [, worker] of workers) {
        sendToClient(worker.ws, {
            type: "kill_pipeline",
            pipelineId: req.params.id,
        });
    }

    pipeline.status = "cancelled";
    pipeline.updatedAt = new Date().toISOString();
    broadcast({ type: "pipeline_update", pipeline });

    res.json({ message: "Kill signal sent", pipeline });
});

// ── REST API: Stage Reporting (called by report-to-dashboard.sh) ────────────

app.post("/api/e2e-agent/report", (req, res) => {
    const body = req.body;
    const ticketKey = body.ticket_key || body.ticketKey;
    const stage = body.stage;
    const status = body.status || "completed";

    if (!ticketKey || !stage) {
        return res.status(400).json({ error: "ticket_key and stage required" });
    }

    let pipeline = pipelines.get(ticketKey);
    if (!pipeline) {
        // Auto-create pipeline record from agent report
        pipeline = {
            pipelineId: ticketKey,
            pipelineType: "implementation",
            ticketKey,
            flags: {},
            discovery: {},
            fix: {},
            status: "running",
            stages: [],
            currentStage: stage,
            createdAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
            completedAt: null,
            error: null,
            prUrl: null,
            testResults: null,
            videoUrl: null,
            diff: null,
            featureDoc: null,
        };
        pipelines.set(ticketKey, pipeline);
    }

    // Update stage info
    const stageRecord = {
        name: stage,
        status,
        timestamp: new Date().toISOString(),
        data: body.data || null,
        duration: body.duration || null,
    };

    // Remove existing entry for this stage, add updated one
    pipeline.stages = pipeline.stages.filter((s) => s.name !== stage);
    pipeline.stages.push(stageRecord);
    pipeline.currentStage = stage;
    pipeline.updatedAt = new Date().toISOString();

    // Handle special fields
    if (body.pr_url) pipeline.prUrl = body.pr_url;
    if (body.test_results) pipeline.testResults = body.test_results;
    if (body.video_url) pipeline.videoUrl = body.video_url;
    if (body.diff) pipeline.diff = body.diff;
    if (body.feature_doc) pipeline.featureDoc = body.feature_doc;
    if (body.error) pipeline.error = body.error;

    if (status === "completed" && stage === "pr") {
        pipeline.status = "completed";
        pipeline.completedAt = new Date().toISOString();
    } else if (status === "failed") {
        pipeline.status = "failed";
        pipeline.error = body.error || `Failed at stage: ${stage}`;
    } else {
        pipeline.status = "running";
    }

    broadcast({ type: "pipeline_update", pipeline });
    broadcast({
        type: "stage_update",
        pipelineId: ticketKey,
        stage: stageRecord,
    });

    res.json({ received: true, pipelineId: ticketKey, stage });
});

// ── REST API: Pipeline Logs ─────────────────────────────────────────────────

app.get("/api/pipelines/:id/logs", (req, res) => {
    const logs = logStreams.get(req.params.id) || [];
    const since = req.query.since ? new Date(req.query.since) : null;
    const filtered = since
        ? logs.filter((l) => new Date(l.timestamp) > since)
        : logs;
    res.json({ logs: filtered, total: filtered.length });
});

app.post("/api/pipelines/:id/logs", (req, res) => {
    const { message, level, agent, stage } = req.body;
    const pipelineId = req.params.id;

    const entry = {
        timestamp: new Date().toISOString(),
        pipelineId,
        message: (message || "").slice(0, 2000),
        level: level || "info",
        agent: agent || null,
        stage: stage || null,
    };

    if (!logStreams.has(pipelineId)) logStreams.set(pipelineId, []);
    const logs = logStreams.get(pipelineId);
    logs.push(entry);

    // Cap at 5000 entries per pipeline
    if (logs.length > 5000) logs.splice(0, logs.length - 5000);

    broadcast({ type: "log_entry", ...entry });

    res.json({ received: true });
});

// ── REST API: Workers ───────────────────────────────────────────────────────

app.get("/api/workers", (req, res) => {
    const list = Array.from(workers.values()).map((w) => ({
        workerId: w.workerId,
        hostname: w.hostname,
        capacity: w.capacity,
        runningJobs: w.runningJobs,
        platform: w.platform,
        connectedAt: w.connectedAt,
        lastHeartbeat: w.lastHeartbeat,
    }));
    res.json({ workers: list, total: list.length });
});

// ── REST API: System Status ─────────────────────────────────────────────────

app.get("/api/status", (req, res) => {
    const pipelineList = Array.from(pipelines.values());
    res.json({
        uptime: process.uptime(),
        pipelines: {
            total: pipelineList.length,
            running: pipelineList.filter((p) => p.status === "running").length,
            completed: pipelineList.filter((p) => p.status === "completed").length,
            failed: pipelineList.filter((p) => p.status === "failed").length,
            queued: pipelineList.filter((p) => p.status === "queued" || p.status === "pending").length,
        },
        workers: {
            total: workers.size,
            available: Array.from(workers.values()).filter((w) => w.runningJobs < w.capacity).length,
        },
        wsClients: wsClients.size,
        timestamp: new Date().toISOString(),
    });
});

// ── REST API: Config (read framework/platform configs) ──────────────────────

app.get("/api/config/frameworks", (req, res) => {
    try {
        const dir = path.join(PROJECT_DIR, "config", "frameworks");
        const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
        const frameworks = files.map((f) => {
            const data = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
            return {
                id: data.framework_id,
                name: data.display_name,
                language: data.language,
                testType: data.test_type,
            };
        });
        res.json({ frameworks });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.get("/api/config/platforms", (req, res) => {
    try {
        const dir = path.join(PROJECT_DIR, "config", "platforms");
        const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
        const platforms = files.map((f) => {
            const data = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
            return {
                id: data.platform_id,
                name: data.display_name,
                keyPattern: data.ticket_key_pattern,
            };
        });
        res.json({ platforms });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// ── REST API: Memory / Artifacts ────────────────────────────────────────────

app.get("/api/artifacts/:ticketKey/:filename", (req, res) => {
    const { ticketKey, filename } = req.params;
    // Only allow alphanumeric, hyphens, and dots in filenames
    if (!/^[\w\-.]+$/.test(filename)) {
        return res.status(400).json({ error: "Invalid filename" });
    }

    const filePath = path.join(PROJECT_DIR, "memory", "tickets", ticketKey, filename);
    if (!fs.existsSync(filePath)) {
        // Try GP runs
        const gpPath = path.join(PROJECT_DIR, "memory", "gp-runs", ticketKey, filename);
        if (fs.existsSync(gpPath)) {
            return res.sendFile(gpPath);
        }
        return res.status(404).json({ error: "Artifact not found" });
    }
    res.sendFile(filePath);
});

// ── Fallback: serve SPA ─────────────────────────────────────────────────────

app.get("*", (req, res) => {
    res.sendFile(path.join(__dirname, "public", "index.html"));
});

// ── WebSocket ───────────────────────────────────────────────────────────────

wss.on("connection", (ws) => {
    wsClients.add(ws);

    ws.on("message", (raw) => {
        let msg;
        try {
            msg = JSON.parse(raw.toString());
        } catch {
            return;
        }

        handleWsMessage(ws, msg);
    });

    ws.on("close", () => {
        wsClients.delete(ws);
        // Remove worker if this was a worker connection
        for (const [id, worker] of workers) {
            if (worker.ws === ws) {
                workers.delete(id);
                broadcast({
                    type: "worker_disconnected",
                    workerId: id,
                    timestamp: new Date().toISOString(),
                });
                break;
            }
        }
    });

    // Send current state to new client
    sendToClient(ws, {
        type: "init",
        pipelines: Array.from(pipelines.values()),
        workers: Array.from(workers.values()).map((w) => ({
            workerId: w.workerId,
            hostname: w.hostname,
            capacity: w.capacity,
            runningJobs: w.runningJobs,
        })),
    });
});

function handleWsMessage(ws, msg) {
    switch (msg.type) {
        case "worker_hello": {
            const worker = {
                workerId: msg.workerId,
                hostname: msg.hostname || "unknown",
                capacity: msg.capacity || 1,
                runningJobs: msg.runningJobs || 0,
                platform: msg.platform || "unknown",
                connectedAt: new Date().toISOString(),
                lastHeartbeat: new Date().toISOString(),
                ws,
            };
            workers.set(msg.workerId, worker);
            sendToClient(ws, { type: "worker_welcome", workerId: msg.workerId });
            broadcast({
                type: "worker_connected",
                workerId: msg.workerId,
                hostname: worker.hostname,
                capacity: worker.capacity,
            });
            // Dispatch any queued pipelines
            dispatchQueuedPipelines();
            break;
        }

        case "worker_heartbeat": {
            const worker = workers.get(msg.workerId);
            if (worker) {
                worker.runningJobs = msg.runningJobs || 0;
                worker.lastHeartbeat = new Date().toISOString();
            }
            break;
        }

        case "worker_pipeline_started": {
            const pipeline = pipelines.get(msg.pipelineId);
            if (pipeline) {
                pipeline.status = "running";
                pipeline.updatedAt = new Date().toISOString();
                broadcast({ type: "pipeline_update", pipeline });
            }
            break;
        }

        case "worker_pipeline_completed": {
            const pipeline = pipelines.get(msg.pipelineId);
            if (pipeline) {
                pipeline.status = "completed";
                pipeline.completedAt = new Date().toISOString();
                pipeline.updatedAt = new Date().toISOString();
                broadcast({ type: "pipeline_update", pipeline });
            }
            break;
        }

        case "worker_pipeline_failed": {
            const pipeline = pipelines.get(msg.pipelineId);
            if (pipeline) {
                pipeline.status = "failed";
                pipeline.error = msg.error || `Exit code: ${msg.exitCode}`;
                pipeline.updatedAt = new Date().toISOString();
                broadcast({ type: "pipeline_update", pipeline });
            }
            break;
        }

        case "worker_pipeline_log": {
            const pipelineId = msg.pipelineId;
            if (!logStreams.has(pipelineId)) logStreams.set(pipelineId, []);
            const entry = {
                timestamp: new Date().toISOString(),
                pipelineId,
                message: (msg.message || "").slice(0, 2000),
                level: msg.stream === "stderr" ? "error" : "info",
                agent: null,
                stage: null,
            };
            logStreams.get(pipelineId).push(entry);
            broadcast({ type: "log_entry", ...entry });
            break;
        }

        case "worker_pipeline_queued": {
            const pipeline = pipelines.get(msg.pipelineId);
            if (pipeline) {
                pipeline.status = "queued";
                pipeline.updatedAt = new Date().toISOString();
                broadcast({ type: "pipeline_update", pipeline });
            }
            break;
        }

        case "worker_trigger_rejected": {
            const pipeline = pipelines.get(msg.pipelineId);
            if (pipeline) {
                pipeline.status = "rejected";
                pipeline.error = (msg.errors || []).join("; ");
                pipeline.updatedAt = new Date().toISOString();
                broadcast({ type: "pipeline_update", pipeline });
            }
            break;
        }

        // Browser client commands
        case "subscribe_logs": {
            // Client wants live logs for a specific pipeline
            ws._subscribedPipeline = msg.pipelineId;
            break;
        }

        case "trigger_pipeline": {
            // Browser client triggers pipeline — route through REST handler logic
            const { pipelineType, ticketKey, flags, discovery, fix } = msg;
            const pipelineId = ticketKey || `pipeline-${Date.now()}`;
            const record = {
                pipelineId,
                pipelineType,
                ticketKey: ticketKey || null,
                flags: flags || {},
                discovery: discovery || {},
                fix: fix || {},
                status: "pending",
                stages: [],
                currentStage: null,
                createdAt: new Date().toISOString(),
                updatedAt: new Date().toISOString(),
                completedAt: null,
                error: null,
                prUrl: null,
                testResults: null,
            };
            pipelines.set(pipelineId, record);

            const worker = findAvailableWorker();
            if (worker) {
                const workerSecret = process.env.WORKER_SECRET || "";
                const secretHash = workerSecret
                    ? crypto.createHash("sha256").update(workerSecret).digest("hex")
                    : "";
                sendToClient(worker.ws, {
                    type: "trigger_pipeline",
                    pipelineId,
                    pipelineType,
                    ticketKey,
                    flags,
                    discovery,
                    fix,
                    workerSecret: secretHash,
                });
                record.status = "dispatched";
            } else {
                record.status = "queued";
            }
            record.updatedAt = new Date().toISOString();
            broadcast({ type: "pipeline_update", pipeline: record });
            break;
        }
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function sendToClient(ws, data) {
    if (ws.readyState === 1) {
        try {
            ws.send(JSON.stringify(data));
        } catch { /* ignore */ }
    }
}

function broadcast(data) {
    const msg = JSON.stringify(data);
    for (const client of wsClients) {
        if (client.readyState === 1) {
            try { client.send(msg); } catch { /* ignore */ }
        }
    }
}

function findAvailableWorker() {
    for (const [, worker] of workers) {
        if (worker.runningJobs < worker.capacity) return worker;
    }
    return null;
}

function dispatchQueuedPipelines() {
    for (const [, pipeline] of pipelines) {
        if (pipeline.status === "queued" || pipeline.status === "pending") {
            const worker = findAvailableWorker();
            if (!worker) break;

            const workerSecret = process.env.WORKER_SECRET || "";
            const secretHash = workerSecret
                ? crypto.createHash("sha256").update(workerSecret).digest("hex")
                : "";

            sendToClient(worker.ws, {
                type: "trigger_pipeline",
                pipelineId: pipeline.pipelineId,
                pipelineType: pipeline.pipelineType,
                ticketKey: pipeline.ticketKey,
                flags: pipeline.flags,
                discovery: pipeline.discovery,
                fix: pipeline.fix,
                workerSecret: secretHash,
            });

            pipeline.status = "dispatched";
            pipeline.updatedAt = new Date().toISOString();
            broadcast({ type: "pipeline_update", pipeline });
        }
    }
}

// ── Direct Execution (no worker needed) ─────────────────────────────────────

const VALID_PIPELINE_TYPES = new Set(["implementation", "discovery", "discovery-ticket", "fix"]);
const TICKET_KEY_RE = /^[A-Z][A-Z0-9]+-[0-9]+$/;
const directJobs = new Map(); // pipelineId -> child process

function buildSkillCommand(trigger) {
    const { pipelineType, ticketKey, flags = {}, discovery = {}, fix = {} } = trigger;

    if (!VALID_PIPELINE_TYPES.has(pipelineType)) return null;

    if (pipelineType === "implementation") {
        if (!ticketKey) return null;
        const parts = [`/gp-test-agent ${ticketKey}`];
        if (flags.auto) parts.push("--auto");
        if (flags.framework) parts.push(`--framework ${flags.framework}`);
        if (flags.env) parts.push(`--env ${flags.env}`);
        return parts.join(" ");
    }

    if (pipelineType === "discovery") {
        const parts = ["/qa-discover-changes"];
        if (discovery.services && discovery.services.length > 0) {
            parts.push(discovery.services.join(" "));
        }
        if (discovery.since) parts.push(`--since ${discovery.since}`);
        if (discovery.until) parts.push(`--until ${discovery.until}`);
        if (flags.noAuto) parts.push("--no-auto");
        return parts.join(" ");
    }

    if (pipelineType === "discovery-ticket") {
        const key = (discovery && discovery.ticket) || ticketKey;
        if (!key) return null;
        return `/qa-discover-changes --ticket ${key}`;
    }

    if (pipelineType === "fix") {
        const parts = ["/qa-fix-failures"];
        if (fix.job) parts.push(`--job ${fix.job}`);
        if (fix.folder) parts.push(`--folder ${fix.folder}`);
        if (fix.category) parts.push(`--category ${fix.category}`);
        if (flags.env) parts.push(`--env ${flags.env}`);
        return parts.join(" ");
    }

    return null;
}

function spawnDirectPipeline(pipelineId, skillCommand, record) {
    console.log(`[dashboard] Direct execution: claude -p "${skillCommand}"`);

    // CRITICAL Windows quoting: shell:true causes cmd.exe to split args on spaces.
    // The skill command "/gp-test-agent KAN-4 --auto" must stay as ONE argument to -p.
    // Solution: windowsVerbatimArguments:true + wrap the prompt in escaped quotes.
    const isWin = process.platform === "win32";
    const promptArg = isWin ? `"${skillCommand}"` : skillCommand;

    const child = spawn("claude", ["-p", promptArg], {
        cwd: PROJECT_DIR,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env },
        shell: true,
        windowsVerbatimArguments: isWin,
    });

    // Close stdin
    child.stdin.end();

    directJobs.set(pipelineId, child);

    // Stream output as logs
    const streamOutput = (stream, level) => {
        let buffer = "";
        stream.on("data", (chunk) => {
            buffer += chunk.toString();
            const lines = buffer.split("\n");
            buffer = lines.pop() || "";
            for (const line of lines) {
                if (line.trim()) {
                    const entry = {
                        timestamp: new Date().toISOString(),
                        pipelineId,
                        message: line.slice(0, 2000),
                        level,
                        agent: null,
                        stage: null,
                    };
                    if (!logStreams.has(pipelineId)) logStreams.set(pipelineId, []);
                    logStreams.get(pipelineId).push(entry);
                    broadcast({ type: "log_entry", ...entry });
                }
            }
        });
    };

    streamOutput(child.stdout, "info");
    streamOutput(child.stderr, "error");

    child.on("exit", (code) => {
        directJobs.delete(pipelineId);
        const status = (code === 0) ? "completed" : "failed";
        record.status = status;
        record.updatedAt = new Date().toISOString();
        if (status === "completed") {
            record.completedAt = new Date().toISOString();
        } else {
            record.error = `Process exited with code ${code}`;
        }
        broadcast({ type: "pipeline_update", pipeline: record });
        console.log(`[dashboard] Pipeline ${pipelineId} ${status} (exit code ${code})`);
    });

    child.on("error", (err) => {
        directJobs.delete(pipelineId);
        record.status = "failed";
        record.error = err.message;
        record.updatedAt = new Date().toISOString();
        broadcast({ type: "pipeline_update", pipeline: record });
        console.error(`[dashboard] Pipeline ${pipelineId} spawn error: ${err.message}`);
    });
}

// ── Start Server ────────────────────────────────────────────────────────────

server.listen(PORT, () => {
    console.log(`[dashboard] QA Agent Dashboard running on http://localhost:${PORT}`);
    console.log(`[dashboard] WebSocket on ws://localhost:${PORT}/ws`);
    console.log(`[dashboard] API docs: GET /api/status`);
    console.log(`[dashboard] Direct execution: enabled (no worker required)`);
});
