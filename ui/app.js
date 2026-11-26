const tauri = window.__TAURI__;

const SIZE_PRESETS = {
  minimal: { w: 320, h: 150 },
  compact: { w: 400, h: 360 },
  detail: { w: 470, h: 520 },
  expanded: { w: 760, h: 540 },
  settings: { w: 445, h: 640 },
};

const state = {
  snapshots: [],
  discovered: null,
  filter: "all", // all | active | needs_input
  inSettings: false,
  recordingHotkey: null,
  savedHudSize: null,
  savedBeforeMini: null,
  expandedCards: new Set(),
  prevStates: new Map(),
  recentlyCompleted: new Map(), // cardId -> epochSecs
  contextPath: null,
  lastRenderKey: "",
  config: {
    density: "compact",
    tray_style: "project",
    lang: "auto",
    opacity: 94,
    context_window_override: 0,
    preferred_launcher: "auto",
    project_scope: "all", // "single" | "active" | "all"
    show_all_active_projects: true,
    snap_grid_enabled: true,
    show_cost_estimate: true,
    hotkey_hud: "ctrl+alt+o",
    hotkey_density: "off",
    hotkey_active: "off",
    hotkey_mini: "off",
    notify_on_needs_input: true,
    notify_on_completion: true,
    notify_sound: false,
    launch_at_login: false,
    custom_agents: [],
    watched_folders: [],
    checklist: [],
  },
};

const SVG = {
  branch: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/></svg>`,
  clock: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 15 14"/></svg>`,
  eta: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round"><path d="M5 22h14M5 2h14M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"/></svg>`,
  checkDone: `<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#30d158" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>`,
  checkRun: `<span class="dots-spinner"><i></i><i></i><i></i><i></i></span>`,
  checkPend: `<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#667085" stroke-width="2"><circle cx="12" cy="12" r="5"/></svg>`,
  bolt: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>`,
  alert: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>`,
  moon: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>`,
  edit: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="#64d2ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 1 1 3 3L7 19l-4 1 1-4Z"/></svg>`,
  app: `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="4"/><path d="M9 9h6v6H9z"/></svg>`,
};

const I18N = {
  de: {
    needs_input: "Eingabe",
    running: "Aktiv",
    done: "Fertig",
    idle: "Idle",
    offline: "Offline",
    unavailable: "N/A",
    empty: "Keine passenden Agent-Sessions.",
    subReady: "Echtzeit · Bereit",
    subActive: (n) => `Echtzeit · ${n} aktiv`,
    ctx: "Kontext",
    ctxTip: "Kontext-Auslastung: Grün <65% · Gelb 65–84% · Rot ≥85%",
    allDone: "Alle Schritte fertig",
    day: "Tag",
    week: "Woche",
    month: "Monat",
  },
  en: {
    needs_input: "Input",
    running: "Active",
    done: "Done",
    idle: "Idle",
    offline: "Offline",
    unavailable: "N/A",
    empty: "No matching agent sessions.",
    subReady: "Realtime · Ready",
    subActive: (n) => `Realtime · ${n} active`,
    ctx: "Context",
    ctxTip: "Context fill: Green <65% · Amber 65–84% · Red ≥85%",
    allDone: "All steps done",
    day: "Day",
    week: "Week",
    month: "Month",
  },
};

function resolvedLang() {
  if (state.config.lang === "en") return "en";
  if (state.config.lang === "de") return "de";
  return (navigator.language || "de").toLowerCase().startsWith("en") ? "en" : "de";
}

