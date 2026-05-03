const state = {workspace: null, activeView: "dashboard", sourceMode: "manual_entry", selectedSourceId: null, askThreadId: null, focus: null};
const views = {dashboard: "dashboardView", brief: "briefView", decisions: "decisionsView", commitments: "commitmentsView", risks: "risksView", review: "reviewView", meetings: "meetingsView", ask: "askView", sources: "sourcesView"};

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

function setView(view, focus = null) {
  state.activeView = view;
  state.focus = focus;
  Object.entries(views).forEach(([key, id]) => qs(`#${id}`).classList.toggle("active-view", key === view));
  document.querySelectorAll(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.view === view));
  loadViewData().catch((error) => toast(error.message));
}

function consumeFocus(view) {
  if (state.focus?.view !== view) return null;
  const focus = state.focus;
  state.focus = null;
  return focus;
}

function focusRecordElement(element) {
  if (!element) return;
  element.classList.add("record-focus");
  element.scrollIntoView({block: "center", behavior: "smooth"});
  window.setTimeout(() => element.classList.remove("record-focus"), 2600);
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

  if (state.activeView === "dashboard") {
    await loadDashboard();
  }

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
    await loadRisks();
  }

  if (state.activeView === "review") {
    await loadReviewInbox();
  }

  if (state.activeView === "meetings") {
    await loadMeetings();
  }

  if (state.activeView === "sources") await loadSources();
}

async function loadDashboard() {
  const dashboard = await api(`/api/workspaces/${state.workspace.id}/dashboard`);
  qs("#dashboardSummary").innerHTML = renderDashboardSummary(dashboard);
  qs("#dashboardBrief").innerHTML = dashboard.latest_brief ? renderDashboardBrief(dashboard.latest_brief) : empty("No Daily Brief yet. Generate one after accepting project records.");
  qs("#dashboardOverdue").innerHTML = dashboard.overdue_commitments.length ? dashboard.overdue_commitments.map(renderDashboardCommitment).join("") : empty("No overdue accepted commitments.");
  qs("#dashboardRisks").innerHTML = dashboard.open_risks.length ? dashboard.open_risks.map(renderDashboardRisk).join("") : empty("No accepted open risks.");
  qs("#dashboardDecisions").innerHTML = dashboard.recent_decisions.length ? dashboard.recent_decisions.map(renderDashboardDecision).join("") : empty("No accepted decisions yet.");
  bindDashboardActions();
}

function renderDashboardSummary(dashboard) {
  return `<article class="brief-card"><p class="label">Current status summary</p><h3>${escapeHtml(state.workspace.name)}</h3><p>${escapeHtml(dashboard.summary)}</p><div class="source-meta"><button class="secondary-button" type="button" data-dashboard-view="brief">Daily Brief</button><button class="secondary-button" type="button" data-dashboard-view="decisions">${dashboard.counts.recent_decisions} recent decisions</button><button class="secondary-button" type="button" data-dashboard-view="commitments">${dashboard.counts.overdue_commitments} overdue</button><button class="secondary-button" type="button" data-dashboard-view="risks">${dashboard.counts.open_risks} open risks</button></div></article>`;
}

function renderDashboardBrief(brief) {
  return `<article class="brief-item"><div class="source-meta"><span class="status ready">daily</span><span class="stat-pill">${escapeHtml(formatDate(brief.brief_date))}</span></div><h5>${escapeHtml(brief.title)}</h5><p>${escapeHtml(brief.summary)}</p><button class="secondary-button" type="button" data-dashboard-brief-id="${escapeHtml(brief.id)}">Open brief</button></article>`;
}

function renderDashboardCommitment(commitment) {
  return `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span><span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date) || "unknown")}</span><span class="stat-pill">${escapeHtml(commitment.evidence_count ? `${commitment.evidence_count} evidence` : "No evidence")}</span></div><h5>${escapeHtml(commitment.title)}</h5><p><strong>Owner:</strong> ${escapeHtml(commitment.owner)}</p>${renderRecordEvidence(commitment)}<button class="secondary-button" type="button" data-dashboard-record-view="commitments" data-dashboard-record-id="${escapeHtml(commitment.id)}">Open commitment</button></article>`;
}

