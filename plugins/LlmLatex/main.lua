-- LlmLatex plugin MVP:
-- 1) Collect selection metadata from strokes/images/texts
-- 2) Send payload to an external LLM endpoint
-- 3) Insert returned LaTeX as text (Phase 1 fallback)
-- 4) Insert returned LaTeX as alatex opbject (Phase 2+)

local CONFIG_FILENAME = "llm_latex.conf"
local MENU_NAME = "LLM to LaTeX (MVP)"
local TOOLBAR_ID = "LLM_LATEX"
local TOOLBAR_ICON_NAME = "xopp-tool-math-tex"
local DEFAULT_PROMPT_FILENAME = "prompt-default.txt"
local DEFAULT_API_TYPE = "openai"
local DEFAULT_SELECTION_IMAGE_WIDTH = 2200
local DEFAULT_SELECTION_IMAGE_DENSITY = 300
local DEFAULT_SHOW_DEBUG_DIALOGS = false
local DEFAULT_SHOW_INSERT_DEBUG_DIALOGS = false
local DEFAULT_MATCH_SELECTION_COLOR = true

local DEFAULT_TIMEOUT_SEC = 15
local MAX_STROKES = 150 -- limit number of strokes to prevent excessively large payloads and timeouts
local MAX_POINTS_PER_STROKE = 100 -- limit number of points per stroke to prevent excessively large payloads and timeouts
local MAX_TEXTS = 40
local MAX_IMAGES = 10
local MAX_RESPONSE_CHARS = 20000
local MAX_CURL_PREVIEW_BODY_CHARS = 1200
local MAX_CURL_DIALOG_CHARS = 4000
local MAX_REQUEST_BODY_CHARS = 8000000
local MAX_CURL_ERROR_CHARS = 1200
local MAX_DEBUG_PREVIEW_CHARS = 1400

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

local function parseBool(value, fallback)
  if value == nil then
    return fallback
  end
  local s = trim(tostring(value)):lower()
  if s == "1" or s == "true" or s == "yes" or s == "on" then
    return true
  end
  if s == "0" or s == "false" or s == "no" or s == "off" then
    return false
  end
  return fallback
end

local function stripTrailingSlash(url)
  return (url:gsub("/+$", ""))
end

local function monotonicMs()
  local f = io.open("/proc/uptime", "r")
  if f then
    local line = f:read("*l")
    f:close()
    local secs = line and tonumber((line:match("^(%S+)")))
    if secs then
      return math.floor(secs * 1000)
    end
  end
  return (os.time() or 0) * 1000
end

local function elapsedMs(startMs)
  return math.max(0, monotonicMs() - (tonumber(startMs) or 0))
end

