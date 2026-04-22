"use strict";

/**
 * QA Agent Dashboard — Frontend Application
 *
 * Single-page application managing:
 * - Pipeline list with real-time updates via WebSocket
 * - Pipeline trigger form
 * - Live log streaming
 * - System configuration view
 * - Pipeline detail modal with stage timeline and diff viewer
 */

// ── State ───────────────────────────────────────────────────────────────────

const state = {
    pipelines: [],
    workers: [],
    logs: {},          // pipelineId -> LogEntry[]
    selectedLog: null, // pipelineId currently streaming
    ws: null,
    connected: false,
};

const STAGE_ORDER = [
    "triage", "scanner", "analyzer", "ticket-creator",
    "explorer", "playwright", "code-writer", "validator",
    "test-runner", "debug", "cross-env-check", "pr",
    "review-pr", "retrospective",
    // GP stages
    "intake", "plan", "scaffold", "browse", "codegen",
    "run", "report", "learn",
];

const STATUS_ICONS = {
    running: "\u25B6",
    completed: "\u2713",
    failed: "\u2717",
    queued: "\u23F3",
    pending: "\u23F3",
    dispatched: "\u2192",
    cancelled: "\u2500",
    rejected: "\u26A0",
};

// ── WebSocket ───────────────────────────────────────────────────────────────

function connectWs() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const url = proto + "//" + location.host + "/ws";

    state.ws = new WebSocket(url);

    state.ws.onopen = () => {
        state.connected = true;
        updateWorkerBadge();
    };

    state.ws.onmessage = (event) => {
        try {
            const msg = JSON.parse(event.data);
            handleWsMessage(msg);
        } catch { /* ignore parse errors */ }
    };

    state.ws.onclose = () => {
        state.connected = false;
        updateWorkerBadge();
        setTimeout(connectWs, 3000);
    };

    state.ws.onerror = () => { /* reconnect handled by onclose */ };
}

function handleWsMessage(msg) {
    switch (msg.type) {
        case "init":
            state.pipelines = msg.pipelines || [];
            state.workers = msg.workers || [];
            renderPipelines();
            updateWorkerBadge();
            updateStats();
            updateLogPipelineSelect();
            break;

        case "pipeline_update":
            upsertPipeline(msg.pipeline);
            renderPipelines();
            updateStats();
            updateLogPipelineSelect();
            break;

        case "stage_update":
            // Also handled via pipeline_update, but this gives finer detail
            break;

        case "log_entry":
            appendLog(msg);
            break;

        case "worker_connected":
            state.workers.push(msg);
            updateWorkerBadge();
            break;

        case "worker_disconnected":
            state.workers = state.workers.filter((w) => w.workerId !== msg.workerId);
            updateWorkerBadge();
            break;
    }
}

function upsertPipeline(pipeline) {
    const idx = state.pipelines.findIndex((p) => p.pipelineId === pipeline.pipelineId);
    if (idx >= 0) {
        state.pipelines[idx] = pipeline;
    } else {
        state.pipelines.unshift(pipeline);
    }
}

// ── Rendering: Pipelines ────────────────────────────────────────────────────

function renderPipelines() {
    const container = document.getElementById("pipeline-list");
    if (state.pipelines.length === 0) {
        container.innerHTML = '<div class="empty-state">No pipelines yet. Trigger one from the "New Pipeline" tab.</div>';
        return;
    }

    // Show no-worker banner if any pipelines are queued
    const hasQueued = state.pipelines.some((p) => p.status === "queued" || p.status === "pending");
    let bannerHtml = "";
    if (hasQueued && state.workers.length === 0) {
        bannerHtml = '<div class="no-worker-banner">No worker daemon connected. Pipelines will stay queued until you start one: <code>./scripts/start.sh --worker</code></div>';
    }

    const sorted = [...state.pipelines].sort(
        (a, b) => new Date(b.createdAt) - new Date(a.createdAt)
    );

    container.innerHTML = bannerHtml + sorted.map((p) => renderPipelineCard(p)).join("");

    // Attach click handlers
    container.querySelectorAll(".pipeline-card").forEach((card) => {
        card.addEventListener("click", () => {
            const id = card.dataset.id;
            const pipeline = state.pipelines.find((p) => p.pipelineId === id);
            if (pipeline) showPipelineDetail(pipeline);
        });
    });
}