function renderDashboardRisk(risk) {
  return `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(risk.status)}">${escapeHtml(risk.status)}</span><span class="stat-pill">${escapeHtml(risk.severity)}</span><span class="stat-pill">${escapeHtml(risk.evidence_count ? `${risk.evidence_count} evidence` : "No evidence")}</span></div><h5>${escapeHtml(risk.title)}</h5><p>${escapeHtml(risk.description)}</p><p><strong>Owner:</strong> ${escapeHtml(risk.owner)}</p>${renderRecordEvidence(risk)}<button class="secondary-button" type="button" data-dashboard-record-view="risks" data-dashboard-record-id="${escapeHtml(risk.id)}">Open risk</button></article>`;
}

function renderDashboardDecision(decision) {
  return `<article class="brief-item"><div class="source-meta"><span class="status ${escapeHtml(decision.status)}">${escapeHtml(decision.status)}</span><span class="stat-pill">${escapeHtml(formatDate(decision.decision_date))}</span><span class="stat-pill">${escapeHtml(decision.evidence_count ? `${decision.evidence_count} evidence` : "No evidence")}</span></div><h5>${escapeHtml(decision.title)}</h5><p>${escapeHtml(decision.context)}</p><p><strong>Owner:</strong> ${escapeHtml(decision.owner)}</p>${renderRecordEvidence(decision)}<button class="secondary-button" type="button" data-dashboard-record-view="decisions" data-dashboard-record-id="${escapeHtml(decision.id)}">Open decision</button></article>`;
}

function bindDashboardActions() {
  document.querySelectorAll("[data-dashboard-view]").forEach((button) => button.addEventListener("click", () => setView(button.dataset.dashboardView)));
  document.querySelectorAll("[data-dashboard-brief-id]").forEach((button) => button.addEventListener("click", () => setView("brief", {view: "brief", id: button.dataset.dashboardBriefId})));
  document.querySelectorAll("[data-dashboard-record-view]").forEach((button) => button.addEventListener("click", () => setView(button.dataset.dashboardRecordView, {view: button.dataset.dashboardRecordView, id: button.dataset.dashboardRecordId})));
  document.querySelectorAll("#dashboardView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
}

function demoSteps() {
  return [
    {key: "source", label: "Ready source", state: "pending"},
    {key: "answer", label: "Cited Ask answer", state: "pending"},
    {key: "decision", label: "Accepted decision", state: "pending"},
    {key: "commitment", label: "Accepted commitment", state: "pending"},
    {key: "brief", label: "Saved Daily Brief", state: "pending"},
    {key: "dashboard", label: "Dashboard refreshed", state: "pending"}
  ];
}

function updateDemoFlowPanel(steps, message, artifacts = {}) {
  const actions = [
    artifacts.source && `<button class="secondary-button" type="button" data-demo-source-id="${escapeHtml(artifacts.source.id)}">Open source</button>`,
    artifacts.answer && `<button class="secondary-button" type="button" data-demo-view="ask">Open Ask answer</button>`,
    artifacts.decision && `<button class="secondary-button" type="button" data-demo-record-view="decisions" data-demo-record-id="${escapeHtml(artifacts.decision.id)}">Open decision</button>`,
    artifacts.commitment && `<button class="secondary-button" type="button" data-demo-record-view="commitments" data-demo-record-id="${escapeHtml(artifacts.commitment.id)}">Open commitment</button>`,
    artifacts.brief && `<button class="secondary-button" type="button" data-demo-brief-id="${escapeHtml(artifacts.brief.id)}">Open brief</button>`,
    artifacts.dashboard && `<button class="secondary-button" type="button" data-demo-view="dashboard">Open dashboard</button>`
  ].filter(Boolean).join("");

  qs("#demoFlowPanel").innerHTML = `<p class="label">End-to-end demo</p><p>${escapeHtml(message)}</p><div class="demo-steps">${steps.map((step) => `<div class="demo-step"><span class="status ${escapeHtml(step.state)}">${escapeHtml(step.state)}</span><span>${escapeHtml(step.label)}</span>${step.detail ? `<small>${escapeHtml(step.detail)}</small>` : ""}</div>`).join("")}</div>${actions ? `<div class="source-actions">${actions}</div>` : ""}`;
  bindDemoActions();
}

function bindDemoActions() {
  document.querySelectorAll("[data-demo-source-id]").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.demoSourceId);
  }));
  document.querySelectorAll("[data-demo-view]").forEach((button) => button.addEventListener("click", () => setView(button.dataset.demoView)));
  document.querySelectorAll("[data-demo-brief-id]").forEach((button) => button.addEventListener("click", () => setView("brief", {view: "brief", id: button.dataset.demoBriefId})));
  document.querySelectorAll("[data-demo-record-view]").forEach((button) => button.addEventListener("click", () => setView(button.dataset.demoRecordView, {view: button.dataset.demoRecordView, id: button.dataset.demoRecordId})));
}

