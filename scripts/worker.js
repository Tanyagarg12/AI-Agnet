#!/usr/bin/env node
// worker.js — Persistent daemon that connects to the dashboard WS server,
// receives trigger_pipeline commands, and spawns Claude Code with the correct skill.
//
// Usage:
//   node scripts/worker.js [--capacity N] [--dashboard ws://host:port/ws]
//
// Or via start.sh:
//   ./scripts/start.sh --worker [--capacity N]

"use strict";

const { spawn } = require("child_process");
const path = require("path");
const os = require("os");
const { randomUUID } = require("crypto");

// ---------------------------------------------------------------------------
// Resolve ws from E2E framework node_modules (same pattern as agent-relay.js)
// ---------------------------------------------------------------------------
const frameworkPath = process.env.E2E_FRAMEWORK_PATH || "";
let WebSocket;
try {
  WebSocket = require(path.join(frameworkPath, "node_modules", "ws"));
} catch {
  try {
    WebSocket = require(
      path.join(__dirname, "..", "dashboard", "node_modules", "ws"),
    );
  } catch {
    try {
      WebSocket = require("ws");
    } catch {
      console.error(
        "[worker] FATAL: Cannot find 'ws' module. Set E2E_FRAMEWORK_PATH or install ws locally.",
      );
      process.exit(1);
    }
  }
}

// ---------------------------------------------------------------------------
// Parse CLI arguments
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
let capacity = 1;
let dashboardUrl = "";

for (let i = 0; i < args.length; i++) {
  if ((args[i] === "--capacity" || args[i] === "-c") && args[i + 1]) {
    const n = parseInt(args[++i], 10);
    if (n > 0 && n <= 10) capacity = n;
  } else if (args[i] === "--dashboard" && args[i + 1]) {
    dashboardUrl = args[++i];
  }
}

if (process.env.WORKER_CAPACITY) {
  const n = parseInt(process.env.WORKER_CAPACITY, 10);
  if (n > 0 && n <= 10) capacity = n;
}

// Worker secret — only triggers with matching secret are accepted.
// Set via WORKER_SECRET env var or --secret flag. If not set, worker accepts all triggers.
let workerSecret = process.env.WORKER_SECRET || "";
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--secret" && args[i + 1]) {
    workerSecret = args[++i];
  }
}

if (!dashboardUrl) {
  const base = process.env.DASHBOARD_URL || "http://52.51.14.138:3459";
  dashboardUrl = base.replace(/^http/, "ws").replace(/\/$/, "") + "/ws";
}

// Worker secret is mandatory — refuse to start without it
if (!workerSecret) {
  console.error(
    "FATAL: WORKER_SECRET is required. Set it in .env or pass --secret <value>.",
  );
  console.error(
    "Run ./scripts/setup.sh to generate one, or add WORKER_SECRET=<hex> to .env",
  );
  process.exit(1);
}

const PROJECT_DIR = path.resolve(__dirname, "..");
const START_SCRIPT = path.join(PROJECT_DIR, "scripts", "start.sh");
const WORKER_ID = `worker-${os.hostname()}-${process.pid}`;

const log = (msg) => console.log(`[worker ${WORKER_ID}] ${msg}`);
const logErr = (msg) => console.error(`[worker ${WORKER_ID}] ${msg}`);

// ---------------------------------------------------------------------------
// Input validation — whitelist all values from trigger messages
// ---------------------------------------------------------------------------
const VALID_PIPELINE_TYPES = new Set([
  "implementation",
  "discovery",
  "discovery-ticket",
  "fix",
]);
const VALID_ENVS = new Set(["dev", "stg"]);
const VALID_FOLDERS = new Set(["Staging", "Dev", "Prod"]);
const VALID_CATEGORIES = new Set(["automation_issue", "possible_real_issue"]);
const VALID_SERVICES = new Set([
  "frontend",
  "connectors",
  "settings-service",
  "report-service",
  "gateway",
]);
const TICKET_KEY_RE = /^[A-Z]{1,10}-\d{1,10}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const JOB_NAME_RE = /^[a-zA-Z0-9_-]{1,80}$/;

