--[[
Unit Tests for koassistant/integrations/quicknote.lua (llm-note fork)

Pure parts only (no network, no outbox file):
- QuickNote.buildNote(): title, quote, question, answer, footer, #koreader marker
- QuickNote.classifyStatus(): which capture responses retry, drop or stop
- QuickNote.capturePayload(): client_request_id + tags on the capture request
- settings helpers: serverUrl, isEnabled, maskedKey
- the apikeys.lua key: fallback, precedence, auto-enable on init

Run: lua tests/run_tests.lua --unit
]]

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

require("mock_koreader")

local QuickNote = require("koassistant.integrations.quicknote")

local TestRunner = { passed = 0, failed = 0 }

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal", tostring(expected), tostring(actual)), 2)
    end
end

function TestRunner:assertContains(str, substring, message)
    if not str or not str:find(substring, 1, true) then
        error(string.format("%s: '%s' not found in '%s'",
            message or "Substring not found", substring, tostring(str)), 2)
    end
end

function TestRunner:assertNotContains(str, substring, message)
    if str and str:find(substring, 1, true) then
        error(string.format("%s: '%s' should not be in output",
            message or "Unexpected substring", substring), 2)
    end
end

local function runAll()
    print("\n=== QuickNote integration ===")
    -- hermetic: a developer's real apikeys.lua must not supply a key
    QuickNote._setFileKeyLoaderForTests(function() return nil end)

    TestRunner:test("buildNote: AI note has title, quote, question, answer, footer, marker", function()
        local note = QuickNote.buildNote({
            kind = "ai",
            action_name = "Key Concepts",
            book_title = "Thinking, Fast and Slow",
            book_author = "Daniel Kahneman",
            highlighted_text = "System 1 operates automatically.\nSystem 2 allocates attention.",
            follow_up = "How do they interact?",
            response = "**System 1** is fast.",
            page_info = { page = 42, progress = 15, chapter = "The Characters of the Story" },
            timestamp = "2026-10-17 14:30",
        })
        TestRunner:assertEqual(note.title, "Thinking, Fast and Slow — Key Concepts", "title")
        TestRunner:assertContains(note.body, "> System 1 operates automatically.\n> System 2 allocates attention.", "multi-line quote")
        TestRunner:assertContains(note.body, "**Q:** How do they interact?", "question")
        TestRunner:assertContains(note.body, "**System 1** is fast.", "answer")
        TestRunner:assertContains(note.body,
            "— *Thinking, Fast and Slow*, Daniel Kahneman · p. 42 (15%) · The Characters of the Story · 2026-10-17 14:30",
            "footer")
        TestRunner:assertEqual(note.body:sub(-#QuickNote.MARKER), QuickNote.MARKER, "marker is the last line")
    end)

    TestRunner:test("buildNote: highlight-only note, no book, no answer", function()
        local note = QuickNote.buildNote({
            kind = "highlight",
            highlighted_text = "  A passage.  ",
            timestamp = "2026-10-17 14:30",
        })
        TestRunner:assertEqual(note.title, "Highlight", "title falls back to the kind")
        TestRunner:assertContains(note.body, "> A passage.", "trimmed quote")
        TestRunner:assertNotContains(note.body, "**Q:**", "no question line")
        TestRunner:assertContains(note.body, "— 2026-10-17 14:30", "footer with time only")
    end)

    TestRunner:test("buildNote: nothing to send gives nil", function()
        TestRunner:assertEqual(QuickNote.buildNote({ highlighted_text = "  ", response = "" }), nil, "empty")
        TestRunner:assertEqual(QuickNote.buildNote(nil), nil, "nil entry")
    end)

    TestRunner:test("buildNote: model name only when given", function()
        local with = QuickNote.buildNote({ response = "x", model_name = "claude-haiku-5-5", timestamp = "t" })
        TestRunner:assertContains(with.body, "· claude-haiku-5-5", "model in footer")
        local without = QuickNote.buildNote({ response = "x", timestamp = "t" })
        TestRunner:assertNotContains(without.body, "claude", "no model")
    end)

    TestRunner:test("classifyStatus: ok / retry / auth / drop", function()
        TestRunner:assertEqual(QuickNote.classifyStatus(201), "ok", "201 created")
        TestRunner:assertEqual(QuickNote.classifyStatus(200), "ok", "200")
        TestRunner:assertEqual(QuickNote.classifyStatus(nil), "retry", "transport error")
        TestRunner:assertEqual(QuickNote.classifyStatus(429), "retry", "rate limited")
        TestRunner:assertEqual(QuickNote.classifyStatus(503), "retry", "server down")
        TestRunner:assertEqual(QuickNote.classifyStatus(401), "auth", "bad key")
        TestRunner:assertEqual(QuickNote.classifyStatus(400), "drop", "malformed note")
    end)

    TestRunner:test("capturePayload: item id as client_request_id, koreader tag, body keeps the marker", function()
        local note = QuickNote.buildNote({ response = "x", timestamp = "t" })
        local p = QuickNote.capturePayload({ id = "abc-1-0011", title = note.title, body = note.body, attempts = 3 })
        TestRunner:assertEqual(p.client_request_id, "abc-1-0011", "client_request_id")
        TestRunner:assertEqual(#p.tags, 1, "one tag")
        TestRunner:assertEqual(p.tags[1], "koreader", "koreader tag")
        TestRunner:assertEqual(p.title, note.title, "title")
        TestRunner:assertEqual(p.body:sub(-#QuickNote.MARKER), QuickNote.MARKER, "marker line kept for the Mac agent")
        TestRunner:assertEqual(p.attempts, nil, "outbox bookkeeping not sent")
    end)

    TestRunner:test("settings helpers", function()
        TestRunner:assertEqual(QuickNote.serverUrl({}), QuickNote.DEFAULT_SERVER, "default server")
        TestRunner:assertEqual(QuickNote.serverUrl({ quicknote_server_url = " https://qn.example.com// " }),
            "https://qn.example.com", "trimmed, no trailing slash")
        TestRunner:assertEqual(QuickNote.isEnabled({ quicknote_enabled = true }), false, "no key")
        TestRunner:assertEqual(QuickNote.isEnabled({ quicknote_enabled = true, quicknote_api_key = "qn_abc" }), true, "on with key")
        TestRunner:assertEqual(QuickNote.isEnabled({ quicknote_api_key = "qn_abc" }), false, "key but off")
        TestRunner:assertEqual(QuickNote.maskedKey({ quicknote_api_key = "qn_abcdefghijklmnop" }), "qn_ab…mnop", "masked")
    end)

    TestRunner:test("apikeys.lua: quicknote entry is read; placeholders and odd values ignored", function()
        local saved_mod = package.loaded["apikeys"]
        QuickNote._setFileKeyLoaderForTests(nil)  -- the real reader, over a stubbed module
        package.loaded["apikeys"] = { anthropic = "sk-x", quicknote = "  qn_fromfile  " }
        TestRunner:assertEqual(QuickNote.fileKey(), "qn_fromfile", "plain string, trimmed")
        package.loaded["apikeys"] = { quicknote = { key = "qn_aliased", alias = "kindle" } }
        TestRunner:assertEqual(QuickNote.fileKey(), "qn_aliased", "{ key = ... } shape")
        package.loaded["apikeys"] = { quicknote = "YOUR_QUICKNOTE_API_KEY" }
        TestRunner:assertEqual(QuickNote.fileKey(), nil, "sample placeholder")
        package.loaded["apikeys"] = { anthropic = "sk-x" }
        TestRunner:assertEqual(QuickNote.fileKey(), nil, "no entry")
        package.loaded["apikeys"] = saved_mod
        QuickNote._setFileKeyLoaderForTests(function() return nil end)
    end)

    TestRunner:test("apikeys.lua: Settings key wins; file key alone enables when switched on", function()
        QuickNote._setFileKeyLoaderForTests(function() return "qn_file" end)
        TestRunner:assertEqual(QuickNote.apiKey({}), "qn_file", "file fallback")
        TestRunner:assertEqual(QuickNote.keySource({}), "file", "source file")
        TestRunner:assertEqual(QuickNote.apiKey({ quicknote_api_key = "qn_typed" }), "qn_typed", "typed wins")
        TestRunner:assertEqual(QuickNote.keySource({ quicknote_api_key = "qn_typed" }), "settings", "source settings")
        TestRunner:assertEqual(QuickNote.isEnabled({ quicknote_enabled = true }), true, "enabled via file key")
        QuickNote._setFileKeyLoaderForTests(function() return nil end)
        TestRunner:assertEqual(QuickNote.keySource({}), nil, "no key anywhere")
    end)

    TestRunner:test("init: a file key turns sync on once; an explicit off stays off", function()
        local function fakeSettings(features)
            local store = { features = features }
            return {
                readSetting = function(_, k) return store[k] end,
                saveSetting = function(_, k, v) store[k] = v end,
                flush = function() end,
            }, store
        end
        QuickNote._setFileKeyLoaderForTests(function() return "qn_file" end)
        local st, store = fakeSettings({})
        QuickNote.init(st)
        TestRunner:assertEqual(store.features.quicknote_enabled, true, "switched on")
        st, store = fakeSettings({ quicknote_enabled = false })
        QuickNote.init(st)
        TestRunner:assertEqual(store.features.quicknote_enabled, false, "reader's off kept")
        QuickNote._setFileKeyLoaderForTests(function() return nil end)
        st, store = fakeSettings({})
        QuickNote.init(st)
        TestRunner:assertEqual(store.features.quicknote_enabled, nil, "no key: untouched")
        QuickNote.init(nil)
    end)

    -- ── flush: the outbox against a scripted server ─────────────────────────
    -- Every unit file shares one Lua state, so the stubs are swapped in for
    -- these tests only and the originals restored afterwards.
    local STUBBED = { "luasettings", "ui/network/manager", "koassistant.api.base" }
    local saved = {}
    for _idx, name in ipairs(STUBBED) do saved[name] = package.loaded[name] end

    local files = {}  -- path -> data, so reopening the outbox sees earlier writes
    -- Values are copied in and out, like the real LuaSettings round-tripping
    -- through its file: a table read from one open must not change when a
    -- later open saves.
    local function copy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, x in pairs(v) do t[k] = copy(x) end
        return t
    end
    package.loaded["luasettings"] = {
        open = function(_, path)
            files[path] = files[path] or {}
            local store = files[path]
            return {
                readSetting = function(_, k) return copy(store[k]) end,
                saveSetting = function(_, k, v) store[k] = copy(v) end,
                flush = function() end,
            }
        end,
    }
    local wifi = true
    package.loaded["ui/network/manager"] = { isWifiOn = function() return wifi end }
    local responses, posted = {}, {}
    local on_post = nil
    package.loaded["koassistant.api.base"] = {
        fetchAsync = function(url, opts, on_done)
            local json = require("json")
            local req = json.decode(opts.body)
            table.insert(posted, { url = url, title = req.title, auth = opts.headers.Authorization,
                client_request_id = req.client_request_id, tags = req.tags })
            if on_post then local f = on_post; on_post = nil; f() end
            local r = table.remove(responses, 1) or { 201, "{}" }
            on_done(r[1], r[2])
        end,
    }
    local features = { quicknote_enabled = true, quicknote_api_key = "qn_test",
        quicknote_server_url = "https://qn.example.com" }
    local function reset(script)
        QuickNote.clearOutbox()
        responses, posted, on_post, wifi = script or {}, {}, nil, true
    end
    local function queue(title) QuickNote.enqueue({ title = title, body = title .. " body" }) end
    local function flush()
        local result
        QuickNote.flush(features, function(sent, remaining, err)
            result = { sent = sent, remaining = remaining, err = err }
        end)
        return result
    end

    TestRunner:test("flush: sends oldest first to the capture endpoint, empties the outbox", function()
        reset()
        queue("one"); queue("two")
        local r = flush()
        TestRunner:assertEqual(r.sent, 2, "sent")
        TestRunner:assertEqual(r.remaining, 0, "remaining")
        TestRunner:assertEqual(posted[1].title, "one", "order")
        TestRunner:assertEqual(posted[1].url, "https://qn.example.com/api/v1/notes/capture", "url")
        TestRunner:assertEqual(posted[1].auth, "Bearer qn_test", "auth header")
        TestRunner:assertEqual(type(posted[1].tags), "table", "tags sent as a list")
        TestRunner:assertEqual(posted[1].tags[1], "koreader", "koreader tag")
        TestRunner:assertEqual(type(posted[1].client_request_id), "string", "client_request_id sent")
        TestRunner:assertEqual(posted[1].client_request_id == posted[2].client_request_id, false,
            "each note has its own client_request_id")
    end)

    TestRunner:test("flush: a network error stops the pass and keeps the order", function()
        reset({ { 201 }, { nil, "timeout" } })
        queue("one"); queue("two"); queue("three")
        local r = flush()
        TestRunner:assertEqual(r.sent, 1, "first sent")
        TestRunner:assertEqual(r.remaining, 2, "two left")
        TestRunner:assertEqual(#posted, 2, "third not tried")
        TestRunner:assertEqual(posted[2].title, "two", "second note tried next")
        local r2 = flush()
        TestRunner:assertEqual(r2.sent, 2, "retry sends the rest")
        TestRunner:assertEqual(posted[3].title, "two", "retry resumes at the failed note")
        TestRunner:assertEqual(posted[3].client_request_id, posted[2].client_request_id,
            "the retry reuses the failed attempt's client_request_id")
    end)

    TestRunner:test("flush: a rejected key stops and keeps every note", function()
        reset({ { 401, "{}" } })
        queue("one"); queue("two")
        local r = flush()
        TestRunner:assertEqual(r.err, "auth", "auth error")
        TestRunner:assertEqual(r.remaining, 2, "nothing dropped")
    end)

    TestRunner:test("flush: a 400 skips the note and goes on; dropped after MAX_ATTEMPTS", function()
        reset({ { 400, "bad" } })
        queue("bad"); queue("good")
        local r = flush()
        TestRunner:assertEqual(r.sent, 1, "the good one went")
        TestRunner:assertEqual(r.remaining, 1, "the bad one waits")
        for _i = 2, QuickNote.MAX_ATTEMPTS do
            responses = { { 400, "bad" } }
            flush()
        end
        TestRunner:assertEqual(QuickNote.pendingCount(), 0, "dropped at the cap")
    end)

    TestRunner:test("flush: a note queued during the pass goes out in the same pass", function()
        reset()
        queue("one")
        on_post = function() queue("late") end
        local r = flush()
        TestRunner:assertEqual(r.sent, 2, "both sent")
        TestRunner:assertEqual(posted[2].title, "late", "late note")
    end)

    TestRunner:test("flush: Wi-Fi off sends nothing; sync off sends nothing", function()
        reset()
        queue("one")
        wifi = false
        TestRunner:assertEqual(flush().err, "offline", "offline")
        wifi = true
        local r
        QuickNote.flush({ quicknote_enabled = false, quicknote_api_key = "qn_x" }, function(s, rem, err) r = err end)
        TestRunner:assertEqual(r, "disabled", "disabled")
        TestRunner:assertEqual(#posted, 0, "no request")
    end)

    for _idx, name in ipairs(STUBBED) do package.loaded[name] = saved[name] end
    QuickNote._setFileKeyLoaderForTests(nil)

    print(string.format("\n=== Results: %d passed, %d failed ===\n", TestRunner.passed, TestRunner.failed))
    return TestRunner.failed == 0
end

if arg and arg[0] and arg[0]:match("test_quicknote%.lua$") then
    local success = runAll()
    os.exit(success and 0 or 1)
end

return {
    runAll = runAll,
    TestRunner = TestRunner,
}