async function runDemoFlow() {
  const panel = qs("#demoFlowPanel");
  const steps = demoSteps();
  const artifacts = {};
  let currentStep = steps[0];

  const mark = (key, state, detail = "") => {
    const step = steps.find((candidate) => candidate.key === key);
    if (!step) return;
    step.state = state;
    step.detail = detail;
    currentStep = step;
    updateDemoFlowPanel(steps, state === "failed" ? `Demo stopped at ${step.label}.` : "Running Source -> answer -> decision -> commitment -> brief.", artifacts);
  };

  panel.classList.remove("hidden");
  updateDemoFlowPanel(steps, "Running Source -> answer -> decision -> commitment -> brief.");

  try {
    const today = new Date().toISOString().slice(0, 10);
    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    const text = "Launch update: the team decided to keep private beta scoped until support readiness is clear. Mira will finish the launch checklist before beta expansion. Blocker: support coverage is blocking beta expansion; owner is Rina.";

    mark("source", "running");
    const source = await api(`/api/workspaces/${state.workspace.id}/sources/text`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: `P0 Demo Source ${Date.now()}`,
        source_type: "meeting_note",
        origin: "manual_entry",
        source_date: today,
        text_content: text
      })
    });
    if (source.processing_status !== "ready" || !source.text_content) throw new Error("Demo source was not ready with readable text.");
    artifacts.source = source;
    mark("source", "done", source.title);

    mark("answer", "running");
    const answer = await api(`/api/workspaces/${state.workspace.id}/ask`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({question: "What is the launch plan and what follow-up matters?"})
    });
    if (!answer.citations?.length) throw new Error("Demo answer did not include citations.");
    artifacts.answer = answer;
    renderAnswer(answer);
    const citation = answer.citations[0];
    mark("answer", "done", `${answer.citations.length} citation${answer.citations.length === 1 ? "" : "s"}`);

    mark("decision", "running");
    const decision = await api(`/api/workspaces/${state.workspace.id}/decisions`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: "Keep private beta scoped",
        context: "Private beta remains scoped until support readiness is clear.",
        decision_date: today,
        owner: "Mira",
        status: "active",
        evidence_source_id: citation.source_id || source.id,
        evidence_text: citation.quote || citation.evidence_text,
        location_hint: citation.location_hint || citation.source_location
      })
    });
    if (decision.record_state !== "accepted") throw new Error("Demo decision was not accepted.");
    artifacts.decision = decision;
    mark("decision", "done", decision.title);

    mark("commitment", "running");
    const commitment = await api(`/api/workspaces/${state.workspace.id}/commitments`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: "Finish launch checklist",
        description: "Complete the checklist before beta expansion.",
        owner: "Mira",
        due_date: yesterday,
        due_date_known: true,
        status: "open",
        evidence_source_id: citation.source_id || source.id,
        evidence_text: citation.quote || citation.evidence_text,
        location_hint: citation.location_hint || citation.source_location
      })
    });
    if (commitment.record_state !== "accepted") throw new Error("Demo commitment was not accepted.");
    artifacts.commitment = commitment;
    mark("commitment", "done", commitment.title);

    mark("brief", "running");
    const brief = await api(`/api/workspaces/${state.workspace.id}/briefs/daily`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({brief_date: today, window_days: 7})
    });
    if (brief.brief_type !== "daily" || !brief.summary) throw new Error("Demo Daily Brief was not saved correctly.");
    artifacts.brief = brief;
    mark("brief", "done", brief.title);

    mark("dashboard", "running");
    await refreshWorkspace();
    await loadDashboard();
    artifacts.dashboard = true;
    mark("dashboard", "done", "Dashboard reflects saved records");
    updateDemoFlowPanel(steps, "End-to-end demo complete. Created ready source, cited answer, accepted decision, accepted commitment, saved Daily Brief, and refreshed the dashboard.", artifacts);
  } catch (error) {
    currentStep.state = "failed";
    currentStep.detail = error.message;
    updateDemoFlowPanel(steps, `Demo incomplete. Missing or invalid product record: ${currentStep.label}.`, artifacts);
    toast(error.message);
  }
}

