--[[
KOAssistant Setup Wizard v2 (wizard_onboarding_plan.md, built 2026-08-11).

INERT UNTIL RELEASE: no user-facing entry routes here yet. The old wizard in
main.lua keeps serving first-run (`checkSetupWizard`) and the "Re-run Setup
Wizard" row untouched; this module's only entry is the debug-gated
"Setup Wizard v2 (dev)" row (Settings > Advanced, visible with Console Debug
on). The release flip is: point `checkSetupWizard` at
`SetupWizard.runChain(plugin, {mark_complete = true})` and `rerunSetupWizard`
at `SetupWizard.showTopicMenu(plugin)`.

Steps are FUNCTIONS with per-step "configured?" PROBES, so one implementation
serves both first-run onboarding and the completer re-run (maintainer
2026-08-11: the wizard must respect what is already set — never re-ask, only
offer change). The topic menu runs any single step with `force = true`.

Font install target (maintainer rule 2026-08-11): the user koreader folder's
fonts/ everywhere KOReader scans it — that is `data_dir/fonts` (the install
dir on e-ink/PocketBook, <external storage>/koreader/fonts on Android).
Desktop mac/linux is the lone exception: KOReader does not scan its data dir
there, so we use KOReader's own designated user font dir (first
FontSettings:getPath() entry). Both branches call KOReader's functions; no
paths of our own. We never touch system font locations.

Everything the wizard writes into KOReader-owned state is RECORDED in plugin
settings for precise undo (features._wizard_font_install /
_wizard_gesture_writes — registered in the storage registry's internal
bucket): the full-reset audit item.
]]

local logger = require("koassistant.core.logger")
local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template

local SetupWizard = {}

-- The plugin's root folder (for the bundled font), without a trailing slash
local PLUGIN_DIR = (require("koassistant.core.paths").ROOT:gsub("/$", ""))

SetupWizard.FONT_FILE = "NotoEmoji-Regular.ttf"
-- Mirrors Font.additional_fallback_max_nb (KOReader ui/font.lua); the
-- fallback list is shared with the user's own language fallbacks — never
-- evict, only inform (plan §2 cap-full rule).
SetupWizard.FALLBACK_MAX = 4

-- Curated picker for the connect step: the maintained providers a fresh user
-- should choose from (brand names untranslated). Community providers and
-- custom endpoints stay in Settings — the wizard names the door instead.
SetupWizard.PROVIDER_CHOICES = {
    { id = "anthropic",  name = "Anthropic" },
    { id = "openai",     name = "OpenAI" },
    { id = "gemini",     name = "Google Gemini" },
    { id = "deepseek",   name = "DeepSeek" },
    { id = "mistral",    name = "Mistral" },
    { id = "xai",        name = "xAI (Grok)" },
    { id = "openrouter", name = "OpenRouter" },
    { id = "zai",        name = "Z.AI" },
    { id = "perplexity", name = "Perplexity" },
    { id = "ollama",     name = "Ollama (local)" },
}

-- Gesture candidates offered per mode. Deliberately excludes hold-corner
-- slots (the ignore_hold_corners setting silently disables those) and
-- anything a stock KOReader ships bound. Ids verified against the Gestures
-- plugin's gestures_list 2026-08-11.
SetupWizard.GESTURE_CANDIDATES = {
    { id = "tap_right_bottom_corner",       label = _("Tap bottom-right corner") },
    { id = "tap_left_bottom_corner",        label = _("Tap bottom-left corner") },
    { id = "double_tap_bottom_right_corner", label = _("Double-tap bottom-right corner") },
    { id = "double_tap_bottom_left_corner", label = _("Double-tap bottom-left corner") },
    { id = "short_diagonal_swipe",          label = _("Short diagonal swipe") },
}

--========================================================================--
--  Pure helpers (unit-tested in tests/unit/test_setup_wizard.lua;
--  no KOReader state, everything injected)
--========================================================================--

-- Where the emoji font goes. opts = { is_desktop, data_dir, user_font_path }
-- (user_font_path = FontSettings:getPath(), possibly semicolon-joined).
function SetupWizard.resolveFontDir(opts)
    if opts.is_desktop then
        local first = opts.user_font_path and opts.user_font_path:match("[^;]+")
        if first and first ~= "" then
            return first
        end
    end
    return opts.data_dir .. "/fonts"
end

-- Append a font path to a font_ui_fallbacks list (KOReader semantics: new
-- entries go to position 1 of the additional list). Returns the new list,
-- or nil + reason ("present" | "cap"). Never mutates the input.
function SetupWizard.appendFallback(list, path, max_nb)
    local fname = path:match("[^/]+$")
    local out = {}
    for i = 1, #(list or {}) do
        local entry = list[i]
        if entry:match("[^/]+$") == fname then
            return nil, "present"
        end
        out[i] = entry
    end
    if #out >= (max_nb or SetupWizard.FALLBACK_MAX) then
        return nil, "cap"
    end
    table.insert(out, 1, path)
    return out
