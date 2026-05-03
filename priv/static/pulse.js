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
    await loadBriefs();
  }

  if (state.activeView === "decisions") {
    await loadDecisions();
  }

  if (state.activeView === "commitments") {
    await loadCommitments();
  }

  if (state.activeView === "risks") {
    const risks = await api(`/api/workspaces/${workspaceId}/risks`);
    qs("#riskList").innerHTML = risks.length ? risks.map((risk) => `<article class="row-card"><div><div class="source-meta"><span class="status ${escapeHtml(risk.status)}">${escapeHtml(risk.status)}</span><span class="stat-pill">${escapeHtml(risk.severity)}</span></div><h3>${escapeHtml(risk.title)}</h3><p>${escapeHtml(risk.description)}</p>${risk.mitigation ? `<p><strong>Mitigation:</strong> ${escapeHtml(risk.mitigation)}</p>` : ""}</div></article>`).join("") : empty("No accepted risks have been captured yet.");
  }

  if (state.activeView === "meetings") {
    await loadMeetings();
  }

  if (state.activeView === "sources") await loadSources();
}

async function loadBriefs(selectedBriefId = null) {
  const workspaceId = state.workspace.id;
  const briefs = await api(`/api/workspaces/${workspaceId}/briefs`);
  const selectedBrief = selectedBriefId
    ? await api(`/api/workspaces/${workspaceId}/briefs/${selectedBriefId}`)
    : briefs[0];
  qs("#briefPanel").innerHTML = selectedBrief ? renderBrief(selectedBrief) : empty("No daily brief has been generated yet.");
  qs("#briefList").innerHTML = briefs.length ? briefs.map(renderBriefListItem).join("") : empty("No briefs have been created yet.");
  bindBriefActions();
}

function renderBriefListItem(brief) {
  return `<article class="row-card"><button type="button" data-brief-id="${escapeHtml(brief.id)}"><div class="source-meta"><span class="status ready">${escapeHtml(brief.brief_type)}</span><span class="stat-pill">${escapeHtml(formatDate(brief.brief_date))}</span><span class="stat-pill">${brief.what_changed_count ?? 0} changes</span><span class="stat-pill">${brief.needs_attention_count ?? 0} attention</span></div><h3>${escapeHtml(brief.title)}</h3><p>${escapeHtml(brief.summary)}</p></button></article>`;
}

function renderBrief(brief) {
  const sections = brief.sections || {};
  return `<article class="brief-card"><div class="source-meta"><span class="status ready">${escapeHtml(brief.brief_type)}</span><span class="stat-pill">${escapeHtml(formatDate(brief.brief_date))}</span></div><h3>${escapeHtml(brief.title)}</h3><p>${escapeHtml(brief.summary)}</p>${renderBriefSection("What changed?", sections.what_changed || [])}${renderBriefSection("Needs attention", sections.needs_attention || [])}</article>`;
}

function renderBriefSection(title, items) {
  return `<section class="brief-section"><h4>${escapeHtml(title)}</h4><div class="brief-items">${items.map(renderBriefItem).join("")}</div></section>`;
}

function renderBriefItem(item) {
  const evidence = item.evidence_refs || [];
  const link = item.linked_entity_type && item.linked_entity_id && item.linked_entity_type !== "source"
    ? `<button class="secondary-button" type="button" data-record-view="${escapeHtml(item.linked_entity_type)}">Open ${escapeHtml(item.linked_entity_type)}</button>`
    : "";
  return `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(item.evidence_state || "none")}">${escapeHtml(item.evidence_state || "none")} evidence</span><span class="stat-pill">${escapeHtml(labelize(item.item_type))}</span></div><h5>${escapeHtml(item.title)}</h5><p>${escapeHtml(item.body)}</p>${evidence.length ? `<div class="citation-list">${evidence.map(renderBriefEvidence).join("")}</div>` : `<p class="empty">No linked source evidence.</p>`}<div class="source-actions">${link}</div></article>`;
}

function renderBriefEvidence(reference) {
  return `<button class="citation" type="button" data-source-id="${escapeHtml(reference.source_id)}"><strong>${escapeHtml(reference.source_title || "Source evidence")} - ${escapeHtml(reference.location_hint || "source")}</strong><span>${escapeHtml(reference.evidence_text || "")}</span></button>`;
}