async function loadBriefs(selectedBriefId = null) {
  const workspaceId = state.workspace.id;
  const focus = consumeFocus("brief");
  selectedBriefId = selectedBriefId || focus?.id || null;
  const briefs = await api(`/api/workspaces/${workspaceId}/briefs`);
  const selectedBrief = selectedBriefId
    ? await api(`/api/workspaces/${workspaceId}/briefs/${selectedBriefId}`)
    : briefs[0];
  qs("#briefPanel").innerHTML = selectedBrief ? renderBrief(selectedBrief) : empty("No daily brief has been generated yet.");
  qs("#briefList").innerHTML = briefs.length ? briefs.map(renderBriefListItem).join("") : empty("No briefs have been created yet.");
  bindBriefActions();
  if (focus && selectedBrief) focusRecordElement(qs("#briefPanel .brief-card"));
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
  const focus = consumeFocus("decisions");
  const [decisions, suggestions] = await Promise.all([
    api(`/api/workspaces/${workspaceId}/decisions`),
    api(`/api/workspaces/${workspaceId}/decision_suggestions`)
  ]);
  qs("#decisionList").innerHTML = decisions.length ? decisions.map(renderDecisionCard).join("") : empty("No accepted decisions yet. Create one manually or accept a suggested decision.");
  qs("#decisionInbox").innerHTML = suggestions.length ? suggestions.map(renderDecisionSuggestion).join("") : empty("No suggested decisions are waiting for approval.");
  bindDecisionActions();
  if (focus) focusRecordElement(qs(`#decisionList [data-record-id="${focus.id}"]`));
}

function renderDecisionCard(decision) {
  return `<article class="row-card" data-record-id="${escapeHtml(decision.id)}"><div><div class="source-meta"><span class="status ${escapeHtml(decision.status)}">${escapeHtml(decision.status)}</span><span class="stat-pill">${escapeHtml(labelize(decision.source_origin || "manual"))}</span><span class="stat-pill">${escapeHtml(formatDate(decision.decision_date))}</span><span class="stat-pill">${escapeHtml(decision.evidence_count ? `${decision.evidence_count} evidence` : "No evidence")}</span></div><h3>${escapeHtml(decision.title)}</h3><p>${escapeHtml(decision.context)}</p><p><strong>Owner:</strong> ${escapeHtml(decision.owner)}</p>${renderDecisionEvidence(decision)}</div></article>`;
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
  const focus = consumeFocus("commitments");
  if (focus) qs("#commitmentStatusFilter").value = "";
  const query = queryString({status: qs("#commitmentStatusFilter")?.value});
  const [commitments, suggestions] = await Promise.all([
    api(`/api/workspaces/${workspaceId}/commitments${query}`),
    api(`/api/workspaces/${workspaceId}/commitment_suggestions`)
  ]);
  qs("#commitmentList").innerHTML = commitments.length ? commitments.map(renderCommitmentCard).join("") : empty("No accepted commitments yet. Create one manually or accept a suggested commitment.");
  qs("#commitmentInbox").innerHTML = suggestions.length ? suggestions.map(renderCommitmentSuggestion).join("") : empty("No suggested commitments are waiting for approval.");
  bindCommitmentActions();
  if (focus) focusRecordElement(qs(`#commitmentList [data-record-id="${focus.id}"]`));
}

