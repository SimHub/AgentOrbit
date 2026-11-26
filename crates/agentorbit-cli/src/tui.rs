use agentorbit_core::{
    default_config_path, estimate_cost, load_config_from, now_epoch_secs, scan_agents_with_config,
    watch_paths_for, AgentRunState, AgentSnapshot, OrbitConfig, OrbitWatcher, TaskStepStatus,
};
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
    MouseButton, MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Padding, Paragraph};
use ratatui::{Frame, Terminal};
use std::collections::HashMap;
use std::io;
use std::process::Command;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

// TrueColor palette matching the AgentOrbit macOS Glass HUD
const BG_CANVAS: Color = Color::Rgb(11, 15, 22);
const BG_CARD: Color = Color::Rgb(18, 24, 34);
const BG_CARD_SELECTED: Color = Color::Rgb(24, 34, 50);
const BG_PILL_DARK: Color = Color::Rgb(26, 33, 46);
const BORDER_SUBTLE: Color = Color::Rgb(42, 52, 68);
const BORDER_SELECTED: Color = Color::Rgb(56, 152, 255);
const ACCENT_BLUE: Color = Color::Rgb(10, 132, 255);
const ACCENT_CYAN: Color = Color::Rgb(100, 210, 255);
const ACCENT_EMERALD: Color = Color::Rgb(48, 209, 88);
const ACCENT_AMBER: Color = Color::Rgb(255, 159, 10);
const ACCENT_CORAL: Color = Color::Rgb(255, 107, 107);
const ACCENT_PURPLE: Color = Color::Rgb(191, 90, 242);
const TEXT_PRIMARY: Color = Color::Rgb(236, 242, 250);
const TEXT_MUTED: Color = Color::Rgb(132, 146, 166);
const TEXT_DIM: Color = Color::Rgb(86, 98, 118);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScopeMode {
    Single,
    Active,
    All,
}

impl ScopeMode {
    fn from_str(s: &str) -> Self {
        match s {
            "single" => Self::Single,
            "active" => Self::Active,
            _ => Self::All,
        }
    }

    fn next(self) -> Self {
        match self {
            Self::Single => Self::Active,
            Self::Active => Self::All,
            Self::All => Self::Single,
        }
    }