function validateTrigger(trigger) {
  const errors = [];
  if (!trigger || typeof trigger !== "object")
    return ["Invalid trigger payload"];

  const {
    pipelineType,
    ticketKey,
    flags = {},
    discovery = {},
    fix = {},
  } = trigger;

  if (!VALID_PIPELINE_TYPES.has(pipelineType)) {
    errors.push(`Invalid pipelineType: ${pipelineType}`);
  }

  if (pipelineType === "implementation") {
    if (!ticketKey || !TICKET_KEY_RE.test(ticketKey)) {
      errors.push(`Invalid ticketKey: ${ticketKey}`);
    }
  } else if (pipelineType === "discovery-ticket") {
    const key = discovery.ticket || ticketKey;
    if (!key || !TICKET_KEY_RE.test(key)) {
      errors.push(`Invalid discovery ticket: ${key}`);
    }
  }

  if (flags.env && !VALID_ENVS.has(flags.env)) {
    errors.push(`Invalid env flag: ${flags.env}`);
  }

  if (discovery.services && Array.isArray(discovery.services)) {
    for (const s of discovery.services) {
      if (!VALID_SERVICES.has(s)) errors.push(`Invalid service: ${s}`);
    }
  }

  if (discovery.since && !DATE_RE.test(discovery.since)) {
    errors.push(`Invalid since date: ${discovery.since}`);
  }
  if (discovery.until && !DATE_RE.test(discovery.until)) {
    errors.push(`Invalid until date: ${discovery.until}`);
  }
  if (discovery.ticket && !TICKET_KEY_RE.test(discovery.ticket)) {
    errors.push(`Invalid discovery ticket: ${discovery.ticket}`);
  }

  if (fix.job && !JOB_NAME_RE.test(fix.job)) {
    errors.push(`Invalid job name: ${fix.job}`);
  }
  if (fix.folder && !VALID_FOLDERS.has(fix.folder)) {
    errors.push(`Invalid folder: ${fix.folder}`);
  }
  if (fix.category && !VALID_CATEGORIES.has(fix.category)) {
    errors.push(`Invalid category: ${fix.category}`);
  }

  return errors;
}

// ---------------------------------------------------------------------------
// Command builder — pure function, no shell interpolation
// ---------------------------------------------------------------------------
function buildSkillCommand(trigger) {
  const {
    pipelineType,
    ticketKey,
    flags = {},
    discovery = {},
    fix = {},
  } = trigger;
  const parts = [];

  if (pipelineType === "implementation") {
    parts.push(`/qa-autonomous-e2e ${ticketKey}`);
    if (flags.auto) parts.push("--auto");
    if (flags.watch) parts.push("--watch");
    if (flags.env) parts.push(`--env ${flags.env}`);
  } else if (pipelineType === "discovery-ticket") {
    parts.push(
      `/qa-discover-changes --ticket ${discovery.ticket || ticketKey}`,
    );
    // Pass dashboard-generated key as scan-id so the skill uses it
    if (ticketKey) parts.push(`--scan-id ${ticketKey}`);
    if (flags.noAuto) parts.push("--no-auto");
  } else if (pipelineType === "discovery") {
    parts.push("/qa-discover-changes");
    if (discovery.services && discovery.services.length > 0) {
      parts.push(discovery.services.join(" "));
    }
    if (discovery.since) parts.push(`--since ${discovery.since}`);
    if (discovery.until) parts.push(`--until ${discovery.until}`);
    // Pass dashboard-generated key as scan-id so the skill uses it
    if (ticketKey) parts.push(`--scan-id ${ticketKey}`);
    if (flags.noAuto) parts.push("--no-auto");
  } else if (pipelineType === "fix") {
    parts.push("/qa-fix-failures");
    if (fix.job) parts.push(`--job ${fix.job}`);
    if (fix.folder) parts.push(`--folder ${fix.folder}`);
    if (fix.category) parts.push(`--category ${fix.category}`);
    if (flags.env) parts.push(`--env ${flags.env}`);
  }

  return parts.join(" ");
}

// ---------------------------------------------------------------------------
// Job management
// ---------------------------------------------------------------------------
const runningJobs = new Map(); // pipelineId -> { process, ticketKey, startedAt }
const jobQueue = []; // queued triggers when at capacity

function getRunningCount() {
  return runningJobs.size;
}

