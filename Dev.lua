local _, ns = ...
-- The developer's copy only: the tocs load this file inside a debug block the release packager comments out, and the
-- package leaves it out. It keeps a far bigger save and adds the Settings button that pulls every find a server holds.
ns.DEV = true
ns.MAX_FINDS = 100000

-- Channel traffic: every sharing message in and out, and what this copy did with each find it heard
local Dev = {}
ns.Dev = Dev
local LOG_MAX = 300

local function Item(id)
    local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)
    if type(name) ~= "string" or ns.Secret(name) then return tostring(id) end
    return id .. " " .. name
end

local function When(t)
    if not t or t == 0 then return "the start" end
    return date("%b %d %H:%M", t)
end

local function Describe(msg)
    local P = ns.Proto
    local k = P.Kind(msg)
    if k == "F" then
        local info = P.DecodeFind(msg)
        if info then return "find " .. Item(info.id) .. (info.by and (" by " .. info.by) or "") end
    elseif k == "H" then
        local count, _, since, after = P.DecodeHello(msg)
        if count then
            return "hello: holds " .. count .. " finds, asks for finds since " .. When(since) ..
                ((after or 0) > 0 and (" after item " .. after) or "")
        end
    elseif k == "Y" then
        local target, count = P.DecodeServing(msg)
        if target then return "serving " .. target .. " (" .. count .. " finds)" end
    elseif k == "E" then
        local n, last = P.DecodeEnd(msg)
        if n then return "page end: " .. n .. " finds, last item " .. last end
    end
    if P.OtherVersion(msg) then return "a message from another version of the addon" end
    return "unreadable message"
end

