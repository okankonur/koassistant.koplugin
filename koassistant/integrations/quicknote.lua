--[[--
QuickNote integration for KOAssistant (llm-note fork)

Mirrors book notes (AI answers and plain highlights) to a QuickNote server
through its capture endpoint:

    POST <server>/api/v1/notes/capture
    Authorization: Bearer qn_<key>
    { "title": "...", "body": "<markdown>",
      "client_request_id": "<outbox item id>", "tags": ["koreader"] }

Every note goes through a small persistent outbox first, so a note taken with
Wi-Fi off (or while the server is down) is sent on the next connection. The
upload itself runs in a subprocess (BaseHandler.fetchAsync), so the e-ink UI
never blocks on the network.

The outbox item's id goes out as client_request_id: when a capture succeeds
but its response is lost, the retry gets the original note back (200) instead
of creating a duplicate. Servers that predate the field ignore it.

Notes carry a `#koreader` marker line; the Mac agent (mac-agent/ in the
llm-note repo) uses it to pick book notes out of the QuickNote feed and mirror
them into an Apple Notes folder. The same word is also sent as a QuickNote
tag, so the notes group under it in the QuickNote apps.

@module koassistant.integrations.quicknote
]]

local logger = require("koassistant.core.logger")

local QuickNote = {}

QuickNote.DEFAULT_SERVER = "https://note.okankonur.com"
QuickNote.CAPTURE_PATH = "/api/v1/notes/capture"
QuickNote.PULL_PATH = "/api/v1/sync/pull"
QuickNote.MARKER = "#koreader"
-- User tags attached to every captured note (server lowercases them).
QuickNote.TAGS = { "koreader" }
QuickNote.OUTBOX_FILE = "koassistant_quicknote_outbox.lua"
-- An item that keeps failing with a non-retryable error is dropped after this
-- many tries so one bad note cannot wedge the queue forever.
QuickNote.MAX_ATTEMPTS = 8
QuickNote.REQUEST_TIMEOUT = 20

local _flushing = false
local _settings = nil

-- ── Settings ────────────────────────────────────────────────────────────────

--- Called from main.lua during plugin init (same pattern as Notebook.init)
--- @param settings table LuaSettings instance (plugin.settings)
function QuickNote.init(settings)
    _settings = settings
    -- A key in apikeys.lua (written on a computer, no e-ink typing) turns sync
    -- on the first time it is seen. Stored, so the Settings toggle shows it and
    -- switching it off there sticks.
    local features = settings and settings:readSetting("features")
    if type(features) == "table" and features.quicknote_enabled == nil
            and QuickNote.fileKey() then
        features.quicknote_enabled = true
        settings:saveSetting("features", features)
        settings:flush()
    end
end

--- The plugin's live features table. Callers pass nothing and get the current
--- values, so a key typed in Settings applies to the very next note.
function QuickNote.features()
    if _settings then
        return _settings:readSetting("features") or {}
    end
    return {}
end