function spawnPipeline(trigger) {
  const { pipelineId, ticketKey, skipPermissions } = trigger;
  const skillCommand = buildSkillCommand(trigger);

  if (!skillCommand) {
    logErr(`Empty skill command for pipeline ${pipelineId}`);
    return null;
  }

  log(`Spawning pipeline ${pipelineId}: ${skillCommand}`);

  // Worker mode: no interactive terminal available for permission prompts.
  // PermissionRequest hooks don't fire in -p mode, so we must either skip
  // all permissions or pre-approve tools via --allowedTools.
  const spawnArgs = ["-p", skillCommand, "--dangerously-skip-permissions"];

  // OX Agent: Command Injection prevented by allowlist validation + argument array without shell
  const child = spawn(START_SCRIPT, spawnArgs, {
    cwd: PROJECT_DIR,
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, CLAUDE_WORKER_MODE: "1" },
    detached: true,
  });

  // Close stdin so Claude Code doesn't wait for interactive input
  child.stdin.end();

  const job = {
    process: child,
    pipelineId,
    ticketKey: ticketKey || "unknown",
    startedAt: new Date().toISOString(),
  };

  runningJobs.set(pipelineId, job);

  // Forward stdout/stderr lines — log all locally, send key lines to dashboard
  const forwardOutput = (stream, label) => {
    let buffer = "";
    stream.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop(); // keep incomplete line
      for (const line of lines) {
        if (line.trim()) {
          log(`[${pipelineId}:${label}] ${line}`);
          // Forward stage completions, errors, and key status lines to dashboard
          if (
            line.includes("[stage]") ||
            line.includes("ERROR") ||
            line.includes("error") ||
            line.includes("completed") ||
            line.includes("failed") ||
            line.includes("FATAL")
          ) {
            wsSend({
              type: "worker_pipeline_log",
              pipelineId,
              ticketKey: job.ticketKey,
              stream: label,
              message: line.slice(0, 500),
            });
          }
        }
      }
    });
  };

  forwardOutput(child.stdout, "stdout");
  forwardOutput(child.stderr, "stderr");

  child.on("exit", (code, signal) => {
    runningJobs.delete(pipelineId);
    const status = code === 0 ? "completed" : "failed";
    log(
      `Pipeline ${pipelineId} exited: code=${code} signal=${signal} status=${status}`,
    );

    wsSend({
      type: `worker_pipeline_${status}`,
      pipelineId,
      ticketKey: job.ticketKey,
      exitCode: code,
      signal,
      timestamp: new Date().toISOString(),
    });

    // Dispatch next queued job
    dispatchNext();
  });

  child.on("error", (err) => {
    runningJobs.delete(pipelineId);
    logErr(`Pipeline ${pipelineId} spawn error: ${err.message}`);
    wsSend({
      type: "worker_pipeline_failed",
      pipelineId,
      ticketKey: job.ticketKey,
      error: err.message,
      timestamp: new Date().toISOString(),
    });
    dispatchNext();
  });

  return child;
}

function dispatchNext() {
  while (jobQueue.length > 0 && getRunningCount() < capacity) {
    const next = jobQueue.shift();
    log(`Dispatching queued pipeline ${next.pipelineId}`);
    wsSend({
      type: "worker_pipeline_started",
      pipelineId: next.pipelineId,
      ticketKey: next.ticketKey || "unknown",
      timestamp: new Date().toISOString(),
    });
    spawnPipeline(next);
  }
}

function killPipeline(pipelineId) {
  const job = runningJobs.get(pipelineId);
  if (!job) {
    // Check queue
    const idx = jobQueue.findIndex((j) => j.pipelineId === pipelineId);
    if (idx >= 0) {
      jobQueue.splice(idx, 1);
      log(`Removed queued pipeline ${pipelineId}`);
      return true;
    }
    return false;
  }

  log(`Killing pipeline ${pipelineId} (PID ${job.process.pid})`);
  try {
    // Kill the process group (detached)
    process.kill(-job.process.pid, "SIGTERM");
  } catch {
    try {
      job.process.kill("SIGTERM");
    } catch {}
  }
  return true;
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
    log("Connected to dashboard");
    reconnectDelay = 1000;

    // Register as worker — send secret hash so server knows it's protected
    const crypto = require("crypto");
    const secretHash = crypto
      .createHash("sha256")
      .update(workerSecret)
      .digest("hex");
    wsSend({
      type: "worker_hello",
      workerId: WORKER_ID,
      hostname: os.hostname(),
      capacity,
      platform: process.platform,
      runningJobs: getRunningCount(),
      requiresSecret: true,
      secretHash,
      timestamp: new Date().toISOString(),
    });

    // Start heartbeat
    clearInterval(heartbeatInterval);
    heartbeatInterval = setInterval(() => {
      wsSend({
        type: "worker_heartbeat",
        workerId: WORKER_ID,
        runningJobs: getRunningCount(),
        capacity,
        queuedJobs: jobQueue.length,
        jobs: Array.from(runningJobs.entries()).map(([id, j]) => ({
          pipelineId: id,
          ticketKey: j.ticketKey,
          startedAt: j.startedAt,
        })),
      });
    }, 30000);
  });

  ws.on("message", (data) => {
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return;
    }

    if (msg.type === "trigger_pipeline") {
      handleTrigger(msg);
    } else if (msg.type === "kill_pipeline") {
      const killed = killPipeline(msg.pipelineId);
      wsSend({
        type: "worker_kill_result",
        pipelineId: msg.pipelineId,
        success: killed,
      });
    } else if (msg.type === "worker_welcome") {
      log(`Registered with dashboard as ${msg.workerId || WORKER_ID}`);
    }
  });

  ws.on("close", () => {
    log("Disconnected from dashboard");
    clearInterval(heartbeatInterval);
    scheduleReconnect();
  });

  ws.on("error", (err) => {
    logErr(`WS error: ${err.message}`);
  });
}