function bindBriefActions() {
  document.querySelectorAll("[data-brief-id]").forEach((button) => button.addEventListener("click", () => {
    loadBriefs(button.dataset.briefId).catch((error) => toast(error.message));
  }));
  document.querySelectorAll("#briefView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
  document.querySelectorAll("[data-record-view]").forEach((button) => button.addEventListener("click", () => {
    const view = `${button.dataset.recordView}s`;
    if (views[view]) setView(view);
  }));
}

async function loadDecisions() {
  const workspaceId = state.workspace.id;
  const [decisions, suggestions] = await Promise.all([
    api(`/api/workspaces/${workspaceId}/decisions`),
    api(`/api/workspaces/${workspaceId}/decision_suggestions`)
  ]);
  qs("#decisionList").innerHTML = decisions.length ? decisions.map(renderDecisionCard).join("") : empty("No accepted decisions yet. Create one manually or accept a suggested decision.");
  qs("#decisionInbox").innerHTML = suggestions.length ? suggestions.map(renderDecisionSuggestion).join("") : empty("No suggested decisions are waiting for approval.");
  bindDecisionActions();
}

function renderDecisionCard(decision) {
  return `<article class="row-card"><div><div class="source-meta"><span class="status ${escapeHtml(decision.status)}">${escapeHtml(decision.status)}</span><span class="stat-pill">${escapeHtml(labelize(decision.source_origin || "manual"))}</span><span class="stat-pill">${escapeHtml(formatDate(decision.decision_date))}</span><span class="stat-pill">${escapeHtml(decision.evidence_count ? `${decision.evidence_count} evidence` : "No evidence")}</span></div><h3>${escapeHtml(decision.title)}</h3><p>${escapeHtml(decision.context)}</p><p><strong>Owner:</strong> ${escapeHtml(decision.owner)}</p>${renderDecisionEvidence(decision)}</div></article>`;
}

function renderDecisionSuggestion(decision) {
  const incomplete = String(decision.owner || "").toLowerCase() === "unknown";
  return `<article class="row-card"><div><div class="source-meta"><span class="status suggested">suggested</span><span class="stat-pill">${escapeHtml(formatDate(decision.decision_date))}</span><span class="stat-pill">${escapeHtml(decision.evidence_count ? `${decision.evidence_count} evidence` : "No evidence")}</span>${incomplete ? `<span class="status failed">Needs owner</span>` : ""}</div><h3>${escapeHtml(decision.title)}</h3><p>${escapeHtml(decision.context)}</p><p><strong>Owner:</strong> ${escapeHtml(decision.owner)}</p>${renderDecisionEvidence(decision)}</div><div class="source-actions"><button class="secondary-button" type="button" data-edit-decision="${escapeHtml(decision.id)}">Edit</button><button class="secondary-button" type="button" data-accept-decision="${escapeHtml(decision.id)}">Accept</button><button class="danger-button" type="button" data-reject-decision="${escapeHtml(decision.id)}">Reject</button></div></article>`;
}

function renderDecisionEvidence(decision) {
  const evidence = decision.evidence || [];
  if (!evidence.length) return `<p class="empty">Manual decision with no linked source evidence.</p>`;
  return `<div class="citation-list">${evidence.map((reference) => `<button class="citation" type="button" data-source-id="${escapeHtml(reference.source_id)}"><strong>${escapeHtml(reference.source_title || "Source evidence")} - ${escapeHtml(reference.location_hint || "source")}</strong><span>${escapeHtml(reference.evidence_text || "")}</span></button>`).join("")}</div>`;
}

function bindDecisionActions() {
  document.querySelectorAll("#decisionsView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
  document.querySelectorAll("[data-accept-decision]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/decisions/${button.dataset.acceptDecision}/accept`, {method: "POST"});
    toast("Decision accepted.");
    await loadDecisions();
    await refreshWorkspace();
  }));
  document.querySelectorAll("[data-reject-decision]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/decisions/${button.dataset.rejectDecision}/reject`, {method: "POST"});
    toast("Decision suggestion rejected.");
    await loadDecisions();
  }));
  document.querySelectorAll("[data-edit-decision]").forEach((button) => button.addEventListener("click", async () => {
    const title = window.prompt("Decision title");
    if (title === null) return;
    const owner = window.prompt("Owner");
    if (owner === null) return;
    await api(`/api/workspaces/${state.workspace.id}/decisions/${button.dataset.editDecision}`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({title: title.trim(), owner: owner.trim()})
    });
    toast("Decision suggestion updated.");
    await loadDecisions();
  }));
}

