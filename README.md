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
    AttachmentImporter.swift   Image downscaling, PDF/text extraction, data URLs
    Tools/                     AgentTool protocol + ToolRegistry, one file per domain
  Views/                       Home, TaskDetail, TaskList, Library, Settings/Onboarding, Composer
```

Any OpenAI-compatible endpoint works (OpenAI, OpenRouter, Vercel AI Gateway, Ollama, or a custom URL such as a self-hosted [ai-backends](https://github.com/donvito/ai-backends)). The chat model must support tool calling. Keys live in the iOS Keychain.

## Build

```bash
brew install xcodegen
xcodegen generate
open Sidekick.xcodeproj      # or:
xcodebuild -project Sidekick.xcodeproj -target Sidekick -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`Sidekick.xcodeproj` is generated from `project.yml`; edit the YAML and re-run `xcodegen generate` rather than editing the project by hand.

## Try it without an API key

`Sidekick` talks to whatever base URL you configure, so a tiny local mock is enough to exercise the full loop (streaming, multi-tool rounds, approval, PDF/image/email artifacts). Choose **Custom** in onboarding, set the base URL to `http://localhost:<port>`, any model name, and leave the key blank.