function fmtTokens(n) {
  if (!n) return "";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${Math.round(n / 1_000)}k`;
  return `${n}`;
}

function fmtDuration(secs) {
  const s = Math.max(0, Math.floor(secs));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

function fmtResetCountdown(resetsAtEpoch) {
  if (!resetsAtEpoch) return "";
  const diff = resetsAtEpoch - Math.floor(Date.now() / 1000);
  if (diff <= 0) return "now";
  if (diff >= 86_400) return `${Math.floor(diff / 86_400)}d ${Math.floor((diff % 86_400) / 3600)}h`;
  const h = Math.floor(diff / 3600);
  const m = Math.floor((diff % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function windowLabel(mins, dict) {
  if (!mins || mins <= 360) return `${Math.max(1, Math.round((mins || 300) / 60))}h`;
  if (mins <= 1440) return dict.day;
  if (mins <= 10080) return dict.week;
  return dict.month;
}

function agentIdeDisplay(label) {
  const map = {
    Antigravity: "Antigravity IDE",
    Codex: "Codex CLI / ChatGPT",
    Claude: "Claude Code CLI",
    OpenCode: "OpenCode Desktop",
    Bionic: "LM Studio Bionic",
    Pi: "Pi Coding Agent",
  };
  return map[label] || label;
}

function modelBadgeClass(modelName) {
  const m = (modelName || "").toLowerCase();
  if (m.includes("gemini")) return "gemini";
  if (m.includes("claude") || m.includes("opus") || m.includes("sonnet") || m.includes("haiku")) return "claude";
  if (m.includes("gpt") || m.includes("codex") || m.includes("o3") || m.includes("o4")) return "openai";
  if (m.includes("qwen") || m.includes("deepseek") || m.includes("llama") || m.includes("mistral") || m.includes("mlx")) return "local";
  return "";
}

function agentBadgeMeta(label) {
  const map = {
    Antigravity: { code: "AG", cls: "ag" },
    Codex: { code: "CX", cls: "cx" },
    Claude: { code: "CL", cls: "cl" },
    OpenCode: { code: "OC", cls: "oc" },
    Bionic: { code: "LM", cls: "lm" },
    Pi: { code: "PI", cls: "pi" },
  };
  return map[label] || { code: (label || "AI").slice(0, 2).toUpperCase(), cls: "other" };
}

function circularUsageRing(percent, title, valueText, color, resetEpoch = null) {
  const pct = Math.max(0, Math.min(100, percent));
  const r = 10;
  const c = 2 * Math.PI * r;
  const dash = (pct / 100) * c;
  const cd = resetEpoch ? fmtResetCountdown(resetEpoch) : "";
  const resetHtml = resetEpoch && cd ? ` · <span data-live-reset="${resetEpoch}">${cd}</span>` : "";
  return `
    <span class="usage-ring-card" title="${title}: ${valueText}">
      <svg width="24" height="24" viewBox="0 0 24 24">
        <circle cx="12" cy="12" r="${r}" fill="none" stroke="rgba(255,255,255,0.12)" stroke-width="2.5" />
        <circle cx="12" cy="12" r="${r}" fill="none" stroke="${color}" stroke-width="2.5"
          stroke-linecap="round" stroke-dasharray="${dash.toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 12 12)" />
      </svg>
      <span class="usage-ring-meta">
        <span class="usage-ring-title">${title}</span>
        <span class="usage-ring-val">${valueText}${resetHtml}</span>
      </span>
    </span>
  `;
}

function ringSvg(limit, dict) {
  const pctRem = Math.max(0, Math.min(100, 100 - (limit.used_percent || 0)));
  const color = pctRem < 20 ? "#ff453a" : pctRem < 45 ? "#ff9f0a" : "#30d158";
  const label = windowLabel(limit.window_minutes, dict);
  return circularUsageRing(pctRem, label, `${Math.round(pctRem)}%`, color, limit.resets_at_epoch);
}

function computePeriodUsage(snapshots, agentLabel, nowSecs) {
  let dayTok = 0;
  let weekTok = 0;
  let monthTok = 0;
  for (const item of snapshots) {
    const s = item.snapshot;
    if (s.agent_label !== agentLabel) continue;
    const tok = s.usage?.session_total_tokens || 0;
    const ts = s.last_updated_epoch || 0;
    const age = ts > 0 ? Math.max(0, nowSecs - ts) : Infinity;
    if (age <= 86_400) dayTok += tok;
    if (age <= 7 * 86_400) weekTok += tok;
    if (age <= 30 * 86_400) monthTok += tok;
  }
  return { dayTok, weekTok, monthTok };
}

function effectiveDensity() {
  if (window.innerWidth < 305) return "minimal";
  return state.config.density || "compact";
}

function fitWindowHeightToContent(targetWidth = null) {
  if (!tauri?.core || state.inSettings) return;
  requestAnimationFrame(() => {
    const header = document.getElementById("hud-header");
    const filterBar = document.getElementById("filter-bar");
    const list = document.getElementById("session-list");
    const footer = document.querySelector(".hud-footer");
    if (!header || !list) return;

    const hHeader = header.offsetHeight || 40;
    const hFilter = filterBar && !filterBar.classList.contains("hidden") ? filterBar.offsetHeight : 0;
    const hFooter = footer && getComputedStyle(footer).display !== "none" ? footer.offsetHeight : 0;

    // Measure actual children heights (allows shrinking back down cleanly from 7 -> 1 cards!)
    const style = getComputedStyle(list);
    const padY = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
    const gap = parseFloat(style.rowGap || style.gap) || 8;
    const children = Array.from(list.children);
    const cols = list.classList.contains("cols-3") ? 3 : list.classList.contains("cols-2") ? 2 : 1;

    let contentH = padY;
    if (children.length === 0) {
      contentH += 72;
    } else if (cols === 1) {
      contentH += children.reduce((sum, el) => sum + el.offsetHeight, 0) + gap * Math.max(0, children.length - 1);
    } else {
      const rows = Math.ceil(children.length / cols);
      for (let r = 0; r < rows; r++) {
        let rowMax = 0;
        for (let c = 0; c < cols; c++) {
          const el = children[r * cols + c];
          if (el) rowMax = Math.max(rowMax, el.offsetHeight);
        }
        contentH += rowMax;
      }
      contentH += gap * Math.max(0, rows - 1);
    }

    const maxH = Math.min(720, Math.round((window.screen?.availHeight || 900) * 0.78));
    const idealH = Math.max(108, Math.min(maxH, Math.ceil(hHeader + hFilter + contentH + hFooter + 4)));
    const width = targetWidth || window.innerWidth;
    if (Math.abs(window.innerHeight - idealH) > 4 || (targetWidth && Math.abs(window.innerWidth - targetWidth) > 4)) {
      tauri.core.invoke("resize_hud", { width, height: idealH }).catch(() => {});
    }
  });
}

function effectiveColsClass() {
  const w = window.innerWidth;
  if (w >= 840) return "cols-3";
  if (w >= 560) return "cols-2";
  return "cols-1";
}

function persistConfig() {
  if (tauri?.core) {
    tauri.core.invoke("save_config", { config: state.config }).catch(() => {});
  }
}

function applyAutoSize(densityOverride = null) {
  if (!tauri?.core) return;
  const target = densityOverride || (state.inSettings ? "settings" : state.config.density);
  const preset = SIZE_PRESETS[target] || SIZE_PRESETS.compact;
  if (target === "settings") {
    tauri.core.invoke("resize_hud", { width: preset.w, height: preset.h }).catch(() => {});
  } else {
    tauri.core.invoke("resize_hud", { width: preset.w, height: preset.h }).catch(() => {});
    setTimeout(() => fitWindowHeightToContent(preset.w), 60);
  }
}

function toggleMiniPreview() {
  if (state.inSettings) openSettings(false);
  if (state.config.density === "minimal") {
    const prev = state.savedBeforeMini || { density: "compact", w: 395, h: 430 };
    state.config.density = prev.density;
    state.savedBeforeMini = null;
    syncSettingsUI();
    persistConfig();
    if (tauri?.core) tauri.core.invoke("resize_hud", { width: prev.w, height: prev.h }).catch(() => {});
  } else {
    state.savedBeforeMini = {
      density: state.config.density,
      w: Math.max(window.innerWidth, 380),
      h: Math.max(window.innerHeight, 360),
    };
    state.config.density = "minimal";
    syncSettingsUI();
    persistConfig();
    applyAutoSize("minimal");
  }
  render(true);
}

function openSettings(open) {
  state.inSettings = open;
  document.getElementById("hud-view").classList.toggle("hidden", open);
  document.getElementById("settings-view").classList.toggle("hidden", !open);
  document.getElementById("settings-btn").classList.toggle("active", open);

  if (tauri?.core) {
    if (open) {
      state.savedHudSize = { w: window.innerWidth, h: window.innerHeight };
      tauri.core
        .invoke("resize_hud", {
          width: Math.max(window.innerWidth, SIZE_PRESETS.settings.w),
          height: Math.max(window.innerHeight, SIZE_PRESETS.settings.h),
        })
        .catch(() => {});
      loadDiscovered();
    } else if (state.savedHudSize) {
      tauri.core
        .invoke("resize_hud", { width: state.savedHudSize.w, height: state.savedHudSize.h })
        .catch(() => {});
    }
  }
}

async function loadDiscovered() {
  if (!tauri?.core) return;
  try {
    state.discovered = await tauri.core.invoke("get_discovered_agents");
    renderDiscoveredAgents();
  } catch {}
}

function renderDiscoveredAgents() {
  const el = document.getElementById("discovered-agents-list");
  if (!el || !state.discovered) return;
  const d = state.discovered;
  const rows = [
    { name: "Antigravity", ok: d.has_antigravity },
    { name: "Codex", ok: d.has_codex },
    ...(d.custom_agents || []).map((a) => ({ name: a.name, ok: true })),
  ];
  el.innerHTML = rows
    .map((r) => {
      const b = agentBadgeMeta(r.name);
      return `
        <div class="discovered-item">
          <span class="meta-item"><span class="agent-badge ${b.cls}" style="width:20px;height:20px;font-size:9px">${b.code}</span> ${agentIdeDisplay(r.name)}</span>
          <span class="pill ${r.ok ? "running" : "idle"}">${r.ok ? "Aktiv" : "—"}</span>
        </div>`;
    })
    .join("");
}

function applyOpacity(val) {
  const clamped = Math.max(25, Math.min(100, Number(val) || 94));
  state.config.opacity = clamped;
  document.documentElement.style.setProperty("--bg-alpha", (clamped / 100).toFixed(2));
  document.getElementById("hud-shell").classList.toggle("low-opacity", clamped < 50);
  document.getElementById("opacity-slider").value = String(clamped);
  document.getElementById("opacity-val").textContent = `${clamped}%`;
}

function formatHotkeyDisplay(spec) {
  if (!spec || spec === "off") return "Aus";
  const [rawPart, customLabel] = spec.split("|");
  const parts = rawPart.toLowerCase().split("+").filter(Boolean);
  const sym = [];
  let key = "";
  for (const p of parts) {
    if (p === "ctrl" || p === "control") sym.push("⌃");
    else if (p === "alt" || p === "opt" || p === "option") sym.push("⌥");
    else if (p === "shift") sym.push("⇧");
    else if (p === "cmd" || p === "meta" || p === "super") sym.push("⌘");
    else {
      const cleaned = p.replace(/^key/, "").replace(/^digit/, "");
      key = cleaned === "space" ? "Space" : cleaned.toUpperCase();
    }
  }
  const displayKey = customLabel ? customLabel.toUpperCase() : key;
  return `${sym.join("")} ${displayKey}`.trim();
}

function normalizeHotkeySpec(spec, keepLabel = false) {
  if (!spec || spec === "off") return "off";
  const [rawPart, customLabel] = spec.split("|");
  const parts = rawPart.toLowerCase().split("+").map((s) => s.trim()).filter(Boolean);
  const mods = [];
  let key = "";
  for (const p of parts) {
    if (p === "ctrl" || p === "control") { if (!mods.includes("ctrl")) mods.push("ctrl"); }
    else if (p === "alt" || p === "opt" || p === "option") { if (!mods.includes("alt")) mods.push("alt"); }
    else if (p === "shift") { if (!mods.includes("shift")) mods.push("shift"); }
    else if (p === "cmd" || p === "meta" || p === "super") { if (!mods.includes("cmd")) mods.push("cmd"); }
    else key = p.replace(/^key/, "").replace(/^digit/, "");
  }
  if (!key) return "off";
  const order = ["ctrl", "alt", "shift", "cmd"];
  mods.sort((a, b) => order.indexOf(a) - order.indexOf(b));
  const base = [...mods, key].join("+");
  return keepLabel && customLabel ? `${base}|${customLabel}` : base;
}

function setSelectWithCustom(selectId, value) {
  const sel = document.getElementById(selectId);
  if (!sel) return;
  const fullVal = normalizeHotkeySpec(value, true);
  const baseVal = normalizeHotkeySpec(value, false);
  const matchingOpt = Array.from(sel.options).find(
    (o) => normalizeHotkeySpec(o.value, false) === baseVal
  );
  if (matchingOpt) {
    if (fullVal.includes("|")) {
      matchingOpt.value = fullVal;
      matchingOpt.textContent = `${formatHotkeyDisplay(fullVal)} (Eigene)`;
    }
    sel.value = matchingOpt.value;
    return;
  }
  if (baseVal !== "off") {
    const opt = document.createElement("option");
    opt.value = fullVal;
    opt.textContent = `${formatHotkeyDisplay(fullVal)} (Eigene)`;
    sel.appendChild(opt);
    sel.value = fullVal;
  } else {
    sel.value = "off";
  }
}

function updateHotkeyConflicts() {
  const fields = [
    { key: "hotkey_hud", label: "HUD" },
    { key: "hotkey_density", label: "Ansicht" },
    { key: "hotkey_active", label: "Aktive" },
    { key: "hotkey_mini", label: "Mini" },
  ];
  const counts = new Map();
  for (const f of fields) {
    const norm = normalizeHotkeySpec(state.config[f.key]);
    if (norm !== "off") counts.set(norm, [...(counts.get(norm) || []), f]);
  }
  const conflictKeys = new Set();
  const messages = [];
  for (const [combo, list] of counts.entries()) {
    if (list.length > 1) {
      list.forEach((f) => conflictKeys.add(f.key));
      messages.push(`${formatHotkeyDisplay(combo)} (${list.map((f) => f.label).join(" & ")})`);
    }
  }
  document.querySelectorAll(".hk-row").forEach((row) => {
    row.classList.toggle("conflict", conflictKeys.has(row.getAttribute("data-hk")));
  });
  const banner = document.getElementById("hk-conflict-banner");
  if (messages.length) {
    banner.textContent = `⚠ Doppelbelegung: ${messages.join(" · ")}`;
    banner.classList.remove("hidden");
  } else {
    banner.classList.add("hidden");
  }
}

function syncSettingsUI() {
  applyOpacity(state.config.opacity ?? 94);

  document.querySelectorAll(".density-opt, .quick-density").forEach((b) => {
    b.classList.toggle("active", b.getAttribute("data-density") === state.config.density);
  });
  document.querySelectorAll(".tray-opt").forEach((b) => {
    b.classList.toggle("active", b.getAttribute("data-tray") === state.config.tray_style);
  });
  document.querySelectorAll(".lang-opt").forEach((b) => {
    b.classList.toggle("active", b.getAttribute("data-lang") === state.config.lang);
  });
  document.querySelectorAll(".ctx-opt").forEach((b) => {
    b.classList.toggle("active", Number(b.getAttribute("data-ctx")) === Number(state.config.context_window_override || 0));
  });

  document.querySelectorAll(".scope-opt").forEach((b) => {
    b.classList.toggle("active", b.getAttribute("data-scope") === (state.config.project_scope || "all"));
  });

  document.getElementById("launcher-select").value = state.config.preferred_launcher || "auto";
  document.getElementById("snap-checkbox").checked = Boolean(state.config.snap_grid_enabled);
  document.getElementById("cost-checkbox").checked = state.config.show_cost_estimate !== false;
  setSelectWithCustom("hk-hud-select", state.config.hotkey_hud || "ctrl+alt+o");
  setSelectWithCustom("hk-density-select", state.config.hotkey_density || "off");
  setSelectWithCustom("hk-active-select", state.config.hotkey_active || "off");
  setSelectWithCustom("hk-mini-select", state.config.hotkey_mini || "off");
  updateHotkeyConflicts();
  document.getElementById("notify-done-checkbox").checked = state.config.notify_on_completion !== false;
  document.getElementById("notify-sound-checkbox").checked = Boolean(state.config.notify_sound);
  document.getElementById("notify-input-checkbox").checked = state.config.notify_on_needs_input !== false;
  document.getElementById("autostart-checkbox").checked = Boolean(state.config.launch_at_login);

  const customList = document.getElementById("custom-list");
  customList.innerHTML = (state.config.custom_agents || [])
    .map(
      (agent, idx) => `
      <div class="custom-item">
        <span>${agent.name}: <span class="mono">${agent.path}</span></span>
        <button class="tool-btn remove-custom-btn" data-idx="${idx}">✕</button>
      </div>`
    )
    .join("");
  customList.querySelectorAll(".remove-custom-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.config.custom_agents.splice(Number(btn.getAttribute("data-idx")), 1);
      syncSettingsUI();
      persistConfig();
    });
  });

  const folderList = document.getElementById("folder-list");
  folderList.innerHTML = (state.config.watched_folders || [])
    .map(
      (folder, idx) => `
      <div class="custom-item">
        <span class="mono">${folder}</span>
        <button class="tool-btn remove-folder-btn" data-idx="${idx}">✕</button>
      </div>`
    )
    .join("");
  folderList.querySelectorAll(".remove-folder-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      state.config.watched_folders.splice(Number(btn.getAttribute("data-idx")), 1);
      syncSettingsUI();
      persistConfig();
    });
  });
}

function parseCostUsd(display) {
  if (!display) return 0;
  const m = display.match(/(\d+(?:\.\d+)?)/);
  return m ? Number(m[1]) : 0;
}

function renderTaskChecklist(snap, cardId, nowSecs, dict) {
  const steps = snap.task_steps || [];
  if (!steps.length) return "";

  const total = steps.length;
  const done = steps.filter((st) => st.status === "done" || st.status === "skipped").length;
  const active = steps.find((st) => st.status === "in_progress");
  const pct = Math.round((done / total) * 100);
  const currentTitle = active
    ? active.title
    : done === total
      ? dict.allDone
      : steps[done]?.title || steps[0].title;

  let etaHtml = "";
  if (snap.active_since_epoch && done > 0 && done < total) {
    const elapsed = Math.max(1, nowSecs - snap.active_since_epoch);
    const estRemaining = Math.round((elapsed / done) * (total - done));
    if (estRemaining > 0) {
      etaHtml = `<span class="meta-item task-eta" title="Geschätzte Restzeit">${SVG.eta}~${fmtDuration(estRemaining)}</span>`;
    }
  }

  const expanded = effectiveDensity() === "detail" || state.expandedCards.has(cardId);
  const listHtml = expanded
    ? `<div class="task-steps-list">${steps
        .map((st) => {
          const ico =
            st.status === "done"
              ? SVG.checkDone
              : st.status === "in_progress"
                ? SVG.checkRun
                : SVG.checkPend;
          return `<div class="task-step-row ${st.status}">${ico}<span>${st.title.replace(/</g, "&lt;")}</span></div>`;
        })
        .join("")}</div>`
    : "";

  return `
    <div class="task-box">
      <button class="task-head" data-card-id="${cardId.replace(/"/g, "&quot;")}">
        <span class="task-head-left">
          ${done === total ? SVG.checkDone : SVG.checkRun}
          <span class="task-current">${currentTitle.replace(/</g, "&lt;")}</span>
        </span>
        <span class="task-head-right">
          ${etaHtml}
          <span>${done}/${total}</span>
        </span>
      </button>
      <div class="task-bar-track" title="Task-Fortschritt (Blau)">
        <div class="task-bar-fill" style="width:${pct}%"></div>
      </div>
      ${listHtml}
    </div>
  `;
}

function renderRecentActivity(snap) {
  const acts = snap.recent_activity || [];
  if (!acts.length) return "";
  const items = effectiveDensity() === "detail" ? acts : acts.slice(-2);
  return `
    <div class="activity-box">
      ${items
        .map((a) => `<div class="activity-row">${SVG.edit}<strong>${a.replace(/</g, "&lt;")}</strong></div>`)
        .join("")}
    </div>
  `;
}

// Updates ONLY live duration/countdown text spans every 1s — ZERO DOM rebuild, ZERO hover flicker!
function updateLiveTimestamps() {
  const nowSecs = Math.floor(Date.now() / 1000);
  document.querySelectorAll("[data-live-since]").forEach((el) => {
    const start = Number(el.getAttribute("data-live-since"));
    if (start) el.textContent = fmtDuration(nowSecs - start);
  });
  document.querySelectorAll("[data-live-updated]").forEach((el) => {
    const ts = Number(el.getAttribute("data-live-updated"));
    if (ts) el.textContent = fmtDuration(nowSecs - ts);
  });
  document.querySelectorAll("[data-live-reset]").forEach((el) => {
    const reset = Number(el.getAttribute("data-live-reset"));
    if (reset) el.textContent = fmtResetCountdown(reset);
  });
}

function render(force = false) {
  const list = document.getElementById("session-list");
  const orb = document.getElementById("status-orb");
  const orbRing = document.getElementById("status-ring");
  const badge = document.getElementById("live-badge");
  const headerSub = document.getElementById("header-sub");
  const filterBar = document.getElementById("filter-bar");
  const dict = I18N[resolvedLang()];

  const density = effectiveDensity();
  const colsCls = effectiveColsClass();
  document.getElementById("hud-shell").classList.toggle("is-minimal", density === "minimal" && !state.inSettings);
  list.className = `session-list density-${density} ${colsCls}`;
  filterBar.classList.toggle("hidden", density === "minimal");

  const waitingCount = state.snapshots.filter((s) => s.snapshot.state === "needs_input").length;
  const runningCount = state.snapshots.filter((s) => s.snapshot.state === "running").length;
  const idleCount = state.snapshots.filter((s) => s.snapshot.state === "idle").length;
  const totalCost = state.snapshots.reduce((acc, s) => acc + parseCostUsd(s.cost_display), 0);

  document.getElementById("cnt-all").textContent = String(state.snapshots.length);
  document.getElementById("cnt-active").textContent = String(runningCount + waitingCount);
  document.getElementById("cnt-input").textContent = String(waitingCount);
  document.getElementById("kpi-val-idle").textContent = String(idleCount);
  document.getElementById("kpi-val-cost").textContent =
    state.config.show_cost_estimate !== false && totalCost > 0
      ? `~$${totalCost < 10 ? totalCost.toFixed(2) : totalCost.toFixed(1)}`
      : "—";

  const globalState = waitingCount > 0 ? "needs_input" : runningCount > 0 ? "running" : "idle";
  orb.className = `orb ${globalState}`;
  orbRing.className = `orb-ring ${globalState}`;
  headerSub.textContent =
    runningCount + waitingCount > 0 ? dict.subActive(runningCount + waitingCount) : dict.subReady;

  if (waitingCount + runningCount > 0) {
    badge.className = `badge ${waitingCount > 0 ? "warn" : ""}`;
    badge.textContent = waitingCount > 0 ? `! ${waitingCount}` : `${runningCount}`;
  } else {
    badge.className = "badge hidden";
  }

  const nowSecs = Math.floor(Date.now() / 1000);
  // Track live running -> idle completions BEFORE filtering so "✓ Fertig" stays visible in Active mode!
  for (const item of state.snapshots) {
    const s = item.snapshot;
    const cid = `${s.agent_label}:${s.session_id}`;
    const prev = state.prevStates.get(cid);
    if (prev === "running" && s.state === "idle") {
      state.recentlyCompleted.set(cid, nowSecs);
    } else if (s.state === "running" || s.state === "needs_input") {
      state.recentlyCompleted.delete(cid);
    }
    state.prevStates.set(cid, s.state);
  }
  for (const [cid, ts] of state.recentlyCompleted.entries()) {
    if (nowSecs - ts > 300) state.recentlyCompleted.delete(cid);
  }

  const isRecentlyDoneCard = (s) => {
    if (s.state === "running" || s.state === "needs_input") return false;
    const cid = `${s.agent_label}:${s.session_id}`;
    if (state.recentlyCompleted.has(cid)) return true;
    const allDone =
      (s.task_steps || []).length > 0 &&
      s.task_steps.every((st) => st.status === "done" || st.status === "skipped");
    return Boolean(allDone && s.last_updated_epoch && nowSecs - s.last_updated_epoch < 300);
  };

  const scope = state.config.project_scope || "all";
  let visible = state.snapshots.filter((item) => {
    const s = item.snapshot;
    const st = s.state;
    if (state.filter === "needs_input") return st === "needs_input";
    if (state.filter === "active" || scope === "active") {
      return st === "running" || st === "needs_input" || isRecentlyDoneCard(s);
    }
    return true;
  });
  if (scope === "single" && visible.length > 1) {
    visible = [visible[0]];
  }

  // Skip DOM rebuild if nothing changed (prevents hover flicker!)
  const renderKey = JSON.stringify({
    d: density,
    f: state.filter,
    sc_mode: scope,
    l: resolvedLang(),
    c: state.config.context_window_override,
    sc: state.config.show_cost_estimate,
    exp: Array.from(state.expandedCards),
    doneIds: Array.from(state.recentlyCompleted.keys()),
    v: visible,
  });
  if (!force && renderKey === state.lastRenderKey) {
    updateLiveTimestamps();
    return;
  }
  state.lastRenderKey = renderKey;

  if (!visible.length) {
    list.innerHTML = `<div class="empty-state">${dict.empty}</div>`;
    fitWindowHeightToContent();
    return;
  }

  const showContextBar = Number(state.config.context_window_override || 0) >= 0;

  list.innerHTML = visible
    .map((item) => {
      const s = item.snapshot;
      const cardId = `${s.agent_label}:${s.session_id}`;
      const ab = agentBadgeMeta(s.agent_label);
      const isLive = s.state === "running" || s.state === "needs_input";
      const recentlyFinished = isRecentlyDoneCard(s);

      const stateIcon = recentlyFinished
        ? SVG.checkDone
        : s.state === "needs_input"
          ? SVG.alert
          : s.state === "running"
            ? `<span class="dots-spinner emerald"><i></i><i></i><i></i><i></i></span>`
            : SVG.moon;
      const statusText = recentlyFinished
        ? dict.done
        : s.interaction_reason || dict[s.state] || s.state;
      const pillCls = recentlyFinished ? "done-badge" : s.state;
      const cardExtraCls = recentlyFinished ? "recently-done" : "";

      const effortBadge = s.reasoning_effort
        ? `<span class="effort-badge">${s.reasoning_effort}</span>`
        : "";
      const branch = s.git_branch
        ? `<span class="extra-meta branch-badge">${SVG.branch}${s.git_branch}</span>`
        : "";
      const costBadge = item.cost_display ? `<span class="cost-badge">${item.cost_display}</span>` : "";
      const tokens = fmtTokens(s.usage?.session_total_tokens);

      const timeLabel = s.active_since_epoch
        ? `<span class="mono meta-item">${SVG.clock}<span data-live-since="${s.active_since_epoch}">${fmtDuration(nowSecs - s.active_since_epoch)}</span></span>`
        : s.last_updated_epoch
          ? `<span class="mono" data-live-updated="${s.last_updated_epoch}">${fmtDuration(nowSecs - s.last_updated_epoch)}</span>`
          : "";

      // Show checklist / live progress ONLY for active, waiting, or just-finished tasks
      const showLiveProgress = isLive || recentlyFinished;
      const taskHtml = showLiveProgress ? renderTaskChecklist(s, cardId, nowSecs, dict) : "";
      const activityHtml =
        showLiveProgress && (!taskHtml || density === "detail") ? renderRecentActivity(s) : "";

      // Meaningful 1-line summary for Minimal mode (active step, recent file, or Fertig)
      let miniTaskHtml = "";
      if (recentlyFinished) {
        miniTaskHtml = `<div class="mini-task-line" style="color:#4ade80"><span class="mini-task-text">✓ ${dict.done}</span></div>`;
      } else if (showLiveProgress && (s.task_steps || []).length > 0) {
        const total = s.task_steps.length;
        const done = s.task_steps.filter((st) => st.status === "done" || st.status === "skipped").length;
        const cur = s.task_steps.find((st) => st.status === "in_progress")?.title || (done === total ? dict.allDone : s.task_steps[0].title);
        miniTaskHtml = `<div class="mini-task-line"><span class="mini-task-text">${cur.replace(/</g, "&lt;")}</span><span class="mono">${done}/${total}</span></div>`;
      } else if (showLiveProgress && (s.recent_activity || []).length > 0) {
        const lastAct = s.recent_activity[s.recent_activity.length - 1];
        miniTaskHtml = `<div class="mini-task-line"><span class="mini-task-text">${lastAct.replace(/</g, "&lt;")}</span></div>`;
      }

      let barHtml = "";
      if (showContextBar && s.usage?.context_tokens && s.usage?.context_window > 0) {
        const windowCap =
          Number(state.config.context_window_override) > 0
            ? Number(state.config.context_window_override)
            : s.usage.context_window;
        const pct = Math.min(100, Math.round((s.usage.context_tokens / windowCap) * 100));
        const colorCls = pct >= 85 ? "high" : pct >= 65 ? "warn" : "";
        barHtml = `
          <div class="bar-wrap" title="${dict.ctxTip}">
            <div class="bar-meta">
              <span>${dict.ctx}</span>
              <span class="mono">${pct}% · ${fmtTokens(s.usage.context_tokens)} / ${fmtTokens(windowCap)}</span>
            </div>
            <div class="bar-track">
              <div class="bar-fill ${colorCls}" style="width:${pct}%"></div>
            </div>
          </div>`;
      }

      // Detail Rings: real provider rate-limits + deduplicated Day / Week / Month usage rings
      const limits = [];
      if (s.usage?.primary_limit) limits.push(ringSvg(s.usage.primary_limit, dict));
      if (s.usage?.secondary_limit) limits.push(ringSvg(s.usage.secondary_limit, dict));
      const period = computePeriodUsage(state.snapshots, s.agent_label, nowSecs);
      if (period.dayTok > 0) {
        const p = Math.min(100, Math.round((period.dayTok / 2_000_000) * 100));
        limits.push(circularUsageRing(Math.max(8, p), dict.day, fmtTokens(period.dayTok), "#64d2ff"));
      }
      if (period.weekTok > period.dayTok) {
        const p = Math.min(100, Math.round((period.weekTok / 10_000_000) * 100));
        limits.push(circularUsageRing(Math.max(8, p), dict.week, fmtTokens(period.weekTok), "#bf5af2"));
      }
      if (period.monthTok > period.weekTok) {
        const p = Math.min(100, Math.round((period.monthTok / 40_000_000) * 100));
        limits.push(circularUsageRing(Math.max(8, p), dict.month, fmtTokens(period.monthTok), "#818cf8"));
      }

      const tokParts = [];
      if (s.usage?.input_tokens) tokParts.push(`In ${fmtTokens(s.usage.input_tokens)}`);
      if (s.usage?.cache_read_tokens) tokParts.push(`Cache ${fmtTokens(s.usage.cache_read_tokens)}`);
      if (s.usage?.output_tokens) tokParts.push(`Out ${fmtTokens(s.usage.output_tokens)}`);
      const tokLine = tokParts.length ? tokParts.join(" · ") : tokens ? `Total ${tokens} tok` : "";

      const planBadge = s.usage?.plan_type ? `<span class="plan-badge">${s.usage.plan_type}</span>` : "";
      const ideBadge = `<span class="ide-badge">${SVG.app}${agentIdeDisplay(s.agent_label)}</span>`;

      const pathAttr = s.project_path ? s.project_path.replace(/"/g, "&quot;") : "";
      return `
        <article class="card ${s.state} ${cardExtraCls}" data-path="${pathAttr}">
          <div class="card-header">
            <div class="agent-badge ${ab.cls}" title="${s.agent_label}">${ab.code}</div>
            <div class="card-title-wrap">
              <div class="card-top">
                <button class="project-btn" data-path="${pathAttr}" title="${pathAttr || s.project_name}">
                  ${s.project_name}
                </button>
                <span class="pill ${pillCls}">${stateIcon}${statusText}</span>
              </div>
              <div class="meta">
                <span class="model-badge ${modelBadgeClass(s.model_name)}" title="${s.model_name}">${s.model_name}</span>
                ${effortBadge}
                ${branch}
                ${timeLabel}
              </div>
            </div>
          </div>
          ${miniTaskHtml}
          ${taskHtml}
          ${activityHtml}
          ${barHtml}
          <div class="detail-panel">
            <div class="detail-badges">
              ${ideBadge}
              ${planBadge}
              ${costBadge}
            </div>
            ${tokLine ? `<div class="tok-breakdown">${tokLine}</div>` : ""}
            ${limits.length ? `<div class="limits-row">${limits.join("")}</div>` : ""}
          </div>
        </article>
      `;
    })
    .join("");

  list.querySelectorAll(".project-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const p = btn.getAttribute("data-path");
      if (p && tauri?.core) tauri.core.invoke("open_project", { path: p, target: null }).catch(() => {});
    });
  });

  list.querySelectorAll(".task-head").forEach((btn) => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-card-id");
      if (!id) return;
      if (state.expandedCards.has(id)) state.expandedCards.delete(id);
      else state.expandedCards.add(id);
      render(true);
    });
  });

  const menu = document.getElementById("context-menu");
  list.querySelectorAll(".card").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const rect = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${(e.clientX - rect.left).toFixed(0)}px`);
      card.style.setProperty("--my", `${(e.clientY - rect.top).toFixed(0)}px`);
    });
    card.addEventListener("contextmenu", (e) => {
      const p = card.getAttribute("data-path");
      if (!p) return;
      e.preventDefault();
      state.contextPath = p;
      menu.style.left = `${Math.min(e.clientX, window.innerWidth - 152)}px`;
      menu.style.top = `${Math.min(e.clientY, window.innerHeight - 145)}px`;
      menu.classList.remove("hidden");
    });
  });

  fitWindowHeightToContent();
}

