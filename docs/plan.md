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

**Window:** the window is a normal one. Closing it quits the app. `--toggle` (and Esc on a tab) hides a
shown window while work runs and closes it otherwise, and otherwise starts the app or shows it. A second start hands its arguments to
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
   icons, and the **Maprisma Settings catalog entry** `playground` (flutter + rust, like `theme`:
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

## After Codex's plan review (docs/reviews/codex-plan-review.md, 18 findings, all accepted)

- **Who does what.**
  - Codex (A): the core and its safety. That covers the shared process runner (new session, a
    process-group kill on timeout, overflow or cancel, stdin fed on its own, agent-session
    variables dropped, every child known so shutdown can end it), agents (the access metadata of
    the four adapters, stat-only credential checks, local providers), the media guards (picture
    size, dimensions and pixels checked *before* decoding; ffmpeg protocol and format whitelists;
    yt-dlp without user config or exec hooks), local HTTP (only listeners owned by this user,
    literal 127.0.0.1, no proxy, no redirects, bounded responses), downloads (resumable `.part`
    files opened O_NOFOLLOW with owner and link-count checks, locks, archive checks), the
    `ChessGame` controller, CoreService plus the protocol, and the CLI.
  - Claude (B): the native shell, widgets and pages, the board widget through ChessGame, the
    bar, the installer, the Manager entry and the screenshots.
  - Each reviews the other's work after every slice.
- **Untrusted input:** only `reads_untrusted` agents get it (Claude, Hermes, Pi). Codex never
  does, because its read-only sandbox can still read files.
- **Chess prompts go on stdin** where the agent takes it. This is a deliberate improvement over
  the plugin.
- **Shared configuration that Analyze/frame_check touches** (`~/.config/llama.cpp/models.ini`,
  Pi's models.json entry, the projector next to a model, a server started for vision) keeps the
  plugin's shared names and its backup/safe-write rules. The Manager lists it as shared and never
  removes it.
- **Single instance:** GApplication remote actions (not a socket). Closing quits. Before it quits,
  Dart is told (`closing`) and cancels every job.
- **Settings:** Corners is kept. "Several local models at once" is not a setting: it is the
  per-run GPU dialog.
- **Parity checklist** (screenshots and the acceptance list per tab):
  - Chess: the position editor (piece cards to place, Clear, Reset, side to move), both
    strengths, pause/resume, retry, comments, the separate Games page (search, pages, open the
    original, auto replay), and replacement of a game from the same source.
  - Import: reader choice, frame gap, length limit, a cost warning, the fall-back from text to
    frames, and cancel.
  - Analyze: all 7 cards and the projector download.
  - Generate: sizes, cancel, several results, Clear, seed and time shown.
  - Speed/Duel: local models next to agents, and models unloaded between sequential runs.
  - Esc/Backspace go back.
- **Order:** core runner and agents → shell, plus Speed/Duel/Local as an installed vertical slice
  with the bar on KDE → Chess → Analyze and vision readiness → Vision → video import → Generate →
  Manager and publish.
- **Licenses:** before publishing, the plugin's notices are kept and copied assets are audited
  (icons/Asterism/COPYING).

## New tab: Automaton (the user's request, 2026-11-10)

A tab of its own **after Chess**, not in the plugin: an interactive cellular automaton. Tabs:
Analyze, Chess, Automaton, Speed and cost, Head to head, Vision, Generate, Local LLMs (Ctrl+1…8).
Its look is the playground's own (tab intro, folding cards, small buttons, the board's colours).

- **The engine** (`automaton.dart` in the core, pure Dart, tested). It is a two-state grid with
  Life-like rules in B/S notation: Conway's Life B3/S23, HighLife B36/S23, Seeds B2/S,
  Day & Night B3678/S34678, Maze B3/S12345, Life without Death B3/S012345678, Replicator
  B1357/S1357, or a rule the user types. It also has Brian's Brain, a 3-state rule (B2/S/C3).
  Edges either wrap (torus) or are dead.
- **Interaction:**
  - Paint with the mouse: click or drag sets cells, the right button erases.
  - Play/Pause (Space), Step (→), speed from 1 to 60 generations per second, and zoom with
    Ctrl+wheel.
  - Random fill with a density setting, Clear, and patterns stamped by clicking: glider, LWSS,
    pulsar, Gosper glider gun, R-pentomino, acorn, diehard.
  - The generation, the population and a population sparkline are shown.
- **The grid** follows the window size (cell size 4–24 px). The cells use the board look's
  colours.
- Settings it remembers: rule, speed, wrap, cell size.