local function trim(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

--- The configured server base URL, without a trailing slash.
function QuickNote.serverUrl(features)
    local url = trim(features and features.quicknote_server_url) or QuickNote.DEFAULT_SERVER
    return (url:gsub("/+$", ""))
end

--- The key from apikeys.lua in the plugin folder, if any:
---     return { anthropic = "...", quicknote = "qn_..." }
--- The sample's placeholder (anything not starting with qn_) is ignored.
local function loadFileKey()
    local ok, keys = pcall(require, "apikeys")
    if not ok or type(keys) ~= "table" then return nil end
    local value = keys.quicknote
    if type(value) == "table" then  -- the { key = "...", alias = "..." } shape
        value = value.key or (type(value[1]) == "table" and value[1].key)
    end
    local key = trim(value)
    if key and key:match("^qn_") then return key end
    return nil
end
local _file_key_loader = loadFileKey

function QuickNote.fileKey()
    return _file_key_loader()
end

--- Test seam: replace the apikeys.lua reader (nil restores it).
function QuickNote._setFileKeyLoaderForTests(fn)
    _file_key_loader = fn or loadFileKey
end

--- The key typed in Settings wins over the apikeys.lua one (the same rule
--- KOAssistant applies to provider keys).
function QuickNote.apiKey(features)
    return trim(features and features.quicknote_api_key) or QuickNote.fileKey()
end

--- "settings" | "file" | nil
function QuickNote.keySource(features)
    if trim(features and features.quicknote_api_key) then return "settings" end
    if QuickNote.fileKey() then return "file" end
    return nil
end

--- Sync is on and has a key to send with.
function QuickNote.isEnabled(features)
    return features ~= nil and features.quicknote_enabled == true
        and QuickNote.apiKey(features) ~= nil
end

--- Masked key for display ("qn_ab…wxyz").
function QuickNote.maskedKey(features)
    local key = QuickNote.apiKey(features)
    if not key then return nil end
    if #key <= 10 then return string.rep("•", #key) end
    return key:sub(1, 5) .. "…" .. key:sub(-4)
end

-- ── Formatting (pure) ───────────────────────────────────────────────────────

local function blockquote(text)
    text = trim(text)
    if not text then return nil end
    return "> " .. text:gsub("\r\n", "\n"):gsub("\n", "\n> ")
end

local function locationLine(entry)
    local parts = {}
    local book = trim(entry.book_title)
    if book then
        local author = trim(entry.book_author)
        table.insert(parts, author and ("*" .. book .. "*, " .. author) or ("*" .. book .. "*"))
    end
    local pi = entry.page_info or {}
    if pi.page then
        local page = "p. " .. tostring(pi.page)
        if pi.progress then page = page .. " (" .. tostring(pi.progress) .. "%)" end
        table.insert(parts, page)
    end
    if trim(pi.chapter) then table.insert(parts, trim(pi.chapter)) end
    table.insert(parts, entry.timestamp or os.date("%Y-%m-%d %H:%M"))
    return "— " .. table.concat(parts, " · ")
end

--- Build the QuickNote title and Markdown body for a book note.
--- Pure function (unit-tested).
--- @param entry table {
---     kind = "ai" | "highlight",
---     action_name = string|nil,   -- "Key Concepts"
---     book_title, book_author = string|nil,
---     highlighted_text = string|nil,
---     follow_up = string|nil,     -- the reader's own question/comment
---     response = string|nil,      -- the AI answer (Markdown)
---     model_name = string|nil,
---     page_info = { page, progress, chapter }|nil,
---     timestamp = string|nil,     -- override for tests
---   }
--- @return table|nil { title = string, body = string } (nil when there is nothing to send)
function QuickNote.buildNote(entry)
    entry = entry or {}
    local quote = blockquote(entry.highlighted_text)
    local answer = trim(entry.response)
    local question = trim(entry.follow_up)
    if not quote and not answer and not question then return nil end

    local book = trim(entry.book_title)
    local label = trim(entry.action_name)
        or (entry.kind == "highlight" and "Highlight" or "Note")
    local title = book and (book .. " — " .. label) or label

    local parts = {}
    if quote then table.insert(parts, quote) end
    if question then table.insert(parts, "**Q:** " .. question) end
    if answer then table.insert(parts, answer) end
    local footer = locationLine(entry)
    if trim(entry.model_name) then
        footer = footer .. " · " .. trim(entry.model_name)
    end
    table.insert(parts, footer)
    table.insert(parts, QuickNote.MARKER)

    return { title = title, body = table.concat(parts, "\n\n") }
end

-- ── Outbox ──────────────────────────────────────────────────────────────────

local function outboxPath()
    return require("datastorage"):getSettingsDir() .. "/" .. QuickNote.OUTBOX_FILE
end

local function openOutbox()
    local LuaSettings = require("luasettings")
    return LuaSettings:open(outboxPath())
end

local function readItems(store)
    local items = store:readSetting("items")
    if type(items) ~= "table" then items = {} end
    return items
end

local _id_counter = 0
local function newClientId()
    _id_counter = _id_counter + 1
    local t = { string.format("%x-%x-", os.time(), _id_counter) }
    for i = 1, 8 do t[#t + 1] = string.format("%02x", math.random(0, 255)) end
    return table.concat(t)
end

--- Add a built note to the outbox. Returns the item.
function QuickNote.enqueue(note)
    local store = openOutbox()
    local items = readItems(store)
    local item = {
        id = newClientId(),
        title = note.title,
        body = note.body,
        created = os.time(),
        attempts = 0,
    }
    table.insert(items, item)
    store:saveSetting("items", items)
    store:flush()
    return item
end

function QuickNote.pendingCount()
    local ok, n = pcall(function() return #readItems(openOutbox()) end)
    return ok and n or 0
end

local function removeItem(id)
    local store = openOutbox()
    local items = readItems(store)
    for i = #items, 1, -1 do
        if items[i].id == id then table.remove(items, i) end
    end
    store:saveSetting("items", items)
    store:flush()
end

--- @return number the item's attempt count after this one
local function bumpAttempts(id, err)
    local store = openOutbox()
    local items = readItems(store)
    local attempts = 0
    for _idx, it in ipairs(items) do
        if it.id == id then
            it.attempts = (it.attempts or 0) + 1
            it.last_error = err
            attempts = it.attempts
        end
    end
    store:saveSetting("items", items)
    store:flush()
    return attempts
end

function QuickNote.clearOutbox()
    local store = openOutbox()
    store:saveSetting("items", {})
    store:flush()
end

-- ── Transport ───────────────────────────────────────────────────────────────

local function authHeaders(features, with_body)
    local h = {
        ["Authorization"] = "Bearer " .. (QuickNote.apiKey(features) or ""),
        ["Accept"] = "application/json",
    }
    if with_body then h["Content-Type"] = "application/json" end
    return h
end

--- Classify a capture response. Pure (unit-tested).
--- @return string "ok" | "retry" | "auth" | "drop"
function QuickNote.classifyStatus(status)
    if status == 200 or status == 201 then return "ok" end
    if status == nil or status == 0 then return "retry" end -- transport error
    if status == 401 or status == 403 then return "auth" end
    if status == 429 or status >= 500 then return "retry" end
    if status >= 400 then return "drop" end
    return "retry"
end

--- The capture request body for an outbox item. Pure (unit-tested).
--- The item id is stable across retries, which is what makes it a usable
--- idempotency key.
function QuickNote.capturePayload(item)
    return {
        title = item.title,
        body = item.body,
        client_request_id = item.id,
        tags = QuickNote.TAGS,
    }
end

local function postItem(features, item, on_done)
    local json = require("json")
    local BaseHandler = require("koassistant.api.base")
    local payload = json.encode(QuickNote.capturePayload(item))
    local headers = authHeaders(features, true)
    headers["Content-Length"] = tostring(#payload)
    BaseHandler.fetchAsync(QuickNote.serverUrl(features) .. QuickNote.CAPTURE_PATH, {
        method = "POST",
        headers = headers,
        body = payload,
        timeout = QuickNote.REQUEST_TIMEOUT,
    }, on_done)
end

--- Send every queued note, one at a time, oldest first.
--- @param features table|nil plugin features (nil = live settings)
--- @param on_done function|nil (sent, remaining, err) err = "auth" | "offline" | string | nil
function QuickNote.flush(features, on_done)
    features = features or QuickNote.features()
    on_done = on_done or function() end
    if not QuickNote.isEnabled(features) then
        return on_done(0, QuickNote.pendingCount(), "disabled")
    end
    if _flushing then
        return on_done(0, QuickNote.pendingCount(), "busy")
    end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        return on_done(0, QuickNote.pendingCount(), "offline")
    end

    local queue = readItems(openOutbox())
    if #queue == 0 then return on_done(0, 0, nil) end

    _flushing = true
    local sent = 0
    local idx = 0
    local tried = {}
    local function finish(err)
        _flushing = false
        on_done(sent, QuickNote.pendingCount(), err)
    end
    local function step()
        idx = idx + 1
        local item = queue[idx]
        if not item then
            -- Notes queued while this pass was running (a submit that found
            -- the flush busy) go out in the same pass.
            queue, idx = {}, 1
            for _idx, it in ipairs(readItems(openOutbox())) do
                if not tried[it.id] then table.insert(queue, it) end
            end
            item = queue[1]
            if not item then return finish(nil) end
        end
        tried[item.id] = true
        local ok, perr = pcall(postItem, features, item, function(status, body)
            local verdict = QuickNote.classifyStatus(status)
            if verdict == "ok" then
                sent = sent + 1
                removeItem(item.id)
                return step()
            elseif verdict == "auth" then
                logger.warn("KOAssistant QuickNote: API key rejected (", status, ")")
                return finish("auth")
            elseif verdict == "drop" then
                logger.warn("KOAssistant QuickNote: server refused note", item.id, status, body)
                if bumpAttempts(item.id, tostring(status)) >= QuickNote.MAX_ATTEMPTS then
                    removeItem(item.id)
                end
                return step()
            end
            -- retry: transport error / 5xx / 429 — stop here, keep order
            logger.info("KOAssistant QuickNote: send failed, will retry", status, body)
            bumpAttempts(item.id, tostring(status or body))
            return finish(status and ("HTTP " .. tostring(status)) or "offline")
        end)
        if not ok then
            -- a failure before the request left (DNS, fork): never leave the
            -- flush marked busy
            logger.warn("KOAssistant QuickNote: could not send:", perr)
            finish(tostring(perr))
        end
    end
    step()
end

--- Queue a book note and try to send it right away.
--- @param features table|nil plugin features (nil = live settings)
--- @param entry table see buildNote
--- @param opts table|nil { silent = bool, prefix = string }
---   silent = no toast on success; prefix = what else just happened ("Saved to
---   notebook"), shown before the QuickNote outcome
--- @return boolean queued
function QuickNote.submit(features, entry, opts)
    features = features or QuickNote.features()
    opts = opts or {}
    if not QuickNote.isEnabled(features) then return false end
    local note = QuickNote.buildNote(entry)
    if not note then return false end
    QuickNote.enqueue(note)
    QuickNote.flush(features, function(sent, remaining, err)
        QuickNote.notify(sent, remaining, err, opts)
    end)
    return true
end

--- Toast the outcome of a flush.
--- @param opts table|nil { silent = bool, prefix = string }
function QuickNote.notify(sent, remaining, err, opts)
    opts = opts or {}
    local _ = require("koassistant.core.gettext")
    local T = require("ffi/util").template
    local UIManager = require("ui/uimanager")
    local Notification = require("ui/widget/notification")
    local text
    if err == "auth" then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("QuickNote rejected the API key. Check it under Settings → QuickNote Sync. Notes stay queued."),
            timeout = 5,
        })
        return
    elseif sent > 0 and remaining == 0 then
        if opts.silent then return end
        text = sent == 1 and _("sent to QuickNote") or T(_("%1 notes sent to QuickNote"), sent)
    elseif remaining > 0 then
        -- includes "busy": the running pass picks the new note up
        text = T(_("QuickNote: %1 queued"), remaining)
    else
        return
    end
    if opts.prefix then
        text = opts.prefix .. " · " .. text
    else
        text = text:sub(1, 1):upper() .. text:sub(2)
    end
    UIManager:show(Notification:new{ text = text, timeout = 2 })
end

--- Check the server URL and key: a one-row pull is the cheapest call an API
--- key may make. on_done(ok, message)
function QuickNote.testConnection(features, on_done)
    features = features or QuickNote.features()
    if not QuickNote.apiKey(features) then
        return on_done(false, "no API key")
    end
    local BaseHandler = require("koassistant.api.base")
    local url = QuickNote.serverUrl(features) .. QuickNote.PULL_PATH
        .. "?limit=1&since=" .. os.date("!%Y-%m-%dT%H:%M:%SZ")
    BaseHandler.fetchAsync(url, {
        method = "GET",
        headers = authHeaders(features, false),
        timeout = QuickNote.REQUEST_TIMEOUT,
    }, function(status, body)
        if status == 200 then return on_done(true, "ok") end
        if status == 401 or status == 403 then return on_done(false, "API key rejected") end
        if status == nil then return on_done(false, body or "network error") end
        return on_done(false, "HTTP " .. tostring(status))
    end)
end

return QuickNote
