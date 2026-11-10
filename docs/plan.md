# Maprisma Playground: plan

A Flutter port of the Omarchy plugin **AI Playground** (`ubruckhaus.ai-playground` 0.3.2,
github.com/uBruckhaus/omarchy-ai-playground at 03ca0be, checked out read-only in
`../omarchy-ai-playground`). It is built like the other Maprisma apps (Theme, Manager) and
together with Codex.

## Rules

- **It must look and work like the plugin.** The plugin's view code (`ai_playground.py`, `tabs.py`,
  `chess_page.py`, `chess_import.py`, `analyze_tab.py`, `generate_tab.py`, `host.py`,
  `theme_css.py`) and `reference/omarchy-preview.png` are the UI spec. That means the same header
  (gamepad icon, name, tab buttons, info, gear), the same tab intros (CAPS title plus a dim hint),
  folding cards with a ✓/✗/!/? mark at the right, the same buttons, and the same chess board with its
  taken-pieces cards and replay bar. Each page is screenshot-compared with the plugin
  (it runs here: Python plus GTK4/libadwaita are installed) before the port counts as done.
- **English only.** No i18n, no Language setting. Only the plugin's English texts are kept.
- **The Omarchy plugin stays untouched.** Nothing in `../omarchy-*` is edited.
- **The safety rules carry over exactly:**
  - Agents run with an argv list (never a shell), without tools, in an empty 0700 temp folder
    that is deleted afterwards, with a time limit and a size limit on the answer read back.
  - The prompt goes on stdin where the agent takes it (Hermes only takes it as an argv).
  - Pictures are scaled down and re-saved (so no metadata goes out) and go only to agents
    without tools.
  - Untrusted text (video captions, web) goes only to agents in `reads_untrusted`.
  - Downloads are checked against SHA-256 and written to `.part` files opened exclusively.
  - Video links are YouTube https only.
  - Nothing an agent answers is run.
- **Agents for now:** Claude Code, Codex, Hermes and Pi, with the `[ask]` tables from their
  adapters (argv, games, effort). The table is bundled as data, the way the plugin does it.

## Architecture (like Maprisma Theme)

```
maprisma-playground/
  packages/maprisma_playground_core/   pure Dart, no Flutter: the plugin's logic, plus tests
    lib/src/agents.dart        harnesses + [ask] tables, which agents are installed and set up (signin)
    lib/src/agent_run.dart     ask once: build argv, temp folder, stdin, limits, parse tokens and cost
    lib/src/chess_rules.dart   board, legal moves, SAN, FEN, PGN, game end
    lib/src/chess_agent.dart   the chess prompt, reading the move, asking again
    lib/src/chess_video.dart   yt-dlp/ffmpeg import: text way + frames way, games store
    lib/src/analyze.dart       the Analyze cards (+ frame_check, online_models, the model lists)
    lib/src/local_llm.dart     loopback servers, OpenAI chat, tokens/s; local_hold; gpu_check
    lib/src/picture_gen.dart   sd.cpp + Z-Image-Turbo setup (SHA-256) and generate
    lib/src/pictures.dart      scale and strip pictures (package:image), video frames (ffmpeg)
    lib/src/settings.dart      settings.json (schema with defaults), duel scores, games.json
    bin/maprisma_playground_core.dart   CLI for tests and debugging (agents, ask, chess …)
  flutter_app/                 com.maprisma.Playground; --toggle; one instance
    lib/pages/{analyze,chess,speed,duel,vision,generate,local,info,settings}_page.dart
  bar/                         Rust workspace
    applet/  maprisma-playground-applet  COSMIC panel button (gamepad), runs `maprisma-playground --toggle`
    tray/    maprisma-playground-tray    KDE StatusNotifierItem "Maprisma Playground", same action
  data/                        desktop entries, icons (app + symbolic bar icon), the Tray autostart
  tools/install-local          builds and installs into ~/.local/lib/maprisma-playground (atomic swap)
```