function renderCommitmentCard(commitment) {
  return `<article class="row-card" data-record-id="${escapeHtml(commitment.id)}"><div><div class="source-meta"><span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span><span class="stat-pill">${escapeHtml(labelize(commitment.source_origin || "manual"))}</span><span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date) || "unknown")}</span><span class="stat-pill">${escapeHtml(commitment.evidence_count ? `${commitment.evidence_count} evidence` : "No evidence")}</span></div><h3>${escapeHtml(commitment.title)}</h3><p>${escapeHtml(commitment.description || "")}</p><p><strong>Owner:</strong> ${escapeHtml(commitment.owner)}</p>${renderRecordEvidence(commitment)}</div><div class="source-actions"><select data-commitment-status="${escapeHtml(commitment.id)}" aria-label="Update commitment status"><option value="open" ${commitment.status === "open" ? "selected" : ""}>Open</option><option value="done" ${commitment.status === "done" ? "selected" : ""}>Done</option><option value="overdue" ${commitment.status === "overdue" ? "selected" : ""}>Overdue</option><option value="blocked" ${commitment.status === "blocked" ? "selected" : ""}>Blocked</option></select></div></article>`;
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

async function loadRisks() {
  const workspaceId = state.workspace.id;
  const focus = consumeFocus("risks");
  if (focus) {
    qs("#riskSeverityFilter").value = "";
    qs("#riskStatusFilter").value = "";
  }
  const query = queryString({
    severity: qs("#riskSeverityFilter")?.value,
    status: qs("#riskStatusFilter")?.value
  });
  const risks = await api(`/api/workspaces/${workspaceId}/risks${query}`);
  qs("#riskList").innerHTML = risks.length ? risks.map(renderRiskCard).join("") : empty("No accepted risks have been captured yet. Create one manually or extract risk suggestions from ready sources.");
  bindRiskActions();
  if (focus) focusRecordElement(qs(`#riskList [data-record-id="${focus.id}"]`));
}

function renderRiskCard(risk) {
  return `<article class="row-card" data-record-id="${escapeHtml(risk.id)}"><div><div class="source-meta"><span class="status ${escapeHtml(risk.status)}">${escapeHtml(risk.status)}</span><span class="stat-pill">${escapeHtml(risk.severity)}</span><span class="stat-pill">${escapeHtml(labelize(risk.source_origin || "manual"))}</span><span class="stat-pill">${escapeHtml(risk.evidence_count ? `${risk.evidence_count} evidence` : "No evidence")}</span></div><h3>${escapeHtml(risk.title)}</h3><p>${escapeHtml(risk.description)}</p><p><strong>Owner:</strong> ${escapeHtml(risk.owner)}</p>${risk.mitigation ? `<p><strong>Mitigation:</strong> ${escapeHtml(risk.mitigation)}</p>` : ""}${renderRecordEvidence(risk)}</div><div class="source-actions"><select data-risk-status="${escapeHtml(risk.id)}" aria-label="Update risk status"><option value="open" ${risk.status === "open" ? "selected" : ""}>Open</option><option value="mitigated" ${risk.status === "mitigated" ? "selected" : ""}>Mitigated</option><option value="resolved" ${risk.status === "resolved" ? "selected" : ""}>Resolved</option></select></div></article>`;
}

function bindRiskActions() {
  document.querySelectorAll("#risksView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
  document.querySelectorAll("[data-risk-status]").forEach((select) => select.addEventListener("change", async () => {
    await api(`/api/workspaces/${state.workspace.id}/risks/${select.dataset.riskStatus}/status`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({status: select.value})
    });
    toast("Risk status updated.");
    await loadRisks();
  }));
}

async function loadReviewInbox() {
  const type = qs("#reviewTypeFilter")?.value;
  const query = queryString({type});
  const items = await api(`/api/workspaces/${state.workspace.id}/review_inbox${query}`);
  qs("#reviewInboxList").innerHTML = items.length ? items.map(renderReviewItem).join("") : empty("No suggestions are waiting for review.");
  bindReviewActions();
}

function renderReviewItem(item) {
  const record = item.record;
  return `<article class="row-card"><div><div class="source-meta"><span class="status suggested">suggested ${escapeHtml(item.type)}</span>${item.incomplete ? `<span class="status failed">Needs edit</span>` : ""}<span class="stat-pill">${escapeHtml(item.evidence_count ? `${item.evidence_count} evidence` : "No evidence")}</span>${record.severity ? `<span class="stat-pill">${escapeHtml(record.severity)}</span>` : ""}${record.status ? `<span class="status ${escapeHtml(record.status)}">${escapeHtml(record.status)}</span>` : ""}</div><h3>${escapeHtml(record.title)}</h3><p>${escapeHtml(record.context || record.description || "")}</p><p><strong>Owner:</strong> ${escapeHtml(record.owner || "Unknown")}</p>${renderRecordEvidence(record)}</div><div class="source-actions"><button class="secondary-button" type="button" data-edit-suggestion="${escapeHtml(item.type)}:${escapeHtml(item.id)}">Edit</button><button class="secondary-button" type="button" data-accept-suggestion="${escapeHtml(item.type)}:${escapeHtml(item.id)}">Accept</button><button class="danger-button" type="button" data-reject-suggestion="${escapeHtml(item.type)}:${escapeHtml(item.id)}">Reject</button></div></article>`;
}

function bindReviewActions() {
  document.querySelectorAll("#reviewView .citation").forEach((button) => button.addEventListener("click", () => {
    setView("sources");
    loadSourcePreview(button.dataset.sourceId);
  }));
  document.querySelectorAll("[data-accept-suggestion]").forEach((button) => button.addEventListener("click", async () => {
    const [type, id] = button.dataset.acceptSuggestion.split(":");
    await api(`/api/workspaces/${state.workspace.id}/review_inbox/${type}/${id}/accept`, {method: "POST"});
    toast(`${labelize(type)} accepted.`);
    await loadReviewInbox();
    await refreshWorkspace();
  }));
  document.querySelectorAll("[data-reject-suggestion]").forEach((button) => button.addEventListener("click", async () => {
    const [type, id] = button.dataset.rejectSuggestion.split(":");
    await api(`/api/workspaces/${state.workspace.id}/review_inbox/${type}/${id}/reject`, {method: "POST"});
    toast(`${labelize(type)} rejected.`);
    await loadReviewInbox();
  }));
  document.querySelectorAll("[data-edit-suggestion]").forEach((button) => button.addEventListener("click", async () => {
    const [type, id] = button.dataset.editSuggestion.split(":");
    const attrs = promptSuggestionEdits(type);
    if (!attrs) return;
    await api(`/api/workspaces/${state.workspace.id}/review_inbox/${type}/${id}`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify(attrs)
    });
    toast(`${labelize(type)} suggestion updated.`);
    await loadReviewInbox();
  }));
}

