# Core protocol (Flutter app ⇄ core isolate)

The app runs `CoreService` (packages/maprisma_playground_core) in a background isolate, as
Maprisma Theme does (`flutter_app/lib/backend.dart`). Messages are JSON strings.

- **Request:** `{"protocol": 1, "id": 7, "method": "ask.run", "params": {...}}`
- **Reply:** `{"id": 7, "result": {...}}` or `{"id": 7, "error": {"code": "...", "message": "..."}}`
- **Event** (any number, before the reply): `{"event": "progress", "id": 7, "data": {...}}`
- **Cancel:** `{"cancel": 7}`. The job stops its children (the whole process group). Then it
  replies with error code `cancelled`.
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
(the plugin's `agent_run.Result` and `local_llm.Answer`).

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
| `gpu.check` | `{targets: [target]}` | `{fits: bool, message, alternating_ok: bool}` (gpu_check; asked before two local models run at once) |
| `local.make_room` | `{target}` | `{}` (unloads other models as the plugin does between sequential runs) |

### Asking (Speed and cost, Head to head, Vision, Local LLMs)
| method | params | result |
|---|---|---|
| `ask.run` | `{target, prompt, images?: [path]}` | answer. Images only for `takes_images` agents or local vision models; untrusted text only for `reads_untrusted`. |

### Analyze
| method | params | result |
|---|---|---|
| `analyze.choices` | `{command}` | `{choices: [{label, model, harness?, local?}]}` |
| `analyze.run` | `{command, choice}` | `{}`. Events `finding`: `{key, title, mark: yes/no/slow/unknown/running, summary, text, seconds?, offer?: {kind: "projector", size}}`, one per card (text, pictures, chess_videos, thinking, chess, context, making_pictures). |
| `vision.setup` | `{command, choice}` | `{}`. Events `progress` `{fraction, text}` (the projector download, frame_check). |

### Vision
| method | params | result |
|---|---|---|
| `pictures.prepare` | `{path}` or `{bytes_b64, type}` | `{path}`: a checked, scaled and re-saved copy in the session's private folder, or error `failed` |
| `pictures.screenshot` | – | `{path}` (spectacle on KDE, cosmic-screenshot on COSMIC, else grim) |
| `pictures.video_frames` | `{path}` | `{paths: [4]}` |
| `pictures.clear` | – | `{}` |

### Chess
The rules (`chess_rules.dart`) and the game controller (`ChessGame`) are plain Dart. The app
uses them in its own isolate, because they are cheap and synchronous. Agent moves and imports go
through the protocol.

| method | params | result |
|---|---|---|
| `chess.ask` | `{command, start_fen, moves: [uci], strength, level, retry_of?}` | `{move?: uci, written, comment, error}` |
| `games.list` | `{query?, offset?, limit?}` | `{games: [...], total}` |
| `games.save` | `{game}` | `{id}` |
| `games.rename` / `games.delete` | `{id, name?}` | `{}` |
| `games.pgn` | `{id, path}` | `{}` |
| `import.readers` | – | `{readers: [command]}` (agents that see and `reads_untrusted`) |
| `import.start` | `{path?, url?, reader, gap, limit, way: "text"/"frames", replace_id?}` | `{game?}`. Events `progress` `{fraction, text}`. |

### Generate
| method | params | result |
|---|---|---|
| `generate.status` | – | `{ready, to_download, program, model}` |
| `generate.setup` | – | `{}`. Events `progress` `{fraction, text}`. |
| `generate.run` | `{prompt, size: square/landscape/portrait, seed}` | `{path, seconds, seed}`. Events `progress`. |
| `generate.save` | `{path, to}` | `{}` |