The Flutter app imports the core as a Dart package and runs it in-process. Agents and tools are
child processes, so the UI never blocks. The CLI exists for tests and for Codex to drive things
headless.

**Names:** app id `com.maprisma.Playground`; bar icon
`io.github.ubruckhaus.CosmicMaprismaPlayground-symbolic`; COSMIC applet id
`io.github.ubruckhaus.CosmicMaprismaPlayground`; KDE tray id `maprisma-playground`, with a title that
starts with "Maprisma" so the Maprisma Icons widget picks it up.

**Data:**
- `~/.config/maprisma-playground/`: `settings.json` (0600), `games.json`, duel scores.
- `~/.local/share/maprisma-playground/`: the sd.cpp program and the Z-Image-Turbo model (~11 GB).
- No shared Omarchy names: the plugin's folders live on the Omarchy install, not here.

**Window:** the window is a normal one. Closing it quits the app. `--toggle` closes the window if
it is in front, and otherwise starts the app or raises it. A second start hands its arguments to
the running app over a unix socket in `$XDG_RUNTIME_DIR` (as Theme/Launcher do). Arguments:
`--agent <command> --test <tab>`.

**Settings** (the plugin's, minus language and look): text in choice boxes (bright/dim), several
local models at once (ask/allow), chess look (board style, pieces), the last tab, the window size,
and per-tab state.

**Look:** dark, and following the desktop's colors. The plugin's `am-*` CSS (theme_css.py) is
translated into a Flutter ThemeData plus a few widgets: FoldCard, TabIntro, SmallButton,
ActionButton and the Mark.

## Steps (Codex reviews every step; findings are verified, then fixed)

1. **Core base + chess rules.** Settings, agents (installed/set up), agent_run with its limits, and
   `chess_rules` ported with the plugin's tests (`test_chess_rules.py` → Dart). The CLI gets
   `agents` and `ask`. *Codex writes chess_rules.dart + tests; Claude writes agents/agent_run/settings.*
2. **Flutter shell + Speed / Head to head / Local LLMs.** Header and tabs, Ctrl+1…7, Ctrl+,,
   Info, Settings, single instance and `--toggle`, the agent checks, result cards, the GPU guard
   dialog, and the duel with blind mode and scores.
3. **Chess.** Board (drawn, drag and click, promotion), vs agent and agent vs agent, thinking time,
   taken pieces, saved games, rename/delete, PGN, replay bar, play from here, and the board look.
   *Codex writes the board widget; Claude writes the game controller.*
4. **Chess from a video.** Drop, paste or pick a file or YouTube link; the text way and the frames
   way; checked moves.
5. **Analyze + Vision.** The capability cards, model choices (`pi --list-models`, Codex
   `models_cache.json`), frame_check, picture/screenshot/video frames (on KDE the screenshot uses
   spectacle, on COSMIC cosmic-screenshot, falling back to grim).
6. **Generate.** Set up with its downloads and progress, Generate, Save as…, and Ask about it
   (hands the picture to Vision).
7. **Bar and install.** The Rust applet and tray, `tools/install-local`, the desktop entries and
   icons, and the **Maprisma Manager catalog entry** `playground` (flutter + rust, like `theme`:
   tree `{lib}/maprisma-playground`, links, desktop files, the tray autostart, `BarIcon` with
   COSMIC applet and KDE tray), plus the Manager's inventory.md.
8. **Checks and publish.** Screenshot comparison per tab, a Codex full review, a README with a
   preview, a public repo at `github.com/maprisma/playground` (MIT), and the Manager pushed with
   its new entry.

## Tests

- Core: `dart test`, with the plugin's Python tests ported: chess rules, chess agent, chess video,
  picture_gen, untrusted input, and the playground basics.
- Agents are faked in tests (a fake `claude` script on PATH). No test asks a real agent or
  downloads anything.
- Flutter: widget tests for the header, tabs, fold cards and the board.
- The live checks ask the real agents (the user's plan tokens): a small sum per agent, one chess
  move, and one vision question.