async function loadCommitments() {
  const workspaceId = state.workspace.id;
  const query = queryString({status: qs("#commitmentStatusFilter")?.value});
  const [commitments, suggestions] = await Promise.all([
    api(`/api/workspaces/${workspaceId}/commitments${query}`),
    api(`/api/workspaces/${workspaceId}/commitment_suggestions`)
  ]);
  qs("#commitmentList").innerHTML = commitments.length ? commitments.map(renderCommitmentCard).join("") : empty("No accepted commitments yet. Create one manually or accept a suggested commitment.");
  qs("#commitmentInbox").innerHTML = suggestions.length ? suggestions.map(renderCommitmentSuggestion).join("") : empty("No suggested commitments are waiting for approval.");
  bindCommitmentActions();
}

function renderCommitmentCard(commitment) {
  return `<article class="row-card"><div><div class="source-meta"><span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span><span class="stat-pill">${escapeHtml(labelize(commitment.source_origin || "manual"))}</span><span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date) || "unknown")}</span><span class="stat-pill">${escapeHtml(commitment.evidence_count ? `${commitment.evidence_count} evidence` : "No evidence")}</span></div><h3>${escapeHtml(commitment.title)}</h3><p>${escapeHtml(commitment.description || "")}</p><p><strong>Owner:</strong> ${escapeHtml(commitment.owner)}</p>${renderRecordEvidence(commitment)}</div><div class="source-actions"><select data-commitment-status="${escapeHtml(commitment.id)}" aria-label="Update commitment status"><option value="open" ${commitment.status === "open" ? "selected" : ""}>Open</option><option value="done" ${commitment.status === "done" ? "selected" : ""}>Done</option><option value="overdue" ${commitment.status === "overdue" ? "selected" : ""}>Overdue</option><option value="blocked" ${commitment.status === "blocked" ? "selected" : ""}>Blocked</option></select></div></article>`;
}

function renderCommitmentSuggestion(commitment) {
  const incomplete = String(commitment.owner || "").toLowerCase() === "unknown";
  return `<article class="row-card"><div><div class="source-meta"><span class="status suggested">suggested</span><span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span><span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date) || "unknown")}</span><span class="stat-pill">${escapeHtml(commitment.evidence_count ? `${commitment.evidence_count} evidence` : "No evidence")}</span>${incomplete ? `<span class="status failed">Needs owner</span>` : ""}</div><h3>${escapeHtml(commitment.title)}</h3><p>${escapeHtml(commitment.description || "")}</p><p><strong>Owner:</strong> ${escapeHtml(commitment.owner)}</p>${renderRecordEvidence(commitment)}</div><div class="source-actions"><button class="secondary-button" type="button" data-edit-commitment="${escapeHtml(commitment.id)}">Edit</button><button class="secondary-button" type="button" data-accept-commitment="${escapeHtml(commitment.id)}">Accept</button><button class="danger-button" type="button" data-reject-commitment="${escapeHtml(commitment.id)}">Reject</button></div></article>`;
}

function renderRecordEvidence(record) {
  const evidence = record.evidence || [];
  if (!evidence.length) return `<p class="empty">Manual record with no linked source evidence.</p>`;
  return `<div class="citation-list">${evidence.map((reference) => `<button class="citation" type="button" data-source-id="${escapeHtml(reference.source_id)}"><strong>${escapeHtml(reference.source_title || "Source evidence")} - ${escapeHtml(reference.location_hint || "source")}</strong><span>${escapeHtml(reference.evidence_text || "")}</span></button>`).join("")}</div>`;
}