    fn label(self, is_de: bool) -> &'static str {
        match (self, is_de) {
            (Self::Single, true) => "Einzeln",
            (Self::Active, true) => "Aktive",
            (Self::All, true) => "Alle",
            (Self::Single, false) => "Single",
            (Self::Active, false) => "Active",
            (Self::All, false) => "All",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FilterMode {
    All,
    Active,
    NeedsInput,
}

impl FilterMode {
    fn next(self) -> Self {
        match self {
            Self::All => Self::Active,
            Self::Active => Self::NeedsInput,
            Self::NeedsInput => Self::All,
        }
    }

    fn label(self, is_de: bool) -> &'static str {
        match (self, is_de) {
            (Self::All, true) => "Alle",
            (Self::Active, true) => "Aktiv",
            (Self::NeedsInput, true) => "Eingabe",
            (Self::All, false) => "All",
            (Self::Active, false) => "Active",
            (Self::NeedsInput, false) => "Input",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DensityMode {
    Minimal,
    Compact,
    Detail,
}

impl DensityMode {
    fn from_str(s: &str) -> Self {
        match s {
            "minimal" => Self::Minimal,
            "detail" => Self::Detail,
            _ => Self::Compact,
        }
    }
}

struct TuiState {
    snapshots: Vec<AgentSnapshot>,
    config: OrbitConfig,
    scope: ScopeMode,
    filter: FilterMode,
    density: DensityMode,
    selected: usize,
    scroll_offset: usize,
    grid_cols: usize,
    card_rects: Vec<(Rect, usize)>,
    btn_scope: Option<Rect>,
    btn_m: Option<Rect>,
    btn_k: Option<Rect>,
    btn_d: Option<Rect>,
    last_click: Option<(usize, Instant)>,
    pending_g: bool,
    search_mode: bool,
    search_query: String,
    prev_states: HashMap<String, AgentRunState>,
    active_since: HashMap<String, i64>,
    recently_done: HashMap<String, i64>,
    tick: usize,
    status_hint: String,
}

impl TuiState {
    fn new(snapshots: Vec<AgentSnapshot>, config: OrbitConfig) -> Self {
        let now = now_epoch_secs();
        let prev_states = snapshots.iter().map(|s| (s.id(), s.state)).collect();
        let active_since = snapshots
            .iter()
            .filter(|s| s.state.is_active_or_waiting())
            .map(|s| (s.id(), s.active_since_epoch.unwrap_or(now)))
            .collect();
        let scope = ScopeMode::from_str(&config.project_scope);
        let density = DensityMode::from_str(&config.density);
        Self {
            snapshots,
            config,
            scope,
            filter: FilterMode::All,
            density,
            selected: 0,
            scroll_offset: 0,
            grid_cols: 1,
            card_rects: Vec::new(),
            btn_scope: None,
            btn_m: None,
            btn_k: None,
            btn_d: None,
            last_click: None,
            pending_g: false,
            search_mode: false,
            search_query: String::new(),
            prev_states,
            active_since,
            recently_done: HashMap::new(),
            tick: 0,
            status_hint: "Live".to_string(),
        }
    }

    fn is_de(&self) -> bool {
        match self.config.lang.as_str() {
            "en" => false,
            "de" => true,
            _ => std::env::var("LANG")
                .map(|l| l.to_lowercase().starts_with("de"))
                .unwrap_or(true),
        }
    }

    fn update_snapshots(&mut self, updated: Vec<AgentSnapshot>) {
        let now = now_epoch_secs();
        for s in &updated {
            let id = s.id();
            if s.state.is_active_or_waiting() {
                self.active_since
                    .entry(id.clone())
                    .or_insert_with(|| s.active_since_epoch.unwrap_or(now));
                self.recently_done.remove(&id);
            } else {
                self.active_since.remove(&id);
                if let Some(prev) = self.prev_states.get(&id) {
                    if *prev == AgentRunState::Running && s.state == AgentRunState::Idle {
                        self.recently_done.insert(id.clone(), now);
                    }
                }
            }
            self.prev_states.insert(id, s.state);
        }
        self.recently_done.retain(|_, ts| now - *ts <= 300);
        self.snapshots = updated;
        self.clamp_selection();
    }

    fn is_recently_done(&self, s: &AgentSnapshot, now: i64) -> bool {
        if s.state.is_active_or_waiting() {
            return false;
        }
        if self.recently_done.contains_key(&s.id()) {
            return true;
        }
        let all_done = !s.task_steps.is_empty()
            && s.task_steps
                .iter()
                .all(|st| matches!(st.status, TaskStepStatus::Done | TaskStepStatus::Skipped));
        all_done && s.last_updated_epoch.is_some_and(|ts| now - ts < 300)
    }

    fn filtered(&self) -> Vec<&AgentSnapshot> {
        let now = now_epoch_secs();
        let q = self.search_query.trim().to_lowercase();
        let mut list: Vec<&AgentSnapshot> = self
            .snapshots
            .iter()
            .filter(|s| {
                let done_recent = self.is_recently_done(s, now);
                if self.filter == FilterMode::NeedsInput && s.state != AgentRunState::NeedsInput {
                    return false;
                }
                if (self.filter == FilterMode::Active || self.scope == ScopeMode::Active)
                    && !(s.state.is_active_or_waiting() || done_recent)
                {
                    return false;
                }
                if !q.is_empty() {
                    let hay = format!(
                        "{} {} {} {}",
                        s.project_name,
                        s.agent_label,
                        s.model_name,
                        s.git_branch.as_deref().unwrap_or("")
                    )
                    .to_lowercase();
                    if !hay.contains(&q) {
                        return false;
                    }
                }
                true
            })
            .collect();
        if self.scope == ScopeMode::Single && list.len() > 1 {
            list.truncate(1);
        }
        list
    }

    fn clamp_selection(&mut self) {
        let len = self.filtered().len();
        if len == 0 {
            self.selected = 0;
            self.scroll_offset = 0;
        } else if self.selected >= len {
            self.selected = len - 1;
        }
    }

    fn select_next(&mut self) {
        let len = self.filtered().len();
        if len == 0 {
            return;
        }
        self.selected = (self.selected + 1) % len;
    }

    fn select_prev(&mut self) {
        let len = self.filtered().len();
        if len == 0 {
            return;
        }
        self.selected = if self.selected == 0 {
            len - 1
        } else {
            self.selected - 1
        };
    }

    fn select_down_row(&mut self) {
        let len = self.filtered().len();
        if len == 0 {
            return;
        }
        let step = self.grid_cols.max(1);
        if self.selected + step < len {
            self.selected += step;
        } else {
            self.selected = (self.selected + 1) % len;
        }
    }

    fn select_up_row(&mut self) {
        let len = self.filtered().len();
        if len == 0 {
            return;
        }
        let step = self.grid_cols.max(1);
        if self.selected >= step {
            self.selected -= step;
        } else if self.selected > 0 {
            self.selected -= 1;
        } else {
            self.selected = len - 1;
        }
    }

    fn select_first(&mut self) {
        self.selected = 0;
        self.scroll_offset = 0;
    }

    fn select_last(&mut self) {
        let len = self.filtered().len();
        if len > 0 {
            self.selected = len - 1;
        }
    }

    fn page_down(&mut self) {
        let len = self.filtered().len();
        if len == 0 {
            return;
        }
        let jump = (self.grid_cols * 2).max(2);
        self.selected = (self.selected + jump).min(len - 1);
    }

    fn page_up(&mut self) {
        let jump = (self.grid_cols * 2).max(2);
        self.selected = self.selected.saturating_sub(jump);
    }

    fn selected_snapshot(&self) -> Option<&AgentSnapshot> {
        let visible = self.filtered();
        visible.get(self.selected).copied()
    }
}

pub fn run_tui() -> io::Result<()> {
    let config = load_config_from(&default_config_path());
    let (discovered, initial) = scan_agents_with_config(&config, 12);
    let watch_paths = watch_paths_for(&discovered);

    let (tx, rx) = mpsc::channel::<()>();
    thread::spawn(move || {
        if let Ok(mut watcher) = OrbitWatcher::start(&watch_paths, Duration::from_millis(250)) {
            loop {
                if watcher.wait_for_change(Duration::from_secs(2)) {
                    let _ = tx.send(());
                }
            }
        }
    });

    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = TuiState::new(initial, config);
    let mut last_refresh = Instant::now();

    let result = loop {
        app.tick = app.tick.wrapping_add(1);
        terminal.draw(|f| draw_ui(f, &mut app))?;

        let mut needs_refresh = false;
        while rx.try_recv().is_ok() {
            needs_refresh = true;
        }
        if last_refresh.elapsed() >= Duration::from_secs(2) {
            needs_refresh = true;
            last_refresh = Instant::now();
        }

        if needs_refresh {
            app.config = load_config_from(&default_config_path());
            let (_, updated) = scan_agents_with_config(&app.config, 12);
            app.update_snapshots(updated);
        }

        if event::poll(Duration::from_millis(100))? {
            let is_de = app.is_de();
            match event::read()? {
                Event::Key(key) => {
                    if key.kind != KeyEventKind::Press {
                        continue;
                    }
                    // Neovim-style `/` live search mode
                    if app.search_mode {
                        match key.code {
                            KeyCode::Esc => {
                                app.search_mode = false;
                                app.search_query.clear();
                                app.clamp_selection();
                            }
                            KeyCode::Enter => {
                                app.search_mode = false;
                                app.clamp_selection();
                            }
                            KeyCode::Backspace => {
                                app.search_query.pop();
                                app.clamp_selection();
                            }
                            KeyCode::Char(ch) => {
                                app.search_query.push(ch);
                                app.clamp_selection();
                            }
                            _ => {}
                        }
                        continue;
                    }

                    // Neovim `gg` (jump to top)
                    if app.pending_g {
                        app.pending_g = false;
                        if key.code == KeyCode::Char('g') {
                            app.select_first();
                            continue;
                        }
                    }

                    // Neovim `Ctrl+d` / `Ctrl+u` half-page jump
                    if key.modifiers.contains(KeyModifiers::CONTROL) {
                        match key.code {
                            KeyCode::Char('d') => {
                                app.page_down();
                                continue;
                            }
                            KeyCode::Char('u') => {
                                app.page_up();
                                continue;
                            }
                            KeyCode::Char('c') => break Ok(()),
                            _ => {}
                        }
                    }

                    match key.code {
                        KeyCode::Char('q') => break Ok(()),
                        KeyCode::Esc => {
                            if !app.search_query.is_empty() {
                                app.search_query.clear();
                                app.clamp_selection();
                            } else {
                                break Ok(());
                            }
                        }
                        KeyCode::Char('/') => {
                            app.search_mode = true;
                        }
                        KeyCode::Char('g') => {
                            app.pending_g = true;
                        }
                        KeyCode::Char('G') => app.select_last(),
                        KeyCode::Down | KeyCode::Char('j') => app.select_down_row(),
                        KeyCode::Up | KeyCode::Char('k') => app.select_up_row(),
                        KeyCode::Right | KeyCode::Char('l') | KeyCode::Tab => app.select_next(),
                        KeyCode::Left | KeyCode::Char('h') | KeyCode::BackTab => app.select_prev(),
                        KeyCode::Char('1') => {
                            app.filter = FilterMode::All;
                            app.clamp_selection();
                        }
                        KeyCode::Char('2') => {
                            app.filter = FilterMode::Active;
                            app.clamp_selection();
                        }
                        KeyCode::Char('3') => {
                            app.filter = FilterMode::NeedsInput;
                            app.clamp_selection();
                        }
                        KeyCode::Char('a') => {
                            app.scope = app.scope.next();
                            app.clamp_selection();
                            app.status_hint = format!("Scope: {}", app.scope.label(is_de));
                        }
                        KeyCode::Char('f') => {
                            app.filter = app.filter.next();
                            app.clamp_selection();
                            app.status_hint = format!("Filter: {}", app.filter.label(is_de));
                        }
                        KeyCode::Char('m') => app.density = DensityMode::Minimal,
                        KeyCode::Char('c') => app.density = DensityMode::Compact,
                        KeyCode::Char('d') => app.density = DensityMode::Detail,
                        KeyCode::Char('r') => {
                            app.config = load_config_from(&default_config_path());
                            let (_, updated) = scan_agents_with_config(&app.config, 12);
                            app.update_snapshots(updated);
                            app.status_hint =
                                if is_de { "Aktualisiert" } else { "Refreshed" }.to_string();
                        }
                        KeyCode::Enter | KeyCode::Char('o') | KeyCode::Char(' ') => {
                            if let Some(sel) = app.selected_snapshot() {
                                if let Some(ref path) = sel.project_path {
                                    open_project_os(path, &app.config.preferred_launcher);
                                    app.status_hint = format!("Open: {}", sel.project_name);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Event::Mouse(mouse) => match mouse.kind {
                    MouseEventKind::ScrollDown => app.select_next(),
                    MouseEventKind::ScrollUp => app.select_prev(),
                    MouseEventKind::Down(MouseButton::Left) => {
                        let x = mouse.column;
                        let y = mouse.row;
                        if hit_rect(app.btn_m, x, y) {
                            app.density = DensityMode::Minimal;
                        } else if hit_rect(app.btn_k, x, y) {
                            app.density = DensityMode::Compact;
                        } else if hit_rect(app.btn_d, x, y) {
                            app.density = DensityMode::Detail;
                        } else if hit_rect(app.btn_scope, x, y) {
                            app.scope = app.scope.next();
                            app.clamp_selection();
                            app.status_hint = format!("Scope: {}", app.scope.label(is_de));
                        } else if let Some(&(_, idx)) =
                            app.card_rects.iter().find(|(r, _)| hit_rect(Some(*r), x, y))
                        {
                            let is_double = app
                                .last_click
                                .is_some_and(|(prev_idx, t)| prev_idx == idx && t.elapsed() < Duration::from_millis(500));
                            app.selected = idx;
                            app.last_click = Some((idx, Instant::now()));
                            if is_double {
                                if let Some(sel) = app.selected_snapshot() {
                                    if let Some(ref path) = sel.project_path {
                                        open_project_os(path, &app.config.preferred_launcher);
                                        app.status_hint = format!("Open: {}", sel.project_name);
                                    }
                                }
                            }
                        }
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    };

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    terminal.show_cursor()?;
    result
}

fn hit_rect(rect: Option<Rect>, x: u16, y: u16) -> bool {
    rect.is_some_and(|r| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
}

fn draw_ui(f: &mut Frame, app: &mut TuiState) {
    let area = f.area();
    // Paint full obsidian canvas so the TUI feels like a cohesive macOS Glass HUD
    f.render_widget(Block::default().style(Style::default().bg(BG_CANVAS)), area);

    let inspector_h = match app.density {
        DensityMode::Minimal => 0,
        DensityMode::Compact => 7,
        DensityMode::Detail => 9,
    };

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),           // Top HUD Header + M|K|D + KPIs
            Constraint::Min(6),              // Rounded Session Cards Grid
            Constraint::Length(inspector_h), // Selected Session Inspector
            Constraint::Length(1),           // Keybind Footer
        ])
        .split(area);

    draw_hud_header(f, app, chunks[0]);
    draw_session_cards(f, app, chunks[1]);
    if inspector_h > 0 {
        draw_inspector_panel(f, app, chunks[2]);
    }
    draw_footer(f, app, chunks[3]);
}

fn draw_hud_header(f: &mut Frame, app: &mut TuiState, area: Rect) {
    let is_de = app.is_de();
    let waiting = app
        .snapshots
        .iter()
        .filter(|s| s.state == AgentRunState::NeedsInput)
        .count();
    let running = app
        .snapshots
        .iter()
        .filter(|s| s.state == AgentRunState::Running)
        .count();
    let idle = app
        .snapshots
        .iter()
        .filter(|s| s.state == AgentRunState::Idle)
        .count();

    let total_cost: f64 = if app.config.show_cost_estimate {
        app.snapshots
            .iter()
            .filter_map(|s| estimate_cost(&s.usage, &s.model_name).map(|c| c.amount_usd))
            .sum()
    } else {
        0.0
    };

    let spin = SPINNER[app.tick % SPINNER.len()];
    let orb_color = if waiting > 0 {
        ACCENT_AMBER
    } else if running > 0 {
        ACCENT_EMERALD
    } else {
        ACCENT_CYAN
    };

    let status_sub = if running > 0 || waiting > 0 {
        let active_total = running + waiting;
        if is_de {
            format!("Echtzeit · {active_total} aktiv")
        } else {
            format!("Realtime · {active_total} active")
        }
    } else if is_de {
        "Echtzeit · Bereit".to_string()
    } else {
        "Realtime · Ready".to_string()
    };

    let mut left_spans = vec![
        Span::styled(
            if running > 0 { format!(" {spin} ") } else { " ● ".to_string() },
            Style::default().fg(orb_color).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            "AgentOrbit",
            Style::default()
                .fg(TEXT_PRIMARY)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!(" v{}", env!("CARGO_PKG_VERSION")),
            Style::default().fg(TEXT_DIM),
        ),
        Span::styled(
            format!("  {status_sub}  "),
            Style::default().fg(TEXT_MUTED),
        ),
    ];

    // KPI Pills
    left_spans.push(Span::styled(
        format!(" ⚡ {running} "),
        Style::default()
            .fg(if running > 0 { ACCENT_EMERALD } else { TEXT_DIM })
            .bg(if running > 0 { Color::Rgb(16, 46, 28) } else { BG_PILL_DARK })
            .add_modifier(Modifier::BOLD),
    ));
    left_spans.push(Span::raw(" "));
    left_spans.push(Span::styled(
        format!(" ! {waiting} "),
        Style::default()
            .fg(if waiting > 0 { ACCENT_AMBER } else { TEXT_DIM })
            .bg(if waiting > 0 { Color::Rgb(54, 38, 12) } else { BG_PILL_DARK })
            .add_modifier(Modifier::BOLD),
    ));
    left_spans.push(Span::raw(" "));
    left_spans.push(Span::styled(
        format!(" ☾ {idle} "),
        Style::default().fg(TEXT_MUTED).bg(BG_PILL_DARK),
    ));

    if app.config.show_cost_estimate && total_cost > 0.0 {
        let cost_txt = if total_cost < 10.0 {
            format!(" ~${total_cost:.2} ")
        } else {
            format!(" ~${total_cost:.1} ")
        };
        left_spans.push(Span::raw(" "));
        left_spans.push(Span::styled(
            cost_txt,
            Style::default()
                .fg(ACCENT_PURPLE)
                .bg(Color::Rgb(42, 22, 58))
                .add_modifier(Modifier::BOLD),
        ));
    }

    // Right-side Segmented M | K | D + Scope pill
    let seg_style = |active: bool| {
        if active {
            Style::default()
                .fg(Color::White)
                .bg(ACCENT_BLUE)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(TEXT_MUTED).bg(BG_PILL_DARK)
        }
    };
    let scope_txt = format!(" {} ", app.scope.label(is_de));
    let scope_w = scope_txt.chars().count() as u16;
    let right_spans = vec![
        Span::styled(
            scope_txt,
            Style::default()
                .fg(ACCENT_CYAN)
                .bg(Color::Rgb(14, 42, 58))
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::styled(" M ", seg_style(app.density == DensityMode::Minimal)),
        Span::styled(" K ", seg_style(app.density == DensityMode::Compact)),
        Span::styled(" D ", seg_style(app.density == DensityMode::Detail)),
        Span::raw(" "),
    ];

    let outer = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(BORDER_SUBTLE))
        .style(Style::default().bg(BG_CARD));
    let inner = outer.inner(area);
    f.render_widget(outer, area);

    let bar_split = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(20), Constraint::Length(24)])
        .split(inner);

    // Record exact hit-test rects for mouse clicks on Scope, M, K, D
    let rb = bar_split[1];
    let right_end = rb.x + rb.width;
    let d_x = right_end.saturating_sub(4);
    let k_x = d_x.saturating_sub(3);
    let m_x = k_x.saturating_sub(3);
    let sc_x = m_x.saturating_sub(scope_w + 1);
    app.btn_d = Some(Rect::new(d_x, rb.y, 3, 1));
    app.btn_k = Some(Rect::new(k_x, rb.y, 3, 1));
    app.btn_m = Some(Rect::new(m_x, rb.y, 3, 1));
    app.btn_scope = Some(Rect::new(sc_x, rb.y, scope_w, 1));

    f.render_widget(
        Paragraph::new(Line::from(left_spans)).style(Style::default().bg(BG_CARD)),
        bar_split[0],
    );
    f.render_widget(
        Paragraph::new(Line::from(right_spans))
            .alignment(Alignment::Right)
            .style(Style::default().bg(BG_CARD)),
        bar_split[1],
    );
}

fn draw_session_cards(f: &mut Frame, app: &mut TuiState, area: Rect) {
    app.card_rects.clear();
    let is_de = app.is_de();
    let now = now_epoch_secs();
    let visible: Vec<AgentSnapshot> = app.filtered().into_iter().cloned().collect();

    if visible.is_empty() {
        let msg = if is_de {
            "Keine passenden Agent-Sessions.  (a = Scope wechseln · f = Filter)"
        } else {
            "No matching agent sessions.  (a = Switch Scope · f = Filter)"
        };
        let empty = Paragraph::new(Line::from(Span::styled(
            msg,
            Style::default().fg(TEXT_MUTED),
        )))
        .alignment(Alignment::Center)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(BORDER_SUBTLE))
                .style(Style::default().bg(BG_CARD))
                .padding(Padding::vertical(1)),
        );
        f.render_widget(empty, area);
        return;
    }

    let cols: usize = if area.width >= 108 && visible.len() > 1 {
        2
    } else {
        1
    };
    app.grid_cols = cols;

    let card_h: u16 = match app.density {
        DensityMode::Minimal => 4,
        DensityMode::Compact => 6,
        DensityMode::Detail => 7,
    };

    let rows_per_page = ((area.height / card_h).max(1)) as usize;
    let selected_row = app.selected / cols;
    if selected_row < app.scroll_offset {
        app.scroll_offset = selected_row;
    } else if selected_row >= app.scroll_offset + rows_per_page {
        app.scroll_offset = selected_row + 1 - rows_per_page;
    }

    let row_constraints: Vec<Constraint> = (0..rows_per_page)
        .map(|_| Constraint::Length(card_h))
        .collect();
    let row_areas = Layout::default()
        .direction(Direction::Vertical)
        .constraints(row_constraints)
        .split(area);

    for (r_idx, row_rect) in row_areas.iter().enumerate() {
        let logical_row = app.scroll_offset + r_idx;
        let card_slots: Vec<Rect> = if cols == 2 {
            let split = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Fill(1),
                    Constraint::Length(1),
                    Constraint::Fill(1),
                ])
                .split(*row_rect);
            vec![split[0], split[2]]
        } else {
            vec![*row_rect]
        };

        for (c_idx, card_rect) in card_slots.iter().enumerate() {
            let item_idx = logical_row * cols + c_idx;
            if let Some(snap) = visible.get(item_idx) {
                app.card_rects.push((*card_rect, item_idx));
                let is_selected = item_idx == app.selected;
                draw_single_card(f, app, snap, is_selected, now, is_de, *card_rect);
            }
        }
    }
}

fn draw_single_card(
    f: &mut Frame,
    app: &TuiState,
    s: &AgentSnapshot,
    is_selected: bool,
    now: i64,
    is_de: bool,
    area: Rect,
) {
    let sid = s.id();
    let spin = SPINNER[app.tick % SPINNER.len()];
    let recently_done = app.is_recently_done(s, now);
    let is_live = s.state.is_active_or_waiting();

    let border_color = if is_selected {
        BORDER_SELECTED
    } else if s.state == AgentRunState::NeedsInput {
        ACCENT_AMBER
    } else if s.state == AgentRunState::Running {
        ACCENT_EMERALD
    } else if recently_done {
        Color::Rgb(52, 168, 92)
    } else {
        BORDER_SUBTLE
    };

    let bg = if is_selected { BG_CARD_SELECTED } else { BG_CARD };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(border_color))
        .style(Style::default().bg(bg))
        .padding(Padding::horizontal(1));
    let inner = block.inner(area);
    f.render_widget(block, area);

    if inner.height == 0 || inner.width < 12 {
        return;
    }

    // 1. Header Row: [AG] Project Name   ...   [ ⠋ Aktiv ]
    let (ag_code, ag_fg, ag_bg) = agent_badge_palette(&s.agent_label);
    let (st_txt, st_fg, st_bg) = if recently_done {
        (
            if is_de { " ✓ Fertig " } else { " ✓ Done " }.to_string(),
            Color::Rgb(74, 222, 128),
            Color::Rgb(16, 52, 30),
        )
    } else {
        match s.state {
            AgentRunState::NeedsInput => (
                format!(
                    " ! {} ",
                    s.interaction_reason
                        .as_deref()
                        .unwrap_or(if is_de { "Eingabe" } else { "Input" })
                ),
                ACCENT_AMBER,
                Color::Rgb(58, 38, 10),
            ),
            AgentRunState::Running => (
                format!(" {spin} {} ", if is_de { "Aktiv" } else { "Active" }),
                ACCENT_EMERALD,
                Color::Rgb(14, 52, 30),
            ),
            AgentRunState::Idle => (" ☾ Idle ".to_string(), TEXT_MUTED, BG_PILL_DARK),
            AgentRunState::Offline => (" × Offline ".to_string(), ACCENT_CORAL, Color::Rgb(54, 18, 22)),
            AgentRunState::Unavailable => (" — N/A ".to_string(), TEXT_DIM, BG_PILL_DARK),
        }
    };

    let top_split = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Min(10),
            Constraint::Length(st_txt.chars().count() as u16 + 1),
        ])
        .split(Rect::new(inner.x, inner.y, inner.width, 1));

    let title_line = Line::from(vec![
        Span::styled(
            format!(" {ag_code} "),
            Style::default()
                .fg(ag_fg)
                .bg(ag_bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
        Span::styled(
            &s.project_name,
            Style::default()
                .fg(if is_selected { Color::White } else { TEXT_PRIMARY })
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    f.render_widget(Paragraph::new(title_line).style(Style::default().bg(bg)), top_split[0]);
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            st_txt,
            Style::default()
                .fg(st_fg)
                .bg(st_bg)
                .add_modifier(Modifier::BOLD),
        )))
        .alignment(Alignment::Right)
        .style(Style::default().bg(bg)),
        top_split[1],
    );

    let mut cur_y = inner.y + 1;
    let max_y = inner.y + inner.height;

    // 2. Meta Row: aligned cleanly under the project title (just like the Desktop HUD!)
    if cur_y < max_y {
        let (mod_fg, mod_bg) = model_badge_palette(&s.model_name);
        let mut meta_spans = vec![
            Span::raw("     "),
            Span::styled(
                format!(" {} ", s.model_name),
                Style::default()
                    .fg(mod_fg)
                    .bg(mod_bg)
                    .add_modifier(Modifier::BOLD),
            ),
        ];
        if let Some(ref eff) = s.reasoning_effort {
            meta_spans.push(Span::raw(" "));
            meta_spans.push(Span::styled(
                format!(" {eff} "),
                Style::default()
                    .fg(ACCENT_PURPLE)
                    .bg(Color::Rgb(40, 22, 56)),
            ));
        }
        if let Some(ref br) = s.git_branch {
            meta_spans.push(Span::raw(" "));
            meta_spans.push(Span::styled(
                format!(" ⎇ {br} "),
                Style::default().fg(ACCENT_CYAN).bg(Color::Rgb(14, 38, 52)),
            ));
        }
        if let Some(started) = app.active_since.get(&sid) {
            meta_spans.push(Span::styled(
                format!("  ⏱ {}", format_age((now - *started).max(0))),
                Style::default().fg(ACCENT_EMERALD),
            ));
        } else if let Some(ts) = s.last_updated_epoch {
            meta_spans.push(Span::styled(
                format!("  {}", format_age((now - ts).max(0))),
                Style::default().fg(TEXT_DIM),
            ));
        }
        if app.config.show_cost_estimate {
            if let Some(cost) = estimate_cost(&s.usage, &s.model_name) {
                meta_spans.push(Span::styled(
                    format!("  {}", cost.formatted()),
                    Style::default().fg(ACCENT_PURPLE),
                ));
            }
        }
        f.render_widget(
            Paragraph::new(Line::from(meta_spans)).style(Style::default().bg(bg)),
            Rect::new(inner.x, cur_y, inner.width, 1),
        );
        cur_y += 1;
    }

    // 3. Live Working Line / Task Progress / Animated Sweep
    if cur_y < max_y && app.density != DensityMode::Minimal {
        if (is_live || recently_done) && !s.task_steps.is_empty() {
            let done = s
                .task_steps
                .iter()
                .filter(|st| matches!(st.status, TaskStepStatus::Done | TaskStepStatus::Skipped))
                .count();
            let total = s.task_steps.len();
            let current_title = s
                .task_steps
                .iter()
                .find(|st| st.status == TaskStepStatus::InProgress)
                .map(|st| st.title.as_str())
                .unwrap_or_else(|| {
                    if done == total {
                        if is_de { "Alle Schritte fertig" } else { "All steps done" }
                    } else {
                        s.task_steps[0].title.as_str()
                    }
                });
            let eta = app
                .active_since
                .get(&sid)
                .filter(|_| done > 0 && done < total)
                .map(|started| {
                    let elapsed = (now - *started).max(1) as usize;
                    let rem = (elapsed * (total - done)) / done;
                    format!(" · ETA ~{}", format_age(rem as i64))
                })
                .unwrap_or_default();
            let ico = if done == total { "✓" } else { spin };
            let ico_clr = if done == total { ACCENT_EMERALD } else { ACCENT_CYAN };
            let line = Line::from(vec![
                Span::styled(format!("{ico} "), Style::default().fg(ico_clr)),
                Span::styled(format!("{done}/{total}{eta}  "), Style::default().fg(ACCENT_BLUE).add_modifier(Modifier::BOLD)),
                Span::styled(current_title, Style::default().fg(TEXT_PRIMARY)),
            ]);
            f.render_widget(
                Paragraph::new(line).style(Style::default().bg(bg)),
                Rect::new(inner.x, cur_y, inner.width, 1),
            );
            cur_y += 1;
        } else if is_live && !s.recent_activity.is_empty() {
            let act = s.recent_activity.last().map(String::as_str).unwrap_or("");
            let line = Line::from(vec![
                Span::styled(format!("{spin} "), Style::default().fg(ACCENT_CYAN)),
                Span::styled(act, Style::default().fg(TEXT_PRIMARY)),
            ]);
            f.render_widget(
                Paragraph::new(line).style(Style::default().bg(bg)),
                Rect::new(inner.x, cur_y, inner.width, 1),
            );
            cur_y += 1;
        } else if is_live {
            let working_txt = if is_de {
                "Arbeitet im Hintergrund…"
            } else {
                "Working in background…"
            };
            let line = Line::from(vec![
                Span::styled(format!("{spin} "), Style::default().fg(ACCENT_EMERALD)),
                Span::styled(working_txt, Style::default().fg(TEXT_MUTED)),
            ]);
            f.render_widget(
                Paragraph::new(line).style(Style::default().bg(bg)),
                Rect::new(inner.x, cur_y, inner.width, 1),
            );
            cur_y += 1;
        }
    }

    // 4. Traffic-Light Gradient Context Bar (fixed-column alignment across all cards!)
    if cur_y < max_y && app.density != DensityMode::Minimal && app.config.context_window_override >= 0
    {
        if let Some(ratio) = effective_context_ratio(s, app.config.context_window_override) {
            let pct = (ratio * 100.0).round() as u32;
            let (grad_start, grad_end, ring_clr) = if pct >= 85 {
                ((255, 159, 10), (255, 69, 58), ACCENT_CORAL)
            } else if pct >= 65 {
                ((234, 179, 8), (255, 159, 10), ACCENT_AMBER)
            } else {
                ((56, 189, 248), (48, 209, 88), ACCENT_EMERALD)
            };
            let ctx_lbl = if is_de { "Kontext" } else { "Context" };
            let used = s.usage.context_tokens.unwrap_or(0);
            let win = if app.config.context_window_override > 0 {
                app.config.context_window_override as u64
            } else {
                s.usage.context_window.unwrap_or(0)
            };
            let meta = format!("{pct:>3}% · {}/{}", fmt_tokens(used), fmt_tokens(win));
            let left_w: u16 = 10;
            let right_w: u16 = 18;

            let row_rect = Rect::new(inner.x, cur_y, inner.width, 1);
            let cols = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Length(left_w),
                    Constraint::Min(8),
                    Constraint::Length(right_w),
                ])
                .split(row_rect);

            let left_line = Line::from(vec![
                Span::styled(format!("{} ", ring_glyph(pct as f64)), Style::default().fg(ring_clr)),
                Span::styled(ctx_lbl, Style::default().fg(TEXT_MUTED)),
            ]);
            let bar_w = cols[1].width.saturating_sub(1).max(6) as usize;
            let bar_line = Line::from(gradient_pill_bar_spans(ratio, bar_w, grad_start, grad_end));
            let right_line = Line::from(Span::styled(meta, Style::default().fg(TEXT_MUTED)));

            f.render_widget(Paragraph::new(left_line).style(Style::default().bg(bg)), cols[0]);
            f.render_widget(Paragraph::new(bar_line).style(Style::default().bg(bg)), cols[1]);
            f.render_widget(
                Paragraph::new(right_line)
                    .alignment(Alignment::Right)
                    .style(Style::default().bg(bg)),
                cols[2],
            );
            cur_y += 1;
        }
    }

    // 5. Detail Extra Row: IDE + Plan + Circular Ring Pills (Rate-Limits or Day/Week/Month)
    if cur_y < max_y && app.density == DensityMode::Detail {
        let mut detail_spans = vec![Span::styled(
            format!(" {} ", agent_ide_name(&s.agent_label)),
            Style::default().fg(TEXT_MUTED).bg(BG_PILL_DARK),
        )];
        if let Some(ref plan) = s.usage.plan_type {
            detail_spans.push(Span::raw(" "));
            detail_spans.push(Span::styled(
                format!(" {plan} "),
                Style::default().fg(ACCENT_AMBER).bg(Color::Rgb(50, 36, 12)),
            ));
        }
        if let Some(ref lim) = s.usage.primary_limit {
            detail_spans.push(Span::raw("  "));
            detail_spans.extend(format_limit_ring_pill(lim, now, is_de));
        }
        if let Some(ref lim) = s.usage.secondary_limit {
            detail_spans.push(Span::raw(" "));
            detail_spans.extend(format_limit_ring_pill(lim, now, is_de));
        } else if s.usage.primary_limit.is_none() {
            let (day_tok, _, _) = compute_period_usage(&app.snapshots, &s.agent_label, now);
            if day_tok > 0 {
                let pct = ((day_tok as f64 / 2_000_000.0) * 100.0).clamp(8.0, 100.0);
                detail_spans.push(Span::raw("  "));
                detail_spans.extend(ring_pill(
                    pct,
                    if is_de { "Tag" } else { "Day" },
                    &fmt_tokens(day_tok),
                    ACCENT_CYAN,
                ));
            }
        }
        f.render_widget(
            Paragraph::new(Line::from(detail_spans)).style(Style::default().bg(bg)),
            Rect::new(inner.x, cur_y, inner.width, 1),
        );
    }
}

fn draw_inspector_panel(f: &mut Frame, app: &TuiState, area: Rect) {
    let is_de = app.is_de();
    let now = now_epoch_secs();
    let Some(sel) = app.selected_snapshot() else {
        return;
    };

    let split = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(52), Constraint::Percentage(48)])
        .split(area);

    // Left: Checklist / Activity / Path
    let is_live = sel.state.is_active_or_waiting() || app.is_recently_done(sel, now);
    let mut left_lines: Vec<Line> = Vec::new();
    left_lines.push(Line::from(vec![
        Span::styled(
            format!(" {} ", agent_ide_name(&sel.agent_label)),
            Style::default()
                .fg(ACCENT_CYAN)
                .bg(Color::Rgb(14, 42, 58))
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw("  "),
        Span::styled(
            sel.project_path.as_deref().unwrap_or("—"),
            Style::default().fg(TEXT_MUTED),
        ),
    ]));

    if is_live && !sel.task_steps.is_empty() {
        let spin = SPINNER[app.tick % SPINNER.len()];
        let max_steps = (area.height.saturating_sub(3)) as usize;
        for step in sel.task_steps.iter().take(max_steps) {
            let (ico, clr) = match step.status {
                TaskStepStatus::Done | TaskStepStatus::Skipped => ("✓", ACCENT_EMERALD),
                TaskStepStatus::InProgress => (spin, ACCENT_CYAN),
                TaskStepStatus::Failed => ("✕", ACCENT_CORAL),
                TaskStepStatus::Pending => ("○", TEXT_DIM),
            };
            left_lines.push(Line::from(vec![
                Span::styled(format!(" {ico} "), Style::default().fg(clr)),
                Span::styled(&step.title, Style::default().fg(if step.status == TaskStepStatus::Pending { TEXT_MUTED } else { TEXT_PRIMARY })),
            ]));
        }
    } else if is_live && !sel.recent_activity.is_empty() {
        for act in sel.recent_activity.iter().rev().take(4) {
            left_lines.push(Line::from(vec![
                Span::styled(" ✎ ", Style::default().fg(ACCENT_CYAN)),
                Span::styled(act.as_str(), Style::default().fg(TEXT_PRIMARY)),
            ]));
        }
    } else if let Some(ref title) = sel.session_title {
        left_lines.push(Line::from(vec![
            Span::styled(" 💬 ", Style::default().fg(TEXT_DIM)),
            Span::styled(title.as_str(), Style::default().fg(TEXT_MUTED)),
        ]));
    }

    let left_block = Block::default()
        .title(Span::styled(
            format!(" {} ", sel.project_name),
            Style::default().fg(TEXT_PRIMARY).add_modifier(Modifier::BOLD),
        ))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(BORDER_SUBTLE))
        .style(Style::default().bg(BG_CARD))
        .padding(Padding::horizontal(1));
    f.render_widget(Paragraph::new(left_lines).block(left_block), split[0]);

    // Right: Tokens + Real Visual Circular % Rings (matching Desktop HUD SVG rings!)
    let right_block = Block::default()
        .title(Span::styled(
            " Limits & Tokens ",
            Style::default().fg(ACCENT_CYAN).add_modifier(Modifier::BOLD),
        ))
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(BORDER_SUBTLE))
        .style(Style::default().bg(BG_CARD))
        .padding(Padding::horizontal(1));
    let right_inner = right_block.inner(split[1]);
    f.render_widget(right_block, split[1]);

    if right_inner.height == 0 || right_inner.width < 10 {
        return;
    }

    let mut tok_parts = Vec::new();
    if let Some(v) = sel.usage.input_tokens {
        tok_parts.push(format!("In {}", fmt_tokens(v)));
    }
    if let Some(v) = sel.usage.cache_read_tokens {
        tok_parts.push(format!("Cache {}", fmt_tokens(v)));
    }
    if let Some(v) = sel.usage.output_tokens {
        tok_parts.push(format!("Out {}", fmt_tokens(v)));
    }
    let tok_text = if !tok_parts.is_empty() {
        tok_parts.join(" · ")
    } else if let Some(tot) = sel.usage.session_total_tokens {
        format!("Total {} tok", fmt_tokens(tot))
    } else {
        String::new()
    };

    let mut rings_area = right_inner;
    if !tok_text.is_empty() && right_inner.height >= 2 {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                tok_text,
                Style::default().fg(TEXT_MUTED),
            )))
            .style(Style::default().bg(BG_CARD)),
            Rect::new(right_inner.x, right_inner.y, right_inner.width, 1),
        );
        rings_area = Rect::new(
            right_inner.x,
            right_inner.y + 1,
            right_inner.width,
            right_inner.height - 1,
        );
    }

    // Collect up to 4 circular % ring specs: real provider limits + deduplicated Day/Week/Month
    struct RingSpec {
        percent: f64,
        center: String,
        caption: String,
        color: Color,
    }
    let mut rings: Vec<RingSpec> = Vec::new();
    for lim in [sel.usage.primary_limit.as_ref(), sel.usage.secondary_limit.as_ref()]
        .into_iter()
        .flatten()
    {
        let rem = lim.remaining_percent().clamp(0.0, 100.0);
        let rem_u = rem.round() as u32;
        let lbl = limit_window_label(lim.window_minutes, is_de);
        let reset = lim
            .resets_at_epoch
            .map(|ts| format!("·{}", format_age((ts - now).max(0))))
            .unwrap_or_default();
        let color = if rem_u < 20 {
            ACCENT_CORAL
        } else if rem_u < 45 {
            ACCENT_AMBER
        } else {
            ACCENT_EMERALD
        };
        rings.push(RingSpec {
            percent: rem,
            center: format!("{rem_u}%"),
            caption: format!("{lbl}{reset}"),
            color,
        });
    }

    let (day_tok, week_tok, month_tok) = compute_period_usage(&app.snapshots, &sel.agent_label, now);
    if day_tok > 0 {
        rings.push(RingSpec {
            percent: ((day_tok as f64 / 2_000_000.0) * 100.0).clamp(12.0, 100.0),
            center: fmt_tokens(day_tok),
            caption: if is_de { "Tag" } else { "Day" }.to_string(),
            color: ACCENT_CYAN,
        });
    }
    if week_tok > day_tok {
        rings.push(RingSpec {
            percent: ((week_tok as f64 / 10_000_000.0) * 100.0).clamp(12.0, 100.0),
            center: fmt_tokens(week_tok),
            caption: if is_de { "Woche" } else { "Week" }.to_string(),
            color: ACCENT_PURPLE,
        });
    }
    if month_tok > week_tok {
        rings.push(RingSpec {
            percent: ((month_tok as f64 / 40_000_000.0) * 100.0).clamp(12.0, 100.0),
            center: fmt_tokens(month_tok),
            caption: if is_de { "Monat" } else { "Month" }.to_string(),
            color: Color::Rgb(129, 140, 248),
        });
    }

    if rings.is_empty() {
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                if is_de { "Keine weiteren Metriken" } else { "No extra metrics" },
                Style::default().fg(TEXT_DIM),
            )))
            .style(Style::default().bg(BG_CARD)),
            rings_area,
        );
        return;
    }

    // Fit as many 11-char circular rings side-by-side as the terminal width allows
    let ring_w: u16 = 11;
    let max_fit = ((rings_area.width / ring_w).max(1) as usize).min(rings.len());
    if rings_area.height >= 4 {
        for (idx, ring) in rings.iter().take(max_fit).enumerate() {
            let rx = rings_area.x + (idx as u16) * ring_w;
            let r_rect = Rect::new(rx, rings_area.y, ring_w.min(rings_area.x + rings_area.width - rx), 4);
            draw_mini_ring(f, r_rect, ring.percent, &ring.center, &ring.caption, ring.color);
        }
    } else {
        // Fallback for very short terminals: compact single-line ring pills
        let mut pills: Vec<Span> = Vec::new();
        for (idx, ring) in rings.iter().take(max_fit).enumerate() {
            if idx > 0 {
                pills.push(Span::raw(" "));
            }
            pills.extend(ring_pill(ring.percent, &ring.caption, &ring.center, ring.color));
        }
        f.render_widget(
            Paragraph::new(Line::from(pills)).style(Style::default().bg(BG_CARD)),
            rings_area,
        );
    }
}

