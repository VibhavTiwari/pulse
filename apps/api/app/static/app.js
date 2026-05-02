const state = {
  workspace: null,
  activeView: "brief",
};

const views = {
  brief: "briefView",
  decisions: "decisionsView",
  commitments: "commitmentsView",
  meetings: "meetingsView",
  ask: "askView",
  sources: "sourcesView",
};

function qs(selector) {
  return document.querySelector(selector);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function api(path, options = {}) {
  const response = await fetch(path, options);
  if (!response.ok) {
    let message = `${response.status} ${response.statusText}`;
    try {
      const body = await response.json();
      message = body.detail || message;
    } catch {
      // Keep the HTTP status text.
    }
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

function setWorkspace(workspace) {
  state.workspace = workspace;
  qs("#workspaceName").textContent = workspace ? workspace.name : "No workspace";
  qs("#workspaceSetup").classList.toggle("hidden", Boolean(workspace));
  renderHealth(workspace);
}

function renderHealth(workspace) {
  const node = qs("#workspaceHealth");
  if (!workspace) {
    node.innerHTML = "";
    return;
  }
  const health = workspace.health || {};
  node.innerHTML = `
    <span class="status ${escapeHtml(health.status)}">${escapeHtml(health.status || "unknown")}</span>
    <span class="stat-pill">${health.source_count ?? 0} sources</span>
    <span class="stat-pill">${health.chunk_count ?? 0} chunks</span>
    <span class="stat-pill">${health.answer_count ?? 0} answers</span>
  `;
}

function formatDate(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function setView(view) {
  state.activeView = view;
  Object.entries(views).forEach(([key, id]) => {
    qs(`#${id}`).classList.toggle("active-view", key === view);
  });
  document.querySelectorAll(".nav-item").forEach((item) => {
    item.classList.toggle("active", item.dataset.view === view);
  });
  loadViewData();
}

async function loadWorkspaces() {
  const workspaces = await api("/api/workspaces");
  setWorkspace(workspaces[0] || null);
  if (state.workspace) {
    await loadViewData();
  }
}

async function refreshWorkspace() {
  if (!state.workspace) return;
  const workspace = await api(`/api/workspaces/${state.workspace.id}`);
  setWorkspace(workspace);
}

function empty(label) {
  return `<p class="empty">${escapeHtml(label)}</p>`;
}

async function loadViewData() {
  if (!state.workspace) return;
  const workspaceId = state.workspace.id;
  if (state.activeView === "brief") {
    const briefs = await api(`/api/workspaces/${workspaceId}/briefs`);
    qs("#briefList").innerHTML = briefs.length
      ? briefs.map((brief) => `
          <article class="card">
            <p class="label">${escapeHtml(formatDate(brief.brief_date))}</p>
            <h3>${escapeHtml(brief.title)}</h3>
            <p>${escapeHtml(brief.summary)}</p>
          </article>
        `).join("")
      : empty("No briefs have been created yet.");
  }
  if (state.activeView === "decisions") {
    const decisions = await api(`/api/workspaces/${workspaceId}/decisions`);
    qs("#decisionList").innerHTML = decisions.length
      ? decisions.map((decision) => `
          <article class="row-card">
            <div>
              <div class="source-meta">
                <span class="status ${escapeHtml(decision.status)}">${escapeHtml(decision.status)}</span>
                <span class="label">${escapeHtml(formatDate(decision.created_at))}</span>
              </div>
              <h3>${escapeHtml(decision.title)}</h3>
              <p>${escapeHtml(decision.summary)}</p>
              <p><strong>Rationale:</strong> ${escapeHtml(decision.rationale)}</p>
            </div>
          </article>
        `).join("")
      : empty("No decisions have been logged yet.");
  }
  if (state.activeView === "commitments") {
    const commitments = await api(`/api/workspaces/${workspaceId}/commitments`);
    qs("#commitmentList").innerHTML = commitments.length
      ? commitments.map((commitment) => `
          <article class="row-card">
            <div>
              <div class="source-meta">
                <span class="status ${escapeHtml(commitment.status)}">${escapeHtml(commitment.status)}</span>
                <span class="stat-pill">Due ${escapeHtml(formatDate(commitment.due_date))}</span>
              </div>
              <h3>${escapeHtml(commitment.owner)}</h3>
              <p>${escapeHtml(commitment.description)}</p>
            </div>
          </article>
        `).join("")
      : empty("No commitments have been captured yet.");
  }
  if (state.activeView === "meetings") {
    const meetings = await api(`/api/workspaces/${workspaceId}/meetings`);
    qs("#meetingList").innerHTML = meetings.length
      ? meetings.map((meeting) => {
          const attendees = JSON.parse(meeting.attendees_json || "[]").join(", ");
          return `
            <article class="card">
              <p class="label">${escapeHtml(formatDate(meeting.meeting_date))}</p>
              <h3>${escapeHtml(meeting.title)}</h3>
              <p>${escapeHtml(meeting.agenda)}</p>
              <p><strong>Attendees:</strong> ${escapeHtml(attendees)}</p>
            </article>
          `;
        }).join("")
      : empty("No meeting prep has been created yet.");
  }
  if (state.activeView === "ask") {
    await loadAnswerHistory();
  }
  if (state.activeView === "sources") {
    await loadSources();
  }
}

function renderAnswer(answer) {
  const citations = answer.citations || [];
  qs("#answerPanel").innerHTML = `
    <p>${escapeHtml(answer.answer)}</p>
    ${citations.length ? `
      <div class="citation-list">
        ${citations.map((citation) => `
          <button class="citation" type="button" data-source-id="${escapeHtml(citation.source_id)}">
            <strong>${escapeHtml(citation.source_title)} · ${escapeHtml(citation.source_location)}</strong>
            <span>${escapeHtml(citation.quote)}</span>
          </button>
        `).join("")}
      </div>
    ` : `<p class="empty">No citations were found, so this answer is not source-backed.</p>`}
  `;
  document.querySelectorAll(".citation").forEach((button) => {
    button.addEventListener("click", () => {
      setView("sources");
      loadSourcePreview(button.dataset.sourceId);
    });
  });
}

async function loadAnswerHistory() {
  const answers = await api(`/api/workspaces/${state.workspace.id}/answers`);
  qs("#answerHistory").innerHTML = answers.length
    ? answers.map((answer) => `
        <button class="history-item" type="button" data-answer-id="${escapeHtml(answer.id)}">
          <strong>${escapeHtml(answer.question)}</strong>
          <span class="label">${escapeHtml(formatDate(answer.created_at))}</span>
        </button>
      `).join("")
    : empty("No saved answers yet.");
  document.querySelectorAll(".history-item").forEach((button) => {
    button.addEventListener("click", async () => {
      const answer = await api(`/api/answers/${button.dataset.answerId}`);
      renderAnswer(answer);
    });
  });
}

async function loadSources() {
  const sources = await api(`/api/workspaces/${state.workspace.id}/sources`);
  qs("#sourceList").innerHTML = sources.length
    ? sources.map((source) => `
        <article class="row-card">
          <button type="button" data-source-id="${escapeHtml(source.id)}">
            <div class="source-meta">
              <span class="status ${escapeHtml(source.status)}">${escapeHtml(source.status)}</span>
              <span class="stat-pill">${source.chunk_count ?? 0} chunks</span>
            </div>
            <h3>${escapeHtml(source.title)}</h3>
            <p>${escapeHtml(source.original_filename)}</p>
            ${source.error_message ? `<p><strong>Error:</strong> ${escapeHtml(source.error_message)}</p>` : ""}
          </button>
          <button type="button" data-delete-source="${escapeHtml(source.id)}">Delete</button>
        </article>
      `).join("")
    : empty("Upload a .txt or .md source to start building evidence.");
  document.querySelectorAll("[data-source-id]").forEach((button) => {
    button.addEventListener("click", () => loadSourcePreview(button.dataset.sourceId));
  });
  document.querySelectorAll("[data-delete-source]").forEach((button) => {
    button.addEventListener("click", async () => {
      await api(`/api/sources/${button.dataset.deleteSource}`, { method: "DELETE" });
      toast("Source deleted from active search.");
      await loadSources();
      await refreshWorkspace();
    });
  });
}

async function loadSourcePreview(sourceId) {
  const source = await api(`/api/sources/${sourceId}`);
  qs("#sourcePreview").innerHTML = `
    <h3>${escapeHtml(source.title)}</h3>
    <div class="source-meta">
      <span class="status ${escapeHtml(source.status)}">${escapeHtml(source.status)}</span>
      <span class="stat-pill">${escapeHtml(source.source_type)}</span>
    </div>
    ${(source.chunks || []).map((chunk) => `
      <div class="source-chunk">
        <p class="label">Chunk ${chunk.chunk_index + 1}</p>
        <p>${escapeHtml(chunk.text)}</p>
      </div>
    `).join("")}
  `;
}

function bindEvents() {
  document.querySelectorAll(".nav-item").forEach((button) => {
    button.addEventListener("click", () => setView(button.dataset.view));
  });

  qs("#workspaceForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = qs("#workspaceInput").value.trim();
    const workspace = await api("/api/workspaces", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    setWorkspace(workspace);
    toast("Workspace created.");
    await loadViewData();
  });

  qs("#seedDemoBtn").addEventListener("click", async () => {
    const result = await api("/api/demo/reset", { method: "POST" });
    setWorkspace(result.workspace);
    toast("Demo data reset.");
    await loadViewData();
  });

  qs("#uploadForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const fileInput = qs("#sourceFile");
    if (!fileInput.files.length) return;
    const data = new FormData();
    data.append("file", fileInput.files[0]);
    const source = await api(`/api/workspaces/${state.workspace.id}/sources`, {
      method: "POST",
      body: data,
    });
    fileInput.value = "";
    toast(source.status === "indexed" ? "Source indexed." : `Source ${source.status}.`);
    await loadSources();
    await refreshWorkspace();
  });

  qs("#askForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const question = qs("#questionInput").value.trim();
    if (!question) return;
    const answer = await api(`/api/workspaces/${state.workspace.id}/ask`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question }),
    });
    renderAnswer(answer);
    await loadAnswerHistory();
    await refreshWorkspace();
  });
}

async function start() {
  bindEvents();
  try {
    await loadWorkspaces();
  } catch (error) {
    toast(error.message);
  }
}

start();