end

-- Registered emoji fallback in a font_ui_fallbacks list? Returns the path.
function SetupWizard.findEmojiFallback(list)
    for i = 1, #(list or {}) do
        if list[i]:match("[^/]+$") == SetupWizard.FONT_FILE then
            return list[i]
        end
    end
    return nil
end

-- The emoji font's state for the Emoji Font row in Settings (B397):
-- "missing" (not registered, or the registered file is gone), "restart"
-- (registered, but KOReader reads the list at startup and has not loaded
-- it), "installed".
function SetupWizard.fontState(registered_path, file_exists, loaded)
    if not registered_path or not file_exists then
        return "missing"
    end
    if not loaded then
        return "restart"
    end
    return "installed"
end

function SetupWizard.fontRowLabel(state)
    if state == "installed" then
        return _("Emoji Font: Installed")
    elseif state == "restart" then
        return _("Emoji Font: Restart KOReader")
    end
    return _("Emoji Font: Not Installed")
end

function SetupWizard.probeLanguageF(features)
    if features.interaction_languages and #features.interaction_languages > 0 then
        return true, features.interaction_languages[1]
    end
    if features.user_languages and features.user_languages ~= "" then
        return true, features.user_languages
    end
    return false
end

-- Privacy counts as configured when ANY of the consent keys is explicitly
-- present — they are nil until a preset or toggle writes them, and an
-- explicit false is as much a decision as a true.
local PRIVACY_KEYS = {
    "enable_highlights_sharing", "enable_annotations_sharing",
    "enable_notebook_sharing", "enable_basic_stats", "enable_advanced_stats",
    "enable_book_text_extraction", "enable_library_scanning",
}
function SetupWizard.probePrivacyF(features)
    for _idx, key in ipairs(PRIVACY_KEYS) do
        if features[key] ~= nil then
            return true, key
        end
    end
    return false
end

-- gui_keys = features.api_keys, file_keys = decoded apikeys.lua table (or
-- nil), has_oauth = codex token present, is_placeholder = predicate.
function SetupWizard.probeProviderF(gui_keys, file_keys, has_oauth, is_placeholder)
    for provider, key in pairs(gui_keys or {}) do
        if type(key) == "string" and not is_placeholder(key) then
            return true, T(_("key saved for %1"), provider)
        end
    end
    for provider, key in pairs(file_keys or {}) do
        -- quicknote (llm-note fork) is the notes server's key, not an AI provider
        if provider ~= "quicknote" and type(key) == "string" and not is_placeholder(key) then
            return true, T(_("apikeys.lua key for %1"), provider)
        end
    end
    if has_oauth then
        return true, _("OpenAI Subscription connected")
    end
    return false
end

-- Any KOAssistant action bound in a gestures table? Returns count + a
-- description of the first hit. Entry tables may carry a "settings"
-- ordering subtable — that key is not an action.
function SetupWizard.scanGestures(gestures_data)
    local count, first = 0, nil
    for _idx, section_name in ipairs({ "gesture_reader", "gesture_fm" }) do
        local section = (gestures_data or {})[section_name]
        if type(section) == "table" then
            for slot, entry in pairs(section) do
                if type(entry) == "table" then
                    for action_id in pairs(entry) do
                        if type(action_id) == "string" and action_id:find("^koassistant") then
                            count = count + 1
                            first = first or (action_id .. " @ " .. slot)
                            break
                        end
                    end
                end
            end
        end
    end
    return count, first
end

-- Free/taken state of one gesture slot entry.
function SetupWizard.slotState(entry)
    if entry == nil or (type(entry) == "table" and next(entry) == nil) then
        return "free", 0
    end
    local n = 0
    if type(entry) == "table" then
        for k in pairs(entry) do
            if k ~= "settings" then n = n + 1 end
        end
    end
    return "taken", n
end

--========================================================================--
--  Live state readers
--========================================================================--

local function feats(plugin)
    return plugin.settings:readSetting("features") or {}
end

local function saveFeats(plugin, features)
    plugin.settings:saveSetting("features", features)
    plugin.settings:flush()
end

-- The emoji font as KOReader sees it now: registered in font_ui_fallbacks,
-- its file present, and loaded into Font.fallbacks (read once at startup, so
-- a fresh install waits for the restart). Returns the state and the path.
function SetupWizard.readFontState()
    local registered = G_reader_settings
        and SetupWizard.findEmojiFallback(G_reader_settings:readSetting("font_ui_fallbacks"))
    local exists, loaded = false, false
    if registered then
        local lfs = require("libs/libkoreader-lfs")
        exists = lfs.attributes(registered, "mode") ~= nil
        local ok, Font = pcall(require, "ui/font")
        local fallbacks = (ok and type(Font) == "table") and Font.fallbacks or {}
        for _idx, path in ipairs(fallbacks) do
            if path == registered then
                loaded = true
                break
            end
        end
    end
    return SetupWizard.fontState(registered, exists, loaded), registered