document.querySelectorAll("#context-menu button").forEach((btn) => {
  btn.addEventListener("click", () => {
    const target = btn.getAttribute("data-target");
    if (state.contextPath && tauri?.core) {
      tauri.core.invoke("open_project", { path: state.contextPath, target }).catch(() => {});
    }
    document.getElementById("context-menu").classList.add("hidden");
  });
});
window.addEventListener("click", () => {
  document.getElementById("context-menu").classList.add("hidden");
});

async function init() {
  if (tauri?.core) {
    try {
      const ver = await tauri.core.invoke("get_app_version");
      if (ver) {
        const tag = document.getElementById("version-tag");
        if (tag) tag.textContent = `AgentOrbit v${ver}`;
      }
    } catch {}
    try {
      const loaded = await tauri.core.invoke("get_config");
      if (loaded) state.config = { ...state.config, ...loaded };
    } catch {}
  }
  syncSettingsUI();
  await refreshNow();
}

async function refreshNow() {
  if (!tauri?.core) return;
  try {
    state.snapshots = await tauri.core.invoke("scan_sessions");
    render(true);
  } catch (err) {
    console.error("scan_sessions failed:", err);
  }
}

function setFilter(next) {
  state.filter = next;
  document.querySelectorAll(".filter-opt").forEach((c) => {
    c.classList.toggle("active", c.getAttribute("data-filter") === next);
  });
  render(true);
}

