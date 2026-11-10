# Core protocol amendments

The authoritative protocol, including step 2 and step 3 shapes, is now
[`docs/protocol.md`](../../../docs/protocol.md).

# Historical step 2 notes (superseded where shapes differ)

This is the step 2 amendment to the repository's `docs/protocol.md`. It lives
inside the core package because this implementation was restricted to editing
`packages/maprisma_playground_core`.

The existing protocol 1 request, reply, event, cancellation and shutdown envelopes
are unchanged. All operations below return a result object. Failures use
`bad_params`, `failed`, `cancelled` or `not_found` as documented by the base protocol.
Picture decoding/preparation failures always use `failed` with an English message.

| Method | Params | Exact result shape |
|---|---|---|
| `gpu.check` | `{targets: [target]}` | `{fits: bool|null, message: string, needs: [{label: string, loaded: bool, size: int|null, bytes_needed: int|null}], needed: int|null, free: int|null, total: int|null}` |
| `local.servers` | `{}` | `{servers: [{port: int, runtime: string, name: string, models: [string], error?: string}]}` |
| `analyze.choices` | `{command: string}` | `{choices: [{label: string, arg: string, local?: {runtime: string, port?: int, model: string}, images?: bool|null, thinking?: bool|null, levels?: [string], context?: int}]}` |
| `analyze.run` | `{command: string, choice: choice}` | `{}` |
| `vision.setup` | `{command: string, choice: choice, download: download}` | `{}` |
| `pictures.prepare` | `{path: string}` | `{path: string}` |
| `pictures.screenshot` | `{}` | `{path: string}` |
| `pictures.video_frames` | `{path: string}` | `{paths: [string, string, string, string]}` |
| `pictures.clear` | `{}` | `{}` |
| `generate.status` | `{}` | `{ready: bool, program: bool, to_download: int, folder: string}` |
| `generate.setup` | `{}` | `{}` |
| `generate.run` | `{prompt: string, size: "square"|"landscape"|"portrait", seed: int}` | `{path: string, seconds: number, seed: int}` |
| `generate.clear` | `{}` | `{}` |
| `games.list` | `{query?: string, offset?: int, limit?: int}` | `{games: [game], total: int}` |
| `games.save` | `{game: game}` | `{id: string}` |
| `games.rename` | `{id: string, name: string}` | `{}` |
| `games.delete` | `{id: string}` | `{}` |
| `games.pgn` | `{id: string, path: string}` | `{}` |
| `import.readers` | `{}` | `{readers: [{command: string, name: string, local?: {runtime: string, port: int, model: string}}]}` |
| `import.start` | `{path?: string, url?: string, reader: string|reader, way: "text"|"frames", gap?: 2|4|8, limit?: 0|300|900|1800, replace_id?: string}` | `{game: game}` |

All GPU sizes, model download sizes and `to_download` are bytes. With no GPU total,
`fits` is true, `free`/`total` are null. Unknown weight sizes remain null. A single
model needs no guard and returns empty needs and null memory figures. Servers
owned by another account are listed with `error: "another account"` and empty
models; they are never contacted. Other errors are preserved in `error`.

A `finding` event is `{key, state, summary, detail, download?}`. Keys are `text`,
`pictures`, `video`, `thinking`, `chess`, `context`, `making`; states are `yes`,
`no`, `slow`, `unknown`, `waiting`, `skipped`. Each completed card is sent immediately.
A `download` is `{repo, path, size, sha256, target, section}`. Return the choice and
download unchanged to `vision.setup`; only an offer issued in this session may
be installed. Its progress events are `{fraction}`. Cached vision checks are
forgotten after setup. Shared llama.cpp/Pi configuration keeps the plugin's names
and backups under `~/.local/state/ai-playground/backups/`.

Generate and import emit `progress: {fraction, text}`. Generate starts with
`text: "loading the model"`. Setup uses `(program)` and `(42 %)` style text.
Cancellation retains Generate's `.part` files for resumption, but deletes an
incomplete projector download. `to_download` subtracts valid own partial-file
lengths. No program release bytes are included in this count, as in the plugin.
The data root is `Places.data`, displayed with `~` for home.

A `game` is `{id, name, white, black, source?: {kind: "file"|"url", value},
start_fen, moves: [uci], created, result?}`. Additional plugin metadata such as
`kind`, `read`, and legacy `title`/`start`/`date` is retained. Legacy game fields
are accepted on save/load. Games are bounded to 200 records, 4 MiB JSON and 2000
moves per newly saved game; PGN writes and the store use atomic 0600 writes.
Same-source saves replace their existing id (YouTube URL variants count as one
source); imports also suppress identical start-position/move sequences.

Import limits are seconds; legacy minute values 5/15/30 are also accepted.
Local readers carry an extra `local` object. Their `command` can also be returned
unchanged as `local:<port>:<model>`. Text imports permit reads-untrusted text-only
agents; if frames are required, a safe seeing agent is selected. Cloud frame
questions run in batches of up to three, in chronological answer order; local
questions are sequential. YouTube downloads disable configuration and execution
hooks and validate the resulting real path inside a private temporary directory.

`ask.run` images must belong to this service's prepared-picture folder or its
Generate output folder. Symlink escapes and arbitrary file paths are rejected.
Pictures are limited by headers before decoding, re-encoded as metadata-free
JPEG quality 90, and scaled to 1600 pixels maximum. Both output folders are 0700,
cleared independently, and removed on disposal. Shutdown cancels and reaps child
process groups before removing output folders.

## Deliberate differences from upstream

- Maprisma data/store locations and the JSON field names above follow the supplied
  app contract; shared vision configuration retains upstream names.
- Screenshot backends are selected for KDE/COSMIC/other Wayland desktops; COSMIC
  flags are checked using `--help` before capture.
- Incoming pictures, including imported frames, are always stripped and prepared
  before they are sent. Codex can receive only the core's synthetic Analyze probe,
  never an external picture or video text.
- Archive headers are validated before inflation; duplicate archive names are also
  rejected. Downloads and shared writes reject hard links, and temporary writes
  cannot broaden an existing file's mode.
- Downloads and generators use the shared process-group runner; cancellations
  stop descendants too. Hash verification checks cancellation between chunks.
- Generate reports remaining partial-file bytes. Upstream counts entire missing
  model files even if a resumable partial download exists.
- Cloud frame concurrency is bounded in batches of three rather than a sliding
  queue of three; frame order, safety and maximum concurrency are the same.
- GTK-specific drop-stream and packaging/translation tests are outside this pure
  Dart package. Their relevant URL/media guards are covered here with fake tools.