end

local function fontInstallDir()
    local Device = require("device")
    local DataStorage = require("datastorage")
    local is_desktop = Device:isDesktop() or Device:isEmulator()
    local user_path
    if is_desktop then
        local ok, FontSettings = pcall(require, "ui/elements/font_settings")
        if ok and FontSettings then
            local ok2, path = pcall(function() return FontSettings:getPath() end)
            user_path = ok2 and path or nil
        end
    end
    return SetupWizard.resolveFontDir({
        is_desktop = is_desktop,
        data_dir = DataStorage:getDataDir(),
        user_font_path = user_path,
    })
end

local function readFileApiKeys()
    local path = PLUGIN_DIR .. "/apikeys.lua"
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(path, "mode") then return nil end
    local ok, keys = pcall(dofile, path)
    if ok and type(keys) == "table" then return keys end
    return nil
end

local function readGesturesData(plugin)
    -- Prefer the live Gestures plugin instance (its settings object is
    -- class-level, shared by reader and file-browser instances).
    local ges = plugin.ui and plugin.ui.gestures
    if ges and ges.settings and ges.settings.data then
        return ges.settings.data, ges.settings
    end
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/gestures.lua")
    settings.data = settings.data or {}
    return settings.data, settings
end

-- Raw probes (ignore the pretend flag). Each returns configured, detail.
local function probeRaw(plugin, name)
    local f = feats(plugin)
    if name == "language" then
        return SetupWizard.probeLanguageF(f)
    elseif name == "provider" then
        local Base = require("koassistant.api.base")
        local has_oauth = type(f.openai_codex_oauth) == "table"
            and next(f.openai_codex_oauth) ~= nil
        return SetupWizard.probeProviderF(f.api_keys, readFileApiKeys(),
            has_oauth, Base.isPlaceholderKey)
    elseif name == "privacy" then
        return SetupWizard.probePrivacyF(f)
    elseif name == "icons" then
        -- Configured = the user decided the toggles (any of the three
        -- explicitly present). Registration state rides in the detail.
        local registered = G_reader_settings
            and SetupWizard.findEmojiFallback(G_reader_settings:readSetting("font_ui_fallbacks"))
        local decided = f.enable_emoji_icons ~= nil
            or f.enable_emoji_panel_icons ~= nil
            or f.enable_data_access_indicators ~= nil
        local detail
        if registered then
            detail = f.enable_emoji_icons and _("font registered, icons on")
                or _("font registered")
        elseif decided then
            detail = _("decided without font install")
        end
        return decided, detail
    elseif name == "gestures" then
        local data = readGesturesData(plugin)
        local count, first = SetupWizard.scanGestures(data)
        if count > 0 then
            return true, T(_("%1 assigned (%2)"), count, first)
        end
        return false
    end
    return false
end

-- Probe with the dev "pretend unconfigured" flag honored (skip logic only;
-- the inspector shows raw values).
function SetupWizard.probe(plugin, name)
    if feats(plugin)._wizard_pretend_unconfigured then
        return false
    end
    return probeRaw(plugin, name)
end

--========================================================================--
--  Font install
--========================================================================--

