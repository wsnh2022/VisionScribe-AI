# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AHK v2 + Python desktop tool for extracting text from images via two pipelines:
- **OCR mode**: Tesseract OCR (via Python) → editable intermediate box → AI (OpenRouter text API)
- **Direct vision mode**: Images sent directly to a vision model via Python (base64 + OpenRouter vision API)

## Files

| File | Role |
|------|------|
| `VisionScribe_v2.ahk` | **Active script** — v1.6 feature set; v2.0 (InstaSnap + Notion) not yet implemented |
| `AI_Image_To_Text.ahk` | Old standalone — hardcoded models, no config, no OCR. Not active. |
| `InstaImage2TextConverter.py` | Python CLI helper — OCR, direct vision, and (v2) instasnap + notion modes |
| `config.ini` | Live config — API key, Tesseract path, models, prompts (gitignored) |
| `config - example.ini` | Safe template to commit — no real keys |
| `roadmap.md` | Full v2.0 implementation plan including phase-by-phase code detail |

## Running

Double-click the `.ahk` file or:
```
"C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" "VisionScribe_v2.ahk"
```

`Ctrl+S` reloads the running script during development.

## Python Setup

```bash
# v1.x
pip install pytesseract pillow requests

# v2.0 additions (Notion push)
pip install notion-client
```

`pytesseract` + `pillow` — OCR mode only. `requests` — direct vision and InstaSnap fetch. `notion-client` — Notion push (v2.0-beta).

Tesseract OCR must be installed separately (Windows installer). Default path: `C:\Program Files\Tesseract-OCR\tesseract.exe`. Override in `config.ini [Paths] TesseractExe`.

## Architecture

### AHK side (`VisionScribe_v2.ahk` / `v1.ahk`)

Single `ImageChat` static class — all GUI controls, state, and methods are static properties. `__New()` runs at class load time and reads `config.ini` before `Build()` is called.

**OCR pipeline** (`ExtractOCR` → `Send`):
1. Text/MD files: read directly via `FileRead`
2. Image files: shelled to `InstaImage2TextConverter.py` with `--tesseract` flag, output captured from a temp file
3. Result lands in editable OCR box — user can fix before AI send
4. `BuildTextJson()` concatenates prompt + OCR text, POSTs to OpenRouter text endpoint

**Direct vision pipeline** (`SendDirect`):
1. Shells to `InstaImage2TextConverter.py --direct` with `--apikey`, `--model`, `--prompt`, and file paths
2. Python handles base64 encoding and the API call (binary-safe, avoids AHK `crypt32` approach)
3. Result captured from temp file

**Model fallback**: if selected model returns 429 / rate-limit signals, tries remaining models from `ModelLabels` in order (when Auto Fallback is checked).

**JSON parsing**: done via regex on raw response string — no JSON library. `ParseResponse()` also strips markdown formatting from the AI response for plain-text display.

### Python helper (`InstaImage2TextConverter.py`)

Modes dispatched in `main()` by flag presence. File arguments are remaining positional args after all flags are consumed by `pop_arg()`. Files sorted by `natural_sort_key` so `img2.png` comes before `img10.png`.

| Flag | Mode | Added in |
|------|------|----------|
| *(none)* | OCR via Tesseract | v1.5 |
| `--direct` | Base64 + OpenRouter vision API | v1.6 |
| `--instasnap` | oEmbed thumbnail fetch → temp file path on stdout | v2.0-alpha |
| `--notion` | Markdown → Notion blocks → create page via API | v2.0-beta |

**v2.0 Python detail:**

`instasnap_mode()`:
- Accepts full Instagram URL or bare shortcode
- Calls `https://api.instagram.com/oembed/?url={post_url}&format=json` (no auth)
- Downloads `thumbnail_url` to `%TEMP%\ahk_instasnap_{shortcode}.jpg`
- Prints the temp file path to stdout — AHK reads it the same way as OCR output
- Errors prefixed with `ERROR:` so AHK can detect them

`notion_mode()`:
- Receives `--token`, `--database`, `--title`, `--mdfile` (path to temp file with Markdown)
- Markdown → Notion blocks: `#`→`heading_1`, `##`→`heading_2`, `###`→`heading_3`, `- `→`bulleted_list_item`, `1. `→`numbered_list_item`, else `paragraph`
- Blocks exceeding 2000 chars are split (Notion API limit)
- POSTs to `https://api.notion.com/v1/pages`, prints created page URL or `ERROR:`

### Config-driven design

- **Models**: add/remove in `config.ini [Models]` without touching AHK. `Count` controls how many entries are read. First entry = default.
- **Prompt presets**: same pattern in `[Prompts]`. Selecting a preset fills the prompt Edit box immediately. Prompts must be single-line in the INI (no multiline support).
- **Last folder**: auto-persisted to `config.ini [State] LastFolder` on each Browse.

## Key Constraints

- `config.ini` is gitignored — never commit it. Edit `config - example.ini` for safe-to-commit changes.
- `AI_Image_To_Text.ahk` has its API key hardcoded in static properties — it predates the config-driven approach and is not the active script.
- The AHK `PostJson()` method uses `WinHTTP.WinHTTPRequest.5.1` (synchronous) — the GUI freezes during API calls. This is expected behavior, not a bug.
- Response display strips markdown formatting (headers, bold, inline code, bullets normalized) before showing in the Edit control.

## v2.0 InstaSnap — New AHK architecture

New static properties on `ImageChat`:
```ahk
static InstaUrlEdit  := unset   ; URL/shortcode input
static FetchBtn      := unset   ; triggers FetchInstagram()
static InstaStatusLbl := unset  ; inline fetch status
static NotionBtn     := unset   ; Push to Notion (disabled until result ready)
static NotionToken   := ""      ; from config.ini [Notion] Token
static NotionDbId    := ""      ; from config.ini [Notion] DatabaseId
static LastShortcode := ""      ; stored after successful fetch, used as Notion page title
```

GUI layout addition (between Files row and Step 1 divider):
```
--- InstaSnap: paste URL or shortcode ---
URL: [________________________________] [Fetch Image]
     Fetch status: Ready.
```

`FetchInstagram()` flow:
1. Read `InstaUrlEdit.Value` — shell to Python `--instasnap`
2. Capture stdout (temp file path) — load into `SelectedFiles`, store shortcode in `LastShortcode`
3. User then clicks existing **Send Image Direct** — no new pipeline needed

`PushToNotion()` flow:
1. Write `ResultEdit.Value` to temp `.txt` file
2. Shell to Python `--notion --mdfile "temppath"` — avoids shell-escaping issues with long Markdown
3. Show returned page URL in `StatusLbl`

`NotionBtn` is enabled only when `ResultEdit` has content AND `NotionToken != ""`.

Hotkey (after `ImageChat.Build()`): reads clipboard, regex-matches Instagram URL or bare shortcode, populates `InstaUrlEdit`, calls `FetchInstagram()`. Hotkey string loaded from `config.ini [Hotkeys] InstaSnap`.

See `roadmap.md` for full phase-by-phase implementation plan.