function renderPipelineCard(p) {
    const icon = STATUS_ICONS[p.status] || "?";
    const typeLabel = {
        implementation: "E2E Test",
        discovery: "Discovery",
        "discovery-ticket": "Discovery (Ticket)",
        fix: "Fix Tests",
    }[p.pipelineType] || p.pipelineType;

    const timeAgo = formatTimeAgo(p.updatedAt || p.createdAt);
    const stages = renderStageDotsHTML(p);

    // Show status notes
    let statusNote = "";
    if (p.status === "running" && state.workers.length === 0) {
        statusNote = '<div class="pipeline-warning" style="border-color:rgba(63,185,80,0.3);color:var(--accent-green);background:rgba(63,185,80,0.1)">Running directly via Claude CLI</div>';
    } else if ((p.status === "queued" || p.status === "pending") && state.workers.length === 0) {
        statusNote = '<div class="pipeline-warning">Waiting to start... If stuck, check that <code>claude</code> CLI is installed.</div>';
    }

    return `
        <div class="pipeline-card" data-id="${escapeHtml(p.pipelineId)}">
            <div class="pipeline-status-icon ${p.status}">${icon}</div>
            <div class="pipeline-info">
                <h3>${escapeHtml(p.ticketKey || p.pipelineId)}</h3>
                <span class="pipeline-meta">${typeLabel} &middot; ${p.status}${p.currentStage ? " &middot; " + p.currentStage : ""}</span>
                ${statusNote}
            </div>
            <div class="pipeline-stages">${stages}</div>
            <div class="pipeline-time">${timeAgo}</div>
        </div>
    `;
}

function renderStageDotsHTML(p) {
    const allStages = p.pipelineType === "discovery"
        ? ["scanner", "analyzer", "ticket-creator"]
        : ["triage", "explorer", "playwright", "code-writer", "validator", "test-runner", "debug", "pr"];

    return allStages.map((s) => {
        const stageData = (p.stages || []).find((st) => st.name === s);
        let cls = "";
        if (stageData) {
            cls = stageData.status === "completed" ? "completed"
                : stageData.status === "failed" ? "failed"
                : "running";
        }
        return `<div class="stage-dot ${cls}" title="${s}"></div>`;
    }).join("");
}

// ── Rendering: Pipeline Detail Modal ────────────────────────────────────────

function showPipelineDetail(p) {
    const modal = document.getElementById("modal-overlay");
    const title = document.getElementById("modal-title");
    const body = document.getElementById("modal-body");

    title.textContent = `${p.ticketKey || p.pipelineId} — ${p.status}`;

    let html = "";

    // Info section
    html += `<div class="detail-section">
        <h4>Pipeline Info</h4>
        <div class="detail-row"><span class="detail-label">ID</span><span class="detail-value">${escapeHtml(p.pipelineId)}</span></div>
        <div class="detail-row"><span class="detail-label">Type</span><span class="detail-value">${escapeHtml(p.pipelineType)}</span></div>
        <div class="detail-row"><span class="detail-label">Status</span><span class="detail-value">${escapeHtml(p.status)}</span></div>
        <div class="detail-row"><span class="detail-label">Created</span><span class="detail-value">${escapeHtml(p.createdAt)}</span></div>
        <div class="detail-row"><span class="detail-label">Updated</span><span class="detail-value">${escapeHtml(p.updatedAt)}</span></div>
        ${p.completedAt ? `<div class="detail-row"><span class="detail-label">Completed</span><span class="detail-value">${escapeHtml(p.completedAt)}</span></div>` : ""}
        ${p.prUrl ? `<div class="detail-row"><span class="detail-label">PR/MR</span><span class="detail-value"><a href="${escapeHtml(p.prUrl)}" target="_blank">${escapeHtml(p.prUrl)}</a></span></div>` : ""}
        ${p.error ? `<div class="detail-row"><span class="detail-label">Error</span><span class="detail-value" style="color:var(--accent-red)">${escapeHtml(p.error)}</span></div>` : ""}
    </div>`;

    // Stage timeline
    if (p.stages && p.stages.length > 0) {
        html += `<div class="detail-section"><h4>Stage Timeline</h4><div class="stage-timeline">`;
        const sorted = [...p.stages].sort((a, b) => {
            const ia = STAGE_ORDER.indexOf(a.name);
            const ib = STAGE_ORDER.indexOf(b.name);
            return (ia === -1 ? 999 : ia) - (ib === -1 ? 999 : ib);
        });
        for (const s of sorted) {
            const icon = s.status === "completed" ? "\u2713" : s.status === "failed" ? "\u2717" : "\u25B6";
            html += `
                <div class="stage-timeline-item">
                    <div class="stage-icon ${s.status}">${icon}</div>
                    <div class="stage-details">
                        <div class="stage-name">${escapeHtml(s.name)}</div>
                        <div class="stage-time">${escapeHtml(s.timestamp || "")}${s.duration ? " (" + s.duration + ")" : ""}</div>
                    </div>
                </div>
            `;
        }
        html += `</div></div>`;
    }

    // Test results
    if (p.testResults) {
        const r = p.testResults;
        html += `<div class="detail-section">
            <h4>Test Results</h4>
            <div class="detail-row"><span class="detail-label">Passed</span><span class="detail-value" style="color:var(--accent-green)">${r.passed || 0}</span></div>
            <div class="detail-row"><span class="detail-label">Failed</span><span class="detail-value" style="color:var(--accent-red)">${r.failed || 0}</span></div>
            <div class="detail-row"><span class="detail-label">Skipped</span><span class="detail-value">${r.skipped || 0}</span></div>
            <div class="detail-row"><span class="detail-label">Total</span><span class="detail-value">${r.total || 0}</span></div>
        </div>`;
    }

    // Video
    if (p.videoUrl) {
        html += `<div class="detail-section">
            <h4>Test Video</h4>
            <video src="${escapeHtml(p.videoUrl)}" controls style="max-width:100%;border-radius:var(--radius-sm)"></video>
        </div>`;
    }

    // Feature doc
    if (p.featureDoc) {
        html += `<div class="detail-section">
            <h4>Feature Documentation</h4>
            <p style="font-size:13px;color:var(--text-secondary)">${escapeHtml(p.featureDoc)}</p>
        </div>`;
    }

    // Diff viewer
    if (p.diff) {
        html += `<div class="detail-section">
            <h4>Code Changes</h4>
            <div class="diff-viewer">${renderDiff(p.diff)}</div>
        </div>`;
    }

    // Actions
    html += `<div class="detail-section" style="display:flex;gap:8px;">`;
    if (p.status === "running" || p.status === "dispatched") {
        html += `<button class="btn btn-danger" onclick="cancelPipeline('${escapeHtml(p.pipelineId)}')">Cancel Pipeline</button>`;
    }
    html += `<button class="btn" onclick="viewLogs('${escapeHtml(p.pipelineId)}')">View Logs</button>`;
    html += `</div>`;

    body.innerHTML = html;
    modal.classList.remove("hidden");
}