-- Install the bundled font into KOReader's fonts folder and enable it as a UI
-- fallback: ONE installer, run by the wizard's Icons step and by the Emoji
-- Font row in Settings (B397). opts.wizard = the wizard's session (its results
-- line, its restart flag, the glyph test after the restart); opts.done(installed)
-- runs when the flow's last popup closes.
function SetupWizard.installFont(plugin, opts)
    opts = opts or {}
    local ctx = opts.wizard
    local done = opts.done or function() end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    local ffiutil = require("ffi/util")

    local src = PLUGIN_DIR .. "/fonts/" .. SetupWizard.FONT_FILE
    local dest_dir = fontInstallDir()
    local dest = dest_dir .. "/" .. SetupWizard.FONT_FILE

    if not lfs.attributes(dest, "mode") then
        if not lfs.attributes(src, "mode") then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("The bundled emoji font is missing from this build. The wiki's Troubleshooting page has the manual route."),
                dismiss_callback = function() done(false) end,
            })
            return
        end
        util.makePath(dest_dir)
        local err = ffiutil.copyFile(src, dest)
        if err then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Could not install the font: %1"), tostring(err)),
                dismiss_callback = function() done(false) end,
            })
            return
        end
    end

    -- Register as a UI fallback (KOReader reads this at startup).
    local fallback_added = false
    local list = G_reader_settings:readSetting("font_ui_fallbacks")
    local new_list, reason = SetupWizard.appendFallback(list, dest, SetupWizard.FALLBACK_MAX)
    if new_list then
        G_reader_settings:saveSetting("font_ui_fallbacks", new_list)
        fallback_added = true
    elseif reason == "present" then
        fallback_added = true -- already registered (possibly by the user)
    end

    -- Record what we wrote into KOReader-owned state (precise undo; the
    -- "full reset actually resets" audit reads this).
    local f = feats(plugin)
    f._wizard_font_install = { path = dest, fallback_added = fallback_added }
    if ctx then
        f._wizard_font_pending_confirm = true
    end
    saveFeats(plugin, f)

    if ctx then
        table.insert(ctx.results, _("Emoji font installed (restart pending)"))
        ctx.restart_needed = true
    end

    local function restartThen()
        local UIM = require("ui/uimanager")
        UIM:askForRestart()
        done(true)
    end

    if reason == "cap" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("The font was installed, but KOReader's additional fallback list is full (limit %1). Uncheck one in KOReader Settings > Device > Additional UI fallback fonts, then check Noto Emoji there."), SetupWizard.FALLBACK_MAX),
            dismiss_callback = restartThen,
        })
        return
    end

    local text
    if ctx then
        text = _("Emoji font installed and registered. After the restart, the wizard shows a quick glyph test to confirm it works.")
    else
        text = _("Noto Emoji is installed and enabled as a UI fallback font. Restart KOReader to load it, then tap Emoji Font again to test the icons.")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        dismiss_callback = restartThen,
    })
end

-- The install offer, ONE copy: the wizard's Icons step (opts.wizard = its
-- session), the Emoji Font row in Settings, and the one-time offer when icons
-- are on without a font (opts.intro replaces the first sentence, opts.later
-- names the row for next time).
function SetupWizard.offerFontInstall(plugin, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local ctx = opts.wizard
    local done = opts.done or function() end
    local intro = opts.intro
        or _("KOReader ships no emoji font, so KOAssistant's menu icons show as empty boxes. Install the bundled Noto Emoji font (about 860 KB) into KOReader now?")
    local tail
    if ctx then
        tail = _("Icons appear in plugin menus, buttons and panels, never inside the Markdown chat view. Requires a KOReader restart; a glyph test follows after it.")
    else
        tail = _("Icons appear in plugin menus, buttons and panels, never inside the Markdown chat view. Requires a KOReader restart; the Emoji Font row then offers a display test.")
    end
    local parts = {}
    if ctx then table.insert(parts, _("ICONS")) end
    table.insert(parts, intro)
    table.insert(parts, tail)
    if opts.later then table.insert(parts, opts.later) end
    local advancing = false
    UIManager:show(ConfirmBox:new{
        text = table.concat(parts, "\n\n"),
        ok_text = _("Install"),
        cancel_text = ctx and _("Skip") or _("Not now"),
        ok_callback = function()
            advancing = true
            SetupWizard.installFont(plugin, { wizard = ctx, done = done })
        end,
        cancel_callback = function()
            if not advancing then
                advancing = true
                done(false)
            end
        end,
    })
end

local function showGlyphTest(plugin, ctx, next_step)
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local text = _("EMOJI DISPLAY TEST") .. "\n\n" ..
        _("Do these icons display correctly on your device?") .. "\n\n" ..
        "📄 Document  📝 Notes  📓 Notebook\n" ..
        "🔍 Search  🌐 Web  🎭 Behavior\n" ..
        "📜 History  🔖 Bookmark  📖 Book" .. "\n\n" ..
        _("Emoji appear in plugin menus, buttons and panels, never inside the Markdown chat view (a KOReader renderer limit).") .. "\n\n" ..
        _("If you see blank boxes or question marks, choose \"No\".")

    local advancing = false
    local function clearPending()
        local f = feats(plugin)
        if f._wizard_font_pending_confirm then
            f._wizard_font_pending_confirm = nil
            saveFeats(plugin, f)
        end
    end
    UIManager:show(ConfirmBox:new{
        icon = "notice-info",
        text = text,
        ok_text = _("Yes, enable"),
        cancel_text = _("No, skip"),
        ok_callback = function()
            advancing = true
            local f = feats(plugin)
            f.enable_emoji_icons = true
            f.enable_emoji_panel_icons = true
            f.enable_data_access_indicators = true
            f._wizard_font_pending_confirm = nil
            saveFeats(plugin, f)
            plugin:updateConfigFromSettings()
            table.insert(ctx.results, _("Emoji icons enabled"))
            next_step()
        end,
        cancel_callback = function()
            if not advancing then
                advancing = true
                clearPending()
                next_step()
            end
        end,
    })
end

-- The Emoji Font row, Settings → Display Settings → Emoji (B397): the install
-- offer while the font is missing, the restart ask while KOReader has not
-- loaded it, the display test (which turns the icons on) once it has.
function SetupWizard.showFontRow(plugin)
    local state = SetupWizard.readFontState()
    if state == "installed" then
        return showGlyphTest(plugin, { results = {} }, function() end)
    end
    if state == "restart" then
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Noto Emoji is installed and enabled as a UI fallback font, but KOReader loads fonts at startup. Restart KOReader now?"),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function()
                UIManager:askForRestart()
            end,
        })
        return
    end
    SetupWizard.offerFontInstall(plugin, {})