function setDensity(next, shouldResize = false) {
  state.config.density = next;
  syncSettingsUI();
  persistConfig();
  if (shouldResize && !state.inSettings) {
    applyAutoSize(next);
  }
  render(true);
}

function cycleDensity() {
  const order = ["minimal", "compact", "detail"];
  setDensity(order[(order.indexOf(state.config.density) + 1) % order.length], true);
}

// Settings tabs
document.querySelectorAll(".tab-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    const tab = btn.getAttribute("data-tab");
    document.querySelectorAll(".tab-btn").forEach((b) => b.classList.toggle("active", b === btn));
    for (const id of ["display", "agents", "folders"]) {
      document.getElementById(`tab-${id}`).classList.toggle("hidden", id !== tab);
    }
  });
});

function toggleExpandHud() {
  if (state.inSettings) openSettings(false);
  const isWide = window.innerWidth >= 660;
  if (isWide) {
    setDensity("compact", true);
    document.getElementById("autosize-btn").classList.remove("active");
  } else {
    state.config.density = "detail";
    syncSettingsUI();
    persistConfig();
    applyAutoSize("expanded");
    document.getElementById("autosize-btn").classList.add("active");
    render(true);
  }
}

// Toolbar & Settings buttons
document.getElementById("settings-btn").addEventListener("click", () => openSettings(!state.inSettings));
document.getElementById("settings-done-btn").addEventListener("click", () => openSettings(false));
document.getElementById("autosize-btn").addEventListener("click", toggleExpandHud);
document.getElementById("settings-autosize-btn").addEventListener("click", () => {
  openSettings(false);
  applyAutoSize();
});
document.getElementById("refresh-btn").addEventListener("click", refreshNow);
document.getElementById("hide-btn").addEventListener("click", () => {
  if (tauri?.core) tauri.core.invoke("toggle_hud_visibility").catch(() => {});
});

