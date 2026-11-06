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
    elseif k == "Q" then
        local token = P.DecodePing(msg)
        if token then return "ping " .. token end
    elseif k == "A" then
        local token, heard, host, version = P.DecodeAnswer(msg)
        if token then return "answer to ping " .. token .. ": " .. host .. " " .. version .. ", heard it by " .. Dev.HowWord(heard) end
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
-- the other copies heard this session, by sender: when last heard and what they sent
Dev.seen = {}
local KIND_WORD = { F = "a find", H = "a hello", Y = "a serving claim", E = "a page end", Q = "a ping", A = "a ping answer" }

local HOW = { m = "addon message", l = "chat line", ml = "addon message and chat line" }
function Dev.HowWord(heard)
    return HOW[heard] or "?"
end

-- the last ping this copy sent, and its answers by sender: addon, version, how the ping reached them, and the routes
-- each answer came by
Dev.ping = nil
function Dev.SendPing()
    local token = math.random(1, 2000000000)
    if not ns.Sync.Ping(token) then return false end
    Dev.ping = { token = token, t = ns.Now(), answers = {} }
    return true
end

local function OnAnswer(sender, token, heard, host, version, dist, via)
    local ping = Dev.ping
    if not ping or token ~= ping.token or type(sender) ~= "string" then return end
    local a = ping.answers[sender] or { routes = {} }
    ping.answers[sender] = a
    a.t, a.heard, a.host, a.version = ns.Now(), heard, host, version
    a.routes[via == "line" and (dist .. " line") or dist] = true
    ns.Signal("TrafficChanged")
end

-- the engine's own calls are wrapped, so the log shows what the engine really sent and decided
local function Install()
    local engine = ns.Sync.Engine and ns.Sync.Engine()
    if not engine or engine.devTraffic then return end
    engine.devTraffic = true
    ns.Sync.OnAnswer = OnAnswer
    ns.Sync.OnNotice = function(kind, name) Log("channel notice " .. kind .. " on " .. name) end
    ns.Sync.OnBounce = function(name) Log("whisper to " .. name .. " bounced (not online), nothing more sent to them this session") end
    ns.Sync.OnDrop = function(msg, gaveUp, gap)
        Log("chat line dropped by the server, " .. (gaveUp and "given up" or ("sent again in " .. math.floor(gap) .. " s")) ..
            "  " .. Describe(msg))
    end
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
    engine.Receive = function(self, msg, dist, sender, via)
        local own = sender == env.me or (env.isMe ~= nil and env.isMe(sender))
        local muted = self.muted[sender]
        if sender and not own then Dev.seen[sender] = { t = ns.Now(), what = KIND_WORD[P.Kind(msg)] or "a message" } end
        local route = via == "line" and (dist .. " line") or dist
        Log("in  " .. route .. " from " .. (own and "you (your own message coming back)" or tostring(sender)) .. "  " .. Describe(msg))
        asked = false
        receive(self, msg, dist, sender, via)
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

local function Heard()
    local n = 0
    for _ in pairs(Dev.seen) do n = n + 1 end
    return n > 0 and tostring(n) or "none yet"
end

-- the channel's place in the Chat Channels list and its member count (nil until the client has the count)
local function Display(channel)
    if not (channel and GetNumDisplayChannels and GetChannelDisplayInfo) then return end
    for i = 1, GetNumDisplayChannels() or 0 do
        local name, header, _, _, count = GetChannelDisplayInfo(i)
        if not header and type(name) == "string" and not ns.Secret(name) and name:lower() == channel:lower() then
            if type(count) ~= "number" or ns.Secret(count) or count == 0 then count = nil end
            return i, count
        end
    end
end

