# Maprisma Playground

Try out the AI agents on your computer, one test per tab:
- **Analyze:** see at a glance what an agent and its model can do.
- **Chess:** play against Claude Code, Codex, Hermes or Pi, or let two of them play each other.
  An agent that runs on a local LLM plays with that model.
- **Automaton:** watch a cellular automaton.
- **Speed and cost:** compare how fast the agents answer and what it costs.
- **Head to head:** judge two answers blind.
- **Vision:** test what they see in a picture.
- **Generate:** make pictures from a text on your own graphics card.
- **Local LLMs:** ask your local models and see their tokens per second.

It is the Flutter port of [AI Playground](https://github.com/uBruckhaus/omarchy-ai-playground), the
Omarchy plugin, for **KDE Plasma** and **COSMIC**. It goes with
[Maprisma](https://github.com/maprisma/maprisma), which shows and changes how the agents are set up;
Maprisma Playground asks them. The one exception is Analyze, which may set up a local model for
pictures (see "Shared settings Analyze may change" below).

**For now it works with four agents: Claude Code, Codex, Hermes and Pi.**

![Maprisma Playground](preview.png)

## Install

With [Maprisma Manager](https://github.com/maprisma/manager): **Install** on Maprisma Playground.

From the source (Flutter, Dart, cargo; no root needed):

```sh
git clone https://github.com/maprisma/playground.git maprisma-playground
cd maprisma-playground
FLUTTER=/path/to/flutter/bin tools/install-local
```

This installs into `~/.local/lib/maprisma-playground`, with links in `~/.local/bin`, a desktop
entry and icons.
- **KDE Plasma:** a tray icon (a gamepad) is started and starts again at login. The Maprisma Icons
  panel widget shows it with the other Maprisma apps.
- **COSMIC:** add "Maprisma Playground" in Settings › Desktop › Panel › Applets.

A click on the icon opens Maprisma Playground, brings it to the front, or closes it when it is
already the window in front (`maprisma-playground --toggle`). `maprisma-playground --test chess`
opens a tab, including in a window that is already open.

Optional tools, each only for the feature named:
- `yt-dlp`, `ffmpeg` and `ffprobe`: reading a chess game from a video, and video frames on Vision.
- `spectacle` (KDE), `cosmic-screenshot` (COSMIC) or `grim`: Screenshot on Vision.

## The tabs

- **Analyze:** pick an agent and one of its models. There is one card per capability (text,
  pictures, chess videos, thinking time, chess, context, making pictures), with a mark: green ✓
  can, red ✗ cannot, yellow ! only slowly, ? not stated. A few short test questions are asked; the
  rest is read from the agent's own settings and model lists.
- **Chess:** play against an agent, or let two agents play each other (also agents that run on local
  models), each with its own strength.
  - The board checks every move. An agent that answers with an illegal move is asked again.
  - You can set up a position by hand.
  - Games are saved, replayed move by move, renamed and saved as PGN.
  - A game can be read from a chess video (a file or a YouTube link).
- **Automaton:** a cellular automaton you draw on. It has Life-like rules in B/S notation (Conway's
  Life, HighLife, Seeds, Day & Night, Brian's Brain …, or your own), patterns such as the glider
  and the Gosper glider gun, random fill, step, speed, and wrapping edges. Nothing is asked of any
  agent.
- **Speed and cost:** one question to several agents and local models; their answers side by side,
  with time, tokens and cost where the agent reports them.
- **Head to head:** one question to two agents or local models. You pick the better answer. In
  **Blind** mode you see who wrote which only afterwards. The score is kept.
- **Vision:** a picture, a screenshot or four frames of a video, for the agents that can see and
  run without tools (Claude Code, Pi). Pictures are scaled down and saved again first, so no photo
  metadata goes out.
- **Generate:** a picture from a text, made on this computer's graphics card with
  [stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) and the
  [Z-Image-Turbo](https://huggingface.co/leejet/Z-Image-Turbo-GGUF) model. The first time, **Set
  up** downloads the program (about 40 MB) and the model with its text encoder (about 11 GB), each
  file checked against its SHA-256.
- **Local LLMs:** one question to a model of a local LLM server running on this computer
  (llama.cpp, Ollama, LM Studio, vLLM, Jan, KoboldCpp), with its time and tokens per second,
  optionally compared with a second model. When two local models might not fit in the graphics
  card's memory together, you are asked first.

Keys:
- Ctrl+1 … Ctrl+8 switch tabs.
- Ctrl+, opens the settings.
- Esc goes back.

## How the agents are asked

Each agent is started once per question, the way its own command line offers for one prompt and one
answer:
- `claude -p --tools ""`: no tools.
- `hermes -z`: only its in-memory task list.
- `pi -p --no-tools --no-mcp --no-skills --no-context-files`: no tools.
- `codex exec --sandbox read-only`: Codex keeps its tools, inside its read-only sandbox. That is why
  it is never given anything from outside (see below).

The rules for each run:
- It runs in an empty private folder (created 0700, deleted afterwards).
- It has a time limit, and its answer is read with a size limit.
- Its whole process group is stopped when the time is up, when you cancel, or when the app closes.
- Claude Code, Codex and Pi get the question on stdin. Hermes takes it only as an argument.
- Every program is started as an argument list, never through a shell.
- Nothing an agent answers is run.
- What comes from the web (a video's captions, pictures) goes only to agents without any tools.
  Codex's read-only sandbox can still read files, so it never gets it.

## Shared settings Analyze may change

When a local model could see pictures but lacks its vision file (a projector), the Pictures card
offers **Download the vision file**. After you click it, Analyze does the following:
- It puts the file next to the model.
- It adds the file to `~/.config/llama.cpp/models.ini`, or to Pi's model entry. The old file is
  backed up first and the new one is written in one step.
- It may restart the local LLM server it started for the test.

These settings belong to the local LLM and Pi, so removing Maprisma Playground leaves them in place.
Nothing else outside `~/.config/maprisma-playground` and `~/.local/share/maprisma-playground` is
changed.

## Privacy

The agents send the question to their own providers, as they always do; Maprisma Playground adds
nothing. Local LLM servers are asked only when they run under your own account, at 127.0.0.1,
without a proxy. Generate downloads only from GitHub (stable-diffusion.cpp's release, checked by its
published digest) and Hugging Face (files pinned by size and SHA-256). Settings and saved games stay
in `~/.config/maprisma-playground`.

## Building and testing

```sh
cd packages/maprisma_playground_core && dart test     # the core: rules, runner, agents, chess, automaton
cd flutter_app && flutter test                        # the window
cd bar && cargo test                                  # the tray's menu
```

The plan and the reviews are in `docs/`. The core speaks the protocol in `docs/protocol.md`.

## License

MIT, like AI Playground.
