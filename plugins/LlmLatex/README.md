# LLM to LaTeX Plugin (MVP)

This plugin sends the current Xournal++ selection to an external LLM endpoint and inserts the returned LaTeX as a text element.

Current phase: MVP fallback behavior.
Returned LaTeX is inserted with app.addTexts, not as a native TeX object yet.

## What It Does

1. Reads selected strokes, texts, images, and selection bounds.
2. Sends a JSON payload to your HTTP endpoint using curl.
3. Extracts a LaTeX string from the response.
4. Inserts that result at the selection bounding-box position.

## Requirements

- Xournal++ with plugin support enabled.
- curl available on PATH.
- A reachable LLM endpoint that accepts JSON.

## Installation

### Option 1: Included in this source tree

If you are building Xournal++ from this repository, this plugin is already in:

- plugins/LlmLatex

The top-level CMake install step installs the plugins directory into share/xournalpp/plugins.

### Option 2: Manual install into a user plugin directory

Copy this folder into your local Xournal++ plugins path so it contains:

- plugin.ini
- main.lua
- README.md

Typical Linux locations used by Xournal++ builds are under XDG data paths, for example:

- ~/.local/share/xournalpp/plugins/LlmLatex

If your Xournal++ packaging uses a different plugin search path, use that location instead.

## Enable The Plugin

1. Start Xournal++.
2. Open the plugin manager in Xournal++.
3. Enable LLM to LaTeX (MVP) plugin.
4. Restart Xournal++ if your build requires restart for new plugins.

Registered action:

- Menu name: LLM to LaTeX (MVP)
- Accelerator: Shift+Alt+L

## Configuration

Settings can be provided in two ways:

1. Environment variables.
2. Config file in the plugin config folder.

Environment variables take precedence over config file values.

### Environment Variables

- XOJ_LLM_LATEX_API_TYPE
- XOJ_LLM_LATEX_ENDPOINT
- XOJ_LLM_LATEX_API_KEY
- XOJ_LLM_LATEX_MODEL
- XOJ_LLM_LATEX_PROMPT_FILE
- XOJ_LLM_LATEX_TIMEOUT_SEC

### Config File

File name:

- llm_latex.conf

Location:

- app.getFolder("config") + /llm_latex.conf

Format:

- key=value per line
- empty lines are ignored
- lines starting with # or ; are ignored

Supported config keys:

- api_type
- endpoint
- api_key
- model
- prompt_file
- timeout_sec

Example:

```ini
api_type=openai
endpoint=https://api.openai.com
api_key=replace-with-token
model=gpt-4.1-mini
prompt_file=prompt-default.txt
timeout_sec=20
```

### Effective Defaults

- timeout_sec default: 15
- minimum timeout_sec: 2
- api_type default: openai
- api_key optional
- model optional
- prompt_file default: prompt-default.txt
- endpoint required

If endpoint is missing, the plugin shows an error dialog and exits.

API type behavior:

1. `api_type=openai` sends a Chat Completions request to `/v1/chat/completions` using `messages` and `response_format`.
2. `api_type=ollama` sends a native Ollama chat request to `/api/chat` using `messages`, `stream=false`, and `format="json"`.
3. If `endpoint` is a base URL, the plugin appends the correct path for the selected API.
4. For both API types, the plugin sends sanitized selection JSON and an SVG rendering of the selected content as text in the user message.

Prompt handling:

1. The plugin reads the prompt text from the configured prompt file.
2. Relative prompt paths are resolved against the plugin config folder.
3. You can keep several prompt files in that folder and switch between them by changing `prompt_file`.

## Endpoint Contract

The plugin converts the selected content into a provider-specific chat request.

OpenAI request shape:

- model
- messages
  - system: prompt file contents
  - user: selection payload JSON plus conversion instruction
- response_format: `{ "type": "json_object" }`

Ollama request shape:

- model
- messages
  - system: prompt file contents
  - user: conversion instruction + selection summary + full selection JSON + SVG markup
- stream: false
- format: json

Selection data embedded in the user message includes:

- selection:
  - toolInfo
  - strokeCount, textCount, imageCount
  - strokes (sanitized)
  - texts (sanitized)
  - images (metadata only in MVP)
- context:
  - xoppFilename
  - currentPage
  - prompt
  - promptFile
  - selectionBounds
  - note
- svg:
  - generated SVG markup of the selected strokes/texts plus image placeholders

Safety and payload limits used by the plugin:

- Max strokes: 50
- Max points per stroke: 80
- Max texts: 40
- Max images: 10
- Max encoded payload size: 350000 bytes

## Response Contract

Preferred response format:

```json
{"latex":"\\frac{a}{b}"}
```

Behavior:

1. OpenAI responses are read from `choices[0].message.content`.
2. Ollama responses are read from `message.content` or `response`.
3. If the content contains a JSON field named `latex`, that value is used.
4. Otherwise, if response content is non-JSON text, full trimmed body is used.
5. Empty or unusable output triggers an error dialog.

Response body is truncated internally to 20000 characters before parsing.

## Security Notes

- Do not hardcode API secrets in source files.
- Prefer environment variables for secrets.
- If you use llm_latex.conf, protect file permissions.
- The plugin shells out to curl; endpoint and headers are shell-quoted in code.

## Troubleshooting

- Selection is empty: select at least one stroke, text, or image first.
- Prompt file is empty or missing: verify `prompt_file` and the target file contents.
- Wrong API type: set `api_type=ollama` for native Ollama endpoints or `api_type=openai` for OpenAI-compatible chat endpoints.
- If results look wrong, verify your selection contains the intended strokes/texts/images.
- Network request failed (curl exit N): verify URL, TLS, proxy, and connectivity.
- Endpoint did not return a usable LaTeX string: check response format.
- Failed to insert LaTeX text: verify document edit state and selection/page context.

For testing, the plugin shows a curl preview dialog before running the request. The preview redacts the bearer token and may truncate large payloads.


## Known MVP Limitations

- Inserts plain text, not native TeX objects.
- Embedded images are currently represented as metadata/placeholder rectangles in the generated SVG.
- Response parsing is minimal and expects simple JSON or plain text output.

Phase 2 will add true native TeX insertion via core API support.
