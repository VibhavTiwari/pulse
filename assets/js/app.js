const state = {workspace: null, activeView: "brief"};
const views = {brief: "briefView", decisions: "decisionsView", commitments: "commitmentsView", risks: "risksView", meetings: "meetingsView", ask: "askView", sources: "sourcesView"};

const qs = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");

async function api(path, options = {}) {
  const response = await fetch(path, options);
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`;
    try {
      const body = await response.json();
      message = body.error || body.detail || JSON.stringify(body.errors || body);
    } catch {}
    throw new Error(message);
  }
  return response.json();
}

function toast(message) {
  const node = qs("#toast");
  node.textContent = message;
  node.classList.remove("hidden");
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => node.classList.add("hidden"), 3200);
}

function formatDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString(undefined, {month: "short", day: "numeric", year: "numeric"});
}

function setWorkspace(workspace) {
  state.workspace = workspace;
  qs("#workspaceName").textContent = workspace ? workspace.name : "No workspace";
  qs("#workspaceSetup").classList.toggle("hidden", Boolean(workspace));
  const health = workspace?.health || {};
  qs("#workspaceHealth").innerHTML = workspace ? `
    <span class="status ready">${escapeHtml(health.status || "ready")}</span>
    <span class="stat-pill">${health.source_count ?? 0} sources</span>
    <span class="stat-pill">${health.decision_count ?? 0} decisions</span>
    <span class="stat-pill">${health.commitment_count ?? 0} commitments</span>
    <span class="stat-pill">${health.risk_count ?? 0} risks</span>` : "";
}

function setView(view) {
  state.activeView = view;
  Object.entries(views).forEach(([key, id]) => qs(`#${id}`).classList.toggle("active-view", key === view));
  document.querySelectorAll(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.view === view));
  loadViewData().catch((error) => toast(error.message));
}

function empty(label) {
  return `<p class="empty">${escapeHtml(label)}</p>`;
}

async function loadWorkspaces() {
  const workspaces = await api("/api/workspaces");
  setWorkspace(workspaces[0] || null);
  if (state.workspace) await loadViewData();
}

async function refreshWorkspace() {
  if (!state.workspace) return;
  setWorkspace(await api(`/api/workspaces/${state.workspace.id}`));
}

async function loadViewData() {
  if (!state.workspace) return;
  const workspaceId = state.workspace.id;

  if (state.activeView === "brief") {
    const briefs = await api(`/api/workspaces/${workspaceId}/briefs`);
    qs("#briefList").innerHTML = briefs.length ? briefs.map((brief) => `<article class="card"><p class="label">${escapeHtml(formatDate(brief.brief_date))}</p><h3>${escapeHtml(brief.title)}</h3><p>${escapeHtml(brief.summary)}</p></article>`).join("") : empty("No briefs have been created yet.");
  }

  if (state.activeView === "decisions") {
    const decisions = await api(`/api/workspaces/${workspaceId}/decisions`);
    qs("#decisionList").innerHTML = decisions.length ? decisions.map((decision) => `<article class="row-card"><div><div class="source-meta"><span class="status">${escapeHtml(decision.status)}</span><span class="stat-pill">${escapeHtml(decision.record_state)}</span></div><h3>${escapeHtml(decision.title)}</h3><p>${escapeHtml(decision.context)}</p></div></article>`).join("") : empty("No accepted decisions have been logged yet.");
  }

  if (state.activeView === "commitments") {
    const commitments = await api(`/api/workspaces/${workspaceId}/commitments`);
    qs("#commitmentList").innerHTML = commitments.length ? commitments.map((commitment) => `<article class="row-card"><div><div class="source-meta"><span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span><span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date)) || "unknown"}</span></div><h3>${escapeHtml(commitment.title)}</h3><p>${escapeHtml(commitment.owner)}</p></div></article>`).join("") : empty("No accepted commitments have been captured yet.");
  }

  if (state.activeView === "risks") {
    const risks = await api(`/api/workspaces/${workspaceId}/risks`);
    qs("#riskList").innerHTML = risks.length ? risks.map((risk) => `<article class="row-card"><div><div class="source-meta"><span class="status ${escapeHtml(risk.status)}">${escapeHtml(risk.status)}</span><span class="stat-pill">${escapeHtml(risk.severity)}</span></div><h3>${escapeHtml(risk.title)}</h3><p>${escapeHtml(risk.description)}</p>${risk.mitigation ? `<p><strong>Mitigation:</strong> ${escapeHtml(risk.mitigation)}</p>` : ""}</div></article>`).join("") : empty("No accepted risks have been captured yet.");
  }

  if (state.activeView === "meetings") {
    const meetings = await api(`/api/workspaces/${workspaceId}/meetings`);
    qs("#meetingList").innerHTML = meetings.length ? meetings.map((meeting) => `<article class="card"><p class="label">${escapeHtml(formatDate(meeting.meeting_date))}</p><h3>${escapeHtml(meeting.title)}</h3><p>${escapeHtml(meeting.description || "")}</p><p><strong>Attendees:</strong> ${escapeHtml((meeting.attendees || []).join(", "))}</p></article>`).join("") : empty("No meeting prep has been created yet.");
  }

  if (state.activeView === "sources") await loadSources();
}

