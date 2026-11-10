# Core protocol (Flutter app ⇄ core isolate)

The app runs `CoreService` (packages/maprisma_playground_core) in a background isolate, as
Maprisma Theme does (`flutter_app/lib/backend.dart`). Messages are JSON strings.

- **Request:** `{"protocol": 1, "id": 7, "method": "ask.run", "params": {...}}`
- **Reply:** `{"id": 7, "result": {...}}` or `{"id": 7, "error": {"code": "...", "message": "..."}}`
- **Event** (any number, before the reply): `{"event": "progress", "id": 7, "data": {...}}`
- **Cancel:** `{"cancel": 7}`. The job stops its children (the whole process group). Then it
  replies with error code `cancelled`, except imports that have read moves: those save and return the partial game.
- **Shutdown:** `null`. Every running job is cancelled, temp folders are removed, and held local
  models are released.

Error codes: `bad_params`, `not_found`, `cancelled`, `failed` (the message says why, in English,
and is shown as it is).

A **target** is the thing that is asked:
- `{"kind": "agent", "command": "claude", "model": "", "level": "normal"}`. `model` is empty for
  the agent's own model.
- `{"kind": "local", "port": 8080, "model": "gemma-…", "runtime": "llama.cpp"}`

An **answer** is
`{"text", "seconds", "tokens_in"?, "tokens_out"?, "cost"?, "per_second"?, "error"}`
(the plugin's `agent_run.Result` and `local_llm.Answer`). `per_second` is omitted for agents; only local models report it.

## Methods

### App and settings
| method | params | result |
|---|---|---|
| `app.info` | – | `{version, desktop, look: desktop_look}` |
| `settings.get` | `{keys?: [..]}` | `{values: {key: value}}` (the defaults filled in) |
| `settings.set` | `{values: {key: value or null}}` | `{}` |

### Agents and local LLMs
| method | params | result |
|---|---|---|
| `agents.list` | – | `{agents: [{command, name, installed, set_up, can_ask, plays_chess, takes_images, reads_untrusted, model_flag}]}`. Only Claude Code, Codex, Hermes and Pi; `set_up` = credentials present (stat only) or a local provider configured. |
| `local.servers` | – | `{servers: [{port, runtime, models: [id]}]}`. Loopback listeners of this user only. |
| `gpu.check` | `{targets: [target]}` | `{fits: bool|null, message, needs: [{label, loaded, size: int|null, bytes_needed: int|null}], needed: int|null, free: int|null, total: int|null}` (gpu_check; asked before two local models run at once) |
| `local.make_room` | `{target}` | `{}` (unloads other models as the plugin does between sequential runs) |

### Asking (Speed and cost, Head to head, Vision, Local LLMs)
| method | params | result |
|---|---|---|
| `ask.run` | `{target, prompt, images?: [path]}` | answer. Images only for `takes_images` agents or local vision models; untrusted text only for `reads_untrusted`. |

### Analyze
| method | params | result |
|---|---|---|
| `analyze.choices` | `{command}` | `{choices: [{label, arg, local?, images?, thinking?, levels?, context?}]}` |
| `analyze.run` | `{command, choice}` | `{}`. Events `finding`: `{key, state: yes/no/slow/unknown/waiting/skipped, summary, detail, download?}`, one per card (`text`, `pictures`, `video`, `thinking`, `chess`, `context`, `making`). Download offers are `{repo, path, size, sha256, target, section}`. |
| `vision.setup` | `{command, choice, download}` | `{}`. Events `progress` `{fraction}` (the projector download, frame_check). |

### Vision
| method | params | result |
|---|---|---|
| `pictures.prepare` | `{path}` | `{path}`: a checked, scaled and re-saved copy in the session's private folder, or error `failed` |
| `pictures.screenshot` | – | `{path}` (spectacle on KDE, cosmic-screenshot on COSMIC, else grim) |
| `pictures.video_frames` | `{path}` | `{paths: [4]}` |
| `pictures.clear` | `{paths: string[]}` or `{}` | `{}` |

### Chess
The rules (`chess_rules.dart`) and the game controller (`ChessGame`) are plain Dart. The app
uses them in its own isolate, because they are cheap and synchronous. Agent moves and imports go
through the protocol.

| method | params | result |
|---|---|---|
| `chess.ask` | `{command, start_fen, moves: [uci], strength, level, retry_of?}` | `{move?: uci, written, comment, error}` |
| `games.list` | `{query?, offset?, limit?}` | `{games: [...], total}` |
| `games.save` | `{game}` | `{id, duplicate?: true}` |
| `games.rename` | `{id, name}` | `{}` |
| `games.delete` | `{id}` | `{}` |
| `games.pgn` | `{id, path}` | `{}` |
| `import.readers` | `{path?, url?}` | `{readers: [command], text_readers: [command], reader_details: [{command, name, local?}], before?: {id, title, date}, seconds?: number}` |
| `import.start` | `{path?, url?, reader, gap, limit, way: "text"/"frames", replace_id?}` | `{game, read: "description"/"commentary"/"frames", unmatched: int}`. Events `progress` `{text, fraction?}`; omitted fraction means indeterminate. |

### Generate
| method | params | result |
|---|---|---|
| `generate.status` | – | `{ready: bool, to_download: int, program: bool, folder: string}` |
| `generate.setup` | – | `{}`. Events `progress` `{fraction, text}`. |
| `generate.run` | `{prompt, size: square/landscape/portrait, seed}` | `{path, seconds, seed}`. Events `progress`. |
| `generate.clear` | – | `{}` (the UI saves a chosen image by copying its path) |


### Saved games and video reading
A game record contains `{id, title, source: string, kind: "played"|"video", date: "YYYY-MM-DD HH:MM", start: FEN, moves: [uci], white, black, result: "1-0"|"0-1"|"1/2-1/2"|"*"}`.
Legacy `name`, `start_fen`, and `created` are also returned; extra metadata is retained.
`games.list` searches titles (case insensitive, every query word), and `total` counts all matches before pagination.
`games.save` updates an explicit id in its existing position. Matching start/moves already saved under another id returns `{id, duplicate: true}` without adding a record.
`games.rename {id, name}`, `games.delete {id}`, and `games.pgn {id, path}` return `{}`.
Stores are limited to 200 records, 4 MiB JSON, and 2000 moves per newly saved game.

`import.readers.readers` lists safe picture readers; `text_readers` includes all ready
`reads_untrusted` agents, including text-only Hermes. `reader_details` retains names and local-model targets.
For a supplied source, `before` identifies a previous reading by video key (YouTube URL variants
and local file symlinks count as the same source). Local duration `seconds` is included when ffprobe can determine it.
Return the previous id as `replace_id` to replace that reading. Limits are seconds (0/300/900/1800;
legacy minute values 5/15/30 are accepted), gaps are 2/4/8 seconds.
Import records also contain `read` and `unmatched`. Cancellation after any moves have been read
saves and returns `{game, read, unmatched}`; before any moves it returns error `cancelled`.
Temporary frames and child process groups are removed in either case.

In replay, `ChessGame.replayTitle` supplies `<title>: move N of M`; `playFromHere` keeps the
original start and moves up to the current replay index, discarding the future replay moves.

Agent executables are resolved on PATH first, then in `~/.local/bin`,
`~/.local/share/mise/shims`, `~/.bun/bin`, `~/.npm-global/bin`, `~/.cargo/bin`,
`~/.deno/bin`, `~/.volta/bin`, `~/.asdf/shims`, and `/home/linuxbrew/.linuxbrew/bin`.
Only regular executables owned by this user or root qualify. Runs use the absolute path and
prepend its directory to the child PATH so shims can find their sibling programs.

Prepared picture ownership: `pictures.prepare`, `pictures.screenshot`, and
`pictures.video_frames` return paths owned by the calling operation. Release them
with `pictures.clear` params `{"paths":["/absolute/prepared/path.jpg", "..."]}`.
Only listed paths belonging to Vision's prepared-picture folder are removed;
`{"paths":[]}` removes nothing. Omitting `paths` (`{}`) clears all of Vision's
prepared pictures. Chess imports use a separate private folder per import and
clean it up themselves, so Vision clear never deletes chess-import frames.