// Filter & Setting Segmented Controls
document.querySelectorAll(".filter-opt").forEach((b) => {
  b.addEventListener("click", () => setFilter(b.getAttribute("data-filter") || "all"));
});
document.querySelectorAll(".density-opt, .quick-density").forEach((b) => {
  b.addEventListener("click", () => {
    const target = b.getAttribute("data-density") || "compact";
    if (target === "minimal" && state.config.density !== "minimal") {
      toggleMiniPreview();
    } else {
      state.savedBeforeMini = null;
      setDensity(target, true);
    }
  });
});
document.querySelectorAll(".tray-opt").forEach((b) => {
  b.addEventListener("click", () => {
    state.config.tray_style = b.getAttribute("data-tray") || "project";
    syncSettingsUI();
    persistConfig();
  });
});
document.querySelectorAll(".lang-opt").forEach((b) => {
  b.addEventListener("click", () => {
    state.config.lang = b.getAttribute("data-lang") || "auto";
    syncSettingsUI();
    persistConfig();
    render(true);
  });
});
document.querySelectorAll(".ctx-opt").forEach((b) => {
  b.addEventListener("click", () => {
    state.config.context_window_override = Number(b.getAttribute("data-ctx")) || 0;
    syncSettingsUI();
    persistConfig();
    render(true);
  });
});

