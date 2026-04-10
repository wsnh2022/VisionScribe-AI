# Roadmap - VisionScribe

---

## v1.0 (Shipped)
- Single image input via Browse button
- GDI+ resize to 800px before base64 encoding
- Image sent directly to OpenRouter vision models
- Model dropdown: Llama 3.2 11B Vision, Gemini 2.0 Flash Lite, Gemma 3 4B
- Auto-fallback across models on rate limit
- Single response Edit box with Copy button

---

## v1.5 (Shipped)
Theme: OCR-first pipeline with editable intermediate step

- Multi-file selection: images AND .txt / .md files in one dialog
- Tesseract OCR via Python CLI (no Tkinter, stdout only)
- .txt and .md files read directly via FileRead
- Editable OCR Raw Output box - fix Tesseract errors before AI send
- Two-step GUI: Step 1 Extract OCR, Step 2 Send to AI
- Status label showing current pipeline stage
- Save .md button with file manager dialog
- Python script takes file paths as CLI args, writes only to stdout

---

## v1.6 (Shipped)
Theme: Dual-mode pipeline + config-driven models and prompts

- Send Image Direct mode - bypasses OCR, sends images to vision model via Python
- Base64 encoding moved to Python (binary safe, crypt32 removed)
- Model list moved to config.ini [Models] - add/remove without code edits
- Prompt presets dropdown - 10 presets with [OCR] / [Vision] / [OCR/Vision] tags
- Prompts stored in config.ini [Prompts] - add/edit without code edits
- Dark mode GUI (BackColor 1E1E1E, dark Edit controls)
- AI Result box made editable before saving
- Save OCR button - saves OCR box content to .txt via file manager
- Remember last used folder across sessions via config.ini [State]
- OCR into AI button (renamed from Send to AI for clarity)
- View Logs link to openrouter.ai/logs in GUI
- Auto Fallback checkbox for model chain on rate limit

---

## v2.0 (Planned)
Theme: InstaSnap - Instagram post to Markdown pipeline

### Concept
Extract content from Instagram posts by shortcode and convert to organized Markdown notes,
saved locally or pushed to Notion.

Flow:
Instagram URL or shortcode → download image → OCR or Direct Vision → AI → .md file or Notion page

### Input
- User pastes full URL: `https://www.instagram.com/p/DWTpDvNj72a/`
- Or just the shortcode: `DWTpDvNj72a`
- Or selects text in any app and triggers via hotkey
- Shortcode extracted by regex from whatever form is provided

### Image Acquisition
- Option A: RapidAPI / Instagram oEmbed / public CDN scrape to download image directly
- Option B: Open post URL in default browser, user screenshots, drops into tool
- Option C: Puppeteer/Playwright headless fetch (Python subprocess) - most reliable for private posts

### Processing
- Downloaded image fed into existing Send Image Direct pipeline
- Or OCR if image contains mostly text (e.g. quote cards, infographics)
- Prompt preset added: "Extract Instagram Post Content [Vision]"

### Output Options
1. Save .md locally - file manager dialog, same as existing Save .md
2. Push to Notion API
   - Notion integration token stored in config.ini [Notion]
   - Target database or page ID configured in config.ini
   - Creates a new Notion page with title = post shortcode or first line of content
   - Body = AI-generated Markdown converted to Notion blocks

### config.ini additions
```ini
[Notion]
Token      = secret_xxxxx
DatabaseId = xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### New GUI elements
- Tab or section: "InstaSnap"
- Input field: paste URL or shortcode
- Button: Fetch Image
- Status shows download progress
- Existing pipeline takes over after image is fetched
- Extra button: Push to Notion (appears after AI result is ready)

### Technical dependencies
- `requests` - already required
- `notion-client` or raw Notion API via requests - Python
- Image download: `requests` + URL resolution from Instagram oEmbed endpoint
- oEmbed endpoint (no auth): `https://api.instagram.com/oembed/?url=POST_URL`
  - Returns thumbnail_url which can be downloaded directly

### Constraints and risks
- Instagram oEmbed only returns thumbnail (640px) not full resolution
- Private posts require login - out of scope for v2.0
- Instagram rate limits oEmbed at scale - acceptable for personal use
- Notion API has block-level rate limits - handle with retry

### Phased delivery
- v2.0-alpha: URL input + oEmbed thumbnail download + existing pipeline
- v2.0-beta: Notion push output
- v2.0-rc: Hotkey trigger from selected text in any window

---

## v2.0 Implementation Plan

### File changes

| File | What changes |
|------|-------------|
| `VisionScribe_v2.ahk` | New static props, InstaSnap GUI section, `FetchInstagram()`, `PushToNotion()`, hotkey |
| `InstaImage2TextConverter.py` | `instasnap_mode()`, `notion_mode()`, updated `main()` dispatch |
| `config - example.ini` | `[Notion]` section, `[Hotkeys]` section, 11th prompt preset |

