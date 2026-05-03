const state = {workspace: null, activeView: "brief", sourceMode: "manual_entry", selectedSourceId: null, askThreadId: null};
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

function labelize(value) {
  return String(value ?? "").replaceAll("_", " ");
}

function queryString(params) {
  const search = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value) search.set(key, value);
  });
  const value = search.toString();
  return value ? `?${value}` : "";
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
  state.askThreadId = answer.thread_id || state.askThreadId;
  const citations = answer.citations || [];
  const turn = `<article class="ask-turn"><p class="label">Question</p><p>${escapeHtml(answer.question)}</p><div class="source-meta"><span class="status ${escapeHtml(answer.evidence_state || "none")}">${escapeHtml(answer.evidence_state || "none")} evidence</span></div><p>${escapeHtml(answer.answer)}</p>${citations.length ? `<div class="citation-list">${citations.map((citation) => `<button class="citation" type="button" data-source-id="${escapeHtml(citation.source_id)}"><strong>${escapeHtml(citation.source_title)} · ${escapeHtml(citation.source_location || citation.location_hint || "source passage")}</strong><span>${escapeHtml(citation.quote || citation.evidence_text)}</span></button>`).join("")}</div>` : `<p class="empty">No citations were found, so Pulse is not making a project-truth claim.</p>`}</article>`;
  const panel = qs("#answerPanel");
  if (panel.querySelector(".empty") && !panel.querySelector(".ask-turn")) panel.innerHTML = "";
  panel.insertAdjacentHTML("beforeend", turn);
  document.querySelectorAll(".citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
}

async function loadSources() {
  const query = queryString({
    processing_status: qs("#sourceStatusFilter")?.value,
    source_type: qs("#sourceTypeFilter")?.value
  });
  const sources = await api(`/api/workspaces/${state.workspace.id}/sources${query}`);
  qs("#sourceList").innerHTML = sources.length ? sources.map((source) => `<article class="row-card"><button type="button" data-source-id="${escapeHtml(source.id)}"><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span><span class="stat-pill">${escapeHtml(labelize(source.source_type))}</span><span class="stat-pill">${escapeHtml(labelize(source.origin))}</span>${source.source_date ? `<span class="stat-pill">${escapeHtml(formatDate(source.source_date))}</span>` : ""}</div><h3>${escapeHtml(source.title)}</h3><p>${escapeHtml(source.original_filename || "Manual source")} · Updated ${escapeHtml(formatDate(source.updated_at))}</p></button><button class="danger-button" type="button" data-delete-source="${escapeHtml(source.id)}">Delete</button></article>`).join("") : empty("Source Library is where project evidence starts. Add pasted text or upload a readable .txt/.md file.");
  document.querySelectorAll("[data-source-id]").forEach((button) => button.addEventListener("click", () => loadSourcePreview(button.dataset.sourceId)));
  document.querySelectorAll("[data-delete-source]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/sources/${button.dataset.deleteSource}`, {method: "DELETE"});
    toast("Source removed from active search.");
    await loadSources();
    await refreshWorkspace();
  }));
}

async function loadSourcePreview(sourceId) {
  state.selectedSourceId = sourceId;
  const source = await api(`/api/workspaces/${state.workspace.id}/sources/${sourceId}`);
  const textReady = source.processing_status === "ready" && source.text_content;
  const textPanel = textReady
    ? `<div class="source-text">${escapeHtml(source.text_content)}</div>`
    : `<p class="empty">${source.processing_status === "failed" ? escapeHtml(source.error_message || "Pulse could not extract readable text from this source.") : "This source is pending readable text extraction."}</p>`;
  qs("#sourcePreview").innerHTML = `<h3>${escapeHtml(source.title)}</h3><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span><span class="stat-pill">${escapeHtml(labelize(source.source_type))}</span></div><div class="source-detail-grid"><div class="source-detail"><p class="label">Origin</p><p>${escapeHtml(labelize(source.origin))}</p></div><div class="source-detail"><p class="label">Source date</p><p>${escapeHtml(formatDate(source.source_date) || "Unknown")}</p></div><div class="source-detail"><p class="label">Created</p><p>${escapeHtml(formatDate(source.created_at))}</p></div><div class="source-detail"><p class="label">Updated</p><p>${escapeHtml(formatDate(source.updated_at))}</p></div></div><form id="metadataForm" class="metadata-form"><div class="form-grid"><label><span>Title</span><input id="metadataTitle" type="text" value="${escapeHtml(source.title)}" required /></label><label><span>Type</span><select id="metadataType" required>${["note","document","transcript","meeting_note","project_update","other"].map((type) => `<option value="${type}" ${source.source_type === type ? "selected" : ""}>${escapeHtml(labelize(type))}</option>`).join("")}</select></label><label><span>Source date</span><input id="metadataDate" type="date" value="${escapeHtml(source.source_date || "")}" /></label></div><button type="submit">Save metadata</button></form><div class="source-actions">${source.origin === "manual_entry" ? `<button id="editTextButton" class="secondary-button" type="button">Edit text</button>` : ""}</div><h4>Readable text Pulse has stored</h4><div id="sourceTextPanel">${textPanel}</div>`;
  qs("#metadataForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    await api(`/api/workspaces/${state.workspace.id}/sources/${source.id}`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: qs("#metadataTitle").value.trim(),
        source_type: qs("#metadataType").value,
        source_date: qs("#metadataDate").value || null
      })
    });
    toast("Source metadata saved.");
    await loadSources();
    await loadSourcePreview(source.id);
  });
  qs("#editTextButton")?.addEventListener("click", () => renderTextEditor(source));
}