document.getElementById("opacity-slider").addEventListener("input", (e) => applyOpacity(e.target.value));
document.getElementById("opacity-slider").addEventListener("change", persistConfig);

document.querySelectorAll(".scope-opt").forEach((b) => {
  b.addEventListener("click", () => {
    state.config.project_scope = b.getAttribute("data-scope") || "all";
    state.config.show_all_active_projects = state.config.project_scope !== "single";
    if (state.config.project_scope === "active") {
      setFilter("active");
    } else if (state.filter === "active") {
      setFilter("all");
    }
    syncSettingsUI();
    persistConfig();
    render(true);
  });
});

document.getElementById("launcher-select").addEventListener("change", (e) => {
  state.config.preferred_launcher = e.target.value;
  persistConfig();
});
document.getElementById("snap-checkbox").addEventListener("change", (e) => {
  state.config.snap_grid_enabled = e.target.checked;
  persistConfig();
});
document.getElementById("cost-checkbox").addEventListener("change", (e) => {
  state.config.show_cost_estimate = e.target.checked;
  persistConfig();
  render(true);
});

for (const [id, key] of [
  ["hk-hud-select", "hotkey_hud"],
  ["hk-density-select", "hotkey_density"],
  ["hk-active-select", "hotkey_active"],
  ["hk-mini-select", "hotkey_mini"],
]) {
  document.getElementById(id).addEventListener("change", (e) => {
    state.config[key] = e.target.value;
    updateHotkeyConflicts();
    persistConfig();
  });
}