`VisionScribe_v2.ahk` currently carries the v1.6 codebase - v2.0 features are not yet added.

---

### Phase alpha - Instagram fetch

**Python: `instasnap_mode()`**

New `--instasnap` flag in `InstaImage2TextConverter.py`:
```
python InstaImage2TextConverter.py --instasnap "https://www.instagram.com/p/DWTpDvNj72a/"
python InstaImage2TextConverter.py --instasnap "DWTpDvNj72a"
```
1. If input has no `/`, treat as shortcode - build full URL: `https://www.instagram.com/p/{shortcode}/`
2. Call oEmbed (no auth): `https://api.instagram.com/oembed/?url={post_url}&format=json`
3. Extract `thumbnail_url` from JSON response
4. Download to `%TEMP%\ahk_instasnap_{shortcode}.jpg` via `requests`
5. Print temp file path to stdout - AHK reads it the same way it reads OCR output
6. Handle errors: network failure, bad shortcode (oEmbed 400), rate limit (429) - prefix with `ERROR:`

**AHK: GUI section in `Build()`**

Add between Files row and Step 1 divider:
```
--- InstaSnap: paste URL or shortcode ---
URL: [________________________________] [Fetch Image]
     Status: Ready.
```
New controls: `InstaUrlEdit`, `FetchBtn`, `InstaStatusLbl`

**AHK: `FetchInstagram()` method**

1. Read `InstaUrlEdit.Value` - reject if empty
2. Disable `FetchBtn`, set `InstaStatusLbl` → "Fetching..."
3. Shell to Python `--instasnap` → capture stdout from temp file
4. If returned path exists on disk: load into `SelectedFiles`, update `PathEdit`, store shortcode in `static LastShortcode`
5. If stdout starts with `ERROR:`, show in `InstaStatusLbl`
6. Re-enable `FetchBtn`

After fetch, user continues with the existing **Send Image Direct** button - no new pipeline.

**`config - example.ini`: new preset**
```ini
11_Title = Extract Instagram Post Content [Vision]
11_Text  = Describe the full content of this Instagram post. Extract all visible text exactly as written, identify the subject or topic, and note any key visual elements. Format as clean Markdown with a title, extracted text section, and brief description.
```
Increment `[Prompts] Count` to `11`.

---

### Phase beta - Notion push

**`config - example.ini`: new section**
```ini
[Notion]
Token      = secret_xxxxx
DatabaseId = xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**AHK: read in `__New()`**
```ahk
static NotionToken := ""
static NotionDbId  := ""
```
Read from `config.ini [Notion]`. If both empty, Notion button stays disabled.

**AHK: `NotionBtn` in `Build()`**

Add to the existing action button row:
```
[OCR into AI]  [Copy Response]  [Save .md]  [Push to Notion]
```
Starts disabled. Enabled after `Send()` or `SendDirect()` produce a result AND `NotionToken != ""`.

**Python: `notion_mode()`**

New `--notion` flag:
```
python InstaImage2TextConverter.py --notion --token "secret_..." --database "abc123" --title "DWTpDvNj72a" --mdfile "C:\Temp\result.txt"
```
Pass AI result via temp file (not inline shell arg) to avoid escaping issues with long text.

Markdown → Notion block conversion:
- `# text` → `heading_1` block
- `## text` → `heading_2` block
- `### text` → `heading_3` block
- `- text` / `* text` → `bulleted_list_item` block
- `1. text` → `numbered_list_item` block
- Everything else → `paragraph` block
- Split any block exceeding 2000 chars (Notion API limit)

POST to `https://api.notion.com/v1/pages` with `parent.database_id`, `properties.title`, and `children` blocks.
Print created page URL to stdout, or `ERROR:` on failure.

**AHK: `PushToNotion()` method**

1. Get `ResultEdit.Value` - return if empty
2. Title = `LastShortcode` if set, else first non-empty line of result
3. Write result text to temp file, pass file path to Python (avoids shell escaping on long Markdown)
4. Shell to Python `--notion` with token, database, title, mdfile
5. Show response URL or error in `StatusLbl`

---

### Phase rc - Hotkey trigger

**AHK: global hotkey (after `ImageChat.Build()`)**

```ahk
^+i:: {
    prevClip := A_Clipboard
    A_Clipboard := ""
    Send "^c"
    ClipWait 1
    selected := A_Clipboard
    A_Clipboard := prevClip
    if RegExMatch(selected, "instagram\.com/p/|^[A-Za-z0-9_-]{10,12}$") {
        ImageChat.InstaUrlEdit.Value := Trim(selected)
        ImageChat.Win.Show()
        ImageChat.FetchInstagram()
    }
}
```

Make hotkey configurable in `config.ini`:
```ini
[Hotkeys]
InstaSnap = ^+i
```

---
