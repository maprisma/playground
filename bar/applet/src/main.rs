// Maprisma Playground for COSMIC: its gamepad in the panel. A click opens Maprisma Playground,
// or, when it is shown (focused or not), hides it while work runs and closes it otherwise.
//
// That is the app's own: `maprisma-playground --toggle` (single instance).

mod fonts;

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::LazyLock;

use cosmic::app::{Core, Task};
use cosmic::applet::cosmic_panel_config::PanelAnchor;
use cosmic::widget::{Id, autosize, button, icon};
use cosmic::{Element, theme};

const APP_ID: &str = "io.github.ubruckhaus.CosmicMaprismaPlayground";
const ICON: &str = "io.github.ubruckhaus.CosmicMaprismaPlayground-symbolic";
static AUTOSIZE_ID: LazyLock<Id> = LazyLock::new(|| Id::new("playground-autosize"));

fn main() -> cosmic::iced::Result {
    fonts::keep_fonts();
    cosmic::applet::run::<Applet>(())
}

// MAPRISMA_PLAYGROUND, or the link tools/install-local makes, or one on PATH.
fn playground_bin() -> PathBuf {
    if let Some(path) = std::env::var_os("MAPRISMA_PLAYGROUND") {
        return PathBuf::from(path);
    }
    let local = PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/bin/maprisma-playground");
    if local.exists() { local } else { PathBuf::from("maprisma-playground") }
}

fn toggle() {
    let child = std::process::Command::new(playground_bin())
        .arg("--toggle")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut child) = child {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

#[derive(Default)]
struct Applet {
    core: Core,
}

#[derive(Debug, Clone)]
enum Message {
    Toggle,
}

impl cosmic::Application for Applet {
    type Executor = cosmic::SingleThreadExecutor;
    type Flags = ();
    type Message = Message;
    const APP_ID: &'static str = APP_ID;

    fn core(&self) -> &Core {
        &self.core
    }

    fn core_mut(&mut self) -> &mut Core {
        &mut self.core
    }

    fn init(core: Core, _flags: ()) -> (Self, Task<Message>) {
        (Self { core }, Task::none())
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Toggle => toggle(),
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Message> {
        fonts::keep_fonts();
        let horizontal = matches!(self.core.applet.anchor, PanelAnchor::Top | PanelAnchor::Bottom);
        let padding = self.core.applet.suggested_padding(true).0;
        let size = self.core.applet.suggested_size(true).0;
        let button = button::custom(icon::from_name(ICON).size(size).symbolic(true).icon())
            .padding(if horizontal { [0, padding] } else { [padding, 0] })
            .on_press_down(Message::Toggle)
            .class(theme::Button::AppletIcon);
        autosize::autosize(button, AUTOSIZE_ID.clone()).into()
    }

    fn style(&self) -> Option<cosmic::iced::theme::Style> {
        Some(cosmic::applet::style())
    }
}