/// Renders a sleek 3-line circular progress ring + caption underneath:
///   ╭───╮
///   │78%│
///   ╰───╯
///   5h·2h
/// with top/right/bottom/left arc segments lit proportionally to `percent`.
fn draw_mini_ring(
    f: &mut Frame,
    area: Rect,
    percent: f64,
    center: &str,
    caption: &str,
    color: Color,
) {
    let dim = Color::Rgb(46, 56, 74);
    let p = percent.clamp(0.0, 100.0);
    let c_top = if p >= 15.0 { color } else { dim };
    let c_right = if p >= 40.0 { color } else { dim };
    let c_bot = if p >= 65.0 { color } else { dim };
    let c_left = if p >= 88.0 { color } else { dim };

    let val: String = center.chars().take(5).collect();
    let pad_l = (5_usize.saturating_sub(val.len())) / 2;
    let pad_r = 5_usize.saturating_sub(val.len() + pad_l);
    let centered = format!("{}{}{}", " ".repeat(pad_l), val, " ".repeat(pad_r));

    let cap: String = caption.chars().take(area.width as usize).collect();

    let lines = vec![
        Line::from(vec![
            Span::styled("╭", Style::default().fg(c_left)),
            Span::styled("─────", Style::default().fg(c_top)),
            Span::styled("╮", Style::default().fg(c_right)),
        ]),
        Line::from(vec![
            Span::styled("│", Style::default().fg(c_left)),
            Span::styled(
                centered,
                Style::default()
                    .fg(TEXT_PRIMARY)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("│", Style::default().fg(c_right)),
        ]),
        Line::from(vec![
            Span::styled("╰", Style::default().fg(c_left)),
            Span::styled("─────", Style::default().fg(c_bot)),
            Span::styled("╯", Style::default().fg(c_right)),
        ]),
        Line::from(Span::styled(cap, Style::default().fg(TEXT_MUTED))),
    ];
    f.render_widget(
        Paragraph::new(lines)
            .alignment(Alignment::Center)
            .style(Style::default().bg(BG_CARD)),
        area,
    );
}

fn ring_glyph(percent: f64) -> &'static str {
    if percent >= 88.0 {
        "●"
    } else if percent >= 63.0 {
        "◕"
    } else if percent >= 38.0 {
        "◑"
    } else if percent >= 13.0 {
        "◔"
    } else {
        "○"
    }
}