local function Log(text)
    if not ns.db then return end
    local r = ns.db.traffic or {}
    ns.db.traffic = r
    r[#r + 1] = { t = ns.Now(), text = text }
    while #r > LOG_MAX do table.remove(r, 1) end
    ns.Signal("TrafficChanged")
end
Dev.Log = Log

local function InUse()
    local S = ns.Sync
    for i = 1, 9 do
        local name = i == 1 and S.CHANNEL or (S.CHANNEL .. i)
        local id = GetChannelName(name)
        if type(id) == "number" and id > 0 then return name, id end
    end
end

local function Channel()
    local name, id = InUse()
    if name then return name .. " (channel " .. id .. ")" end
    return "not in a sharing channel"
end

-- this session's counts, kept by the wrapped engine calls below
Dev.stats = { sent = 0, taken = 0, refused = 0 }

-- the engine's own calls are wrapped, so the log shows what the engine really sent and decided
local function Install()
    local engine = ns.Sync.Engine and ns.Sync.Engine()
    if not engine or engine.devTraffic then return end
    engine.devTraffic = true
    local env, P = engine.env, ns.Proto
    local send = env.send
    env.send = function(dist, target, msg)
        local r = send(dist, target, msg)
        if dist == "CHANNEL" and r == "ok" and P.Kind(msg) == "F" then Dev.stats.sent = Dev.stats.sent + 1 end
        local route = dist == "WHISPER" and ("WHISPER to " .. tostring(target)) or dist
        Log("out " .. route .. "  " .. Describe(msg) .. (r ~= "ok" and ("  [" .. tostring(r) .. "]") or ""))
        return r
    end
    local status
    local recorded = env.onRecorded
    env.onRecorded = function(rec, st, info)
        status = st
        if recorded then return recorded(rec, st, info) end
    end
    local asked
    local accept = env.accept
    env.accept = function(info, sender, done)
        asked = true
        local id = info.id
        return accept(info, sender, function(ok)
            if not ok then
                Dev.stats.refused = Dev.stats.refused + 1
                Log("    " .. Item(id) .. ": refused (this copy's data calls it an old item, or the game does not know it)")
                return done(ok)
            end
            status = nil
            done(ok)
            if status then Dev.stats.taken = Dev.stats.taken + 1 end
            Log("    " .. Item(id) .. ": taken" .. (status and (" (" .. tostring(status) .. ")") or " (nothing new: already held)"))
        end)
    end
    local receive = engine.Receive
    engine.Receive = function(self, msg, dist, sender)
        local own = sender == env.me or (env.isMe ~= nil and env.isMe(sender))
        local muted = self.muted[sender]
        Log("in  " .. dist .. " from " .. (own and "you (your own message coming back)" or tostring(sender)) .. "  " .. Describe(msg))
        asked = false
        receive(self, msg, dist, sender)
        if own or P.Kind(msg) ~= "F" or asked then return end
        local why
        if muted then
            why = "the sender is muted for this session"
        elseif env.banned and env.banned(sender) then
            why = "the sender is on the ban list"
        elseif not P.DecodeFind(msg) then
            why = "unreadable"
        elseif self.muted[sender] then
            why = "the sender just got muted for flooding"
        else
            why = "the same report already came by another route"
        end
        Log("    not taken: " .. why)
    end
    Log("logging started; " .. Channel())
end
ns.Listen("Login", Install)
ns.Listen("SyncState", function()
    Install()
    Log("sharing " .. tostring(ns.Sync.state) .. "; " .. Channel())
end)

-- the copies that spoke this session, newest word first
local function Heard()
    local engine = ns.Sync.Engine and ns.Sync.Engine()
    local list = {}
    for name, b in pairs(engine and engine.senders or {}) do list[#list + 1] = { name = name, t = b.start } end
    table.sort(list, function(a, b) return a.t > b.t end)
    local names = {}
    for i, e in ipairs(list) do names[i] = e.name end
    return #names > 0 and table.concat(names, ", ") or "none yet"
end

-- the channel's members and owner as the game's member list has them; the list fills once the client has asked for
-- it (opening the Chat Channels window does)
local function Members(channel)
    if not (channel and GetNumDisplayChannels and GetChannelDisplayInfo and C_ChatInfo.GetChannelRosterInfo) then return end
    for i = 1, GetNumDisplayChannels() or 0 do
        local name, header, _, _, count = GetChannelDisplayInfo(i)
        if not header and type(name) == "string" and not ns.Secret(name) and name:lower() == channel:lower() then
            if type(count) ~= "number" or ns.Secret(count) or count == 0 then return end
            local owner
            for r = 1, count do
                local n, isOwner = C_ChatInfo.GetChannelRosterInfo(i, r)
                if type(n) == "string" and not ns.Secret(n) and not ns.Secret(isOwner) and isOwner then owner = n end
            end
            return count, owner
        end
    end
end

-- where this copy stands: the channel, who holds it, what went out and came in, what still waits
function Dev.StatusLines()
    local engine = ns.Sync.Engine and ns.Sync.Engine()
    local channel = InUse()
    local count, owner = Members(channel)
    local own = channel and IsChannelOwner and IsChannelOwner(channel)
    local mine = own ~= nil and not ns.Secret(own) and own == true
    local waiting = 0
    for _, e in pairs(ns.db and ns.db.finds or {}) do
        if e.uh then waiting = waiting + 1 end
    end
    local catch = "not asked yet"
    if engine and engine.caughtUp then
        catch = "caught up"
    elseif engine and engine.round and engine.round.best then
        catch = "being sent finds by " .. engine.round.best
    elseif engine and engine.helloSent then
        catch = "asked, no answer yet"
    end
    local s = Dev.stats
    return {
        "Channel: " .. Channel() .. (count and (", " .. count .. " members") or ", member list not loaded (open Chat Channels once)"),
        "Owner: " .. (mine and "you" or owner or "unknown until the member list loads"),
        "Other copies heard this session: " .. Heard(),
        "This session: " .. s.sent .. " finds sent, " .. s.taken .. " taken from others, " .. s.refused .. " refused",
        "Your finds still to send: " .. waiting .. " (they go out while another copy is online)",
        "Catch-up: " .. catch,
        "Pop-ups waiting their turn: " .. #(ns.db and ns.db.later or {}),
    }
end

function Dev.TrafficText()
    local lines = Dev.StatusLines()
    lines[#lines + 1] = ""
    local r = ns.db and ns.db.traffic or {}
    if #r == 0 then lines[#lines + 1] = "No messages yet." end
    for i = #r, 1, -1 do lines[#lines + 1] = date("%H:%M:%S", r[i].t) .. "  " .. r[i].text end
    return table.concat(lines, "\n")
end

local box
local function Fill()
    if not box or not box:IsShown() or box.box:HasFocus() then return end
    box.box.keep = Dev.TrafficText()
    box.box:SetText(box.box.keep)
end

function Dev.ShowTraffic()
    if not box then
        local T = ns.Theme
        local C, U = T.C, T.U
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetSize(U(640), U(420))
        f:SetPoint("CENTER", 0, U(40))
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        T.Panel(f, C.bg, C.gold)
        local title = T.Text(f, 15, C.title)
        title:SetPoint("TOPLEFT", U(12), -U(10))
        title:SetText("Channel traffic")
        local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        x:SetPoint("TOPRIGHT", 2, 2)
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", U(12), -U(40))
        scroll:SetPoint("BOTTOMRIGHT", -U(32), U(48))
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFont(T.FONT, U(12), "")
        edit:SetTextColor(T.RGB(C.ink))
        edit:SetWidth(U(590))
        scroll:SetScrollChild(edit)
        edit:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
            f:Hide()
        end)
        edit:SetScript("OnTextChanged", function(self, user)
            if user and self.keep then
                self:SetText(self.keep)
                self:HighlightText()
            end
        end)
        -- new lines wait while the text is picked for copying
        edit:SetScript("OnEditFocusLost", Fill)
        local all = T.Button(f, "Select all", nil, U(26))
        all:SetPoint("BOTTOMLEFT", U(12), U(12))
        all:SetScript("OnClick", function()
            edit:SetFocus()
            edit:HighlightText()
        end)
        local clear = T.Button(f, "Clear", nil, U(26))
        clear:SetPoint("LEFT", all, "RIGHT", U(8), 0)
        clear:SetScript("OnClick", function()
            ns.db.traffic = {}
            edit:ClearFocus()
            Fill()
        end)
        f.box, f.all, f.clear = edit, all, clear
        box = f
        ns.Listen("TrafficChanged", Fill)
        Dev.trafficBox = f
    end
    box:Show()
    Fill()
end