document.querySelectorAll(".rec-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    const field = btn.getAttribute("data-hk");
    if (state.recordingHotkey === field) {
      state.recordingHotkey = null;
      btn.classList.remove("recording");
      btn.textContent = "Aufnehmen";
      return;
    }
    state.recordingHotkey = field;
    document.querySelectorAll(".rec-btn").forEach((b) => {
      const active = b === btn;
      b.classList.toggle("recording", active);
      b.textContent = active ? "Drücke…" : "Aufnehmen";
    });
  });
});

document.getElementById("notify-done-checkbox").addEventListener("change", (e) => {
  state.config.notify_on_completion = e.target.checked;
  persistConfig();
});
document.getElementById("notify-sound-checkbox").addEventListener("change", (e) => {
  state.config.notify_sound = e.target.checked;
  persistConfig();
});
document.getElementById("notify-input-checkbox").addEventListener("change", (e) => {
  state.config.notify_on_needs_input = e.target.checked;
  persistConfig();
});
document.getElementById("autostart-checkbox").addEventListener("change", (e) => {
  state.config.launch_at_login = e.target.checked;
  persistConfig();
});

document.getElementById("add-custom-btn").addEventListener("click", () => {
  const nameEl = document.getElementById("custom-name");
  const pathEl = document.getElementById("custom-path");
  const name = nameEl.value.trim();
  const path = pathEl.value.trim();
  if (!name || !path) return;
  state.config.custom_agents = state.config.custom_agents || [];
  state.config.custom_agents.push({ name, path, is_enabled: true });
  nameEl.value = "";
  pathEl.value = "";
  syncSettingsUI();
  persistConfig();
});