end

-- Once per install: emoji icons are on but no emoji font is there (B397).
-- Runs from ensureInitialized after the first-run wizard and the language
-- prompt; the stamp is written whatever the answer. Returns true when shown.
function SetupWizard.maybeOfferFont(plugin)
    if not plugin.settings:readSetting("setup_wizard_completed") then
        return false
    end
    local f = feats(plugin)
    if f._emoji_font_offered then
        return false
    end
    if not (f.enable_emoji_icons or f.enable_emoji_panel_icons or f.enable_data_access_indicators) then
        return false
    end
    if SetupWizard.readFontState() ~= "missing" then
        return false
    end
    f._emoji_font_offered = true
    saveFeats(plugin, f)
    SetupWizard.offerFontInstall(plugin, {
        intro = _("Emoji icons are on, but KOReader has no emoji font, so they show as empty boxes. Install the bundled Noto Emoji font (about 860 KB) into KOReader now?"),
        later = _("Later: Settings → Display Settings → Emoji → Emoji Font."),
    })
    return true
end

--========================================================================--
--  Steps (each: function(plugin, ctx, next_step); self-skips on its probe
--  unless ctx.force)
--========================================================================--

function SetupWizard.stepWelcome(plugin, ctx, next_step)
    if ctx.single then return next_step() end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("Welcome to KOAssistant!") .. "\n\n" ..
            _("Let's set up four things: how you connect to an AI provider, what the plugin may read, your language and icons, and how you open it fast.") .. "\n\n" ..
            _("Every step can be skipped and changed later in Settings. Tap to continue."),
        dismiss_callback = next_step,
    })
end