-- the channel's members as the game's member list has them: the count, then { name, owner, mod } per member whose
-- name has arrived. The names fill once the client has asked for them (picking the channel in Chat Channels, or
-- Load members)
local function Roster(channel)
    local i, count = Display(channel)
    if not count then return end
    local list = {}
    for r = 1, C_ChatInfo.GetChannelRosterInfo and count or 0 do
        local n, isOwner, isMod = C_ChatInfo.GetChannelRosterInfo(i, r)
        if type(n) == "string" and not ns.Secret(n) then
            list[#list + 1] = { name = n, owner = not ns.Secret(isOwner) and isOwner == true, mod = not ns.Secret(isMod) and isMod == true }
        end
    end
    return count, list
end

local function Members(channel)
    local count, list = Roster(channel)
    if not count then return end
    local owner
    for _, m in ipairs(list) do if m.owner then owner = m.name end end
    return count, owner
end

-- a sender's name without the realm the game adds now and then
local function Base(name)
    return name:match("^[^%-]+") or name
end

local function HeardText(s)
    return "heard " .. date("%H:%M:%S", s.t) .. " (" .. s.what .. ")"
end

local function AnswerText(a)
    local routes = {}
    for r in pairs(a.routes) do routes[#routes + 1] = r end
    table.sort(routes)
    return "runs " .. a.host .. " " .. a.version .. ", got your ping as " .. Dev.HowWord(a.heard) .. ", answered by " ..
        table.concat(routes, " and ")
end

-- the last ping in one line: how many answered, and how it reached them
local function PingLine()
    local ping = Dev.ping
    if not ping then return "Ping: not sent yet (press Ping everyone)" end
    local n, m, l = 0, 0, 0
    for _, a in pairs(ping.answers) do
        n = n + 1
        if a.heard:find("m", 1, true) then m = m + 1 end
        if a.heard:find("l", 1, true) then l = l + 1 end
    end
    return "Ping: sent " .. date("%H:%M:%S", ping.t) .. ", " .. n .. " answered (" .. m .. " got it as an addon message, " ..
        l .. " as a chat line)"
end

-- everyone in the channel, and which of them this copy heard. Copies before the sharing fix send nothing at all, so a
-- member heard from runs a sharing version; silence is an older copy, or a newer one with nothing to say yet
function Dev.MemberLines()
    local engine = ns.Sync.Engine and ns.Sync.Engine()
    local env = engine and engine.env
    local function IsMe(n) return env ~= nil and (n == env.me or (env.isMe ~= nil and env.isMe(n))) end
    local heard = {}
    for sender, s in pairs(Dev.seen) do
        local b = Base(sender)
        if not heard[b] or heard[b].t < s.t then heard[b] = { t = s.t, what = s.what, sender = sender } end
    end
    local answered = {}
    for sender, a in pairs(Dev.ping and Dev.ping.answers or {}) do answered[Base(sender)] = a end
    local count, list = Roster(InUse())
    local lines = {}
    if not list or #list == 0 then
        lines[1] = "Members: " .. (count and (count .. " in the channel, names not loaded") or "not loaded") .. " (press Load members)"
    else
        local you, spoke, quiet = {}, {}, {}
        for _, m in ipairs(list) do
            local h = heard[Base(m.name)]
            if h then h.matched = true end
            local roles = {}
            if IsMe(m.name) then roles[#roles + 1] = "you" end
            if m.owner then roles[#roles + 1] = "owner" elseif m.mod then roles[#roles + 1] = "moderator" end
            local row = { name = m.name, t = h and h.t or 0, roles = table.concat(roles, ", "), h = h, a = answered[Base(m.name)] }
            if IsMe(m.name) then you[#you + 1] = row elseif h then spoke[#spoke + 1] = row else quiet[#quiet + 1] = row end
        end
        table.sort(spoke, function(a, b) return a.t > b.t end)
        table.sort(quiet, function(a, b) return a.name < b.name end)
        lines[1] = "Members: " .. count .. " in the channel, " .. #spoke .. " heard from this session, " .. #quiet .. " not heard yet"
        for _, group in ipairs({ you, spoke, quiet }) do
            for _, row in ipairs(group) do
                local said = row.h and HeardText(row.h) or (not IsMe(row.name) and "not heard yet") or nil
                local parts = {}
                if row.roles ~= "" then parts[#parts + 1] = row.roles end
                if said then parts[#parts + 1] = said end
                if row.a then parts[#parts + 1] = AnswerText(row.a) end
                lines[#lines + 1] = "  " .. row.name .. ": " .. table.concat(parts, ", ")
            end
        end
    end
    -- heard on the guild or the group, or before the names loaded
    local other = {}
    for _, h in pairs(heard) do
        if not h.matched then other[#other + 1] = h end
    end
    table.sort(other, function(a, b) return a.t > b.t end)
    if #other > 0 then
        lines[#lines + 1] = (list and #list > 0) and "Heard, not in the member list:" or "Heard this session:"
        for _, h in ipairs(other) do
            local a = answered[Base(h.sender)]
            lines[#lines + 1] = "  " .. h.sender .. ": " .. HeardText(h) .. (a and (", " .. AnswerText(a)) or "")
        end
    end
    return lines
end

-- asks the client for the channel's member names, as picking it in Chat Channels does
function Dev.LoadMembers()
    local i = Display(InUse())
    if i and SetSelectedDisplayChannel then SetSelectedDisplayChannel(i) end
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
    local L = ns.Sync.lines
    local chat = L.off and "stopped (the game refused one)" or
        (L.sent .. " sent, " .. L.back .. " came back, " .. L.dropped .. " dropped by the server and sent again" ..
        (L.lost > 0 and (", " .. L.lost .. " given up") or "") .. ", " .. L.heard .. " heard from others, " ..
        ns.Sync.LinesWaiting() .. " waiting for a key press or click" ..
        (L.gap > 2 and (", slowed to one every " .. math.floor(L.gap) .. " s") or ""))
    return {
        "Channel: " .. Channel() .. (count and (", " .. count .. " members") or ", member list not loaded (open Chat Channels once)"),
        "Owner: " .. (mine and "you" or owner or "unknown until the member list loads"),
        "Other copies heard this session: " .. Heard(),
        "This session: " .. s.sent .. " finds sent, " .. s.taken .. " taken from others, " .. s.refused .. " refused",
        "Chat lines: " .. chat,
        PingLine(),
        "Your finds still to send: " .. waiting .. " (they go out while another copy is online)",
        "Catch-up: " .. catch,
        "Pop-ups waiting their turn: " .. #(ns.db and ns.db.later or {}),
    }
end

function Dev.TrafficText()
    local lines = Dev.StatusLines()
    lines[#lines + 1] = ""
    for _, line in ipairs(Dev.MemberLines()) do lines[#lines + 1] = line end
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
        local load = T.Button(f, "Load members", nil, U(26))
        load:SetPoint("LEFT", clear, "RIGHT", U(8), 0)
        load:SetScript("OnClick", function()
            Dev.LoadMembers()
            Fill()
        end)
        local ping = T.Button(f, "Ping everyone", nil, U(26))
        ping:SetPoint("LEFT", load, "RIGHT", U(8), 0)
        ping:SetScript("OnClick", function()
            Dev.SendPing()
            Fill()
        end)
        f.box, f.all, f.clear, f.load, f.ping = edit, all, clear, load, ping
        box = f
        ns.Listen("TrafficChanged", Fill)
        local roster = CreateFrame("Frame")
        roster:RegisterEvent("CHANNEL_ROSTER_UPDATE")
        roster:SetScript("OnEvent", Fill)
        Dev.trafficBox = f
    end
    box:Show()
    Dev.LoadMembers()
    Fill()
end