function renderAnswer(answer) {
  const citations = answer.citations || [];
  qs("#answerPanel").innerHTML = `<p>${escapeHtml(answer.answer)}</p>${citations.length ? `<div class="citation-list">${citations.map((citation) => `<button class="citation" type="button" data-source-id="${escapeHtml(citation.source_id)}"><strong>${escapeHtml(citation.source_title)} · ${escapeHtml(citation.source_location)}</strong><span>${escapeHtml(citation.quote)}</span></button>`).join("")}</div>` : `<p class="empty">No citations were found, so this answer is not source-backed.</p>`}`;
  document.querySelectorAll(".citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
}

async function loadSources() {
  const sources = await api(`/api/workspaces/${state.workspace.id}/sources`);
  qs("#sourceList").innerHTML = sources.length ? sources.map((source) => `<article class="row-card"><button type="button" data-source-id="${escapeHtml(source.id)}"><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span></div><h3>${escapeHtml(source.title)}</h3><p>${escapeHtml(source.original_filename || source.source_type)}</p></button><button type="button" data-delete-source="${escapeHtml(source.id)}">Delete</button></article>`).join("") : empty("Upload a .txt or .md source to start building evidence.");
  document.querySelectorAll("[data-source-id]").forEach((button) => button.addEventListener("click", () => loadSourcePreview(button.dataset.sourceId)));
  document.querySelectorAll("[data-delete-source]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/sources/${button.dataset.deleteSource}`, {method: "DELETE"});
    toast("Source removed from active search.");
    await loadSources();
    await refreshWorkspace();
  }));
}

async function loadSourcePreview(sourceId) {
  const source = await api(`/api/sources/${sourceId}`);
  qs("#sourcePreview").innerHTML = `<h3>${escapeHtml(source.title)}</h3><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span><span class="stat-pill">${escapeHtml(source.source_type)}</span></div>${(source.chunks || []).map((chunk) => `<div class="source-chunk"><p class="label">Chunk ${chunk.chunk_index + 1}</p><p>${escapeHtml(chunk.text)}</p></div>`).join("")}`;
}

function bindEvents() {
  document.querySelectorAll(".nav-item").forEach((button) => button.addEventListener("click", () => setView(button.dataset.view)));
  qs("#workspaceForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const workspace = await api("/api/workspaces", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({name: qs("#workspaceInput").value.trim()})});
    setWorkspace(workspace);
    await loadViewData();
  });
  qs("#uploadForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const fileInput = qs("#sourceFile");
    if (!fileInput.files.length) return;
    const data = new FormData();
    data.append("file", fileInput.files[0]);
    const source = await api(`/api/workspaces/${state.workspace.id}/sources`, {method: "POST", body: data});
    fileInput.value = "";
    toast(source.processing_status === "ready" ? "Source ready." : `Source ${source.processing_status}.`);
    await loadSources();
    await refreshWorkspace();
  });
  qs("#askForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const question = qs("#questionInput").value.trim();
    if (!question) return;
    renderAnswer(await api(`/api/workspaces/${state.workspace.id}/ask`, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({question})}));
  });
}

bindEvents();
loadWorkspaces().catch((error) => toast(error.message));