fn lerp_rgb(a: (u8, u8, u8), b: (u8, u8, u8), t: f64) -> Color {
    let t = t.clamp(0.0, 1.0);
    let r = (a.0 as f64 + (b.0 as f64 - a.0 as f64) * t).round() as u8;
    let g = (a.1 as f64 + (b.1 as f64 - a.1 as f64) * t).round() as u8;
    let bl = (a.2 as f64 + (b.2 as f64 - a.2 as f64) * t).round() as u8;
    Color::Rgb(r, g, bl)
}

/// Vertically centered, seamless TrueColor gradient bar (`╺━━━━━━━━━━╸`)
/// with soft inset ends and zero baseline stair-stepping.
fn gradient_pill_bar_spans(
    ratio: f64,
    width: usize,
    start_rgb: (u8, u8, u8),
    end_rgb: (u8, u8, u8),
) -> Vec<Span<'static>> {
    if width == 0 {
        return Vec::new();
    }
    let clamped = ratio.clamp(0.0, 1.0);
    let filled = ((clamped * width as f64).round() as usize).min(width);
    let track_clr = Color::Rgb(46, 56, 74);
    let denom = (width.saturating_sub(1)).max(1) as f64;

    let mut out = Vec::with_capacity(width);
    for i in 0..width {
        let ch = if i == 0 {
            "╺"
        } else if i + 1 == width {
            "╸"
        } else {
            "━"
        };
        let clr = if i < filled {
            lerp_rgb(start_rgb, end_rgb, i as f64 / denom)
        } else {
            track_clr
        };
        out.push(Span::styled(ch, Style::default().fg(clr)));
    }
    out
}