local function appendTimingMeta(lines, prefix, timing)
  if type(timing) ~= "table" then
    return
  end

  local keys = {}
  for k, _ in pairs(timing) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    lines[#lines + 1] = tostring(prefix or "") .. key .. "=" .. tostring(timing[key])
  end
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
    result[#result + 1] = (i + 1 <= len) and alphabet:sub(c3, c3) or "="
    result[#result + 1] = (i + 2 <= len) and alphabet:sub(c4, c4) or "="

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
  local imageWidthRaw =
      os.getenv("XOJ_LLM_LATEX_SELECTION_IMAGE_WIDTH") or cfg.selection_image_width or tostring(DEFAULT_SELECTION_IMAGE_WIDTH)
    local imageDensityRaw =
      os.getenv("XOJ_LLM_LATEX_SELECTION_IMAGE_DENSITY") or cfg.selection_image_density or tostring(DEFAULT_SELECTION_IMAGE_DENSITY)
  local showDebugDialogsRaw =
      os.getenv("XOJ_LLM_LATEX_SHOW_DEBUG_DIALOGS") or cfg.show_debug_dialogs
  local showInsertDebugDialogsRaw =
      os.getenv("XOJ_LLM_LATEX_SHOW_INSERT_DEBUG_DIALOGS") or cfg.show_insert_debug_dialogs
    local matchSelectionColorRaw =
      os.getenv("XOJ_LLM_LATEX_MATCH_SELECTION_COLOR") or cfg.match_selection_color
  local timeoutRaw = os.getenv("XOJ_LLM_LATEX_TIMEOUT_SEC") or cfg.timeout_sec or tostring(DEFAULT_TIMEOUT_SEC)
  local timeoutSec = tonumber(timeoutRaw) or DEFAULT_TIMEOUT_SEC
  local selectionImageWidth = tonumber(imageWidthRaw) or DEFAULT_SELECTION_IMAGE_WIDTH
    local selectionImageDensity = tonumber(imageDensityRaw) or DEFAULT_SELECTION_IMAGE_DENSITY
  local showDebugDialogs = parseBool(showDebugDialogsRaw, DEFAULT_SHOW_DEBUG_DIALOGS)
  local showInsertDebugDialogs = parseBool(showInsertDebugDialogsRaw, DEFAULT_SHOW_INSERT_DEBUG_DIALOGS)
  local matchSelectionColor = parseBool(matchSelectionColorRaw, DEFAULT_MATCH_SELECTION_COLOR)
  if timeoutSec < 2 then
    timeoutSec = 2
  end
  if selectionImageWidth < 600 then
    selectionImageWidth = 600
  end
  if selectionImageDensity < 72 then
    selectionImageDensity = 72
  elseif selectionImageDensity > 1200 then
    selectionImageDensity = 1200
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
    selectionImageDensity = math.floor(selectionImageDensity),
    showDebugDialogs = showDebugDialogs,
    showInsertDebugDialogs = showInsertDebugDialogs,
    matchSelectionColor = matchSelectionColor,
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
      currentPage = tonumber(doc.currentPage) or 1,
      pageWidth = nil,
      pageHeight = nil,
      selectionBounds = (selectionInfo and selectionInfo.snappedBounds) or (selectionInfo and selectionInfo.boundingBox) or {}
    }
  }

  local pages = (doc and doc.pages) or {}
  local page = pages[payload.context.currentPage]
  if page then
    payload.context.pageWidth = tonumber(page.pageWidth)
    payload.context.pageHeight = tonumber(page.pageHeight)
  end

  return payload, hasSelection, selectionInfo
end

local function xmlEscape(text)
  return tostring(text or "")
      :gsub("&", "&amp;")
      :gsub("<", "&lt;")
      :gsub(">", "&gt;")
      :gsub('"', "&quot;")
      :gsub("'", "&apos;")
end

local function updateExtents(extents, x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    return
  end

  if not extents.minX or x < extents.minX then extents.minX = x end
  if not extents.maxX or x > extents.maxX then extents.maxX = x end
  if not extents.minY or y < extents.minY then extents.minY = y end
  if not extents.maxY or y > extents.maxY then extents.maxY = y end
end

local function getSelectionFrame(payload)
  local bounds = payload.context.selectionBounds or {}
  local x = tonumber(bounds.x)
  local y = tonumber(bounds.y)
  local width = tonumber(bounds.width)
  local height = tonumber(bounds.height)

  if x and y and width and height and width > 0 and height > 0 then
    return x, y, width, height
  end

  local extents = {}

  for _, s in ipairs(payload.selection.strokes or {}) do
    local pointCount = math.min(#(s.x or {}), #(s.y or {}))
    for i = 1, pointCount do
      updateExtents(extents, tonumber(s.x[i]), tonumber(s.y[i]))
    end
  end

  for _, t in ipairs(payload.selection.texts or {}) do
    local tx = tonumber(t.x)
    local ty = tonumber(t.y)
    local tw = tonumber(t.width) or 0
    local th = tonumber(t.height) or 0
    updateExtents(extents, tx, ty)
    updateExtents(extents, (tx or 0) + tw, (ty or 0) + th)
  end

  for _, im in ipairs(payload.selection.images or {}) do
    local ix = tonumber(im.x)
    local iy = tonumber(im.y)
    local iw = tonumber(im.width) or 0
    local ih = tonumber(im.height) or 0
    updateExtents(extents, ix, iy)
    updateExtents(extents, (ix or 0) + iw, (iy or 0) + ih)
  end

  if extents.minX and extents.maxX and extents.minY and extents.maxY then
    local pad = 4
    local ex = extents.minX - pad
    local ey = extents.minY - pad
    local ew = math.max(1, (extents.maxX - extents.minX) + pad * 2)
    local eh = math.max(1, (extents.maxY - extents.minY) + pad * 2)
    return ex, ey, ew, eh
  end

  return 0, 0, 1000, 1000
end

local function colorIntToSvg(color)
  local n = tonumber(color)
  if not n then
    return "#000000"
  end

  if n < 0 then
    n = n + 4294967296
  end

  local rgb = n % 16777216
  return string.format("#%06x", rgb)
end

local function fmtCoord(v)
  return string.format("%.4f", tonumber(v) or 0)
end

local function buildSelectionSvg(payload)
  local minX, minY, width, height = getSelectionFrame(payload)
  local svgPad = 30  -- extra whitespace around content to prevent clipping
  local svgW = width + svgPad * 2
  local svgH = height + svgPad * 2
  local parts = {
    string.format(
      '<svg xmlns="http://www.w3.org/2000/svg" width="%.2f" height="%.2f" viewBox="0 0 %.2f %.2f">',
      svgW,
      svgH,
      svgW,
      svgH
    ),
    string.format('<rect x="0" y="0" width="%.2f" height="%.2f" fill="white"/>', svgW, svgH)
  }

  for _, s in ipairs(payload.selection.strokes or {}) do
    local pointCount = math.min(#(s.x or {}), #(s.y or {}))
    if pointCount > 0 then
      local points = {}
      for i = 1, pointCount do
        local x = tonumber(s.x[i]) or 0
        local y = tonumber(s.y[i]) or 0
        points[#points + 1] = fmtCoord(x - minX + svgPad) .. "," .. fmtCoord(y - minY + svgPad)
      end

      parts[#parts + 1] = string.format(
        '<polyline fill="none" stroke="%s" stroke-width="%.2f" stroke-linecap="round" stroke-linejoin="round" points="%s"/>',
        colorIntToSvg(s.color),
        tonumber(s.width) or 1.5,
        table.concat(points, " ")
      )
    end
  end

  for _, t in ipairs(payload.selection.texts or {}) do
    local tx = (tonumber(t.x) or 0) - minX + svgPad
    local ty = (tonumber(t.y) or 0) - minY + svgPad
    local fontSize = math.max(8, tonumber(t.height) or 16)
    parts[#parts + 1] = string.format(
      '<text x="%.2f" y="%.2f" fill="%s" font-size="%.2f">%s</text>',
      tx,
      ty,
      colorIntToSvg(t.color),
      fontSize,
      xmlEscape(t.text)
    )
  end

  for i, im in ipairs(payload.selection.images or {}) do
    local ix = (tonumber(im.x) or 0) - minX + svgPad
    local iy = (tonumber(im.y) or 0) - minY + svgPad
    local iw = math.max(1, tonumber(im.width) or 1)
    local ih = math.max(1, tonumber(im.height) or 1)
    parts[#parts + 1] = string.format(
      '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="#fff8e1" stroke="#cc8800" stroke-dasharray="5 3"/>',
      ix,
      iy,
      iw,
      ih
    )
    parts[#parts + 1] = string.format(
      '<text x="%.2f" y="%.2f" fill="#cc8800" font-size="12">%s</text>',
      ix + 4,
      iy + 14,
      xmlEscape("image " .. tostring(i) .. " (metadata only)")
    )
  end

  parts[#parts + 1] = "</svg>"
  return table.concat(parts, "\n")
end

local function buildApiRequest(settings, payload, promptText, selectionImageBase64)
  local boundsJson = encodeJson(payload.context.selectionBounds or {})

  local userContent = "Convert the attached selection image into LaTeX."

  if settings.apiType == "ollama" then
    return {
      model = settings.model,
      stream = false,
      format = "json",
      messages = {
        { role = "system", content = promptText },
        {
          role = "user",
          content = userContent,
          images = {selectionImageBase64}
        }
      }
    }, {
      userContent = userContent,
      selectionBounds = boundsJson
    }
  end

  return {
    model = settings.model,
    response_format = { type = "json_object" },
    messages = {
      { role = "system", content = promptText },
      { role = "user", content = userContent }
    }
  }, {
    userContent = userContent,
    selectionBounds = boundsJson
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

local function commandSucceeded(ok)
  return ok == true or ok == 0
end

local function fileSize(path)
  local f = io.open(path, "rb")
  if not f then
    return 0
  end
  local sz = f:seek("end") or 0
  f:close()
  return sz
end

local IMAGE_TOOL_COMMAND_CACHE = nil

local function findImageToolCommand()
  if IMAGE_TOOL_COMMAND_CACHE ~= nil then
    return IMAGE_TOOL_COMMAND_CACHE
  end

  if commandSucceeded(os.execute("command -v magick >/dev/null 2>&1")) then
    IMAGE_TOOL_COMMAND_CACHE = "magick"
    return IMAGE_TOOL_COMMAND_CACHE
  end
  if commandSucceeded(os.execute("command -v convert >/dev/null 2>&1")) then
    IMAGE_TOOL_COMMAND_CACHE = "convert"
    return IMAGE_TOOL_COMMAND_CACHE
  end

  IMAGE_TOOL_COMMAND_CACHE = false
  return nil
end

local function renderSvgFileToPng(svgPath, pngPath, targetWidth, targetDensity)
  local imageTool = findImageToolCommand()
  if not imageTool then
    return false, "No image render tool found (magick/convert)."
  end

  local density = math.max(72, math.min(1200, math.floor(targetDensity or DEFAULT_SELECTION_IMAGE_DENSITY)))

  local cmd = table.concat({
    imageTool,
    "-density",
    tostring(density),
    "-background",
    "white",
    shellQuote(svgPath),
    "-alpha",
    "remove",
    "-resize",
    tostring(math.max(800, math.floor(targetWidth or 2200))) .. "x",
    "-quality",
    "95",
    shellQuote(pngPath),
    ">/dev/null 2>&1"
  }, " ")

  if commandSucceeded(os.execute(cmd)) and fileExists(pngPath) and fileSize(pngPath) > 0 then
    return true
  end

  return false, "Failed to render selection SVG to PNG."
end

local function renderSelectionDataAsBase64Png(settings, payload, timing)
  local stepStart = monotonicMs()
  local svgPath = os.tmpname() .. "_llm_sel.svg"
  local pngPath = os.tmpname() .. "_llm_sel.png"
  local svgText = buildSelectionSvg(payload)
  if timing then
    timing.svg_build_ms = elapsedMs(stepStart)
  end

  stepStart = monotonicMs()
  if not writeAll(svgPath, svgText) then
    return nil, nil, "Failed to write temporary selection SVG."
  end
  if timing then
    timing.svg_write_ms = elapsedMs(stepStart)
  end

  stepStart = monotonicMs()
  local ok, renderErr = renderSvgFileToPng(
    svgPath,
    pngPath,
    settings.selectionImageWidth,
    settings.selectionImageDensity
  )
  if timing then
    timing.svg_render_ms = elapsedMs(stepStart)
    timing.selection_target_width = tostring(settings.selectionImageWidth or "")
    timing.selection_target_density = tostring(settings.selectionImageDensity or "")
  end
  os.remove(svgPath)
  if not ok then
    os.remove(pngPath)
    return nil, nil, renderErr
  end

  stepStart = monotonicMs()
  local pngData = readAll(pngPath)
  if timing then
    timing.png_read_ms = elapsedMs(stepStart)
  end
  os.remove(pngPath)
  if not pngData or pngData == "" then
    return nil, nil, "Failed to read rendered selection PNG."
  end

  if timing then
    timing.selection_png_bytes = #pngData
  end

  stepStart = monotonicMs()
  local encoded = encodeBase64(pngData)
  if timing then
    timing.base64_encode_ms = elapsedMs(stepStart)
    timing.selection_b64_chars = #encoded
  end

  return encoded, pngData
end

local function renderSelectionAsBase64Png(settings, payload, timing)
  local totalStart = monotonicMs()
  -- Render selected data directly and do not fall back to page export/cropping.
  local selB64, selPng, selErr = renderSelectionDataAsBase64Png(settings, payload, timing)
  if selB64 then
    if timing then
      timing.render_path = "selection-svg"
      timing.raster_total_ms = elapsedMs(totalStart)
    end
    return selB64, selPng, "selection-svg-rasterized"
  end
  if timing then
    timing.render_path = "selection-svg-only"
    timing.raster_total_ms = elapsedMs(totalStart)
  end
  return nil, nil, "Failed to rasterize selected content: " .. tostring(selErr or "unknown")
end

local function persistDebugFile(filename, content)
  local base = app.getFolder("config")
  if not base or base == "" then
    return nil
  end

  local path = base .. "/" .. filename
  if writeAll(path, content or "") then
    return path
  end

  return nil
end

local function saveDebugSnapshot(endpoint, body, raw, curlErr, httpCode, exitCode, debugParts)
  local requestPath = persistDebugFile("request.json", body or "")
  local responsePath = persistDebugFile("response.json", raw or "")

  if debugParts then
    persistDebugFile("user_content.txt", debugParts.userContent or "")
    persistDebugFile("selection_bounds.json", debugParts.selectionBounds or "")
    if debugParts.selectionImageData then
      persistDebugFile("selection_image.png", debugParts.selectionImageData)
    end
  end

  local metaLines = {
    "timestamp=" .. os.date("%Y-%m-%d %H:%M:%S"),
    "endpoint=" .. tostring(endpoint or ""),
    "curl_exit=" .. tostring(exitCode or ""),
    "http_status=" .. tostring(httpCode or ""),
    "curl_stderr=" .. tostring(curlErr or ""),
    "selection_crop_warning=" .. tostring((debugParts and debugParts.selectionCropWarning) or "")
  }
  appendTimingMeta(metaLines, "timing_", debugParts and debugParts.timing)
  local meta = table.concat(metaLines, "\n")
  local metaPath = persistDebugFile("debug.txt", meta)

  return requestPath, responsePath, metaPath
end

local function showDebugSnapshotDialog(requestPath, responsePath, metaPath, body, raw)
  local msg = table.concat({
    "LLM debug snapshot saved.",
    "",
    "Request JSON:",
    tostring(requestPath or "(failed to write)"),
    "",
    "Response text:",
    tostring(responsePath or "(failed to write)"),
    "",
    "Request/response metadata:",
    tostring(metaPath or "(failed to write)"),
    "",
    "Request preview:",
    truncateForDialog(body or "", MAX_DEBUG_PREVIEW_CHARS),
    "",
    "Response preview:",
    truncateForDialog(raw or "", MAX_DEBUG_PREVIEW_CHARS)
  }, "\n")

  app.openDialog(msg, {"OK"}, "", false)
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

local function requestLatex(settings, payload, promptText, runTiming)
  local requestTiming = {
    api_type = settings.apiType,
    pipeline_start_ms = runTiming and runTiming.pipeline_start_ms or nil
  }
  local requestStart = monotonicMs()

  local bodyPath = os.tmpname()
  local outPath = os.tmpname()
  local httpPath = os.tmpname()
  local errPath = os.tmpname()
  local statusPath = os.tmpname()

  local selectionImageBase64 = nil
  local selectionImageData = nil
  local selectionCropWarning = nil
  if settings.apiType == "ollama" then
    local imageErr
    local rasterStart = monotonicMs()
    selectionImageBase64, selectionImageData, imageErr = renderSelectionAsBase64Png(settings, payload, requestTiming)
    requestTiming.raster_stage_ms = elapsedMs(rasterStart)
    if not selectionImageBase64 then
      return nil, imageErr or "Failed to rasterize current selection for model request."
    end
    selectionCropWarning = imageErr
  end

  local requestPayload, debugParts = buildApiRequest(settings, payload, promptText, selectionImageBase64)
  if debugParts then
    debugParts.selectionImageData = selectionImageData
    debugParts.selectionCropWarning = selectionCropWarning
  end

  local stepStart = monotonicMs()
  local body = encodeJson(requestPayload)
  requestTiming.encode_json_ms = elapsedMs(stepStart)

  if #body > MAX_REQUEST_BODY_CHARS then
    return nil, "Payload too large; reduce selection size."
  end

  stepStart = monotonicMs()
  if not writeAll(bodyPath, body) then
    return nil, "Could not write temporary request file."
  end
  requestTiming.write_body_file_ms = elapsedMs(stepStart)

  local requestSettings = {
    apiKey = settings.apiKey,
    endpoint = resolveEndpointUrl(settings),
    timeoutSec = settings.timeoutSec
  }
  local cmd = buildCurlCommand(requestSettings, bodyPath, outPath, httpPath, errPath, statusPath)

  stepStart = monotonicMs()
  os.execute(cmd)
  requestTiming.curl_exec_ms = elapsedMs(stepStart)

  stepStart = monotonicMs()
  local statusText = readAll(statusPath) or "999"
  local code = tonumber(trim(statusText)) or 999
  local httpCodeText = trim(readAll(httpPath) or "")
  local httpCode = tonumber(httpCodeText) or 0
  local curlErr = trim(readAll(errPath) or "")
  local raw = readAll(outPath) or ""
  requestTiming.read_http_artifacts_ms = elapsedMs(stepStart)

  stepStart = monotonicMs()
  local latex = trim(extractLatexFromResponse(settings, raw) or "")
  requestTiming.extract_latex_ms = elapsedMs(stepStart)

  requestTiming.total_request_ms = elapsedMs(requestStart)
  if runTiming and runTiming.pipeline_start_ms then
    requestTiming.pre_request_ms = math.max(0, requestStart - runTiming.pipeline_start_ms)
    requestTiming.total_pipeline_ms = math.max(0, monotonicMs() - runTiming.pipeline_start_ms)
  end

  if debugParts then
    debugParts.timing = requestTiming
  end

  local requestPath, responsePath, metaPath =
      saveDebugSnapshot(requestSettings.endpoint, body, raw, curlErr, httpCode, code, debugParts)
  if settings.showDebugDialogs then
    showDebugSnapshotDialog(requestPath, responsePath, metaPath, body, raw)
  end

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

local function getValidBounds(bounds)
  if type(bounds) ~= "table" then
    return nil
  end
  local x = tonumber(bounds.x)
  local y = tonumber(bounds.y)
  local width = tonumber(bounds.width)
  local height = tonumber(bounds.height)
  if x and y and width and height and width > 0 and height > 0 then
    return {
      x = x,
      y = y,
      width = width,
      height = height
    }
  end
  return nil
end

local function resolveInsertBounds(selectionInfo, payload)
  -- Prefer snapped/original bounds because UI boundingBox includes selection padding.
  local candidates = {
    payload and payload.context and payload.context.selectionBounds,
    selectionInfo and selectionInfo.snappedBounds,
    selectionInfo and selectionInfo.originalBounds,
    selectionInfo and selectionInfo.boundingBox
  }

  for _, bounds in ipairs(candidates) do
    local valid = getValidBounds(bounds)
    if valid then
      return valid
    end
  end

  return nil
end

local function formatDebugNumber(value)
  local n = tonumber(value)
  if not n then
    return "nil"
  end
  return string.format("%.2f", n)
end

local function collectInsertLatexDebug(latex, selectionInfo, x, y, width, height, targetWidth, targetHeight, refs)
  local inputBox = (selectionInfo and selectionInfo.boundingBox) or {}
  local insertedInfo = safeCall(app.getToolInfo, "selection") or {}
  local insertedBox = insertedInfo.boundingBox or {}
  local latexText = tostring(latex or "")
  local _, newlineCount = latexText:gsub("\n", "\n")
  local lineCount = (latexText ~= "") and (newlineCount + 1) or 0

  local inW = tonumber(inputBox.width)
  local inH = tonumber(inputBox.height)
  local outW = tonumber(insertedBox.width)
  local outH = tonumber(insertedBox.height)

  local lines = {
    "timestamp=" .. os.date("%Y-%m-%d %H:%M:%S"),
    "latex_chars=" .. tostring(#latexText),
    "latex_lines=" .. tostring(lineCount),
    "selection_bbox_x=" .. formatDebugNumber(inputBox.x),
    "selection_bbox_y=" .. formatDebugNumber(inputBox.y),
    "selection_bbox_w=" .. formatDebugNumber(inW),
    "selection_bbox_h=" .. formatDebugNumber(inH),
    "insert_x=" .. formatDebugNumber(x),
    "insert_y=" .. formatDebugNumber(y),
    "target_width=" .. formatDebugNumber(targetWidth),
    "target_height=" .. formatDebugNumber(targetHeight),
    "requested_width=" .. formatDebugNumber(width),
    "requested_height=" .. formatDebugNumber(height),
    "inserted_bbox_x=" .. formatDebugNumber(insertedBox.x),
    "inserted_bbox_y=" .. formatDebugNumber(insertedBox.y),
    "inserted_bbox_w=" .. formatDebugNumber(outW),
    "inserted_bbox_h=" .. formatDebugNumber(outH),
    "added_refs=" .. tostring((refs and #refs) or 0)
  }

  if inW and inW > 0 and outW then
    lines[#lines + 1] = string.format("width_scale=%.4f", outW / inW)
  end
  if inH and inH > 0 and outH then
    lines[#lines + 1] = string.format("height_scale=%.4f", outH / inH)
  end
  if inW and inW > 0 and inH and inH > 0 and outW and outH then
    lines[#lines + 1] = string.format("area_scale=%.4f", (outW * outH) / (inW * inH))
  end

  local debugText = table.concat(lines, "\n")
  local debugPath = persistDebugFile("insert_latex_debug.txt", debugText)
  return debugPath, insertedBox
end

local function deleteSelectionRefs(refs)
  if not refs or #refs == 0 then
    return
  end
  app.clearSelection()
  app.addToSelection(refs)
  app.activateAction("delete")
end

local function insertLatexItem(latex, x, y, width, height, undoMode)
  return app.texImages({
    latexItems = {
      {
        latex = latex,
        x = x,
        y = y,
        width = width,
        height = height
      }
    },
    allowUndoRedoAction = undoMode or "grouped"
  })
end

local function chooseLatexInsertSize(latex, x, y, targetWidth, targetHeight)
  if not targetWidth or not targetHeight or targetWidth <= 0 or targetHeight <= 0 then
    return nil, nil
  end

  local probeRefs = insertLatexItem(latex, x, y, nil, nil, "none")
  if not probeRefs or #probeRefs == 0 then
    return targetWidth, nil
  end

  app.clearSelection()
  app.addToSelection(probeRefs)
  local probeInfo = safeCall(app.getToolInfo, "selection") or {}
  local probeBox = probeInfo.boundingBox or {}
  local probeW = tonumber(probeBox.width)
  local probeH = tonumber(probeBox.height)
  deleteSelectionRefs(probeRefs)

  if not probeW or not probeH or probeW <= 0 or probeH <= 0 then
    return targetWidth, nil
  end

  local probeAspect = probeW / probeH
  local targetAspect = targetWidth / targetHeight
  if probeAspect >= targetAspect then
    return targetWidth, nil
  end
  return nil, targetHeight
end

local function dominantSelectionColor(payload)
  if type(payload) ~= "table" or type(payload.selection) ~= "table" then
    return nil
  end

  local counts = {}
  local function addColor(color)
    local c = tonumber(color)
    if not c then
      return
    end
    counts[c] = (counts[c] or 0) + 1
  end

  for _, s in ipairs(payload.selection.strokes or {}) do
    addColor(s.color)
  end
  for _, t in ipairs(payload.selection.texts or {}) do
    addColor(t.color)
  end

  local bestColor = nil
  local bestCount = 0
  for color, count in pairs(counts) do
    if count > bestCount then
      bestCount = count
      bestColor = color
    end
  end

  return bestColor
end

local function colorIntToRgb(color)
  local c = tonumber(color)
  if not c then
    return nil, nil, nil
  end
  c = math.floor(c) % 0x1000000
  local r = math.floor(c / 0x10000) % 0x100
  local g = math.floor(c / 0x100) % 0x100
  local b = c % 0x100
  return r, g, b
end

local function forceLatexColor(latex, color)
  local r, g, b = colorIntToRgb(color)
  if not r then
    return latex
  end

  local src = trim(tostring(latex or ""))
  if src == "" then
    return latex
  end

  -- Remove direct color switches so selection color can be enforced consistently.
  src = src:gsub("\\color%s*%b[]%s*%b{}", "")
  src = src:gsub("\\color%s*%b{}", "")

  return string.format("\\begingroup\\color[RGB]{%d,%d,%d}%s\\endgroup", r, g, b, src)
end

local function recolorCurrentSelection(color)
  local targetColor = tonumber(color)
  if not targetColor then
    return nil
  end

  local activeToolInfo = safeCall(app.getToolInfo, "active") or {}
  local originalToolColor = tonumber(activeToolInfo.color)

  safeCall(app.changeToolColor, {
    color = targetColor,
    selection = true
  })

  if originalToolColor and originalToolColor ~= targetColor then
    safeCall(app.changeToolColor, {
      color = originalToolColor,
      selection = false
    })
  end

  return targetColor
end

local function withTemporaryActiveToolColor(color, fn)
  local targetColor = tonumber(color)
  if not targetColor then
    return fn()
  end

  local activeToolInfo = safeCall(app.getToolInfo, "active") or {}
  local originalToolColor = tonumber(activeToolInfo.color)

  safeCall(app.changeToolColor, {
    color = targetColor,
    selection = false
  })

  local ok, result = pcall(fn)

  if originalToolColor and originalToolColor ~= targetColor then
    safeCall(app.changeToolColor, {
      color = originalToolColor,
      selection = false
    })
  end

  if not ok then
    error(result)
  end

  return result
end

local function insertLatex(latex, selectionInfo, settings, payload)
  local insertBounds = resolveInsertBounds(selectionInfo, payload)
  local x, y = pickInsertPosition(selectionInfo)
  local targetWidth = nil
  local targetHeight = nil
  if insertBounds then
    x = insertBounds.x
    y = insertBounds.y
    targetWidth = insertBounds.width
    targetHeight = insertBounds.height
  elseif selectionInfo and selectionInfo.boundingBox then
    targetWidth = tonumber(selectionInfo.boundingBox.width)
    targetHeight = tonumber(selectionInfo.boundingBox.height)
  end

  local width, height = chooseLatexInsertSize(latex, x, y, targetWidth, targetHeight)
  if not width and not height and targetWidth and targetWidth > 0 then
    width = targetWidth
  end

  local selectionColor = nil
  if settings and settings.matchSelectionColor then
    selectionColor = dominantSelectionColor(payload)
  end

  local latexToInsert = latex
  if selectionColor then
    latexToInsert = forceLatexColor(latexToInsert, selectionColor)
  end

  local refs = withTemporaryActiveToolColor(selectionColor, function()
    return insertLatexItem(latexToInsert, x, y, width, height, "grouped")
  end)

  if refs and #refs > 0 then
    app.clearSelection()
    app.addToSelection(refs)
    if settings and settings.matchSelectionColor and selectionColor then
      recolorCurrentSelection(selectionColor)
    end
  end

  local shouldShowInsertDebug = settings and settings.showInsertDebugDialogs
  if shouldShowInsertDebug then
    local debugPath, insertedBox = collectInsertLatexDebug(
      latex,
      selectionInfo,
      x,
      y,
      width,
      height,
      targetWidth,
      targetHeight,
      refs
    )
    local msg = table.concat({
      "Insert LaTeX sizing debug",
      "",
      "Requested box from source selection:",
      "  width=" .. formatDebugNumber(width) .. ", height=" .. formatDebugNumber(height),
      "",
      "Inserted object bounding box:",
      "  width=" .. formatDebugNumber(insertedBox.width) .. ", height=" .. formatDebugNumber(insertedBox.height),
      "",
      "Debug file:",
      tostring(debugPath or "(failed to write)")
    }, "\n")
    app.openDialog(msg, {"OK"}, "", false)
  end
end

local function showError(msg)
  app.openDialog(msg, {"Ok"}, "", true)
end

local function userConfigPath()
  return app.getFolder("config") .. "/" .. CONFIG_FILENAME
end

local function pluginConfigPath()
  return pluginDir() .. "/" .. CONFIG_FILENAME
end

local function serializeSettings(settings)
  local lines = {
    "api_type=" .. tostring(settings.apiType or ""),
    "endpoint=" .. tostring(settings.endpoint or ""),
    "api_key=" .. (settings.apiKey ~= "" and "<set>" or ""),
    "model=" .. tostring(settings.model or ""),
    "prompt_file=" .. tostring(settings.promptPath or ""),
    "selection_image_width=" .. tostring(settings.selectionImageWidth or ""),
    "selection_image_density=" .. tostring(settings.selectionImageDensity or ""),
    "timeout_sec=" .. tostring(settings.timeoutSec or ""),
    "show_debug_dialogs=" .. tostring(settings.showDebugDialogs),
    "show_insert_debug_dialogs=" .. tostring(settings.showInsertDebugDialogs),
    "match_selection_color=" .. tostring(settings.matchSelectionColor)
  }
  return table.concat(lines, "\n")
end

local function defaultUserConfigTemplate()
  local template = readAll(pluginConfigPath())
  if template and trim(template) ~= "" then
    return template
  end

  return table.concat({
    "# LLM to LaTeX user configuration",
    "api_type=openai",
    "endpoint=",
    "api_key=",
    "model=",
    "prompt_file=" .. DEFAULT_PROMPT_FILENAME,
    "selection_image_width=" .. tostring(DEFAULT_SELECTION_IMAGE_WIDTH),
    "selection_image_density=" .. tostring(DEFAULT_SELECTION_IMAGE_DENSITY),
    "timeout_sec=" .. tostring(DEFAULT_TIMEOUT_SEC),
    "show_debug_dialogs=false",
    "show_insert_debug_dialogs=false",
    "match_selection_color=true",
    ""
  }, "\n")
end

local function ensureUserConfigFile()
  local path = userConfigPath()
  if fileExists(path) then
    return path
  end

  local template = defaultUserConfigTemplate()
  if not writeAll(path, template) then
    return nil
  end
  return path
end

local function launchConfigEditor(path)
  local editor = trim(os.getenv("XOJ_LLM_LATEX_EDITOR") or os.getenv("VISUAL") or os.getenv("EDITOR") or "")

  if editor ~= "" then
    local cmd = editor .. " " .. shellQuote(path) .. " >/dev/null 2>&1 &"
    if commandSucceeded(os.execute(cmd)) then
      return true, "Opened config file with editor from environment variables."
    end
  end

  if commandSucceeded(os.execute("command -v xdg-open >/dev/null 2>&1")) then
    local cmd = "xdg-open " .. shellQuote(path) .. " >/dev/null 2>&1 &"
    if commandSucceeded(os.execute(cmd)) then
      return true, "Opened config file via xdg-open."
    end
  end

  return false, "Could not launch editor automatically."
end

local function showConfigDialogMessage()
  local path = userConfigPath()
  local exists = fileExists(path)
  local status = exists and "present" or "missing (will be created from plugin defaults)"
  local msg = table.concat({
    "LLM to LaTeX config",
    "",
    "User config file:",
    path,
    "Status: " .. status,
    "",
    "Choose an action:"
  }, "\n")
  app.openDialog(msg, {"Open Config", "Show Effective Settings", "Reset User Config", "Cancel"}, "llmLatexConfigDialogChoice")
end

local function showEffectiveSettingsDialog()
  local settings = resolveSettings()
  local msg = table.concat({
    "Effective LLM to LaTeX settings",
    "(environment variables override file values)",
    "",
    serializeSettings(settings)
  }, "\n")
  app.openDialog(msg, {"OK"}, "", false)
end

local function resetUserConfigFile()
  local path = userConfigPath()
  local template = defaultUserConfigTemplate()
  if not writeAll(path, template) then
    app.openDialog("Failed to write user config file:\n" .. path, {"OK"}, "", true)
    return
  end
  app.openDialog("User config reset to defaults:\n" .. path, {"OK"}, "", false)
end

function openLlmLatexConfigDialog()
  showConfigDialogMessage()
end

function llmLatexConfigDialogChoice(result)
  if result == 1 then
    local path = ensureUserConfigFile()
    if not path then
      app.openDialog("Failed to create user config file in:\n" .. app.getFolder("config"), {"OK"}, "", true)
      return
    end

    local ok, info = launchConfigEditor(path)
    if ok then
      app.openDialog(info .. "\n\nFile:\n" .. path, {"OK"}, "", false)
    else
      app.openDialog(
        info .. "\n\nPlease open this file manually:\n" .. path,
        {"OK"},
        "",
        true
      )
    end
    return
  end

  if result == 2 then
    showEffectiveSettingsDialog()
    return
  end

  if result == 3 then
    app.openDialog(
      "Reset user config to plugin defaults?\nThis overwrites existing values in:\n" .. userConfigPath(),
      {"Cancel", "Reset"},
      "llmLatexResetConfigConfirm"
    )
    return
  end
end

function llmLatexResetConfigConfirm(result)
  if result == 2 then
    resetUserConfigFile()
  end
end

function initUi()
  app.registerUi({
    ["menu"] = MENU_NAME,
    ["callback"] = "runLlmLatexMvp",
    ["toolbarId"] = TOOLBAR_ID,
    ["iconName"] = TOOLBAR_ICON_NAME,
    ["accelerator"] = "<Alt>a"
  })

  app.registerUi({
    ["menu"] = "LLM to LaTeX: Edit Config",
    ["callback"] = "openLlmLatexConfigDialog"
  })
end

function runLlmLatexMvp()
  local runTiming = {
    pipeline_start_ms = monotonicMs()
  }

  local stepStart = monotonicMs()
  local settings = resolveSettings()
  runTiming.resolve_settings_ms = elapsedMs(stepStart)
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

  stepStart = monotonicMs()
  local payload, hasSelection, selectionInfo = buildPayload(settings)
  runTiming.build_payload_ms = elapsedMs(stepStart)
  if not hasSelection then
    showError("Selection is empty. Select content first.")
    return
  end

  stepStart = monotonicMs()
  local promptText, promptErr = loadPromptText(settings.promptPath)
  runTiming.load_prompt_ms = elapsedMs(stepStart)
  if not promptText then
    showError(promptErr)
    return
  end

  stepStart = monotonicMs()
  local latex, err = requestLatex(settings, payload, promptText, runTiming)
  runTiming.request_call_ms = elapsedMs(stepStart)
  if not latex then
    showError(err)
    return
  end

  local ok, insertErr = pcall(insertLatex, latex, selectionInfo, settings, payload)
  if not ok then
    showError("Failed to insert LaTeX element: " .. tostring(insertErr))
    return
  end

end