function renderDiff(diff) {
    if (!diff) return "";
    return escapeHtml(diff).split("\n").map((line) => {
        if (line.startsWith("@@")) return `<span class="diff-hunk">${line}</span>`;
        if (line.startsWith("+++") || line.startsWith("---")) return `<span class="diff-file">${line}</span>`;
        if (line.startsWith("+")) return `<span class="diff-add">${line}</span>`;
        if (line.startsWith("-")) return `<span class="diff-del">${line}</span>`;
        return line;
    }).join("\n");
}

// ── Rendering: Logs ─────────────────────────────────────────────────────────

function appendLog(entry) {
    const pid = entry.pipelineId;
    if (!state.logs[pid]) state.logs[pid] = [];
    state.logs[pid].push(entry);

    // Cap logs per pipeline
    if (state.logs[pid].length > 5000) {
        state.logs[pid] = state.logs[pid].slice(-5000);
    }

    if (state.selectedLog === pid) {
        renderLogEntry(entry);
    }
}

function renderLogEntry(entry) {
    const container = document.getElementById("log-output");
    if (container.querySelector(".empty-state")) {
        container.innerHTML = "";
    }

    const el = document.createElement("div");
    el.className = "log-entry";

    const time = new Date(entry.timestamp).toLocaleTimeString();
    let msgClass = "log-msg";
    if (entry.level === "error") msgClass += " error";
    else if (entry.message && entry.message.includes("[stage]")) msgClass += " stage";
    else if (entry.message && entry.message.includes("WARNING")) msgClass += " warn";

    el.innerHTML = `<span class="log-time">${escapeHtml(time)}</span><span class="${msgClass}">${escapeHtml(entry.message || "")}</span>`;
    container.appendChild(el);

    if (document.getElementById("auto-scroll").checked) {
        container.scrollTop = container.scrollHeight;
    }
}

function selectLogPipeline(pipelineId) {
    state.selectedLog = pipelineId;
    const container = document.getElementById("log-output");
    container.innerHTML = "";

    const logs = state.logs[pipelineId] || [];
    if (logs.length === 0) {
        container.innerHTML = '<div class="empty-state">No logs yet for this pipeline.</div>';
        return;
    }

    for (const entry of logs) {
        renderLogEntry(entry);
    }
}

