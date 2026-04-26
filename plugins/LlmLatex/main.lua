-- LlmLatex plugin MVP:
-- 1) Collect selection metadata from strokes/images/texts
-- 2) Send payload to an external LLM endpoint
-- 3) Insert returned LaTeX as text (Phase 1 fallback)

local CONFIG_FILENAME = "llm_latex.conf"
local MENU_NAME = "LLM to LaTeX (MVP)"
local DEFAULT_PROMPT_FILENAME = "prompt-default.txt"
local DEFAULT_API_TYPE = "openai"
local DEFAULT_SELECTION_IMAGE_WIDTH = 1800

local DEFAULT_TIMEOUT_SEC = 15
local MAX_STROKES = 50
local MAX_POINTS_PER_STROKE = 80
local MAX_TEXTS = 40
local MAX_IMAGES = 10
local MAX_RESPONSE_CHARS = 20000
local MAX_CURL_PREVIEW_BODY_CHARS = 1200
local MAX_CURL_DIALOG_CHARS = 4000
local MAX_REQUEST_BODY_CHARS = 8000000
local MAX_CURL_ERROR_CHARS = 1200

local function shellQuote(s)
  if s == nil then
    return "''"
  end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function startsWith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function endsWith(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

local function isAbsolutePath(path)
  return startsWith(path, "/")
end

local function fileExists(path)
  local f = io.open(path, "r")
  if not f then
    return false
  end
  f:close()
  return true
end

local function normalizeApiType(value)
  local apiType = trim(value):lower()
  if apiType == "ollama" then
    return "ollama"
  end
  return DEFAULT_API_TYPE
end

local function stripTrailingSlash(url)
  return (url:gsub("/+$", ""))
end

local function encodeBase64(data)
  local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local result = {}
  local len = #data
  local i = 1

  while i <= len do
    local b1 = data:byte(i) or 0
    local b2 = data:byte(i + 1) or 0
    local b3 = data:byte(i + 2) or 0

    local c1 = math.floor(b1 / 4) + 1
    local c2 = (b1 % 4) * 16 + math.floor(b2 / 16) + 1
    local c3 = (b2 % 16) * 4 + math.floor(b3 / 64) + 1
    local c4 = (b3 % 64) + 1

    result[#result + 1] = alphabet:sub(c1, c1)
    result[#result + 1] = alphabet:sub(c2, c2)

    if i + 1 <= len then
      result[#result + 1] = alphabet:sub(c3, c3)
    else
      result[#result + 1] = "="
    end

    if i + 2 <= len then
      result[#result + 1] = alphabet:sub(c4, c4)
    else
      result[#result + 1] = "="
    end

    i = i + 3
  end

  return table.concat(result)
end

local function extractJsonString(raw, key)
  local pattern = '"' .. key .. '"%s*:%s*"'
  local startPos, endPos = raw:find(pattern)
  if not startPos then
    return nil
  end

  local i = endPos + 1
  local out = {}
  local len = #raw
  while i <= len do
    local ch = raw:sub(i, i)
    if ch == '"' then
      return table.concat(out)
    end
    if ch == "\\" and i < len then
      i = i + 1
      local esc = raw:sub(i, i)
      if esc == '"' or esc == "\\" or esc == "/" then
        out[#out + 1] = esc
      elseif esc == "n" then
        out[#out + 1] = "\n"
      elseif esc == "t" then
        out[#out + 1] = "\t"
      elseif esc == "r" then
        out[#out + 1] = "\r"
      elseif esc == "b" then
        out[#out + 1] = "\b"
      elseif esc == "f" then
        out[#out + 1] = "\f"
      else
        out[#out + 1] = "\\"
        out[#out + 1] = esc
      end
    else
      out[#out + 1] = ch
    end
    i = i + 1
  end

  return nil
end

local function resolveEndpointUrl(settings)
  local endpoint = stripTrailingSlash(settings.endpoint)
  if settings.apiType == "ollama" then
    endpoint = endpoint:gsub("/v[0-9]+$", "")
    if endsWith(endpoint, "/api/chat") then
      return endpoint
    end
    if endsWith(endpoint, "/api") then
      return endpoint .. "/chat"
    end
    return endpoint .. "/api/chat"
  end

  if endsWith(endpoint, "/chat/completions") then
    return endpoint
  end
  if endsWith(endpoint, "/v1") then
    return endpoint .. "/chat/completions"
  end
  return endpoint .. "/v1/chat/completions"
end

local function latexInstruction()
  return "Return only JSON with a single key named \"latex\"."
end

local function pluginDir()
  -- debug.getinfo(1).source is "@/path/to/main.lua" when loaded from a file
  local src = debug.getinfo(1, "S").source or ""
  local path = src:match("^@(.+)$") or ""
  local dir = path:match("^(.*)/[^/]+$") or ""
  return dir
end

local function parseConfig(path)
  local cfg = {}
  local f = io.open(path, "r")
  if not f then
    return cfg
  end
  for line in f:lines() do
    local t = trim(line)
    if t ~= "" and not startsWith(t, "#") and not startsWith(t, ";") then
      local k, v = t:match("^([%w_]+)%s*=%s*(.-)%s*$")
      if k and v and v ~= "" then
        cfg[k] = v
      end
    end
  end
  f:close()
  return cfg
end

local function readConfigFile()
  -- Load defaults from the plugin directory (ships next to main.lua), then
  -- let the user config folder override individual keys.
  local dirCfg = parseConfig(pluginDir() .. "/" .. CONFIG_FILENAME)
  local userCfg = parseConfig(app.getFolder("config") .. "/" .. CONFIG_FILENAME)
  for k, v in pairs(userCfg) do
    dirCfg[k] = v
  end
  return dirCfg
end

local function resolveSettings()
  local cfg = readConfigFile()

  local apiType = os.getenv("XOJ_LLM_LATEX_API_TYPE") or cfg.api_type or DEFAULT_API_TYPE
  local endpoint = os.getenv("XOJ_LLM_LATEX_ENDPOINT") or cfg.endpoint or ""
  local apiKey = os.getenv("XOJ_LLM_LATEX_API_KEY") or cfg.api_key or ""
  local model = os.getenv("XOJ_LLM_LATEX_MODEL") or cfg.model or ""
  local promptFile = os.getenv("XOJ_LLM_LATEX_PROMPT_FILE") or cfg.prompt_file or DEFAULT_PROMPT_FILENAME
  local selectionImageWidthRaw =
      os.getenv("XOJ_LLM_LATEX_SELECTION_IMAGE_WIDTH") or cfg.selection_image_width or tostring(DEFAULT_SELECTION_IMAGE_WIDTH)
  local timeoutRaw = os.getenv("XOJ_LLM_LATEX_TIMEOUT_SEC") or cfg.timeout_sec or tostring(DEFAULT_TIMEOUT_SEC)
  local timeoutSec = tonumber(timeoutRaw) or DEFAULT_TIMEOUT_SEC
  local selectionImageWidth = tonumber(selectionImageWidthRaw) or DEFAULT_SELECTION_IMAGE_WIDTH
  if timeoutSec < 2 then
    timeoutSec = 2
  end
  if selectionImageWidth < 200 then
    selectionImageWidth = 200
  end

  local promptPath = trim(promptFile)
  if promptPath == "" then
    promptPath = DEFAULT_PROMPT_FILENAME
  end
  if not isAbsolutePath(promptPath) then
    local configPromptPath = app.getFolder("config") .. "/" .. promptPath
    if fileExists(configPromptPath) then
      promptPath = configPromptPath
    else
      promptPath = pluginDir() .. "/" .. promptPath
    end
  end

  return {
    apiType = normalizeApiType(apiType),
    endpoint = trim(endpoint),
    apiKey = trim(apiKey),
    model = trim(model),
    promptPath = promptPath,
    selectionImageWidth = math.floor(selectionImageWidth),
    timeoutSec = math.floor(timeoutSec)
  }
end

local function isArrayTable(tbl)
  local n = #tbl
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" or k < 1 or k > n or math.floor(k) ~= k then
      return false
    end
  end
  return true
end

local function jsonEscape(str)
  return tostring(str)
      :gsub("\\", "\\\\")
      :gsub('"', '\\"')
      :gsub("\b", "\\b")
      :gsub("\f", "\\f")
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t")
end

local function encodeJson(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    return value and "true" or "false"
  end
  if t == "number" then
    if value ~= value then
      return "null"
    end
    return tostring(value)
  end
  if t == "string" then
    return '"' .. jsonEscape(value) .. '"'
  end
  if t == "table" then
    if isArrayTable(value) then
      local parts = {}
      for i = 1, #value do
        parts[#parts + 1] = encodeJson(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local parts = {}
    for k, v in pairs(value) do
      if type(k) == "string" then
        parts[#parts + 1] = '"' .. jsonEscape(k) .. '":' .. encodeJson(v)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  return "null"
end

local function copyNumericArray(src, maxItems)
  local out = {}
  if type(src) ~= "table" then
    return out
  end
  local count = math.min(#src, maxItems)
  for i = 1, count do
    out[i] = tonumber(src[i]) or 0
  end
  return out
end

local function sanitizeStrokes(strokes)
  local out = {}
  local count = math.min(#strokes, MAX_STROKES)
  for i = 1, count do
    local s = strokes[i]
    local entry = {
      x = copyNumericArray(s.x, MAX_POINTS_PER_STROKE),
      y = copyNumericArray(s.y, MAX_POINTS_PER_STROKE),
      pressure = copyNumericArray(s.pressure, MAX_POINTS_PER_STROKE),
      tool = s.tool,
      width = s.width,
      color = s.color,
      fill = s.fill,
      lineStyle = s.lineStyle
    }
    out[#out + 1] = entry
  end
  return out
end

local function sanitizeTexts(texts)
  local out = {}
  local count = math.min(#texts, MAX_TEXTS)
  for i = 1, count do
    local t = texts[i]
    out[#out + 1] = {
      text = t.text,
      x = t.x,
      y = t.y,
      width = t.width,
      height = t.height,
      color = t.color,
      font = t.font
    }
  end
  return out
end

local function sanitizeImages(images)
  local out = {}
  local count = math.min(#images, MAX_IMAGES)
  for i = 1, count do
    local im = images[i]
    out[#out + 1] = {
      x = im.x,
      y = im.y,
      width = im.width,
      height = im.height,
      format = im.format,
      imageWidth = im.imageWidth,
      imageHeight = im.imageHeight
    }
  end
  return out
end

local function safeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    return nil
  end
  return result
end

local function buildPayload(settings)
  local strokes = safeCall(app.getStrokes, "selection") or {}
  local texts = safeCall(app.getTexts, "selection") or {}
  local images = safeCall(app.getImages, "selection") or {}
  local selectionInfo = safeCall(app.getToolInfo, "selection") or {}
  local doc = safeCall(app.getDocumentStructure) or {}

  local hasSelection = (#strokes > 0) or (#texts > 0) or (#images > 0)

  local payload = {
    task = "convert_selection_to_latex",
    model = settings.model,
    selection = {
      toolInfo = selectionInfo,
      strokeCount = #strokes,
      textCount = #texts,
      imageCount = #images,
      strokes = sanitizeStrokes(strokes),
      texts = sanitizeTexts(texts),
      images = sanitizeImages(images)
    },
    context = {
      xoppFilename = doc.xoppFilename,
      currentPage = tonumber(doc.currentPage) or 1,
      prompt = "",
      promptFile = settings.promptPath,
      selectionBounds = (selectionInfo and selectionInfo.snappedBounds) or (selectionInfo and selectionInfo.boundingBox) or {},
      note = "Images are metadata-only in MVP. " .. latexInstruction()
    }
  }

  return payload, hasSelection, selectionInfo
end

local function buildOllamaSelectionSummary(payload)
  return {
    selection = {
      strokeCount = payload.selection.strokeCount,
      textCount = payload.selection.textCount,
      imageCount = payload.selection.imageCount,
      bounds = payload.context.selectionBounds
    },
    context = {
      xoppFilename = payload.context.xoppFilename,
      currentPage = payload.context.currentPage
    }
  }
end

local function buildApiRequest(settings, payload, selectionImageBase64)
  local selectionJson = encodeJson({
    selection = payload.selection,
    context = payload.context
  })

  local userContent = table.concat({
    "Convert this Xournal++ selection into LaTeX.",
    latexInstruction(),
    "Selection payload:",
    selectionJson
  }, "\n\n")

  if settings.apiType == "ollama" then
    local summaryJson = encodeJson(buildOllamaSelectionSummary(payload))
    return {
      model = settings.model,
      stream = false,
      format = "json",
      messages = {
        { role = "system", content = payload.context.prompt },
        {
          role = "user",
          content = table.concat({
            "Convert this selected handwritten content into LaTeX.",
            latexInstruction(),
            "Focus on the selected region (bounds in document units):",
            summaryJson
          }, "\n\n"),
          images = {selectionImageBase64}
        }
      }
    }
  end

  return {
    model = settings.model,
    response_format = { type = "json_object" },
    messages = {
      { role = "system", content = payload.context.prompt },
      { role = "user", content = userContent }
    }
  }
end

local function parseLatexText(text)
  local trimmed = trim(text or "")
  if trimmed == "" then
    return nil
  end

  local latex = extractJsonString(trimmed, "latex")
  if latex and trim(latex) ~= "" then
    return trim(latex)
  end

  if trimmed:sub(1, 1) ~= "{" then
    return trimmed
  end

  return nil
end

local function extractLatexFromResponse(settings, raw)
  local latex = extractJsonString(raw, "latex")
  if latex and trim(latex) ~= "" then
    return trim(latex)
  end

  if settings.apiType == "ollama" then
    local content = raw:match('"message"%s*:%s*%b{}')
    if content then
      local messageText = extractJsonString(content, "content")
      latex = parseLatexText(messageText)
      if latex then
        return latex
      end
    end

    local responseText = extractJsonString(raw, "response")
    latex = parseLatexText(responseText)
    if latex then
      return latex
    end
  else
    local choiceMessage = raw:match('"message"%s*:%s*%b{}')
    if choiceMessage then
      local messageText = extractJsonString(choiceMessage, "content")
      latex = parseLatexText(messageText)
      if latex then
        return latex
      end
    end
  end

  local trimmed = trim(raw)
  if trimmed:sub(1, 1) ~= "{" then
    return trimmed
  end

  return nil
end

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function writeAll(path, data)
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(data)
  f:close()
  return true
end

local function truncateForDialog(text, maxChars)
  if #text <= maxChars then
    return text
  end
  return text:sub(1, maxChars) .. "\n... [truncated]"
end

local function loadPromptText(promptPath)
  local promptText = trim(readAll(promptPath) or "")
  if promptText == "" then
    return nil, "Prompt file is empty or missing: " .. promptPath
  end
  return promptText
end

local function renderCurrentPageAsBase64Png(settings, payload)
  local tmpPath = os.tmpname() .. ".png"
  local pageNo = tonumber(payload.context.currentPage) or 1
  local exportOpts = {
    outputFile = tmpPath,
    range = tostring(pageNo),
    background = "all",
    pngWidth = settings.selectionImageWidth
  }

  local ok, exportErr = pcall(app.export, exportOpts)
  if not ok then
    os.remove(tmpPath)
    return nil, "Failed to export page image for LLM request: " .. tostring(exportErr)
  end

  local pngData = readAll(tmpPath)
  os.remove(tmpPath)
  if not pngData or pngData == "" then
    return nil, "Failed to read exported page image for LLM request."
  end

  return encodeBase64(pngData)
end

local function buildCurlCommand(settings, bodyPath, outPath, httpPath, errPath, statusPath)
  local parts = {
    "curl -sS --connect-timeout 5 --max-time " .. tostring(settings.timeoutSec),
    "-H " .. shellQuote("Content-Type: application/json")
  }

  if settings.apiKey ~= "" then
    parts[#parts + 1] = "-H " .. shellQuote("Authorization: Bearer " .. settings.apiKey)
  end

  parts[#parts + 1] = "--data-binary @" .. shellQuote(bodyPath)
  parts[#parts + 1] = shellQuote(settings.endpoint)
  parts[#parts + 1] = "-o " .. shellQuote(outPath)
  parts[#parts + 1] = "-w " .. shellQuote("%{http_code}")
  parts[#parts + 1] = "> " .. shellQuote(httpPath)
  parts[#parts + 1] = "2> " .. shellQuote(errPath)

  if statusPath and statusPath ~= "" then
    parts[#parts + 1] = "; printf '%s' $? > " .. shellQuote(statusPath)
  end

  return table.concat(parts, " ")
end

local function buildCurlPreview(settings, body)
  local previewBody = body
  if #previewBody > MAX_CURL_PREVIEW_BODY_CHARS then
    previewBody = previewBody:sub(1, MAX_CURL_PREVIEW_BODY_CHARS) .. "... [truncated]"
  end

  local parts = {
    "curl -sS --connect-timeout 5 --max-time " .. tostring(settings.timeoutSec),
    "-H " .. shellQuote("Content-Type: application/json")
  }

  if settings.apiKey ~= "" then
    parts[#parts + 1] = "-H " .. shellQuote("Authorization: Bearer <redacted>")
  end

  parts[#parts + 1] = "--data-raw " .. shellQuote(previewBody)
  parts[#parts + 1] = shellQuote(settings.endpoint)

  return truncateForDialog(table.concat(parts, " "), MAX_CURL_DIALOG_CHARS)
end

local function requestLatex(settings, payload, selectionImageBase64)
  local bodyPath = os.tmpname()
  local outPath = os.tmpname()
  local httpPath = os.tmpname()
  local errPath = os.tmpname()
  local statusPath = os.tmpname()

  local requestPayload = buildApiRequest(settings, payload, selectionImageBase64)
  local body = encodeJson(requestPayload)
  if #body > MAX_REQUEST_BODY_CHARS then
    return nil, "Payload too large; reduce selection size."
  end
  if not writeAll(bodyPath, body) then
    return nil, "Could not write temporary request file."
  end

  local requestSettings = {
    apiKey = settings.apiKey,
    endpoint = resolveEndpointUrl(settings),
    timeoutSec = settings.timeoutSec
  }
  local cmd = buildCurlCommand(requestSettings, bodyPath, outPath, httpPath, errPath, statusPath)

  os.execute(cmd)

  local statusText = readAll(statusPath) or "999"
  local code = tonumber(trim(statusText)) or 999
  local httpCodeText = trim(readAll(httpPath) or "")
  local httpCode = tonumber(httpCodeText) or 0
  local curlErr = trim(readAll(errPath) or "")
  local raw = readAll(outPath) or ""

  os.remove(bodyPath)
  os.remove(outPath)
  os.remove(httpPath)
  os.remove(errPath)
  os.remove(statusPath)

  if code ~= 0 then
    local errMsg = "Network request failed (curl exit " .. tostring(code) .. "). Endpoint: " .. requestSettings.endpoint
    if curlErr ~= "" then
      errMsg = errMsg .. "\n\ncurl stderr:\n" .. truncateForDialog(curlErr, MAX_CURL_ERROR_CHARS)
    end
    return nil, errMsg
  end

  if httpCode >= 400 then
    local errMsg = "HTTP request failed (status " .. tostring(httpCode) .. "). Endpoint: " .. requestSettings.endpoint
    if curlErr ~= "" then
      errMsg = errMsg .. "\n\ncurl stderr:\n" .. truncateForDialog(curlErr, MAX_CURL_ERROR_CHARS)
    end
    if raw ~= "" then
      errMsg = errMsg .. "\n\nresponse:\n" .. truncateForDialog(raw, MAX_CURL_ERROR_CHARS)
    end
    return nil, errMsg
  end

  if #raw > MAX_RESPONSE_CHARS then
    raw = raw:sub(1, MAX_RESPONSE_CHARS)
  end

  local latex = trim(extractLatexFromResponse(settings, raw) or "")
  if latex == "" then
    return nil, "Endpoint did not return a usable LaTeX string."
  end

  return latex
end

local function pickInsertPosition(selectionInfo)
  if selectionInfo and selectionInfo.boundingBox then
    local b = selectionInfo.boundingBox
    local x = tonumber(b.x)
    local y = tonumber(b.y)
    if x and y then
      return x, y
    end
  end
  return 40, 40
end

local function insertLatexAsText(latex, selectionInfo)
  local x, y = pickInsertPosition(selectionInfo)
  local opts = {
    texts = {
      {
        text = latex,
        color = 0x000000,
        x = x,
        y = y
      }
    },
    allowUndoRedoAction = "grouped"
  }
  local refs = app.addTexts(opts)
  if refs and #refs > 0 then
    app.clearSelection()
    app.addToSelection(refs)
  end
end

local function showError(msg)
  app.openDialog(msg, {"Ok"}, "", true)
end

function initUi()
  app.registerUi({
    ["menu"] = MENU_NAME,
    ["callback"] = "runLlmLatexMvp",
    ["accelerator"] = "<Shift><Alt>l"
  })
end

function runLlmLatexMvp()
  local settings = resolveSettings()
  if settings.endpoint == "" then
    showError(
      "Missing endpoint. Set XOJ_LLM_LATEX_ENDPOINT or configure " .. CONFIG_FILENAME .. " in plugin config folder."
    )
    return
  end
  if settings.model == "" then
    showError("Missing model. Set XOJ_LLM_LATEX_MODEL or configure model in " .. CONFIG_FILENAME .. ".")
    return
  end

  local payload, hasSelection, selectionInfo = buildPayload(settings)
  if not hasSelection then
    showError("Selection is empty. Select content first.")
    return
  end

  local promptText, promptErr = loadPromptText(settings.promptPath)
  if not promptText then
    showError(promptErr)
    return
  end

  payload.context.prompt = promptText

  local selectionImageBase64 = nil
  if settings.apiType == "ollama" then
    local imageErr
    selectionImageBase64, imageErr = renderCurrentPageAsBase64Png(settings, payload)
    if not selectionImageBase64 then
      showError(imageErr)
      return
    end
  end

  local latex, err = requestLatex(settings, payload, selectionImageBase64)
  if not latex then
    showError(err)
    return
  end

  local ok, insertErr = pcall(insertLatexAsText, latex, selectionInfo)
  if not ok then
    showError("Failed to insert LaTeX text: " .. tostring(insertErr))
    return
  end

end