fn ring_pill(percent: f64, label: &str, value: &str, color: Color) -> Vec<Span<'static>> {
    vec![
        Span::styled(
            format!(" {} ", ring_glyph(percent)),
            Style::default()
                .fg(color)
                .bg(BG_PILL_DARK)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{label} "),
            Style::default().fg(TEXT_MUTED).bg(BG_PILL_DARK),
        ),
        Span::styled(
            format!("{value} "),
            Style::default()
                .fg(TEXT_PRIMARY)
                .bg(BG_PILL_DARK)
                .add_modifier(Modifier::BOLD),
        ),
    ]
}

fn format_limit_ring_pill(
    lim: &agentorbit_core::RateLimitWindow,
    now: i64,
    is_de: bool,
) -> Vec<Span<'static>> {
    let rem = lim.remaining_percent().clamp(0.0, 100.0);
    let rem_u = rem.round() as u32;
    let label = limit_window_label(lim.window_minutes, is_de);
    let reset = lim
        .resets_at_epoch
        .map(|ts| format!(" · {}", format_age((ts - now).max(0))))
        .unwrap_or_default();
    let color = if rem_u < 20 {
        ACCENT_CORAL
    } else if rem_u < 45 {
        ACCENT_AMBER
    } else {
        ACCENT_EMERALD
    };
    ring_pill(rem, &label, &format!("{rem_u}%{reset}"), color)
}