document.getElementById("add-folder-btn").addEventListener("click", () => {
  const el = document.getElementById("folder-path");
  const p = el.value.trim();
  if (!p) return;
  state.config.watched_folders = state.config.watched_folders || [];
  state.config.watched_folders.push(p);
  el.value = "";
  syncSettingsUI();
  persistConfig();
});

// Reliable native window dragging across macOS / Linux / Windows + 24pt Snap-Grid on release
document.getElementById("hud-header").addEventListener("mousedown", (e) => {
  if (e.button !== 0) return;
  if (e.target && e.target.closest("button, input, select, .controls")) return;
  if (tauri?.window?.getCurrentWindow) {
    tauri.window.getCurrentWindow().startDragging().catch(() => {});
  }
});
document.getElementById("hud-header").addEventListener("mouseup", (e) => {
  if (state.config.snap_grid_enabled && !e.altKey && tauri?.core) {
    setTimeout(() => tauri.core.invoke("snap_hud_to_grid").catch(() => {}), 80);
  }
});

window.addEventListener("keydown", (e) => {
  if (state.recordingHotkey) {
    e.preventDefault();
    e.stopPropagation();
    if (e.key === "Escape") {
      state.recordingHotkey = null;
      document.querySelectorAll(".rec-btn").forEach((b) => {
        b.classList.remove("recording");
        b.textContent = "Aufnehmen";
      });
      return;
    }
    if (["Control", "Alt", "Shift", "Meta"].includes(e.key)) return;
    const mods = [];
    if (e.ctrlKey) mods.push("ctrl");
    if (e.altKey) mods.push("alt");
    if (e.shiftKey) mods.push("shift");
    if (e.metaKey) mods.push("cmd");
    // macOS rejects Shift-only global hotkeys (needed for typing uppercase letters)
    const hasPrimaryMod = e.ctrlKey || e.altKey || e.metaKey;
    if (!hasPrimaryMod) {
      const banner = document.getElementById("hk-conflict-banner");
      banner.textContent = "ℹ Bitte ⌃, ⌥ oder ⌘ als Modifier mitdrücken (Shift allein wird von macOS blockiert)";
      banner.classList.remove("hidden");
      return;
    }
    let physKey = "";
    if (e.code === "Space") physKey = "space";
    else if (e.code && e.code.startsWith("Key")) physKey = e.code.slice(3).toLowerCase();
    else if (e.code && e.code.startsWith("Digit")) physKey = e.code.slice(5);
    else if (e.code && /^F\d{1,2}$/.test(e.code)) physKey = e.code.toLowerCase();
    else physKey = e.key.toLowerCase();

    const field = state.recordingHotkey;
    // Determine visible label according to the active keyboard layout (QWERTZ/QWERTY/external)
    let layoutLabel = physKey === "space" ? "Space" : physKey.toUpperCase();
    if (e.key && e.key.length === 1 && /^[a-zA-Z0-9]$/.test(e.key)) {
      layoutLabel = e.key.toUpperCase();
    } else if (e.altKey) {
      // On macOS WKWebView, Option+Letter yields composed chars (e.g. ¥ / Á for Y on German QWERTZ).
      const isGermanLayout =
        (navigator.language || "").toLowerCase().startsWith("de") ||
        ["¥", "Á", "á", "Ÿ", "ÿ"].includes(e.key);
      if (isGermanLayout && physKey === "z") layoutLabel = "Y";
      else if (isGermanLayout && physKey === "y") layoutLabel = "Z";
    }

    const baseSpec = normalizeHotkeySpec([...mods, physKey].join("+"));
    const spec =
      baseSpec !== "off" && layoutLabel.toLowerCase() !== physKey
        ? `${baseSpec}|${layoutLabel}`
        : baseSpec;
    if (baseSpec !== "off") {
      state.config[field] = spec;
      state.recordingHotkey = null;
      document.querySelectorAll(".rec-btn").forEach((b) => {
        b.classList.remove("recording");
        b.textContent = "Aufnehmen";
      });
      syncSettingsUI();
      persistConfig();
    }
    return;
  }
  if (e.target && ["INPUT", "SELECT", "TEXTAREA"].includes(e.target.tagName)) {
    if (e.key === "Escape" && state.inSettings) openSettings(false);
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "r") {
    e.preventDefault();
    refreshNow();
  } else if (e.key === "Escape" && state.inSettings) {
    openSettings(false);
  } else if (!state.inSettings && e.key === "1") {
    setFilter("all");
  } else if (!state.inSettings && e.key === "2") {
    setFilter("active");
  } else if (!state.inSettings && e.key === "3") {
    setFilter("needs_input");
  } else if (!state.inSettings && e.key.toLowerCase() === "m") {
    toggleMiniPreview();
  } else if (!state.inSettings && e.key.toLowerCase() === "k") {
    setDensity("compact", true);
  } else if (!state.inSettings && e.key.toLowerCase() === "d") {
    setDensity("detail", true);
  }
});

window.addEventListener("resize", () => render(true));
window.addEventListener("focus", () => refreshNow());
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refreshNow();
});

if (tauri?.event) {
  tauri.event.listen("agentorbit://snapshots", (event) => {
    if (Array.isArray(event.payload)) {
      state.snapshots = event.payload;
      render(false);
    }
  });
  tauri.event.listen("agentorbit://cycle-density", cycleDensity);
  tauri.event.listen("agentorbit://filter-active", () => {
    const order = ["single", "active", "all"];
    const cur = state.config.project_scope || "all";
    const next = order[(order.indexOf(cur) + 1) % order.length];
    state.config.project_scope = next;
    state.config.show_all_active_projects = next !== "single";
    if (next === "active") {
      setFilter("active");
    } else if (state.filter === "active") {
      setFilter("all");
    }
    syncSettingsUI();
    persistConfig();
    render(true);
  });
  tauri.event.listen("agentorbit://toggle-mini", toggleMiniPreview);
}

// 1-second timer updates ONLY live text spans (no DOM rebuild = 0 hover flicker!)
setInterval(updateLiveTimestamps, 1000);
init();
