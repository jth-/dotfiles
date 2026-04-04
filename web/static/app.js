/* SPQR Agent Manager — client-side JS */

// ── Utility ───────────────────────────────────────────────────────

function debounce(fn, ms) {
  let t;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}

function fmt_date(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ── Modal ─────────────────────────────────────────────────────────

const modal = {
  backdrop: null,
  init() {
    this.backdrop = document.getElementById('modal-backdrop');
    this.backdrop?.addEventListener('click', e => {
      if (e.target === this.backdrop) this.close();
    });
    document.getElementById('modal-cancel')?.addEventListener('click', () => this.close());
  },
  open(title, desc, onConfirm, confirmLabel = 'Confirm', confirmClass = 'btn-proscribe') {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-desc').textContent = desc;
    const btn = document.getElementById('modal-confirm');
    btn.textContent = confirmLabel;
    btn.className = `btn ${confirmClass}`;
    btn.onclick = () => { this.close(); onConfirm(); };
    this.backdrop.classList.add('open');
  },
  close() {
    this.backdrop?.classList.remove('open');
  },
};

// ── Job Stream ────────────────────────────────────────────────────

function streamJob(jobId, terminalEl, onDone) {
  const body = terminalEl.querySelector('.terminal-body');
  if (!body) return;
  body.innerHTML = '';
  terminalEl.classList.remove('hidden');

  const es = new EventSource(`/api/stream/${jobId}`);

  es.onmessage = e => {
    const data = JSON.parse(e.data);
    if (data.error) {
      body.innerHTML += `<span class="line-error">${esc(data.error)}</span>\n`;
      es.close();
      return;
    }
    if (data.line !== undefined) {
      const line = data.line;
      let cls = '';
      if (/TRIVMPHVS|✓|done/i.test(line)) cls = 'line-success';
      else if (/PERFIDIA|error|Error|failed/i.test(line)) cls = 'line-error';
      else if (/EDICTVM|RITUS|Ritus/i.test(line)) cls = 'line-gold';
      body.innerHTML += cls ? `<span class="${cls}">${esc(line)}</span>` : esc(line);
      body.scrollTop = body.scrollHeight;
    }
    if (data.done) {
      es.close();
      if (onDone) onDone(data.status, data.returncode);
    }
  };

  es.onerror = () => {
    body.innerHTML += `<span class="line-error">Connection lost.\n</span>`;
    es.close();
  };

  return es;
}

// ── Tabs ──────────────────────────────────────────────────────────

function initTabs(containerEl) {
  const tabs = containerEl.querySelectorAll('.tab');
  const panels = containerEl.querySelectorAll('.tab-panel');

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      panels.forEach(p => p.classList.remove('active'));
      tab.classList.add('active');
      const target = containerEl.querySelector(`#${tab.dataset.panel}`);
      if (target) target.classList.add('active');
    });
  });
}

// ── Legions (Dashboard) ───────────────────────────────────────────

function initLegions() {
  const grid = document.getElementById('workspaces-grid');
  const counter = document.getElementById('legion-count');
  if (!grid) return;

  let prevIds = null;

  async function load() {
    try {
      const res = await fetch('/api/workspaces');
      const workspaces = await res.json();
      if (workspaces.error) return;

      const ids = workspaces.map(w => w.id).sort().join(',');
      if (ids === prevIds) return; // no change
      prevIds = ids;

      if (counter) counter.textContent = workspaces.length;

      if (workspaces.length === 0) {
        grid.innerHTML = `
          <div class="empty-state" style="grid-column:1/-1">
            <div class="empty-icon">⚔</div>
            <div class="empty-title">No legions in the field</div>
            <div class="empty-desc">The Forum awaits your command</div>
            <a href="/senatus" class="btn btn-senatus">Convene the Senate</a>
          </div>`;
        return;
      }

      grid.innerHTML = workspaces.map(w => `
        <div class="card" data-branch="${esc(w.branch)}">
          <div class="card-accent ${w.is_review ? 'review' : ''}"></div>
          <div class="card-body">
            <div class="card-label">${w.is_review ? 'Review' : 'Session'}</div>
            <div class="card-branch">${esc(w.branch)}</div>
            <div class="card-meta">
              <span class="badge badge-active"><span class="dot"></span>Running</span>
            </div>
            <div class="card-meta mt-4" style="font-size:13px;color:var(--slate-light)">
              ${esc(w.status)}
            </div>
          </div>
          <div class="card-footer">
            <a href="${esc(w.preview_url)}" target="_blank" class="btn btn-ghost btn-sm">Preview ↗</a>
            <button class="btn btn-proscribe btn-sm js-proscribe" data-branch="${esc(w.branch)}">
              Proscribe
            </button>
          </div>
        </div>`).join('');

      grid.querySelectorAll('.js-proscribe').forEach(btn => {
        btn.addEventListener('click', () => {
          const branch = btn.dataset.branch;
          modal.open(
            'Proscribe this legion?',
            `This will stop the container, remove the git worktree, and drop the database for "${branch}". This cannot be undone.`,
            () => proscribe(branch),
            'Proscribe',
            'btn-proscribe',
          );
        });
      });
    } catch (e) {
      console.error('workspace load error', e);
    }
  }

  load();
  setInterval(load, 10_000);
}