fn limit_window_label(window_minutes: u32, is_de: bool) -> String {
    if window_minutes <= 360 {
        format!("{}h", (window_minutes / 60).max(1))
    } else if window_minutes <= 1440 {
        if is_de { "Tag" } else { "Day" }.to_string()
    } else if window_minutes <= 10080 {
        if is_de { "Woche" } else { "Week" }.to_string()
    } else {
        if is_de { "Monat" } else { "Month" }.to_string()
    }
}

fn compute_period_usage(snapshots: &[AgentSnapshot], agent_label: &str, now: i64) -> (u64, u64, u64) {
    let mut day_tok = 0_u64;
    let mut week_tok = 0_u64;
    let mut month_tok = 0_u64;
    for s in snapshots {
        if s.agent_label != agent_label {
            continue;
        }
        let tok = s
            .usage
            .session_total_tokens
            .or(s.usage.context_tokens)
            .unwrap_or(0);
        if tok == 0 {
            continue;
        }
        let age = s
            .last_updated_epoch
            .map(|ts| (now - ts).max(0))
            .unwrap_or(i64::MAX);
        if age <= 86_400 {
            day_tok += tok;
        }
        if age <= 7 * 86_400 {
            week_tok += tok;
        }
        if age <= 30 * 86_400 {
            month_tok += tok;
        }
    }
    (day_tok, week_tok, month_tok)
}

