use crate::common;
use crate::common::SYMBOLS;
use crate::state::UcsiState;
use ec_test_lib::ucsi::{PowerRole, UcsiCapability, UcsiConnectorCapability, UcsiConnectorStatus};
use ratatui::{
    buffer::Buffer,
    crossterm::event::Event,
    layout::Rect,
    style::{Color, palette::tailwind},
    text::Line,
    widgets::{Block, Paragraph, Widget},
};

const LABEL_COLOR: Color = tailwind::CYAN.c300;

/// USB-C / UCSI UI module — stateless; all data is read from [`UcsiState`].
pub struct Ucsi;

impl Ucsi {
    pub fn new() -> Self {
        Self
    }

    pub(crate) fn handle_event(&mut self, _evt: &Event) {}

    pub(crate) fn render(&self, state: &UcsiState, area: Rect, buf: &mut Buffer) {
        self.render_titled("USB-C (UCSI)", tailwind::CYAN.c600, state, area, buf);
    }

    pub(crate) fn render_card(&self, state: &UcsiState, area: Rect, buf: &mut Buffer) {
        self.render_titled("USB-C", tailwind::CYAN.c700, state, area, buf);
    }

    /// Both the tab and the dashboard card render the same metric rows inside a
    /// bordered block; only the title and border colour differ.
    fn render_titled(&self, title: &str, border: Color, state: &UcsiState, area: Rect, buf: &mut Buffer) {
        let is_healthy = matches!(state.snapshot, Some(Ok(_)));
        let block = Block::bordered()
            .title(common::status_title(title, is_healthy))
            .border_style(border);
        let inner = block.inner(area);
        block.render(area, buf);
        Paragraph::new(rows(state)).render(inner, buf);
    }
}

// ── Row builder ───────────────────────────────────────────────────────────────

/// One honest UCSI row while pending/failed; four compact rows once the
/// fail-fast snapshot lands.
fn rows(s: &UcsiState) -> Vec<Line<'static>> {
    let snapshot = match &s.snapshot {
        None => return vec![common::metric_row("UCSI", "Pending...".to_string(), LABEL_COLOR)],
        Some(Err(e)) => return vec![common::metric_row("UCSI", format!("Error: {e}"), LABEL_COLOR)],
        Some(Ok(snapshot)) => snapshot,
    };
    vec![
        common::metric_row("Version", version_bcd(snapshot.version), LABEL_COLOR),
        common::metric_row("Capability", capability_summary(&snapshot.capability), LABEL_COLOR),
        common::metric_row("Conn 1", connector_summary(&snapshot.connector_capability), LABEL_COLOR),
        common::metric_row("Status", status_summary(&snapshot.connector_status), LABEL_COLOR),
    ]
}

/// Format the BCD VERSION word (`0x0120` → `1.2`) at the presentation boundary.
fn version_bcd(v: u16) -> String {
    format!("{}.{}", v >> 8, (v >> 4) & 0xf)
}

fn capability_summary(cap: &UcsiCapability) -> String {
    let connector = if cap.num_connectors == 1 {
        "connector"
    } else {
        "connectors"
    };
    format!("{} {connector}", cap.num_connectors)
}

fn connector_summary(cap: &UcsiConnectorCapability) -> String {
    match (cap.provider(), cap.consumer()) {
        (true, true) => "provider/consumer",
        (true, false) => "provider",
        (false, true) => "consumer",
        (false, false) => "-",
    }
    .to_string()
}

fn status_summary(status: &UcsiConnectorStatus) -> String {
    if !status.connect_status {
        return "Disconnected".to_string();
    }
    match &status.status {
        Some(connected) => {
            let direction = match connected.power_direction {
                PowerRole::Sink => "Sink",
                PowerRole::Source => "Source",
            };
            format!("Connected {} {direction}", SYMBOLS.mid_dot)
        }
        None => "Connected".to_string(),
    }
}