async function proscribe(branch) {
  const res = await fetch('/api/proscribe', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ branch }),
  });
  const data = await res.json();
  if (data.job_id) {
    const term = document.getElementById('proscribe-terminal');
    if (term) {
      streamJob(data.job_id, term, (status) => {
        if (status === 'done') setTimeout(() => location.reload(), 1500);
      });
    }
  }
}

// ── Senatus (New Session) ─────────────────────────────────────────

function initSenatus() {
  const form = document.getElementById('senatus-form');
  if (!form) return;

  initTabs(form.closest('.tabs-container') || form);

  // Issue search
  const searchInput = document.getElementById('issue-search');
  const results = document.getElementById('issue-results');
  const selectedId = document.getElementById('selected-issue-id');
  const selectedDisplay = document.getElementById('selected-display');

  if (searchInput) {
    const doSearch = debounce(async (q) => {
      if (!q) {
        // load "my issues"
        const res = await fetch('/api/issues');
        const issues = await res.json();
        renderIssues(issues);
        return;
      }
      const res = await fetch(`/api/issues/search?q=${encodeURIComponent(q)}`);
      const issues = await res.json();
      renderIssues(issues);
    }, 300);

    searchInput.addEventListener('input', e => doSearch(e.target.value));
    searchInput.addEventListener('focus', () => {
      if (!searchInput.value) doSearch('');
    });

    // Load on mount
    fetch('/api/issues').then(r => r.json()).then(renderIssues);
  }

  function renderIssues(issues) {
    if (!results) return;
    if (!issues.length) {
      results.innerHTML = `<div style="padding:16px;text-align:center;color:var(--slate-light);font-size:14px;font-style:italic">No issues found</div>`;
      return;
    }
    results.innerHTML = issues.map(i => `
      <div class="issue-row" data-id="${esc(i.id)}">
        <span class="issue-id">${esc(i.id)}</span>
        <span class="badge badge-tribune" style="white-space:nowrap">${esc(i.state)}</span>
        <span class="issue-title">${esc(i.title)}</span>
      </div>`).join('');

    results.querySelectorAll('.issue-row').forEach(row => {
      row.addEventListener('click', () => {
        results.querySelectorAll('.issue-row').forEach(r => r.classList.remove('selected'));
        row.classList.add('selected');
        const id = row.dataset.id;
        if (selectedId) selectedId.value = id;
        if (selectedDisplay) {
          selectedDisplay.textContent = id;
          selectedDisplay.parentElement.classList.remove('hidden');
        }
      });
    });
  }

  // Form submit
  form.addEventListener('submit', async e => {
    e.preventDefault();
    const activePanel = form.querySelector('.tab-panel.active');
    const isLinear = activePanel?.id === 'panel-linear';

    const body = {};
    if (isLinear) {
      const id = selectedId?.value.trim();
      if (!id) { alert('Select a Linear issue first'); return; }
      body.issue_id = id;
    } else {
      const name = document.getElementById('adhoc-name')?.value.trim();
      if (!name) { alert('Enter a session name'); return; }
      body.name = name;
    }
    body.no_link_deps = document.getElementById('no-link-deps')?.checked || false;

    const btn = form.querySelector('[type="submit"]');
    btn.disabled = true;
    btn.innerHTML = '<span class="loader"></span> Convening…';

    const res = await fetch('/api/senatus', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();

    if (data.error) {
      btn.disabled = false;
      btn.textContent = 'Convene the Senate';
      alert(data.error);
      return;
    }

    const term = document.getElementById('senatus-terminal');
    streamJob(data.job_id, term, (status) => {
      if (status === 'done') {
        term.querySelector('.terminal-body').innerHTML +=
          `\n<span class="line-success">✓ Workspace ready — switch to your terminal to interact with Claude.\n</span>`;
        btn.disabled = false;
        btn.textContent = 'Convene the Senate';
      } else {
        btn.disabled = false;
        btn.textContent = 'Convene the Senate';
      }
    });
  });
}

// ── Censor (PR Reviews) ───────────────────────────────────────────

function initCensor() {
  const container = document.getElementById('pr-table-body');
  if (!container) return;

  let selectedPr = null;
  const startBtn = document.getElementById('start-review-btn');

  async function load() {
    const res = await fetch('/api/prs');
    const data = await res.json();
    if (data.error) {
      container.innerHTML = `<tr><td colspan="6" style="text-align:center;color:var(--crimson);padding:24px">${esc(data.error)}</td></tr>`;
      return;
    }
    if (!data.length) {
      container.innerHTML = `<tr><td colspan="6"><div class="empty-state"><div class="empty-title">No open PRs</div></div></td></tr>`;
      return;
    }

    container.innerHTML = data.map(pr => {
      const requested = pr.reviewRequests?.length > 0;
      return `
        <tr data-pr="${pr.number}" class="${requested ? 'review-requested' : ''}">
          <td><span class="badge ${requested ? 'badge-requested' : 'badge-tribune'}">#${pr.number}</span></td>
          <td>${esc(pr.title)}</td>
          <td style="color:var(--slate-light)">${esc(pr.author?.login || '—')}</td>
          <td>
            <span class="diff-stat">
              <span class="diff-add">+${pr.additions}</span>
              <span style="color:var(--parchment)"> / </span>
              <span class="diff-del">−${pr.deletions}</span>
            </span>
          </td>
          <td style="color:var(--slate-light)">${pr.changedFiles} file${pr.changedFiles !== 1 ? 's' : ''}</td>
          <td>${fmt_date(pr.createdAt)}</td>
        </tr>`;
    }).join('');

    container.querySelectorAll('tr').forEach(row => {
      row.addEventListener('click', () => {
        container.querySelectorAll('tr').forEach(r => r.classList.remove('selected'));
        row.classList.add('selected');
        selectedPr = row.dataset.pr;
        if (startBtn) {
          startBtn.disabled = false;
          startBtn.textContent = `Convene the Tribunal — PR #${selectedPr}`;
        }
      });
    });
  }

  load();

  startBtn?.addEventListener('click', async () => {
    if (!selectedPr) return;
    startBtn.disabled = true;
    startBtn.innerHTML = '<span class="loader"></span> Convening…';

    const res = await fetch('/api/censor', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pr_number: parseInt(selectedPr, 10) }),
    });
    const data = await res.json();

    if (data.error) {
      startBtn.disabled = false;
      startBtn.textContent = 'Convene the Tribunal';
      alert(data.error);
      return;
    }

    const term = document.getElementById('censor-terminal');
    streamJob(data.job_id, term, (status) => {
      startBtn.disabled = false;
      startBtn.textContent = 'Convene the Tribunal';
      if (status === 'done') {
        term.querySelector('.terminal-body').innerHTML +=
          `\n<span class="line-success">✓ Review workspace ready — switch to your terminal.\n</span>`;
      }
    });
  });
}

