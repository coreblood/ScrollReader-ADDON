--[[----------------------------------------------------------------------------
  ScrollReader v1.2.0 (WotLK 3.3.5a, Uncapped server)

  Bulk reader for six scroll types via the server's mass-consume verb, driven
  by a keybindable six-button bar plus the original master sweep buttons.

  Wire (same as the Dashboard's "Use in bulk" buttons):
    Request:  SendAddonMessage("REAGENTBANK", "SCRALL:<itemEntry>", "WHISPER", me)
              -- server consumes EVERY bag copy of that entry in one call.
    Reply:    "SCRDONE:<entry>:<used>:<held>" on prefix "UNC".
              -- THREE fields. A two-field anchored match is the documented
              -- historical dead-branch bug in UncappedScrolls; not repeated here.
    Rejection is NOT silence on this realm: a non-whitelisted entry still gets
    SCRDONE (used=0) plus a server-sent explanation line. The 6s watchdog only
    covers a server build with no handler at all.

  Item entries are resolved live from bag links by exact title (the four kirei
  scrolls also carry their known entries as icon fallbacks). You can only bulk
  what you hold, so bags are always a sufficient source of truth for the entry.

  v1.2.3: NO confirmation dialog, by explicit owner decision (overrides the
  suite's confirm-destructive default for this addon) — every trigger sends
  immediately; the SCRDONE chat line is the receipt.

  Keybindings: Bindings.xml (auto-loaded by the client) exposes one binding per
  scroll type under ESC > Key Bindings > ScrollReader, each calling the global
  ScrollReader_BulkByIndex(i).

  v1.3.0: dungeon-exit auto-read (borrowed from UncappedAutoScroll). ~5s after
  leaving a party instance, Mastery and Delver are read if 300+ are held, and
  the chain spam-pushes SCRALL (ignoring used=0) until bags are clean or the
  CHAIN_MAX budget runs out. Toggle: /sr dungeon.
------------------------------------------------------------------------------]]

local ADDON_NAME = "ScrollReader"
local VERSION    = "1.3.0"
local ICON       = "Interface\\Icons\\INV_Scroll_03"

local TRANSPORT_PREFIX = "REAGENTBANK"  -- client -> server
local REPLY_PREFIX     = "UNC"          -- server -> client
local REPLY_TIMEOUT    = 6.0
local SEND_GAP         = 1.2            -- seconds between SCRALL sends

-- The six bulk types, in bar/binding order. `entry` is a FALLBACK for icons on
-- the four scrolls whose IDs are known from kirei's own bulk list; the live
-- entry is always re-read from bag links before any send.
local TYPES = {
    { title = "Wildcard Transmog Scroll", entry = nil    },
    { title = "Sealed Traveler's Map",    entry = nil    },
    { title = "Scroll of Mastery",        entry = 500205 },
    { title = "Scroll of the Delver",     entry = 500207 },
    { title = "Scroll of Reach",          entry = 500203 },
    { title = "Scroll of Bounty",         entry = 500204 },
}

-- Dungeon-exit auto-read: only these TYPES indices, only at AUTO_MIN+ held.
local AUTO_TYPES    = { 3, 4 }   -- Scroll of Mastery, Scroll of the Delver
local AUTO_MIN      = 300
local DUNGEON_DELAY = 5.0

local TITLES = {}
for i = 1, #TYPES do TITLES[TYPES[i].title] = i end

-- Key Bindings menu strings (resolved when the bindings UI opens).
BINDING_HEADER_SCROLLREADER = "ScrollReader"
for i = 1, #TYPES do
    _G["BINDING_NAME_SCROLLREADER_BULK" .. i] = "Read all: " .. TYPES[i].title
end

local DEFAULTS = {
    dungeon = true,
    minimap = { hide = false, x = -69, y = -40 },
    bar     = { hide = false, point = "CENTER", relPoint = "CENTER", x = 0, y = -240 },
}

local db
local inCombat = false
local minimapButton
local bar
local barButtons = {}

--------------------------------------------------------------------- helpers --

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ScrollReader|r " .. msg)
end

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

------------------------------------------------------------------- bag scan --

-- Returns recs[1..#TYPES] = { title, entry, count } in TYPES order (count may
-- be 0; entry is the live bag-link ID when held, else the known fallback), plus
-- the grand total held across all six.
local function ScanBags()
    local recs = {}
    for i = 1, #TYPES do
        recs[i] = { title = TYPES[i].title, entry = TYPES[i].entry, count = 0 }
    end
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local name = link:match("%[(.-)%]")
                local idx = name and TITLES[name]
                if idx then
                    local entry = tonumber(link:match("item:(%d+)"))
                    if entry then recs[idx].entry = entry end
                    local _, stackCount = GetContainerItemInfo(bag, slot)
                    recs[idx].count = recs[idx].count + (stackCount or 1)
                end
            end
        end
    end
    local total = 0
    for i = 1, #recs do total = total + recs[i].count end
    return recs, total
end

--------------------------------------------------------------- badges/icons --

local function UpdateBadges()
    local recs, total = ScanBags()
    local text = (total > 0) and tostring(total) or ""
    if minimapButton and minimapButton.badge then minimapButton.badge:SetText(text) end
    for i = 1, #barButtons do
        local b, rec = barButtons[i], recs[i]
        b.count = rec.count
        b.badge:SetText(rec.count > 0 and tostring(rec.count) or "")
        if rec.entry then
            local tex = GetItemIcon(rec.entry)
            if tex then b.icon:SetTexture(tex) end
        end
        -- Empty types read as inert; combat greys everything regardless.
        b.icon:SetDesaturated(inCombat or rec.count == 0)
        b:SetAlpha(inCombat and 0.5 or (rec.count == 0 and 0.7 or 1))
    end
    return recs, total
end

local function SetCombatState(flag)
    inCombat = flag
    local alpha = flag and 0.5 or 1
    if minimapButton then
        if minimapButton.icon then minimapButton.icon:SetDesaturated(flag) end
        minimapButton:SetAlpha(alpha)
    end
    UpdateBadges()
end

---------------------------------------------------------- send queue + wire --

local sendQueue = {}       -- FIFO of { entry, name }
local pendingReply = {}    -- entry -> { name = ..., elapsed = 0 } awaiting SCRDONE

-- [v1.2.1] Auto-chain: maps are consumed at most 500 per SCRALL call server-
-- side ([#1350]), so one confirmed "read all 1398" needs several calls. The
-- confirmation covered the full count, so the addon re-sends until the BAGS
-- are clean. Bag scan is the loop condition on purpose: SCRDONE's `held`
-- counts bank too, and chaining on it would spin forever against bank copies
-- SCRALL can't touch. used==0 also ends a chain (server refusal). Budget is a
-- belt-and-braces cap, not pacing.
local CHAIN_MAX = 40
local chainBudget = {}     -- entry -> sends remaining in this confirmation
local chainAgg = {}        -- entry -> { name, used, calls } for one summary line
local chainSpam = {}       -- entry -> true: auto-read chain, re-send even on used=0

local dungeonPending, dungeonWaited = false, 0
local AutoRead             -- forward decl, assigned below

local clock = CreateFrame("Frame")
clock.sinceSend = SEND_GAP -- first send fires immediately
clock:SetScript("OnUpdate", function(self, elapsed)
    if sendQueue[1] and not inCombat then   -- combat holds the queue, resumes after
        self.sinceSend = self.sinceSend + elapsed
        if self.sinceSend >= SEND_GAP then
            self.sinceSend = 0
            local job = table.remove(sendQueue, 1)
            pendingReply[job.entry] = { name = job.name, elapsed = 0 }
            SendAddonMessage(TRANSPORT_PREFIX, "SCRALL:" .. job.entry, "WHISPER", UnitName("player"))
        end
    else
        self.sinceSend = SEND_GAP
    end
    if dungeonPending then
        dungeonWaited = dungeonWaited + elapsed
        if dungeonWaited >= DUNGEON_DELAY then
            dungeonPending = false
            AutoRead()
        end
    end
    for entry, w in pairs(pendingReply) do
        w.elapsed = w.elapsed + elapsed
        if w.elapsed > REPLY_TIMEOUT then
            pendingReply[entry] = nil
            chainBudget[entry], chainAgg[entry], chainSpam[entry] = nil, nil, nil
            Print("no server reply for " .. w.name .. " (entry " .. entry .. ") — " ..
                  "SCRALL may not cover this scroll yet; ask kirei to whitelist entry " .. entry .. ".")
        end
    end
end)

local function QueueConsume(recs, spam)
    for i = 1, #recs do
        local rec = recs[i]
        -- Skip a type whose chain is already running (queued or awaiting reply).
        if rec.count > 0 and rec.entry and not chainBudget[rec.entry] then
            sendQueue[#sendQueue + 1] = { entry = rec.entry, name = rec.title }
            chainBudget[rec.entry] = CHAIN_MAX
            chainAgg[rec.entry] = { name = rec.title, used = 0, calls = 0 }
            chainSpam[rec.entry] = spam or nil
        end
    end
end

-- Dungeon-exit auto-read: Mastery/Delver at AUTO_MIN+, spam-pushed.
AutoRead = function()
    if not db.dungeon then return end
    local recs = ScanBags()
    local picks = {}
    for _, i in ipairs(AUTO_TYPES) do
        if recs[i].count >= AUTO_MIN then picks[#picks + 1] = recs[i] end
    end
    if #picks == 0 then return end
    Print("dungeon exit — auto-reading " .. #picks .. " scroll type(s) held " .. AUTO_MIN .. "+.")
    QueueConsume(picks, true)   -- combat holds the queue, resumes after
end

local wasInDungeon = false
local function InDungeon()
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "party"
end

---------------------------------------------------------------- confirm/use --


-- Master sweep: every held type at once, one dialog.
local function Sweep()
    if inCombat then
        Print("can't read scrolls while in combat.")
        return
    end
    local recs, total = ScanBags()
    if total == 0 then
        Print("no matching scrolls in bags.")
        return
    end
    QueueConsume(recs)
end

-- Single type, by bar/binding index. Global: Bindings.xml calls this.
function ScrollReader_BulkByIndex(index)
    local t = TYPES[index]
    if not t then return end
    if inCombat then
        Print("can't read scrolls while in combat.")
        return
    end
    local recs = ScanBags()
    local rec = recs[index]
    if rec.count == 0 then
        Print("no " .. rec.title .. " in bags.")
        return
    end
    QueueConsume({ rec })
end

-------------------------------------------------------------- minimap button --

local function CreateMinimapButton()
    local mm = CreateFrame("Button", "ScrollReaderMinimapButton", Minimap)
    mm:SetWidth(31)
    mm:SetHeight(31)
    mm:SetFrameStrata("MEDIUM")
    mm:SetFrameLevel(8)
    mm:RegisterForClicks("LeftButtonUp")
    mm:RegisterForDrag("LeftButton")

    -- Canonical LibDBIcon texture layout.
    local overlay = mm:CreateTexture(nil, "OVERLAY")
    overlay:SetWidth(53)
    overlay:SetHeight(53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local background = mm:CreateTexture(nil, "BACKGROUND")
    background:SetWidth(20)
    background:SetHeight(20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = mm:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(17)
    icon:SetHeight(17)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    mm.icon = icon

    local badge = mm:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    badge:SetPoint("BOTTOMRIGHT", mm, "BOTTOMRIGHT", -2, 3)
    mm.badge = badge

    local function Reposition()
        mm:ClearAllPoints()
        mm:SetPoint("CENTER", Minimap, "CENTER", db.minimap.x, db.minimap.y)
    end
    mm.Reposition = Reposition

    -- Free-form drag: exact x/y offsets from Minimap center, no ring snap.
    local function OnDragUpdate(self)
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        db.minimap.x = px - mx
        db.minimap.y = py - my
        Reposition()
    end

    mm:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    mm:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    mm:SetScript("OnClick", function(self)
        Sweep()
    end)
    mm:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ScrollReader")
        GameTooltip:AddLine("Click: read ALL scroll types at once", 1, 1, 1)
        GameTooltip:AddLine("Drag: move", 1, 1, 1)
        GameTooltip:Show()
    end)
    mm:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    Reposition()
    if db.minimap.hide then mm:Hide() end

    minimapButton = mm
end

-------------------------------------------------------------------- the bar --

local BTN_SIZE, BTN_GAP, BAR_PAD = 30, 4, 8

local function CreateBar()
    bar = CreateFrame("Frame", "ScrollReaderBar", UIParent)
    bar:SetWidth(BAR_PAD * 2 + BTN_SIZE * #TYPES + BTN_GAP * (#TYPES - 1))
    bar:SetHeight(BTN_SIZE + 12)
    bar:SetFrameStrata("MEDIUM")
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bar:SetBackdropColor(0, 0, 0, 0.6)

    local function Reposition()
        bar:ClearAllPoints()
        bar:SetPoint(db.bar.point, UIParent, db.bar.relPoint, db.bar.x, db.bar.y)
    end
    bar.Reposition = Reposition

    local function SavePosition()
        local point, _, relPoint, x, y = bar:GetPoint(1)
        db.bar.point    = point or "CENTER"
        db.bar.relPoint = relPoint or "CENTER"
        db.bar.x        = x or 0
        db.bar.y        = y or 0
        Reposition()
    end

    bar:SetScript("OnDragStart", function(self) self:StartMoving() end)
    bar:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition() end)

    for i = 1, #TYPES do
        local b = CreateFrame("Button", "ScrollReaderBarButton" .. i, bar)
        b:SetWidth(BTN_SIZE)
        b:SetHeight(BTN_SIZE)
        b:SetPoint("LEFT", bar, "LEFT", BAR_PAD + (i - 1) * (BTN_SIZE + BTN_GAP), 0)
        b:RegisterForClicks("LeftButtonUp")
        b:RegisterForDrag("LeftButton")
        b.index = i

        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture(ICON)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        b.icon = icon

        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        b:GetHighlightTexture():SetBlendMode("ADD")

        local badge = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        badge:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 2)
        b.badge = badge

        -- Dragging a button moves the whole bar (the bar edge is thin).
        b:SetScript("OnDragStart", function() bar:StartMoving() end)
        b:SetScript("OnDragStop", function() bar:StopMovingOrSizing(); SavePosition() end)

        b:SetScript("OnClick", function(self)
            ScrollReader_BulkByIndex(self.index)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(TYPES[self.index].title)
            GameTooltip:AddLine("Held: " .. (self.count or 0), 1, 1, 1)
            local key = GetBindingKey("SCROLLREADER_BULK" .. self.index)
            if key then
                GameTooltip:AddLine("Bound to: " .. key, 1, 1, 1)
            else
                GameTooltip:AddLine("Bind a key: ESC > Key Bindings > ScrollReader", 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("Click or keybind: read all of these", 1, 1, 1)
            GameTooltip:AddLine("Drag: move bar", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)

        barButtons[i] = b
    end

    Reposition()
    if db.bar.hide then bar:Hide() end
end

----------------------------------------------------------------------- slash --

local function ToggleFrame(which, frameRef)
    if not frameRef then return end
    db[which].hide = not db[which].hide
    if db[which].hide then frameRef:Hide() else frameRef:Show() end
end

local function ResetPositions()
    for _, which in ipairs({ "minimap", "bar" }) do
        db[which] = nil
    end
    CopyDefaults(DEFAULTS, db)
    if minimapButton then minimapButton.Reposition(); minimapButton:Show() end
    if bar then bar.Reposition(); bar:Show() end
end

local function PrintCounts()
    local recs, total = ScanBags()
    if total == 0 then
        Print("no matching scrolls in bags.")
        return
    end
    local parts = {}
    for i = 1, #recs do
        if recs[i].count > 0 then
            parts[#parts + 1] = recs[i].title .. " x" .. recs[i].count ..
                (recs[i].entry and (" (entry " .. recs[i].entry .. ")") or "")
        end
    end
    Print("holding " .. total .. " — " .. table.concat(parts, ", ") .. ".")
end

SLASH_SCROLLREADER1 = "/scrollread"
SLASH_SCROLLREADER2 = "/sr"
SlashCmdList["SCROLLREADER"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$"):lower()
    if msg == "" then
        Sweep()
    elseif msg == "count" then
        PrintCounts()
    elseif msg == "bar" then
        ToggleFrame("bar", bar)
    elseif msg == "minimap" then
        ToggleFrame("minimap", minimapButton)
    elseif msg == "dungeon" then
        db.dungeon = not db.dungeon
        Print("dungeon-exit auto-read (Mastery/Delver at " .. AUTO_MIN .. "+): " ..
              (db.dungeon and "on" or "off") .. ".")
    elseif msg == "reset" then
        ResetPositions()
    else
        Print("commands: /sr (read all), /sr count, /sr bar, /sr minimap, /sr dungeon, /sr reset")
    end
end

---------------------------------------------------------------------- events --

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(self, event, a1, a2)
    if event == "CHAT_MSG_ADDON" then
        if a1 ~= REPLY_PREFIX or not a2 then return end
        -- SCRDONE:<entry>:<used>:<held> — three fields, always.
        local entry, used, held = a2:match("^SCRDONE:(%d+):(%d+):(%d+)$")
        if not entry then return end
        entry = tonumber(entry)
        local w = pendingReply[entry]
        pendingReply[entry] = nil
        UpdateBadges()
        if not w then return end            -- not ours (e.g. a Dashboard bulk button)
        used, held = tonumber(used) or 0, tonumber(held) or 0
        local agg = chainAgg[entry]
        if agg then
            agg.used  = agg.used + used
            agg.calls = agg.calls + 1
        end
        -- Chain while the server is still spending (or this is an auto-read
        -- spam chain) AND our bags still hold the type (bag scan, not `held` —
        -- see the chain comment above).
        if (used > 0 or chainSpam[entry]) and (chainBudget[entry] or 0) > 0 then
            local recs = ScanBags()
            for i = 1, #recs do
                if recs[i].title == w.name and recs[i].count > 0 then
                    chainBudget[entry] = chainBudget[entry] - 1
                    sendQueue[#sendQueue + 1] = { entry = entry, name = w.name }
                    return   -- summary comes when the chain finishes
                end
            end
        end
        -- Chain finished (or was never needed).
        local totalUsed = agg and agg.used or used
        local calls     = agg and agg.calls or 1
        chainBudget[entry], chainAgg[entry], chainSpam[entry] = nil, nil, nil
        -- The Dashboard's UncappedScrolls prints its own "[Scrolls]" line for
        -- every SCRDONE it sees; when it's loaded, ours would be a duplicate.
        if _G.UncappedScrolls then return end
        if totalUsed > 0 then
            Print("read " .. totalUsed .. " " .. w.name ..
                  (calls > 1 and (" over " .. calls .. " calls") or "") .. "." ..
                  (held > 0 and (" " .. held .. " left.") or " None left."))
        elseif held > 0 then
            Print("none of your " .. held .. " " .. w.name .. " could be used.")
        else
            Print("nothing to read — no " .. w.name .. " left in your bags.")
        end
        return
    end

    if event == "BAG_UPDATE" then
        if minimapButton or bar then UpdateBadges() end
        return
    end

    if event == "ADDON_LOADED" and a1 == ADDON_NAME then
        ScrollReaderDB = ScrollReaderDB or {}
        db = ScrollReaderDB
        CopyDefaults(DEFAULTS, db)
        db.button = nil   -- v1.2.2: on-screen master button removed
        CreateMinimapButton()
        CreateBar()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        Print("v" .. VERSION .. " loaded — /sr to read scrolls, bar keybinds in ESC > Key Bindings.")
        UpdateBadges()
        if UnitAffectingCombat("player") then
            SetCombatState(true)
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local nowIn = InDungeon()
        if wasInDungeon and not nowIn and db and db.dungeon then
            dungeonPending, dungeonWaited = true, 0
        end
        wasInDungeon = nowIn
    elseif event == "PLAYER_REGEN_DISABLED" then
        SetCombatState(true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        SetCombatState(false)
    end
end)