function SetupWizard.stepRestore(plugin, ctx, next_step)
    -- Only meaningful on a fresh-looking install (no provider configured)
    -- with a backup archive present — the reinstall / new-device story.
    if not ctx.force and SetupWizard.probe(plugin, "provider") then
        return next_step()
    end
    local BackupManager = require("koassistant.storage.backup_manager")
    local manager = BackupManager:new()
    local ok, backups = pcall(function() return manager:listBackups() end)
    local real = {}
    if ok then
        for _idx, b in ipairs(backups or {}) do
            if not b.is_restore_point then table.insert(real, b) end
        end
    end
    if #real == 0 then return next_step() end

    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local advancing = false
    UIManager:show(ConfirmBox:new{
        text = T(_("A KOAssistant backup was found (%1 available)."), #real) .. "\n\n" ..
            _("Restore your previous settings, chats and data instead of setting up from scratch?"),
        ok_text = _("Restore…"),
        cancel_text = _("Set up fresh"),
        ok_callback = function()
            advancing = true
            -- Hand off to the full restore flow (it has its own preview and
            -- option dialogs). The wizard ends here — after a restore the
            -- probes would be stale; re-enter via the topic menu anytime.
            plugin:showRestoreBackupDialog()
        end,
        cancel_callback = function()
            if not advancing then
                advancing = true
                next_step()
            end
        end,
    })
end

function SetupWizard.stepProvider(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "provider") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")

    local dialog
    local advancing = false
    local function advanceOnce()
        if advancing then return end
        advancing = true
        next_step()
    end

    -- After a key is saved: offer the inline connectivity test.
    local function offerTest(provider_id, provider_name)
        local followup
        followup = ButtonDialog:new{
            title = T(_("%1 is set up."), provider_name) .. "\n" ..
                _("Test the connection now? (one tiny request)"),
            buttons = {
                {
                    {
                        text = _("Test provider"),
                        callback = function()
                            plugin:testProvider(provider_id)
                        end,
                    },
                    {
                        text = _("Continue"),
                        callback = function()
                            UIManager:close(followup)
                            advanceOnce()
                        end,
                    },
                },
            },
            tap_close_callback = advanceOnce,
        }
        UIManager:show(followup)
    end

    local function pickProvider(choice)
        UIManager:close(dialog)
        if choice.id == "ollama" then
            -- Keyless local default: select it and explain the endpoint.
            local f = feats(plugin)
            f.provider = "ollama"
            f.model = nil
            saveFeats(plugin, f)
            plugin:updateConfigFromSettings()
            table.insert(ctx.results, _("Provider: Ollama (local)"))
            UIManager:show(InfoMessage:new{
                text = _("Ollama selected — no API key needed. It expects a local server at localhost:11434 (change the endpoint in Settings > Provider)."),
                dismiss_callback = function() offerTest("ollama", "Ollama") end,
            })
            return
        end
        -- Key entry via the existing dialog: saving the first key also
        -- auto-selects the provider (showApiKeyDialog behavior).
        plugin:showApiKeyDialog(choice.id, choice.name, false, function()
            table.insert(ctx.results, T(_("Provider: %1"), choice.name))
            offerTest(choice.id, choice.name)
        end)
    end

    local buttons = {}
    local row = {}
    for _idx, choice in ipairs(SetupWizard.PROVIDER_CHOICES) do
        table.insert(row, {
            text = choice.name,
            callback = function() pickProvider(choice) end,
        })
        if #row == 2 then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then table.insert(buttons, row) end
    table.insert(buttons, {
        {
            text = _("OpenAI Subscription (no API key)"),
            callback = function()
                UIManager:close(dialog)
                -- The OAuth connect flow owns the screen from here (its
                -- dialog is modal); finish setup later via the topic menu.
                local OAuth = require("koassistant.api.openai_codex_oauth")
                OAuth.startInteractiveConnect(plugin)
            end,
        },
    })
    table.insert(buttons, {
        {
            text = _("Skip for now"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{
                    text = _("No provider configured. Nothing will work until one is: add a key anytime in Settings > API Keys & Auth."),
                    dismiss_callback = advanceOnce,
                })
            end,
        },
    })

    dialog = ButtonDialog:new{
        title = _("CONNECT A PROVIDER") .. "\n" ..
            _("KOAssistant needs an AI provider account. Pick yours — you'll paste its API key next:"),
        buttons = buttons,
        tap_close_callback = advanceOnce,
    }
    UIManager:show(dialog)
end

function SetupWizard.stepPrivacy(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "privacy") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")

    local dialog
    local advancing = false
    local function advanceOnce()
        if advancing then return end
        advancing = true
        next_step()
    end

    -- The three presets of the question model (ruling 10 of 2026-10-14):
    -- one value for every kind of data; "Allow everything" includes book text
    local function applyPreset(method, label)
        UIManager:close(dialog)
        plugin[method](plugin, nil)
        table.insert(ctx.results, T(_("Privacy: %1"), label))
        advanceOnce()
    end

    dialog = ButtonDialog:new{
        title = _("PRIVACY & DATA") .. "\n" ..
            _("What may KOAssistant send to your AI provider? Your highlights, notes, notebook, book text, book list and reading habits each have one value: Ask, Allow or Never.") .. "\n" ..
            _("Ask, the default, means the first action that wants a kind of data asks you, and your answer can be kept for the book. A book can also have its own values (Book Settings > Privacy); a book's Never always wins.") .. "\n" ..
            _("Spoiler protection is separate and ON by default: responses respect your reading position."),
        buttons = {
            {
                { text = _("Default (Ask)"), callback = function() applyPreset("applyPrivacyPresetDefault", _("Default (Ask)")) end },
            },
            {
                { text = _("Allow everything"), callback = function() applyPreset("applyPrivacyPresetFull", _("Allow everything")) end },
                { text = _("Block everything"), callback = function() applyPreset("applyPrivacyPresetMinimal", _("Block everything")) end },
            },
            {
                {
                    text = _("Decide later"),
                    callback = function()
                        UIManager:close(dialog)
                        advanceOnce()
                    end,
                },
            },
        },
        tap_close_callback = advanceOnce,
    }
    UIManager:show(dialog)
end

function SetupWizard.stepLanguage(plugin, ctx, next_step)
    if ctx.force then
        -- Topic-menu entry: go straight to the picker (the confirm flow
        -- self-skips when a language is already set).
        return plugin:showWizardLanguagePicker(next_step)
    end
    if SetupWizard.probe(plugin, "language") then
        return next_step()
    end
    -- Reuse the existing, working step (auto-detect + confirm-or-choose).
    plugin:showSetupStep2Language(next_step)
end

function SetupWizard.stepIcons(plugin, ctx, next_step)
    local f = feats(plugin)
    if f._wizard_font_pending_confirm then
        -- Post-restart continuation of an earlier install.
        return showGlyphTest(plugin, ctx, next_step)
    end
    if not ctx.force and SetupWizard.probe(plugin, "icons") then
        return next_step()
    end
    local registered = G_reader_settings
        and SetupWizard.findEmojiFallback(G_reader_settings:readSetting("font_ui_fallbacks"))
    if registered then
        return showGlyphTest(plugin, ctx, next_step)
    end
    SetupWizard.offerFontInstall(plugin, { wizard = ctx, done = next_step })
end


function SetupWizard.stepGestures(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "gestures") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    local data, settings = readGesturesData(plugin)
    if not data or (not data.gesture_reader and not data.gesture_fm and next(data) == nil) then
        -- gestures.lua not initialized yet (Gestures plugin never ran?) —
        -- don't invent its file shape; point at the manual route.
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("GESTURES") .. "\n\n" ..
                _("KOAssistant's panels can be bound to gestures in KOReader Settings (gear icon) > Taps and gestures. KOReader's gesture data isn't ready yet, so set them up there."),
            dismiss_callback = next_step,
        })
        return
    end

    local assignments = {}

    local function commit()
        if #assignments == 0 then return next_step() end
        for _idx, a in ipairs(assignments) do
            data[a.section] = data[a.section] or {}
            data[a.section][a.slot] = { [a.action] = true }
        end
        -- Write through the SAME settings object the Gestures plugin
        -- flushes (issue-#72 class: a divergent LuaSettings instance would
        -- be silently overwritten by its next onFlushSettings).
        settings:flush()
        -- Record for precise undo / the full-reset audit.
        local f = feats(plugin)
        f._wizard_gesture_writes = f._wizard_gesture_writes or {}
        for _idx, a in ipairs(assignments) do
            table.insert(f._wizard_gesture_writes,
                { section = a.section, slot = a.slot, action = a.action })
        end
        saveFeats(plugin, f)
        local names = {}
        for _idx, a in ipairs(assignments) do table.insert(names, a.label) end
        table.insert(ctx.results,
            T(_("Gestures assigned: %1 (restart pending)"), table.concat(names, ", ")))
        ctx.restart_needed = true
        next_step()
    end

    -- One picker per panel; slots marked free/taken, taken rows disabled
    -- (the wizard never overwrites an existing binding).
    local function pickSlot(section, action_id, panel_title, panel_blurb, done)
        local dialog
        local picked = false
        local function doneOnce()
            if picked then return end
            picked = true
            done()
        end
        local buttons = {}
        for _idx, cand in ipairs(SetupWizard.GESTURE_CANDIDATES) do
            local state = SetupWizard.slotState((data[section] or {})[cand.id])
            local free = state == "free"
            table.insert(buttons, {
                {
                    text = free and cand.label or (cand.label .. " — " .. _("taken")),
                    enabled = free,
                    callback = function()
                        picked = true
                        UIManager:close(dialog)
                        table.insert(assignments, {
                            section = section, slot = cand.id,
                            action = action_id, label = cand.label,
                        })
                        done()
                    end,
                },
            })
        end
        table.insert(buttons, {
            {
                text = _("Skip this panel"),
                callback = function()
                    picked = true
                    UIManager:close(dialog)
                    done()
                end,
            },
        })
        dialog = ButtonDialog:new{
            title = panel_title .. "\n" .. panel_blurb .. "\n" ..
                _("Pick a gesture (restart required to take effect):"),
            buttons = buttons,
            tap_close_callback = doneOnce,
        }
        UIManager:show(dialog)
    end

    pickSlot("gesture_reader", "koassistant_quick_actions",
        _("OPEN IT FAST — Quick Actions (reader)"),
        _("Book actions, artifacts and utilities while reading."),
        function()
            pickSlot("gesture_fm", "koassistant_ai_settings",
                _("OPEN IT FAST — Quick Settings (file browser)"),
                _("Provider, model, behavior and more from the file browser."),
                commit)
        end)