function bindCommitmentActions() {
  document.querySelectorAll("#commitmentsView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
  document.querySelectorAll("[data-accept-commitment]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/commitments/${button.dataset.acceptCommitment}/accept`, {method: "POST"});
    toast("Commitment accepted.");
    await loadCommitments();
    await refreshWorkspace();
  }));
  document.querySelectorAll("[data-reject-commitment]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/commitments/${button.dataset.rejectCommitment}/reject`, {method: "POST"});
    toast("Commitment suggestion rejected.");
    await loadCommitments();
  }));
  document.querySelectorAll("[data-edit-commitment]").forEach((button) => button.addEventListener("click", async () => {
    const title = window.prompt("Commitment title");
    if (title === null) return;
    const owner = window.prompt("Owner");
    if (owner === null) return;
    await api(`/api/workspaces/${state.workspace.id}/commitments/${button.dataset.editCommitment}`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({title: title.trim(), owner: owner.trim()})
    });
    toast("Commitment suggestion updated.");
    await loadCommitments();
  }));
  document.querySelectorAll("[data-commitment-status]").forEach((select) => select.addEventListener("change", async () => {
    await api(`/api/workspaces/${state.workspace.id}/commitments/${select.dataset.commitmentStatus}/status`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({status: select.value})
    });
    toast("Commitment status updated.");
    await loadCommitments();
  }));
}

async function loadMeetings(selectedMeetingId = null) {
  const workspaceId = state.workspace.id;
  const meetings = await api(`/api/workspaces/${workspaceId}/meetings`);
  qs("#meetingList").innerHTML = meetings.length ? meetings.map(renderMeetingCard).join("") : empty("No meeting prep has been created yet.");
  bindMeetingListActions();

  if (selectedMeetingId || meetings[0]) {
    await loadMeetingPrep(selectedMeetingId || meetings[0].id);
  } else {
    qs("#meetingPrepPanel").innerHTML = empty("Create a meeting to prepare with accepted decisions, open commitments, and agenda topics.");
  }
}

function renderMeetingCard(meeting) {
  return `<article class="row-card"><button type="button" data-meeting-id="${escapeHtml(meeting.id)}"><p class="label">${escapeHtml(formatDate(meeting.meeting_date))}</p><h3>${escapeHtml(meeting.title)}</h3><p>${escapeHtml(meeting.description || "")}</p><p><strong>Attendees:</strong> ${escapeHtml((meeting.attendees || []).join(", ") || "Not specified")}</p></button></article>`;
}

function bindMeetingListActions() {
  document.querySelectorAll("[data-meeting-id]").forEach((button) => button.addEventListener("click", () => {
    loadMeetingPrep(button.dataset.meetingId).catch((error) => toast(error.message));
  }));
}

async function loadMeetingPrep(meetingId) {
  const prep = await api(`/api/workspaces/${state.workspace.id}/meetings/${meetingId}/prep`);
  qs("#meetingPrepPanel").innerHTML = renderMeetingPrep(prep);
  bindMeetingPrepActions();
}

function renderMeetingPrep(prep) {
  const meeting = prep.meeting;
  return `<div class="source-meta"><span class="status ready">prep</span><span class="stat-pill">${escapeHtml(formatDate(meeting.meeting_date))}</span></div><h3>${escapeHtml(meeting.title)}</h3><p>${escapeHtml(meeting.description || "No meeting context provided.")}</p><p><strong>Attendees:</strong> ${escapeHtml((meeting.attendees || []).join(", ") || "Not specified")}</p><div class="source-actions"><button id="refreshMeetingPrep" class="secondary-button" type="button" data-refresh-meeting="${escapeHtml(meeting.id)}">Refresh prep</button></div>${renderPrepSection("Relevant decisions", prep.relevant_decisions || [], renderPrepDecision)}${renderPrepSection("Open commitments", prep.open_commitments || [], renderPrepCommitment)}${renderAgenda(prep.agenda_items || [])}`;
}

function renderPrepSection(title, items, renderItem) {
  return `<section class="brief-section"><h4>${escapeHtml(title)}</h4><div class="brief-items">${items.length ? items.map(renderItem).join("") : empty(`No ${title.toLowerCase()} found.`)}</div></section>`;
}

function renderPrepDecision(decision) {
  return `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(decision.status)}">${escapeHtml(decision.status)}</span><span class="stat-pill">${escapeHtml(formatDate(decision.decision_date))}</span><span class="stat-pill">${escapeHtml(decision.evidence_count ? `${decision.evidence_count} evidence` : "No evidence")}</span></div><h5>${escapeHtml(decision.title)}</h5><p>${escapeHtml(decision.context)}</p><p><strong>Owner:</strong> ${escapeHtml(decision.owner)}</p>${renderRecordEvidence(decision)}<div class="source-actions"><button class="secondary-button" type="button" data-open-record="decisions">Open decision</button></div></article>`;
}