fn draw_footer(f: &mut Frame, app: &TuiState, area: Rect) {
    let is_de = app.is_de();
    if app.search_mode {
        let prompt = Line::from(vec![
            Span::styled(
                " /",
                Style::default()
                    .fg(ACCENT_AMBER)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(&app.search_query, Style::default().fg(TEXT_PRIMARY)),
            Span::styled("▌", Style::default().fg(ACCENT_CYAN)),
            Span::styled(
                if is_de {
                    "   (Enter bestätigen · Esc abbrechen)"
                } else {
                    "   (Enter confirm · Esc cancel)"
                },
                Style::default().fg(TEXT_DIM),
            ),
        ]);
        f.render_widget(Paragraph::new(prompt).style(Style::default().bg(BG_CANVAS)), area);
        return;
    }

    let keycap = Style::default()
        .fg(ACCENT_CYAN)
        .bg(BG_PILL_DARK)
        .add_modifier(Modifier::BOLD);
    let lbl = Style::default().fg(TEXT_MUTED);

    let mut spans = vec![
        Span::styled(" ● ", Style::default().fg(ACCENT_EMERALD)),
        Span::styled(&app.status_hint, Style::default().fg(TEXT_MUTED)),
    ];
    if !app.search_query.is_empty() {
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            format!(" /{} ", app.search_query),
            Style::default()
                .fg(ACCENT_AMBER)
                .bg(Color::Rgb(54, 38, 12))
                .add_modifier(Modifier::BOLD),
        ));
    }
    spans.extend([
        Span::raw("   "),
        Span::styled(" h j k l ", keycap),
        Span::raw(" "),
        Span::styled(" ←  ↓  ↑  → ", keycap),
        Span::styled(if is_de { " Nav " } else { " Nav " }, lbl),
        Span::styled(" gg/G ", keycap),
        Span::raw(" "),
        Span::styled(" / ", keycap),
        Span::styled(if is_de { " Suche " } else { " Find " }, lbl),
        Span::styled(" a ", keycap),
        Span::styled(" Scope ", lbl),
        Span::styled(" m/c/d ", keycap),
        Span::styled(if is_de { " Ansicht " } else { " View " }, lbl),
        Span::styled(" ↵ ", keycap),
        Span::styled(if is_de { " Öffnen " } else { " Open " }, lbl),
        Span::styled(" q ", keycap),
        Span::styled(if is_de { " Ende" } else { " Quit" }, lbl),
    ]);
    f.render_widget(Paragraph::new(Line::from(spans)).style(Style::default().bg(BG_CANVAS)), area);
}