end

function SetupWizard.stepFinish(plugin, ctx, next_step)
    if ctx.single then
        if next_step then next_step() end
        return
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    local lines = { _("SETUP COMPLETE") }
    if #ctx.results > 0 then
        table.insert(lines, "")
        for _idx, r in ipairs(ctx.results) do
            table.insert(lines, "• " .. r)
        end
    end
    table.insert(lines, "")
    table.insert(lines, _("You'll also find KOAssistant in the highlight menu, the dictionary popup, the file browser long-press, and the main menu."))
    if ctx.restart_needed then
        table.insert(lines, "")
        table.insert(lines, _("Restart KOReader to finish (font and gesture changes need it)."))
    end
    table.insert(lines, "")
    table.insert(lines, _("Re-run any part of this from the setup topics anytime."))

    if ctx.mark_complete then
        plugin.settings:saveSetting("setup_wizard_completed", true)
        plugin.settings:flush()
    end

    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = {
            {
                {
                    text = _("Open a chat"),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:onKOAssistantGeneralChat()
                    end,
                },
                {
                    text = _("Done"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--========================================================================--
--  Runners
--========================================================================--

local CHAIN = {
    { key = "welcome",  fn = function(...) return SetupWizard.stepWelcome(...) end },
    { key = "restore",  fn = function(...) return SetupWizard.stepRestore(...) end },
    { key = "provider", fn = function(...) return SetupWizard.stepProvider(...) end },
    { key = "privacy",  fn = function(...) return SetupWizard.stepPrivacy(...) end },
    { key = "language", fn = function(...) return SetupWizard.stepLanguage(...) end },
    { key = "icons",    fn = function(...) return SetupWizard.stepIcons(...) end },
    { key = "gestures", fn = function(...) return SetupWizard.stepGestures(...) end },
    { key = "finish",   fn = function(...) return SetupWizard.stepFinish(...) end },
}

-- opts: force (run every step), mark_complete (write the completion flag at
-- the finish step — the release flip passes this; dev runs never do).
function SetupWizard.runChain(plugin, opts)
    opts = opts or {}
    local ctx = {
        force = opts.force or false,
        mark_complete = opts.mark_complete or false,
        results = {},
        restart_needed = false,
    }
    local i = 0
    local function advance()
        i = i + 1
        local step = CHAIN[i]
        if not step then return end
        local ok, err = pcall(step.fn, plugin, ctx, advance)
        if not ok then
            logger.warn("KOAssistant wizard: step", step.key, "failed:", err)
            advance()
        end
    end
    advance()
end

-- The completer surface: per-topic state, each row runs one step forced.
function SetupWizard.showTopicMenu(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    local topics = {
        { key = "provider", label = _("Connection"), step = SetupWizard.stepProvider },
        { key = "privacy",  label = _("Privacy"),    step = SetupWizard.stepPrivacy },
        { key = "language", label = _("Language"),   step = SetupWizard.stepLanguage },
        { key = "icons",    label = _("Icons"),      step = SetupWizard.stepIcons },
        { key = "gestures", label = _("Gestures"),   step = SetupWizard.stepGestures },
    }

    local dialog
    local buttons = {}
    for _idx, topic in ipairs(topics) do
        local configured, detail = probeRaw(plugin, topic.key)
        local suffix
        if configured then
            suffix = detail and T(_("✓ %1"), detail) or _("✓ configured")
        else
            suffix = _("not set")
        end
        table.insert(buttons, {
            {
                text = topic.label .. "  —  " .. suffix,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local ctx = { force = true, single = true, results = {}, restart_needed = false }
                    topic.step(plugin, ctx, function()
                        -- Reopen with fresh states so the ✓ marks update.
                        SetupWizard.showTopicMenu(plugin)
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("KOAssistant setup"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--========================================================================--
--  Dev menu (the ONLY entry until the release flip)
--========================================================================--

function SetupWizard.showDevMenu(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")

    local f = feats(plugin)
    local pretend = f._wizard_pretend_unconfigured == true

    local dialog
    local buttons = {
        {
            {
                text = _("Run setup chain"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.runChain(plugin)
                end,
            },
            {
                text = _("Run all steps (force)"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.runChain(plugin, { force = true })
                end,
            },
        },
        {
            {
                text = _("Topic menu (completer)"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.showTopicMenu(plugin)
                end,
            },
        },
        {
            {
                text = _("Probe inspector"),
                callback = function()
                    UIManager:close(dialog)
                    local lines = { _("Wizard probes (raw state):"), "" }
                    for _idx, name in ipairs({ "provider", "privacy", "language", "icons", "gestures" }) do
                        local configured, detail = probeRaw(plugin, name)
                        local state = configured and "✓" or "✗"
                        table.insert(lines, string.format("%s %s%s", state, name,
                            detail and (" — " .. detail) or ""))
                    end
                    local ff = feats(plugin)
                    table.insert(lines, "")
                    table.insert(lines, "setup_wizard_completed: "
                        .. tostring(plugin.settings:readSetting("setup_wizard_completed") or false))
                    table.insert(lines, "font pending confirm: "
                        .. tostring(ff._wizard_font_pending_confirm or false))
                    table.insert(lines, "pretend unconfigured: "
                        .. tostring(ff._wizard_pretend_unconfigured or false))
                    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
                end,
            },
        },
        {
            {
                text = pretend and _("Pretend unconfigured: ON")
                    or _("Pretend unconfigured: off"),
                callback = function()
                    UIManager:close(dialog)
                    local ff = feats(plugin)
                    ff._wizard_pretend_unconfigured = not pretend or nil
                    saveFeats(plugin, ff)
                    SetupWizard.showDevMenu(plugin)
                end,
            },
            {
                text = _("Clear completion flag"),
                callback = function()
                    UIManager:close(dialog)
                    plugin.settings:delSetting("setup_wizard_completed")
                    plugin.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Completion flag cleared — the (old) wizard fires on the next first interaction."),
                        timeout = 3,
                    })
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = _("Setup Wizard v2 (dev preview)") .. "\n" ..
            _("Inert for users until the release flip — the old wizard still serves first-run."),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return SetupWizard