function renderPrepCommitment(commitment) {
  return `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span><span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date) || "unknown")}</span><span class="stat-pill">${escapeHtml(commitment.evidence_count ? `${commitment.evidence_count} evidence` : "No evidence")}</span></div><h5>${escapeHtml(commitment.title)}</h5><p>${escapeHtml(commitment.description || "")}</p><p><strong>Owner:</strong> ${escapeHtml(commitment.owner)}</p>${renderRecordEvidence(commitment)}<div class="source-actions"><button class="secondary-button" type="button" data-open-record="commitments">Open commitment</button></div></article>`;
}

function renderAgenda(items) {
  return `<section class="brief-section"><h4>Suggested agenda</h4><div class="brief-items">${items.map((item) => `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(item.evidence_state || "none")}">${escapeHtml(item.evidence_state || "none")} evidence</span>${item.linked_entity_type ? `<span class="stat-pill">${escapeHtml(labelize(item.linked_entity_type))}</span>` : ""}</div><h5>${escapeHtml(item.title)}</h5><p>${escapeHtml(item.reason)}</p>${item.linked_entity_type === "decision" ? `<button class="secondary-button" type="button" data-open-record="decisions">Open decision</button>` : ""}${item.linked_entity_type === "commitment" ? `<button class="secondary-button" type="button" data-open-record="commitments">Open commitment</button>` : ""}</article>`).join("")}</div></section>`;
}