function renderTextEditor(source) {
  qs("#sourceTextPanel").innerHTML = `<form id="textEditForm" class="text-edit-form"><textarea id="sourceTextEdit" required>${escapeHtml(source.text_content || "")}</textarea><button type="submit">Save text</button></form>`;
  qs("#textEditForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    await api(`/api/workspaces/${state.workspace.id}/sources/${source.id}/text`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text_content: qs("#sourceTextEdit").value})
    });
    toast("Source text saved.");
    await refreshWorkspace();
    await loadSourcePreview(source.id);
  });
}

function setSourceMode(mode) {
  state.sourceMode = mode;
  document.querySelectorAll("[data-source-mode]").forEach((button) => button.classList.toggle("active", button.dataset.sourceMode === mode));
  qs("#manualEntryPanel").classList.toggle("hidden", mode !== "manual_entry");
  qs("#manualUploadPanel").classList.toggle("hidden", mode !== "manual_upload");
  qs("#sourceText").required = mode === "manual_entry";
  qs("#sourceFile").required = mode === "manual_upload";
}

function bindEvents() {
  document.querySelectorAll(".nav-item").forEach((button) => button.addEventListener("click", () => setView(button.dataset.view)));
  document.querySelectorAll("[data-source-mode]").forEach((button) => button.addEventListener("click", () => setSourceMode(button.dataset.sourceMode)));
  qs("#sourceStatusFilter").addEventListener("change", () => loadSources().catch((error) => toast(error.message)));
  qs("#sourceTypeFilter").addEventListener("change", () => loadSources().catch((error) => toast(error.message)));
  qs("#workspaceForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const workspace = await api("/api/workspaces", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({name: qs("#workspaceInput").value.trim()})});
    setWorkspace(workspace);
    await loadViewData();
  });
  qs("#sourceForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const attrs = {
      title: qs("#sourceTitle").value.trim(),
      source_type: qs("#sourceType").value,
      source_date: qs("#sourceDate").value || null
    };
    let source;
    if (state.sourceMode === "manual_entry") {
      source = await api(`/api/workspaces/${state.workspace.id}/sources/text`, {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({...attrs, origin: "manual_entry", text_content: qs("#sourceText").value})
      });
      qs("#sourceText").value = "";
    } else {
      const fileInput = qs("#sourceFile");
      if (!fileInput.files.length) return;
      const data = new FormData();
      Object.entries(attrs).forEach(([key, value]) => {
        if (value) data.append(key, value);
      });
      data.append("file", fileInput.files[0]);
      source = await api(`/api/workspaces/${state.workspace.id}/sources`, {method: "POST", body: data});
      fileInput.value = "";
    }
    qs("#sourceTitle").value = "";
    qs("#sourceDate").value = "";
    toast(source.processing_status === "ready" ? "Source ready." : `Source ${source.processing_status}.`);
    await loadSources();
    await loadSourcePreview(source.id);
    await refreshWorkspace();
  });
  qs("#askForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const question = qs("#questionInput").value.trim();
    if (!question) return;
    const askPath = state.askThreadId
      ? `/api/workspaces/${state.workspace.id}/ask_threads/${state.askThreadId}/messages`
      : `/api/workspaces/${state.workspace.id}/ask`;
    renderAnswer(await api(askPath, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({question})}));
    qs("#questionInput").value = "";
  });
  qs("#newAskThread").addEventListener("click", () => {
    state.askThreadId = null;
    qs("#answerPanel").innerHTML = `<p class="empty">Ask Pulse answers only from ready project sources and shows citations when evidence exists.</p>`;
  });
}

setSourceMode(state.sourceMode);
bindEvents();
loadWorkspaces().catch((error) => toast(error.message));