function handleTrigger(msg) {
  // Validate worker secret if configured
  // Dashboard sends SHA-256 hash of the secret; compare against our hashed secret
  const crypto = require("crypto");
  const workerSecretHash = workerSecret
    ? crypto.createHash("sha256").update(workerSecret).digest("hex")
    : "";
  if (workerSecret && msg.workerSecret !== workerSecretHash) {
    logErr(`Rejected trigger for pipeline ${msg.pipelineId}: invalid secret`);
    wsSend({
      type: "worker_trigger_rejected",
      pipelineId: msg.pipelineId,
      errors: ["Invalid worker secret"],
    });
    return;
  }

  const errors = validateTrigger(msg);
  if (errors.length > 0) {
    logErr(`Invalid trigger: ${errors.join(", ")}`);
    wsSend({
      type: "worker_trigger_rejected",
      pipelineId: msg.pipelineId,
      errors,
    });
    return;
  }

  // Check for duplicate ticket — reject if same ticket is already running or queued
  const triggerTicket =
    (msg.discovery && msg.discovery.ticket) || msg.ticketKey || "";
  for (const [, job] of runningJobs) {
    if (
      job.ticketKey === triggerTicket ||
      (job.ticketKey && job.ticketKey.includes(triggerTicket))
    ) {
      logErr(
        `Rejected duplicate trigger for ${triggerTicket} — already running`,
      );
      wsSend({
        type: "worker_trigger_rejected",
        pipelineId: msg.pipelineId,
        errors: [`Pipeline already running for ${triggerTicket}`],
      });
      return;
    }
  }
  if (
    jobQueue.some((j) => {
      const jTicket = (j.discovery && j.discovery.ticket) || j.ticketKey || "";
      return (
        jTicket === triggerTicket ||
        (jTicket && jTicket.includes(triggerTicket))
      );
    })
  ) {
    logErr(`Rejected duplicate trigger for ${triggerTicket} — already queued`);
    wsSend({
      type: "worker_trigger_rejected",
      pipelineId: msg.pipelineId,
      errors: [`Pipeline already queued for ${triggerTicket}`],
    });
    return;
  }

  if (getRunningCount() >= capacity) {
    log(`At capacity (${capacity}), queuing pipeline ${msg.pipelineId}`);
    jobQueue.push(msg);
    wsSend({
      type: "worker_pipeline_queued",
      pipelineId: msg.pipelineId,
      ticketKey: msg.ticketKey || "unknown",
      position: jobQueue.length,
    });
    return;
  }

  wsSend({
    type: "worker_pipeline_started",
    pipelineId: msg.pipelineId,
    ticketKey: msg.ticketKey || "unknown",
    timestamp: new Date().toISOString(),
  });

  spawnPipeline(msg);
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
      logErr(`Send error: ${err.message}`);
    }
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

  // Kill all running jobs
  for (const [pipelineId, job] of runningJobs) {
    log(`Killing pipeline ${pipelineId} on shutdown`);
    try {
      process.kill(-job.process.pid, "SIGTERM");
    } catch {
      try {
        job.process.kill("SIGTERM");
      } catch {}
    }
  }

  if (ws) {
    try {
      ws.close(1000, "worker shutdown");
    } catch {}
  }

  log("Stopped");
  // Give processes a moment to clean up
  setTimeout(() => process.exit(0), 1000);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
log("Starting worker daemon");
log(`  Dashboard: ${dashboardUrl}`);
log(`  Capacity:  ${capacity}`);
log(`  Project:   ${PROJECT_DIR}`);
log(`  Worker ID: ${WORKER_ID}`);
log(
  `  Secret:    ${workerSecret ? workerSecret.slice(0, 6) + "..." + workerSecret.slice(-4) + " (protected)" : "NONE (open)"}`,
);

connect();