function bindMeetingPrepActions() {
  qs("#refreshMeetingPrep")?.addEventListener("click", async (event) => {
    const prep = await api(`/api/workspaces/${state.workspace.id}/meetings/${event.currentTarget.dataset.refreshMeeting}/prep/refresh`, {method: "POST"});
    qs("#meetingPrepPanel").innerHTML = renderMeetingPrep(prep);
    bindMeetingPrepActions();
    toast("Meeting prep refreshed.");
  });
  document.querySelectorAll("#meetingsView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
  document.querySelectorAll("#meetingsView [data-open-record]").forEach((button) => button.addEventListener("click", () => {
    setView(button.dataset.openRecord);
  }));
}

function renderAnswer(answer) {
  state.askThreadId = answer.thread_id || state.askThreadId;
  const citations = answer.citations || [];
  const turn = `<article class="ask-turn"><p class="label">Question</p><p>${escapeHtml(answer.question)}</p><div class="source-meta"><span class="status ${escapeHtml(answer.evidence_state || "none")}">${escapeHtml(answer.evidence_state || "none")} evidence</span></div><p>${escapeHtml(answer.answer)}</p>${citations.length ? `<div class="citation-list">${citations.map((citation) => `<button class="citation" type="button" data-source-id="${escapeHtml(citation.source_id)}"><strong>${escapeHtml(citation.source_title)} - ${escapeHtml(citation.source_location || citation.location_hint || "source passage")}</strong><span>${escapeHtml(citation.quote || citation.evidence_text)}</span></button>`).join("")}</div>` : `<p class="empty">No citations were found, so Pulse is not making a project-truth claim.</p>`}</article>`;
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
  qs("#sourceList").innerHTML = sources.length ? sources.map((source) => `<article class="row-card"><button type="button" data-source-id="${escapeHtml(source.id)}"><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span><span class="stat-pill">${escapeHtml(labelize(source.source_type))}</span><span class="stat-pill">${escapeHtml(labelize(source.origin))}</span>${source.source_date ? `<span class="stat-pill">${escapeHtml(formatDate(source.source_date))}</span>` : ""}</div><h3>${escapeHtml(source.title)}</h3><p>${escapeHtml(source.original_filename || "Manual source")} - Updated ${escapeHtml(formatDate(source.updated_at))}</p></button><button class="danger-button" type="button" data-delete-source="${escapeHtml(source.id)}">Delete</button></article>`).join("") : empty("Source Library is where project evidence starts. Add pasted text or upload a readable .txt/.md file.");
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
  qs("#briefDateInput").value = new Date().toISOString().slice(0, 10);
  document.querySelectorAll(".nav-item").forEach((button) => button.addEventListener("click", () => setView(button.dataset.view)));
  document.querySelectorAll("[data-source-mode]").forEach((button) => button.addEventListener("click", () => setSourceMode(button.dataset.sourceMode)));
  qs("#generateBriefButton").addEventListener("click", async () => {
    const brief = await api(`/api/workspaces/${state.workspace.id}/briefs/daily`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        brief_date: qs("#briefDateInput").value,
        window_days: qs("#briefWindowInput").value
      })
    });
    toast(`Daily brief generated: ${brief.title}`);
    await loadBriefs(brief.id);
  });
  qs("#sourceStatusFilter").addEventListener("change", () => loadSources().catch((error) => toast(error.message)));
  qs("#sourceTypeFilter").addEventListener("change", () => loadSources().catch((error) => toast(error.message)));
  qs("#commitmentStatusFilter").addEventListener("change", () => loadCommitments().catch((error) => toast(error.message)));
  qs("#meetingDate").value = new Date().toISOString().slice(0, 10);
  qs("#workspaceForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const workspace = await api("/api/workspaces", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({name: qs("#workspaceInput").value.trim()})});
    setWorkspace(workspace);
    await loadViewData();
  });
  qs("#decisionForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const decision = await api(`/api/workspaces/${state.workspace.id}/decisions`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: qs("#decisionTitle").value.trim(),
        context: qs("#decisionContext").value.trim(),
        decision_date: qs("#decisionDate").value,
        owner: qs("#decisionOwner").value.trim(),
        status: qs("#decisionStatus").value
      })
    });
    qs("#decisionTitle").value = "";
    qs("#decisionContext").value = "";
    qs("#decisionDate").value = "";
    qs("#decisionOwner").value = "";
    toast(`Decision created: ${decision.title}`);
    await loadDecisions();
    await refreshWorkspace();
  });
  qs("#commitmentForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const dueUnknown = qs("#commitmentDueUnknown").checked;
    const dueDate = qs("#commitmentDueDate").value;
    const commitment = await api(`/api/workspaces/${state.workspace.id}/commitments`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: qs("#commitmentTitle").value.trim(),
        description: qs("#commitmentDescription").value.trim(),
        owner: qs("#commitmentOwner").value.trim(),
        due_date: dueUnknown ? null : dueDate,
        due_date_known: !dueUnknown,
        status: qs("#commitmentStatus").value
      })
    });
    qs("#commitmentTitle").value = "";
    qs("#commitmentDescription").value = "";
    qs("#commitmentOwner").value = "";
    qs("#commitmentDueDate").value = "";
    qs("#commitmentDueUnknown").checked = false;
    toast(`Commitment created: ${commitment.title}`);
    await loadCommitments();
    await refreshWorkspace();
  });
  qs("#extractCommitmentsButton").addEventListener("click", async () => {
    const suggestions = await api(`/api/workspaces/${state.workspace.id}/commitments/extract`, {method: "POST"});
    toast(suggestions.length ? `${suggestions.length} commitment suggestion${suggestions.length === 1 ? "" : "s"} found.` : "No clear commitments found in ready sources.");
    await loadCommitments();
  });
  qs("#extractDecisionsButton").addEventListener("click", async () => {
    const suggestions = await api(`/api/workspaces/${state.workspace.id}/decisions/extract`, {method: "POST"});
    toast(suggestions.length ? `${suggestions.length} decision suggestion${suggestions.length === 1 ? "" : "s"} found.` : "No clear decisions found in ready sources.");
    await loadDecisions();
  });
  qs("#meetingForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const meeting = await api(`/api/workspaces/${state.workspace.id}/meetings`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: qs("#meetingTitle").value.trim(),
        meeting_date: qs("#meetingDate").value,
        description: qs("#meetingDescription").value.trim(),
        attendees: qs("#meetingAttendees").value.split(",").map((attendee) => attendee.trim()).filter(Boolean)
      })
    });
    qs("#meetingTitle").value = "";
    qs("#meetingDescription").value = "";
    qs("#meetingAttendees").value = "";
    toast(`Meeting created: ${meeting.title}`);
    await loadMeetings(meeting.id);
    await refreshWorkspace();
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