function promptSuggestionEdits(type) {
  const title = window.prompt(`${labelize(type)} title`);
  if (title === null) return null;
  const owner = window.prompt("Owner");
  if (owner === null) return null;

  if (type === "risk") {
    const severity = window.prompt("Severity: low, medium, high, or critical", "high");
    if (severity === null) return null;
    return {title: title.trim(), owner: owner.trim(), severity: severity.trim()};
  }

  return {title: title.trim(), owner: owner.trim()};
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
    source_type: qs("#sourceTypeFilter")?.value,
    classified_source_type: qs("#sourceClassificationFilter")?.value,
    quality_label: qs("#sourceQualityFilter")?.value
  });
  const sources = await api(`/api/workspaces/${state.workspace.id}/sources${query}`);
  qs("#sourceList").innerHTML = sources.length ? sources.map(renderSourceCard).join("") : empty("Source Library is where project evidence starts. Add pasted text or upload a readable .txt/.md file.");
  await loadSourceTimeline();
  bindSourceActions();
}

async function loadSourceTimeline() {
  const query = queryString({
    classified_source_type: qs("#sourceClassificationFilter")?.value,
    quality_label: qs("#sourceQualityFilter")?.value
  });
  const items = await api(`/api/workspaces/${state.workspace.id}/sources/timeline${query}`);
  qs("#sourceTimeline").innerHTML = items.length ? items.map(renderSourceTimelineItem).join("") : empty("Source timeline appears after sources are added. Sources without a source date use their added date.");
}

function renderSourceCard(source) {
  return `<article class="row-card"><button type="button" data-source-id="${escapeHtml(source.id)}"><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span>${renderSourceSignals(source)}<span class="stat-pill">${escapeHtml(labelize(source.origin))}</span>${source.source_date ? `<span class="stat-pill">${escapeHtml(formatDate(source.source_date))}</span>` : ""}</div><h3>${escapeHtml(source.title)}</h3><p>${escapeHtml(source.original_filename || "Manual source")} - Updated ${escapeHtml(formatDate(source.updated_at))}</p></button><button class="danger-button" type="button" data-delete-source="${escapeHtml(source.id)}">Delete</button></article>`;
}

function renderSourceTimelineItem(item) {
  const source = item.source;
  return `<article class="timeline-item"><button type="button" data-source-id="${escapeHtml(source.id)}"><div class="source-meta"><span class="stat-pill">${escapeHtml(formatDate(item.timeline_date))}</span><span class="stat-pill">${escapeHtml(labelize(item.timeline_date_basis))}</span><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span>${renderSourceSignals(source)}</div><h3>${escapeHtml(source.title)}</h3><p>${item.timeline_date_basis === "created_at" ? "Placed by added date because no source date is set." : "Placed by source date."}</p></button></article>`;
}