function updateLogPipelineSelect() {
    const select = document.getElementById("log-pipeline-select");
    const currentVal = select.value;

    const options = ['<option value="">Select a pipeline...</option>'];
    for (const p of state.pipelines) {
        const label = p.ticketKey || p.pipelineId;
        options.push(`<option value="${escapeHtml(p.pipelineId)}">${escapeHtml(label)} (${p.status})</option>`);
    }
    select.innerHTML = options.join("");

    if (currentVal) select.value = currentVal;
}

// ── Rendering: Config ───────────────────────────────────────────────────────

async function loadConfig() {
    try {
        const [fwRes, platRes, statusRes] = await Promise.all([
            fetch("/api/config/frameworks").then((r) => r.json()),
            fetch("/api/config/platforms").then((r) => r.json()),
            fetch("/api/status").then((r) => r.json()),
        ]);

        // Frameworks
        const fwContainer = document.getElementById("config-frameworks");
        fwContainer.innerHTML = (fwRes.frameworks || []).map((f) =>
            `<div class="config-item"><span class="label">${escapeHtml(f.name)}</span><span class="value">${escapeHtml(f.language)}</span></div>`
        ).join("");

        // Populate framework select in trigger form
        const fwSelect = document.getElementById("framework-select");
        fwSelect.innerHTML = '<option value="">Auto-detect</option>' +
            (fwRes.frameworks || []).map((f) =>
                `<option value="${escapeHtml(f.id)}">${escapeHtml(f.name)}</option>`
            ).join("");

        // Platforms
        const platContainer = document.getElementById("config-platforms");
        platContainer.innerHTML = (platRes.platforms || []).map((p) =>
            `<div class="config-item"><span class="label">${escapeHtml(p.name)}</span><span class="value">${escapeHtml(p.id)}</span></div>`
        ).join("");

        // Status
        const statusContainer = document.getElementById("config-status");
        statusContainer.innerHTML = `
            <div class="config-item"><span class="label">Uptime</span><span class="value">${Math.floor(statusRes.uptime)}s</span></div>
            <div class="config-item"><span class="label">Total Pipelines</span><span class="value">${statusRes.pipelines.total}</span></div>
            <div class="config-item"><span class="label">Running</span><span class="value">${statusRes.pipelines.running}</span></div>
            <div class="config-item"><span class="label">Completed</span><span class="value">${statusRes.pipelines.completed}</span></div>
            <div class="config-item"><span class="label">Failed</span><span class="value">${statusRes.pipelines.failed}</span></div>
            <div class="config-item"><span class="label">Workers</span><span class="value">${statusRes.workers.total} (${statusRes.workers.available} available)</span></div>
            <div class="config-item"><span class="label">WS Clients</span><span class="value">${statusRes.wsClients}</span></div>
        `;
    } catch (err) {
        console.error("Failed to load config:", err);
    }
}

// ── UI Helpers ──────────────────────────────────────────────────────────────

function updateWorkerBadge() {
    const badge = document.getElementById("worker-status");
    const text = document.getElementById("worker-text");

    if (state.workers.length > 0) {
        badge.className = "status-badge status-online";
        text.textContent = `${state.workers.length} Worker${state.workers.length > 1 ? "s" : ""}`;
    } else {
        badge.className = "status-badge status-offline";
        text.textContent = "No Workers";
    }

    // Update config workers section
    const container = document.getElementById("config-workers");
    if (state.workers.length === 0) {
        container.innerHTML = "No workers connected.";
    } else {
        container.innerHTML = state.workers.map((w) =>
            `<div class="config-item"><span class="label">${escapeHtml(w.workerId || w.hostname || "unknown")}</span><span class="value">cap: ${w.capacity || "?"}</span></div>`
        ).join("");
    }
}

function updateStats() {
    const running = state.pipelines.filter((p) => p.status === "running" || p.status === "dispatched").length;
    const queued = state.pipelines.filter((p) => p.status === "queued" || p.status === "pending").length;
    document.getElementById("stat-running").textContent = `${running} running`;
    document.getElementById("stat-queued").textContent = `${queued} queued`;
}

function formatTimeAgo(isoStr) {
    if (!isoStr) return "";
    const diff = Date.now() - new Date(isoStr).getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return "just now";
    if (mins < 60) return `${mins}m ago`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    return `${days}d ago`;
}

