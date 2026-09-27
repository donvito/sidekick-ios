# Sidekick — a personal AI assistant that does the work

Sidekick is a native iOS app (SwiftUI, iOS 17+) that goes beyond chat: you describe an outcome, and an agent plans, uses tools on your device, asks for approval before side effects, and hands back finished deliverables.

## What it does

| Area | How |
|---|---|
| Research the web | `web_search` (DuckDuckGo) + `fetch_url` (readable text / PDF extraction), cited in the answer |
| Understand images & files | Attach photos, camera shots, PDFs, text/CSV/JSON/code; images go to the model as vision input, files are extracted locally |
| Create files | `create_document` → Markdown / PDF / text / CSV / HTML, saved to the Library |
| Generate images & video | `generate_image` (`/images/generations`) and `generate_video` (`/videos` job polling) |
| Calendar & reminders | EventKit: list events, create events, create reminders — gated by an approval card |
| Health | HealthKit read-only summary (steps, energy, exercise, resting HR, sleep) |
| Email assistance | `draft_email` → saved draft, opens in Mail via `mailto:` |
| Marketing / work tasks | Quick-action templates + the document/image tools |
| Memory | `remember` persists durable facts that are injected into future system prompts |
| Offline chat | **On-device (offline)** provider runs Gemma locally with LiteRT‑LM — no key, no network after the model download |

The UX is task-centric: **Home** (quick actions + composer) → **Task** (live timeline of tool steps, approvals, artifacts, final answer) → **Tasks** history → **Library** of everything created → **Settings**.

## Architecture

```
Sidekick/
  App/SidekickApp.swift        SwiftData container, tab root, router, theme
  Models/Models.swift          WorkTask, ChatMessage, ToolStep, Attachment, Artifact, MemoryItem
  Services/
    LLMClient.swift            OpenAI-compatible streaming /chat/completions with tool calls
    AgentRunner.swift          Agent loop: stream → tool calls → approval → run → loop (max 12 rounds)
    AppSettings.swift          Provider presets, Keychain-backed API key
    LocalModelStore.swift      Catalog + download/import/delete of .litertlm models (Application Support/LocalModels)
    LocalLLMEngine.swift       LiteRT-LM Engine/Conversation wrapper streaming StreamEvents
    AttachmentImporter.swift   Image downscaling, PDF/text extraction, data URLs
    Tools/                     AgentTool protocol + ToolRegistry, one file per domain
  Views/                       Home, TaskDetail, TaskList, Library, Settings/Onboarding, Composer
```

Any OpenAI-compatible endpoint works (OpenAI, OpenRouter, Vercel AI Gateway, Ollama, or a custom URL such as a self-hosted [ai-backends](https://github.com/donvito/ai-backends)). The chat model must support tool calling. Keys live in the iOS Keychain.

### On-device models (offline)

Pick **On-device (offline)** as the provider to chat without internet. Inference runs on the phone via [LiteRT‑LM](https://github.com/google-ai-edge/LiteRT-LM) (Swift package `LiteRTLM`, pinned to 0.17.1 in `project.yml`).

- **Models**: the built-in catalog offers Gemma 4 E2B (~2.6 GB) and Gemma 4 E4B (~3.7 GB) from `litert-community` on Hugging Face. Any other `.litertlm` file (e.g. Gemma 3n E2B/E4B from `google/gemma-3n-*-litert-lm`, which requires accepting Google's license) can be added with **Import a .litertlm file**.
- **Download** happens once, with progress, pause/resume and a free-space check; files are stored in Application Support and excluded from iCloud backup. Delete them from Settings when no longer needed.
- **Capabilities**: text chat, writing, summarising attached files and describing photos. Sidekick's tools (web, calendar, health, file/image/video generation, email) are not offered to local models — the system prompt tells the model to suggest switching to a cloud provider for those.
- **Hardware**: use a recent iPhone (A17 Pro / 8 GB RAM class recommended for E4B). The GPU backend is used on device; the simulator falls back to CPU and is slow, so test real inference on hardware.

## Build

```bash
brew install xcodegen
xcodegen generate
open Sidekick.xcodeproj      # or:
xcodebuild -project Sidekick.xcodeproj -target Sidekick -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`Sidekick.xcodeproj` is generated from `project.yml`; edit the YAML and re-run `xcodegen generate` rather than editing the project by hand.

If package resolution fails with a `git-lfs` smudge error while checking out LiteRT-LM (the repo tracks Android prebuilts with LFS that the iOS build doesn't need), resolve with LFS disabled:

```bash
GIT_LFS_SKIP_SMUDGE=1 xcodebuild -project Sidekick.xcodeproj -resolvePackageDependencies
```

## Try it without an API key

`Sidekick` talks to whatever base URL you configure, so a tiny local mock is enough to exercise the full loop (streaming, multi-tool rounds, approval, PDF/image/email artifacts). Choose **Custom** in onboarding, set the base URL to `http://localhost:<port>`, any model name, and leave the key blank.