function renderSourceSignals(source) {
  const classification = source.classified_source_type || "unclassified";
  const confidence = source.classification_confidence || "low";
  const quality = source.quality_label || "unknown";
  const duplicate = source.duplicate_count ? `<span class="status failed">${source.duplicate_count} duplicate flag${source.duplicate_count === 1 ? "" : "s"}</span>` : "";
  return `<span class="stat-pill">${escapeHtml(labelize(classification))} - ${escapeHtml(confidence)}</span><span class="status ${escapeHtml(quality)}">${escapeHtml(quality)} quality</span>${duplicate}`;
}

function bindSourceActions() {
  document.querySelectorAll("#sourcesView [data-source-id]").forEach((button) => button.addEventListener("click", () => loadSourcePreview(button.dataset.sourceId)));
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
  qs("#sourcePreview").innerHTML = `<h3>${escapeHtml(source.title)}</h3><div class="source-meta"><span class="status ${escapeHtml(source.processing_status)}">${escapeHtml(source.processing_status)}</span><span class="stat-pill">${escapeHtml(labelize(source.source_type))}</span>${renderSourceSignals(source)}</div><div class="source-detail-grid"><div class="source-detail"><p class="label">Origin</p><p>${escapeHtml(labelize(source.origin))}</p></div><div class="source-detail"><p class="label">Source date</p><p>${escapeHtml(formatDate(source.source_date) || "Unknown")}</p></div><div class="source-detail"><p class="label">Timeline basis</p><p>${source.source_date ? "Source date" : "Added date fallback"}</p></div><div class="source-detail"><p class="label">Updated</p><p>${escapeHtml(formatDate(source.updated_at))}</p></div></div>${renderSourceQuality(source)}${renderDuplicateFlags(source)}<form id="classificationForm" class="metadata-form"><label><span>P1 classification</span><select id="classificationType">${["meeting","document","update","transcript","plan"].map((type) => `<option value="${type}" ${source.classified_source_type === type ? "selected" : ""}>${escapeHtml(labelize(type))}</option>`).join("")}</select></label><button type="submit">Save classification</button></form><form id="metadataForm" class="metadata-form"><div class="form-grid"><label><span>Title</span><input id="metadataTitle" type="text" value="${escapeHtml(source.title)}" required /></label><label><span>Type</span><select id="metadataType" required>${["note","document","transcript","meeting_note","project_update","other"].map((type) => `<option value="${type}" ${source.source_type === type ? "selected" : ""}>${escapeHtml(labelize(type))}</option>`).join("")}</select></label><label><span>Source date</span><input id="metadataDate" type="date" value="${escapeHtml(source.source_date || "")}" /></label></div><button type="submit">Save metadata</button></form><div class="source-actions"><button id="detectDuplicatesButton" class="secondary-button" type="button">Check duplicates</button><button id="reassessQualityButton" class="secondary-button" type="button">Reassess quality</button>${source.origin === "manual_entry" ? `<button id="editTextButton" class="secondary-button" type="button">Edit text</button>` : ""}</div><h4>Readable text Pulse has stored</h4><div id="sourceTextPanel">${textPanel}</div>`;
  qs("#classificationForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    await api(`/api/workspaces/${state.workspace.id}/sources/${source.id}/classification`, {
      method: "PATCH",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({classified_source_type: qs("#classificationType").value})
    });
    toast("Classification saved.");
    await loadSources();
    await loadSourcePreview(source.id);
  });
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
  qs("#detectDuplicatesButton").addEventListener("click", async () => {
    const flags = await api(`/api/workspaces/${state.workspace.id}/sources/${source.id}/detect_duplicates`, {method: "POST"});
    toast(flags.length ? `${flags.length} duplicate flag${flags.length === 1 ? "" : "s"} found.` : "No duplicate flags found.");
    await loadSources();
    await loadSourcePreview(source.id);
  });
  qs("#reassessQualityButton").addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/sources/${source.id}/reassess_quality`, {method: "POST"});
    toast("Quality reassessed.");
    await loadSources();
    await loadSourcePreview(source.id);
  });
  document.querySelectorAll("[data-confirm-duplicate]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/source_duplicate_flags/${button.dataset.confirmDuplicate}/confirm`, {method: "POST"});
    toast("Duplicate confirmed.");
    await loadSources();
    await loadSourcePreview(source.id);
  }));
  document.querySelectorAll("[data-dismiss-duplicate]").forEach((button) => button.addEventListener("click", async () => {
    await api(`/api/workspaces/${state.workspace.id}/source_duplicate_flags/${button.dataset.dismissDuplicate}/dismiss`, {method: "POST"});
    toast("Duplicate dismissed.");
    await loadSources();
    await loadSourcePreview(source.id);
  }));
  document.querySelectorAll("[data-matched-source-id]").forEach((button) => button.addEventListener("click", () => loadSourcePreview(button.dataset.matchedSourceId)));
  qs("#editTextButton")?.addEventListener("click", () => renderTextEditor(source));
}