// ── Templates ─────────────────────────────────────────────────────

function initTemplates() {
  const tbody = document.getElementById('templates-body');
  if (!tbody) return;

  async function load() {
    const res = await fetch('/api/templates');
    const data = await res.json();
    if (data.error) {
      tbody.innerHTML = `<tr><td colspan="3" style="text-align:center;color:var(--crimson);padding:24px">${esc(data.error)}</td></tr>`;
      return;
    }
    if (!data.length) {
      tbody.innerHTML = `<tr><td colspan="3"><div style="padding:24px;text-align:center;color:var(--slate-light);font-style:italic">No templates yet</div></td></tr>`;
      return;
    }
    tbody.innerHTML = data.map(t => `
      <tr>
        <td class="mono">${esc(t.name)}</td>
        <td>${esc(t.size)}</td>
        <td>
          <button class="btn btn-proscribe btn-sm js-drop-tpl" data-name="${esc(t.name)}"
            style="font-size:10px;padding:6px 14px">Drop</button>
        </td>
      </tr>`).join('');

    tbody.querySelectorAll('.js-drop-tpl').forEach(btn => {
      btn.addEventListener('click', () => {
        const name = btn.dataset.name;
        modal.open(
          'Drop this template?',
          `Template "${name}" will be permanently deleted from Postgres. Existing workspaces using it will be unaffected.`,
          () => dropTemplate(name),
          'Drop Template',
          'btn-proscribe',
        );
      });
    });
  }

  async function dropTemplate(name) {
    const res = await fetch(`/api/templates/${encodeURIComponent(name)}`, { method: 'DELETE' });
    const data = await res.json();
    if (data.job_id) {
      const term = document.getElementById('templates-terminal');
      streamJob(data.job_id, term, () => load());
    }
  }

  load();

  // Create form
  const createForm = document.getElementById('create-tpl-form');
  createForm?.addEventListener('submit', async e => {
    e.preventDefault();
    const name = document.getElementById('tpl-name')?.value.trim();
    const url  = document.getElementById('tpl-url')?.value.trim();
    if (!name || !url) return;

    const btn = createForm.querySelector('[type="submit"]');
    btn.disabled = true;
    btn.innerHTML = '<span class="loader"></span> Creating…';

    const res = await fetch('/api/templates', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, from_url: url }),
    });
    const data = await res.json();

    if (data.error) {
      btn.disabled = false;
      btn.textContent = 'Create Template';
      alert(data.error);
      return;
    }

    const term = document.getElementById('templates-terminal');
    streamJob(data.job_id, term, (status) => {
      btn.disabled = false;
      btn.textContent = 'Create Template';
      if (status === 'done') {
        createForm.reset();
        load();
      }
    });
  });
}

// ── Boot ──────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  modal.init();
  initLegions();
  initSenatus();
  initCensor();
  initTemplates();
});