function escapeHtml(str) {
    if (!str) return "";
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

// ── Global Actions ──────────────────────────────────────────────────────────

window.cancelPipeline = async function(pipelineId) {
    if (!confirm("Cancel this pipeline?")) return;
    try {
        await fetch(`/api/pipelines/${encodeURIComponent(pipelineId)}`, { method: "DELETE" });
        document.getElementById("modal-overlay").classList.add("hidden");
    } catch (err) {
        alert("Failed to cancel: " + err.message);
    }
};

window.viewLogs = function(pipelineId) {
    document.getElementById("modal-overlay").classList.add("hidden");
    document.getElementById("log-pipeline-select").value = pipelineId;
    selectLogPipeline(pipelineId);
    switchTab("logs");
};

// ── Tab Switching ───────────────────────────────────────────────────────────

function switchTab(tabName) {
    document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
    document.querySelectorAll(".tab-content").forEach((c) => c.classList.remove("active"));
    document.querySelector(`.tab[data-tab="${tabName}"]`).classList.add("active");
    document.getElementById(`tab-${tabName}`).classList.add("active");

    if (tabName === "config") loadConfig();
}

// ── Event Listeners ─────────────────────────────────────────────────────────

document.addEventListener("DOMContentLoaded", () => {
    // Tabs
    document.querySelectorAll(".tab").forEach((tab) => {
        tab.addEventListener("click", () => switchTab(tab.dataset.tab));
    });

    // Modal close
    document.getElementById("modal-close").addEventListener("click", () => {
        document.getElementById("modal-overlay").classList.add("hidden");
    });
    document.getElementById("modal-overlay").addEventListener("click", (e) => {
        if (e.target === e.currentTarget) {
            document.getElementById("modal-overlay").classList.add("hidden");
        }
    });

    // Refresh
    document.getElementById("refresh-pipelines").addEventListener("click", async () => {
        try {
            const res = await fetch("/api/pipelines");
            const data = await res.json();
            state.pipelines = data.pipelines || [];
            renderPipelines();
            updateStats();
        } catch (err) {
            console.error("Refresh failed:", err);
        }
    });

    // Pipeline type toggle
    document.getElementById("pipeline-type").addEventListener("change", (e) => {
        const type = e.target.value;
        document.getElementById("impl-fields").classList.toggle("hidden", type !== "implementation" && type !== "discovery-ticket");
        document.getElementById("discovery-fields").classList.toggle("hidden", type !== "discovery");
        document.getElementById("fix-fields").classList.toggle("hidden", type !== "fix");
    });

    // Trigger form
    document.getElementById("trigger-form").addEventListener("submit", async (e) => {
        e.preventDefault();
        const type = document.getElementById("pipeline-type").value;
        const ticketKey = document.getElementById("ticket-key").value.trim();
        const env = document.getElementById("target-env").value;
        const framework = document.getElementById("framework-select").value;
        const auto = document.getElementById("flag-auto").checked;
        const watch = document.getElementById("flag-watch").checked;

        const payload = {
            pipelineType: type,
            ticketKey: ticketKey || null,
            flags: { env, auto, watch },
        };

        if (framework) payload.flags.framework = framework;

        if (type === "discovery") {
            const services = [];
            document.querySelectorAll('#discovery-fields input[type="checkbox"][value]').forEach((cb) => {
                if (cb.checked) services.push(cb.value);
            });
            payload.discovery = {
                services,
                since: document.getElementById("since-date").value || undefined,
                until: document.getElementById("until-date").value || undefined,
            };
            payload.flags.noAuto = document.getElementById("flag-no-auto").checked;
        }

        if (type === "fix") {
            payload.fix = {
                job: document.getElementById("fix-job").value.trim() || undefined,
                folder: document.getElementById("fix-folder").value,
                category: document.getElementById("fix-category").value,
            };
        }

        const btn = document.getElementById("trigger-btn");
        btn.disabled = true;
        btn.textContent = "Starting...";

        try {
            const res = await fetch("/api/pipelines", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(payload),
            });
            const data = await res.json();
            if (res.ok) {
                switchTab("pipelines");
            } else {
                alert("Failed: " + (data.error || "Unknown error"));
            }
        } catch (err) {
            alert("Failed to trigger: " + err.message);
        } finally {
            btn.disabled = false;
            btn.textContent = "Start Pipeline";
        }
    });

    // Log pipeline select
    document.getElementById("log-pipeline-select").addEventListener("change", (e) => {
        selectLogPipeline(e.target.value);
    });

    // Clear logs
    document.getElementById("clear-logs").addEventListener("click", () => {
        document.getElementById("log-output").innerHTML = '<div class="empty-state">Logs cleared.</div>';
    });

    // Connect WebSocket
    connectWs();

    // Load initial data
    loadConfig();
});
