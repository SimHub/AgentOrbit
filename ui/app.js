const tauri = window.__TAURI__;
const state = {
  snapshots: [],
  density: "compact", // minimal | compact | detail
  lang: "de", // de | en
};

const I18N = {
  de: {
    needs_input: "Eingabe nötig",
    running: "Aktiv",
    idle: "Idle",
    offline: "Offline",
    unavailable: "Nicht gefunden",
    empty: "Keine lokalen Agent-Sessions gefunden.",
    ready: "Live-Überwachung aktiv",
  },
  en: {
    needs_input: "Needs input",
    running: "Active",
    idle: "Idle",
    offline: "Offline",
    unavailable: "Unavailable",
    empty: "No local agent sessions found.",
    ready: "Live watch active",
  },
};

function fmtTokens(n) {
  if (!n) return "";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M tok`;
  if (n >= 1_000) return `${Math.round(n / 1_000)}k tok`;
  return `${n} tok`;
}

function fmtAge(epoch) {
  if (!epoch) return "";
  const diff = Math.max(0, Math.floor(Date.now() / 1000) - epoch);
  if (diff < 60) return `${diff}s`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ${diff % 60}s`;
  return `${Math.floor(diff / 3600)}h`;
}

function ringSvg(percentRemaining, label) {
  const r = 8;
  const c = 2 * Math.PI * r;
  const dash = (Math.max(0, Math.min(100, percentRemaining)) / 100) * c;
  const color = percentRemaining < 20 ? "#f79009" : "#32d583";
  return `
    <span class="ring-item" title="${label}: ${Math.round(percentRemaining)}%">
      <svg width="20" height="20" viewBox="0 0 20 20">
        <circle cx="10" cy="10" r="${r}" fill="none" stroke="rgba(255,255,255,0.12)" stroke-width="2.4" />
        <circle cx="10" cy="10" r="${r}" fill="none" stroke="${color}" stroke-width="2.4"
          stroke-dasharray="${dash.toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 10 10)" />
      </svg>
      <span>${label}</span>
    </span>
  `;
}

function effectiveDensity() {
  if (window.innerWidth < 290) return "minimal";
  return state.density;
}

function render() {
  const list = document.getElementById("session-list");
  const orb = document.getElementById("status-orb");
  const badge = document.getElementById("live-badge");
  const footer = document.getElementById("footer-status");
  const dict = I18N[state.lang];

  const density = effectiveDensity();
  list.className = `session-list density-${density}`;

  const waitingCount = state.snapshots.filter((s) => s.snapshot.state === "needs_input").length;
  const runningCount = state.snapshots.filter((s) => s.snapshot.state === "running").length;

  orb.className = `orb ${waitingCount > 0 ? "needs_input" : runningCount > 0 ? "running" : "idle"}`;
  if (waitingCount + runningCount > 0) {
    badge.className = `badge ${waitingCount > 0 ? "warn" : ""}`;
    badge.textContent = waitingCount > 0 ? `! ${waitingCount}` : `${runningCount}`;
  } else {
    badge.className = "badge hidden";
  }
  footer.textContent = dict.ready;

  if (!state.snapshots.length) {
    list.innerHTML = `<div class="empty-state">${dict.empty}</div>`;
    return;
  }

  list.innerHTML = state.snapshots
    .map((item) => {
      const s = item.snapshot;
      const statusText = s.interaction_reason
        ? `${dict[s.state] || s.state} · ${s.interaction_reason}`
        : dict[s.state] || s.state;
      const effort = s.reasoning_effort ? ` (${s.reasoning_effort})` : "";
      const branch = s.git_branch ? `⎇ ${s.git_branch}` : "";
      const cost = item.cost_display ? item.cost_display : "";
      const tokens = fmtTokens(s.usage?.session_total_tokens);
      const age = fmtAge(s.last_updated_epoch);

      const rings = [];
      if (s.usage?.primary_limit) {
        const rem = Math.max(0, 100 - s.usage.primary_limit.used_percent);
        rings.push(ringSvg(rem, "5h"));
      }
      if (s.usage?.secondary_limit) {
        const rem = Math.max(0, 100 - s.usage.secondary_limit.used_percent);
        rings.push(ringSvg(rem, "7d"));
      }

      const pathAttr = s.project_path ? s.project_path.replace(/"/g, "&quot;") : "";
      return `
        <article class="card ${s.state}">
          <div class="card-top">
            <button class="project-btn" data-path="${pathAttr}" title="${pathAttr || s.project_name}">
              ${s.project_name}
            </button>
            <span class="pill ${s.state}">${statusText}</span>
          </div>
          <div class="meta">
            <span>${s.agent_label}</span>
            <span>${s.model_name}${effort}</span>
            ${branch ? `<span class="extra-meta">${branch}</span>` : ""}
            ${age ? `<span>${age}</span>` : ""}
          </div>
          <div class="detail-row">
            <span>${[tokens, cost].filter(Boolean).join(" · ") || "—"}</span>
            <div class="rings">${rings.join("")}</div>
          </div>
        </article>
      `;
    })
    .join("");

  list.querySelectorAll(".project-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const p = btn.getAttribute("data-path");
      if (p && tauri?.core) {
        tauri.core.invoke("open_project", { path: p, target: null }).catch(() => {});
      }
    });
  });
}

async function refreshNow() {
  if (!tauri?.core) return;
  try {
    state.snapshots = await tauri.core.invoke("scan_sessions");
    render();
  } catch (err) {
    console.error("scan_sessions failed:", err);
  }
}

document.getElementById("density-btn").addEventListener("click", () => {
  const order = ["minimal", "compact", "detail"];
  const labels = { minimal: "M", compact: "K", detail: "D" };
  const next = order[(order.indexOf(state.density) + 1) % order.length];
  state.density = next;
  document.getElementById("density-btn").textContent = labels[next];
  render();
});

document.getElementById("lang-btn").addEventListener("click", () => {
  state.lang = state.lang === "de" ? "en" : "de";
  document.getElementById("lang-btn").textContent = state.lang.toUpperCase();
  render();
});

document.getElementById("refresh-btn").addEventListener("click", refreshNow);

document.getElementById("hide-btn").addEventListener("click", () => {
  if (tauri?.core) {
    tauri.core.invoke("toggle_hud_visibility").catch(() => {});
  }
});

document.getElementById("opacity-slider").addEventListener("input", (e) => {
  document.documentElement.style.setProperty("--bg-alpha", (Number(e.target.value) / 100).toFixed(2));
});

window.addEventListener("resize", render);

if (tauri?.event) {
  tauri.event.listen("agentorbit://snapshots", (event) => {
    if (Array.isArray(event.payload)) {
      state.snapshots = event.payload;
      render();
    }
  });
}

refreshNow();
setInterval(render, 1000);
