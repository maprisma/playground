/// What a click in the tray or its menu does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// The icon: open, bring to the front, or close when shown (`--toggle`).
    Toggle,
    /// A menu entry: open on this tab (`--test <tab>`); None: the tab it had.
    Open(Option<&'static str>),
    Quit,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub id: i32,
    pub label: String,
    pub separator: bool,
    pub children: Vec<Item>,
    action: Option<Action>,
}

impl Item {
    pub fn find(&self, id: i32) -> Option<&Self> {
        if self.id == id {
            Some(self)
        } else {
            self.children.iter().find_map(|c| c.find(id))
        }
    }
    pub fn activate(&self, id: i32) -> Option<Action> {
        self.find(id).and_then(|i| i.action)
    }
}

/// The tabs, as the app has them (flutter_app/lib/app.dart).
pub const TABS: [(&str, &str); 8] = [
    ("analyze", "Analyze"),
    ("chess", "Chess"),
    ("automaton", "Automaton"),
    ("speed", "Speed and cost"),
    ("duel", "Head to head"),
    ("vision", "Vision"),
    ("generate", "Generate"),
    ("local", "Local LLMs"),
];

pub fn menu() -> Item {
    let item = |id, label: &str, action| Item {
        id,
        label: label.into(),
        separator: false,
        children: vec![],
        action,
    };
    let separator = |id| Item {
        separator: true,
        ..item(id, "", None)
    };
    let mut root = item(0, "", None);
    root.children.push(item(1, "Open Maprisma Playground", Some(Action::Open(None))));
    root.children.push(separator(2));
    for (i, (key, label)) in TABS.iter().enumerate() {
        root.children.push(item(10 + i as i32, label, Some(Action::Open(Some(key)))));
    }
    root.children.push(separator(3));
    root.children.push(item(4, "Quit tray", Some(Action::Quit)));
    root
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn menu_actions() {
        let m = menu();
        assert_eq!(m.children.len(), 12);
        assert_eq!(m.activate(1), Some(Action::Open(None)));
        assert_eq!(m.activate(12), Some(Action::Open(Some("automaton"))));
        assert_eq!(m.find(12).unwrap().label, "Automaton");
        assert_eq!(m.activate(4), Some(Action::Quit));
        assert_eq!(m.activate(2), None);
        assert_eq!(m.activate(0), None);
        assert_eq!(m.activate(99), None);
    }
}