fn agent_badge_palette(label: &str) -> (&'static str, Color, Color) {
    match label {
        "Antigravity" => ("AG", ACCENT_CYAN, Color::Rgb(12, 46, 64)),
        "Codex" => ("CX", ACCENT_EMERALD, Color::Rgb(12, 48, 30)),
        "Claude" => ("CL", ACCENT_CORAL, Color::Rgb(58, 28, 24)),
        "OpenCode" => ("OC", ACCENT_PURPLE, Color::Rgb(44, 22, 62)),
        "Bionic" => ("LM", Color::Rgb(129, 140, 248), Color::Rgb(24, 32, 68)),
        "Pi" => ("PI", ACCENT_AMBER, Color::Rgb(56, 38, 12)),
        _ => ("AI", TEXT_PRIMARY, BG_PILL_DARK),
    }
}

fn model_badge_palette(model: &str) -> (Color, Color) {
    let m = model.to_lowercase();
    if m.contains("gemini") {
        (ACCENT_CYAN, Color::Rgb(14, 42, 58))
    } else if m.contains("claude") || m.contains("opus") || m.contains("sonnet") || m.contains("haiku") {
        (ACCENT_CORAL, Color::Rgb(56, 28, 24))
    } else if m.contains("gpt") || m.contains("codex") || m.contains("o3") || m.contains("o4") {
        (ACCENT_EMERALD, Color::Rgb(14, 46, 28))
    } else if m.contains("qwen") || m.contains("deepseek") || m.contains("llama") || m.contains("mlx") {
        (ACCENT_PURPLE, Color::Rgb(42, 22, 58))
    } else {
        (TEXT_PRIMARY, BG_PILL_DARK)
    }
}

fn agent_ide_name(label: &str) -> &str {
    match label {
        "Antigravity" => "Antigravity IDE",
        "Codex" => "Codex CLI / ChatGPT",
        "Claude" => "Claude Code CLI",
        "OpenCode" => "OpenCode Desktop",
        "Bionic" => "LM Studio Bionic",
        "Pi" => "Pi Coding Agent",
        other => other,
    }
}

fn effective_context_ratio(snap: &AgentSnapshot, override_val: i64) -> Option<f64> {
    if override_val < 0 {
        return None;
    }
    let used = snap.usage.context_tokens?;
    let window = if override_val > 0 {
        override_val as u64
    } else {
        snap.usage.context_window?
    };
    if window == 0 {
        return None;
    }
    Some((used as f64 / window as f64).clamp(0.0, 1.0))
}

fn fmt_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{}k", n / 1_000)
    } else {
        n.to_string()
    }
}

fn format_age(secs: i64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m {}s", secs / 60, secs % 60)
    } else {
        format!("{}h", secs / 3600)
    }
}

fn open_project_os(path: &str, launcher: &str) {
    let editor = launcher.trim().to_lowercase();
    #[cfg(target_os = "macos")]
    {
        let mut cmd = Command::new("open");
        match editor.as_str() {
            "vscode" | "code" => {
                cmd.args(["-a", "Visual Studio Code", path]);
            }
            "cursor" => {
                cmd.args(["-a", "Cursor", path]);
            }
            "antigravity" => {
                cmd.args(["-a", "Antigravity", path]);
            }
            "terminal" => {
                cmd.args(["-a", "Terminal", path]);
            }
            "finder" => {
                cmd.args(["-a", "Finder", path]);
            }
            _ => {
                cmd.arg(path);
            }
        }
        let _ = cmd.spawn();
    }
    #[cfg(target_os = "linux")]
    {
        let bin = match editor.as_str() {
            "vscode" | "code" => "code",
            "cursor" => "cursor",
            _ => "xdg-open",
        };
        let _ = Command::new(bin).arg(path).spawn();
    }
    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("cmd").args(["/C", "start", "", path]).spawn();
    }
}