function renderSourceQuality(source) {
  const reasons = source.quality_reasons || [];
  const explanation = reasons.length ? reasons.map(labelize).join(", ") : "No weak quality reasons recorded.";
  return `<section class="source-signal-panel"><p class="label">Quality signal</p><div class="source-meta"><span class="status ${escapeHtml(source.quality_label || "unknown")}">${escapeHtml(source.quality_label || "unknown")}</span><span class="stat-pill">${escapeHtml(explanation)}</span></div></section>`;
}

function renderDuplicateFlags(source) {
  const flags = source.duplicate_flags || [];
  if (!flags.length) return `<section class="source-signal-panel"><p class="label">Duplicate flags</p><p class="empty">No unresolved duplicate warnings.</p></section>`;

  return `<section class="source-signal-panel"><p class="label">Duplicate flags</p><div class="brief-items">${flags.map((flag) => `<article class="brief-item"><div class="source-meta"><span class="status failed">${escapeHtml(labelize(flag.duplicate_type))}</span><span class="stat-pill">${escapeHtml(flag.confidence)} confidence</span></div><h5>${escapeHtml(flag.matched_source_title || "Matched source")}</h5><p>${escapeHtml(flag.reason)}</p><div class="source-actions"><button class="secondary-button" type="button" data-matched-source-id="${escapeHtml(flag.matched_source_id)}">Open matched source</button><button class="secondary-button" type="button" data-confirm-duplicate="${escapeHtml(flag.id)}">Confirm duplicate</button><button class="danger-button" type="button" data-dismiss-duplicate="${escapeHtml(flag.id)}">Dismiss</button></div></article>`).join("")}</div></section>`;
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
  qs("#runDemoFlowButton").addEventListener("click", () => runDemoFlow().catch((error) => toast(error.message)));
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
  qs("#sourceClassificationFilter").addEventListener("change", () => loadSources().catch((error) => toast(error.message)));
  qs("#sourceQualityFilter").addEventListener("change", () => loadSources().catch((error) => toast(error.message)));
  qs("#commitmentStatusFilter").addEventListener("change", () => loadCommitments().catch((error) => toast(error.message)));
  qs("#riskSeverityFilter").addEventListener("change", () => loadRisks().catch((error) => toast(error.message)));
  qs("#riskStatusFilter").addEventListener("change", () => loadRisks().catch((error) => toast(error.message)));
  qs("#reviewTypeFilter").addEventListener("change", () => loadReviewInbox().catch((error) => toast(error.message)));
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
  qs("#riskForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const risk = await api(`/api/workspaces/${state.workspace.id}/risks`, {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        title: qs("#riskTitle").value.trim(),
        description: qs("#riskDescription").value.trim(),
        owner: qs("#riskOwner").value.trim(),
        severity: qs("#riskSeverity").value,
        status: qs("#riskStatus").value,
        mitigation: qs("#riskMitigation").value.trim()
      })
    });
    qs("#riskTitle").value = "";
    qs("#riskDescription").value = "";
    qs("#riskOwner").value = "";
    qs("#riskMitigation").value = "";
    toast(`Risk created: ${risk.title}`);
    await loadRisks();
    await refreshWorkspace();
  });
  qs("#extractRisksButton").addEventListener("click", async () => {
    const suggestions = await api(`/api/workspaces/${state.workspace.id}/risks/extract`, {method: "POST"});
    toast(suggestions.length ? `${suggestions.length} risk suggestion${suggestions.length === 1 ? "" : "s"} found.` : "No clear risks found in ready sources.");
    await loadReviewInbox().catch(() => {});
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
