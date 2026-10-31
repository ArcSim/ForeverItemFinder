local _, ns = ...

local P = ns.Proto

-- the engine: no WoW calls, everything through env, so tests can run many copies
-- env: now(), random(lo, hi), after(seconds, fn), send(dist, target, msg) -> "ok" / "wait" / "fail",
--      canSend(), me, finds (Finds API), accept(info, sender, done(ok)), onRecorded(e, status, info),
--      stamp() (the clock finds are stamped with), bookmark() / setBookmark(t) (how far this server is caught up)
local Engine = {}
Engine.__index = Engine
ns.SyncEngine = Engine

local CHANNEL_GAP = 2.0       -- seconds between channel messages from one copy
local WHISPER_GAP = 0.3
local SERVE_LIMIT = 100       -- finds one catch-up page carries
local WHISPER_ROOM = SERVE_LIMIT * 2
local PAGE_GAP = 3            -- seconds before asking for the next page
local PAGE_WAIT = 40          -- seconds a next-page ask waits for an answer before the run counts as done
local OVERLAP = 3600          -- a catch-up reaches an hour back from the bookmark, for finds recorded around it
local SENDER_WINDOW = 300
local SENDER_MAX = 40         -- finds one sender may announce per window before being muted
local BAD_MAX = 5             -- broken messages before a sender is muted

function Engine.New(env)
    local e = setmetatable({ env = env, chanQ = {}, whisQ = {}, pumping = false, nextChan = 0, nextWhis = 0,
        senders = {}, muted = {}, serving = {}, announced = {}, helloSent = false, lastHeard = nil, helped = {},
        round = { claims = {}, bestCount = -1 }, pageAfter = 0 }, Engine)
    return e
end

function Engine:Mute(sender)
    self.muted[sender] = true
end

function Engine:IsMuted(sender)
    return self.muted[sender] == true
end

local function Bucket(self, sender)
    local now = self.env.now()
    local b = self.senders[sender]
    if not b or now - b.start > SENDER_WINDOW then
        b = { start = now, finds = 0, bad = 0 }
        self.senders[sender] = b
    end
    return b
end

function Engine:Pump()
    if self.pumping then return end
    local env = self.env
    local function Step()
        self.pumping = false
        if #self.chanQ == 0 and #self.whisQ == 0 then return end
        if not env.canSend() then
            self.pumping = true
            env.after(5, Step)
            return
        end
        local now = env.now()
        local wait = 60
        if #self.whisQ > 0 then
            if now >= self.nextWhis then
                local m = self.whisQ[1]
                local r = env.send("WHISPER", m.to, m.msg)
                if r == "ok" or r == "fail" then table.remove(self.whisQ, 1) end
                self.nextWhis = now + (r == "wait" and 2 or WHISPER_GAP)
            end
            wait = math.min(wait, math.max(0.05, self.nextWhis - now))
        end
        if #self.chanQ > 0 then
            if now >= self.nextChan then
                local r = env.send("CHANNEL", nil, self.chanQ[1])
                if r == "ok" or r == "fail" then table.remove(self.chanQ, 1) end
                self.nextChan = now + (r == "wait" and 5 or CHANNEL_GAP)
            end
            wait = math.min(wait, math.max(0.05, self.nextChan - now))
        end
        if #self.chanQ > 0 or #self.whisQ > 0 then
            self.pumping = true
            env.after(wait, Step)
        end
    end
    self.pumping = true
    env.after(0, Step)
end

function Engine:QueueChannel(msg)
    -- one copy never floods the channel: old queued lines give way
    if #self.chanQ >= 30 then table.remove(self.chanQ, 1) end
    table.insert(self.chanQ, msg)
    self:Pump()
end

function Engine:QueueWhisper(to, msg)
    if #self.whisQ >= WHISPER_ROOM then return end
    table.insert(self.whisQ, { to = to, msg = msg })
    self:Pump()
end

-- this copy saw something worth telling: once per item per session
function Engine:Announce(rec)
    if self.announced[rec.id] then return end
    self.announced[rec.id] = true
    self:QueueChannel(P.EncodeFind(rec))
end

-- asks this server's copies for the finds changed since its bookmark (a day's overlap), one page at a time
function Engine:SayHello()
    if self.helloSent then return end
    self.helloSent = true
    local env = self.env
    self.lastHello = env.now()
    -- a run of pages starts here: its time becomes the bookmark once the last page is in
    if self.pageAfter == 0 then self.runStamp = env.stamp and env.stamp() or 0 end
    local since = 0
    if not self.everything then
        local mark = env.bookmark and env.bookmark()
        since = mark and math.max(0, mark - OVERLAP) or 0
    end
    local count, sum = env.finds.Summary()
    -- each ask elects its own server: claims for an earlier ask no longer steer the pages
    self.round = { claims = {}, bestCount = -1 }
    self:QueueChannel(P.EncodeHello(count, sum, since, self.pageAfter))
    -- an ask for a next page nobody answers means the last page was the end
    if self.pageAfter > 0 then
        local token = {}
        self.waiting = token
        env.after(PAGE_WAIT, function()
            if self.waiting == token then self:RunDone() end
        end)
    end
end

-- the last page is in: this server is caught up to when the run began
function Engine:RunDone()
    self.pageAfter, self.everything, self.waiting = 0, nil, nil
    if self.env.setBookmark then self.env.setBookmark(self.runStamp or 0) end
end

-- the developer's button: every find this server's copies hold, from the start, whatever the bookmark says
function Engine:CollectAll()
    self.everything, self.pageAfter, self.waiting = true, 0, nil
    self.helloSent = false
    self:SayHello()
end

-- a player's Refresh: hello again, so copies holding finds this one lacks send them; at most once a minute
function Engine:AskAgain()
    if self.lastHello and self.env.now() - self.lastHello < 60 then return false end
    self.helloSent = false
    self:SayHello()
    return true
end

function Engine:OnLogin()
    local env = self.env
    env.after(env.random(15, 60), function() self:SayHello() end)
end

function Engine:Serve(requester, since, after, holding)
    local env = self.env
    self.serving[requester] = nil
    local page = env.finds.Since(since, after, SERVE_LIMIT)
    -- a copy too busy to whisper the whole page leaves the asker to another copy, so no page arrives in part
    if #page == 0 or #self.whisQ + #page + 1 > WHISPER_ROOM then return end
    -- "I have it" goes out at once, ahead of anything queued, so the other copies stand down in time
    local claim = P.EncodeServing(requester, holding)
    if not env.canSend() or env.send("CHANNEL", nil, claim) ~= "ok" then
        table.insert(self.chanQ, 1, claim)
        self:Pump()
    end
    for _, rec in ipairs(page) do self:QueueWhisper(requester, P.EncodeFind(rec)) end
    self:QueueWhisper(requester, P.EncodeEnd(#page, page[#page].id))
end

function Engine:Receive(msg, dist, sender)
    local env = self.env
    if not sender or sender == env.me or self.muted[sender] then return end
    local kind = P.Kind(msg)
    local b = Bucket(self, sender)
    if kind == "F" then
        local info = P.DecodeFind(msg)
        if not info then
            b.bad = b.bad + 1
            if b.bad >= BAD_MAX then self:Mute(sender) end
            return
        end
        -- pages from a copy that served this one lately are expected; only live announcements count against a sender
        local served = self.helped[sender]
        if not (dist == "WHISPER" and served and env.now() - served < SENDER_WINDOW) then
            b.finds = b.finds + 1
            if b.finds > SENDER_MAX then self:Mute(sender) return end
        end
        self.lastHeard = env.now()
        -- a find heard on the channel is a first-hand report; a whispered one is a catch-up copy
        local firstHand = dist == "CHANNEL"
        env.accept(info, sender, function(ok)
            if not ok then return end
            info.fromNet = true
            info.reporter = firstHand and sender or nil
            -- a catch-up copy is old news: it fills the feed and the database but never pops up
            info.quiet = not firstHand or nil
            local status, rec = env.finds.Record(info)
            if status and env.onRecorded then env.onRecorded(rec, status, info) end
        end)
    elseif kind == "H" then
        local count, sum, since, after = P.DecodeHello(msg)
        if not count then b.bad = b.bad + 1 return end
        local myCount, mySum = env.finds.Summary()
        if myCount == count and mySum == sum then return end
        local holding = env.finds.CountSince(since, after)
        if holding == 0 or self.serving[sender] then return end
        -- many copies hear the same hello: each waits a random moment and stands down when a copy holding about as much
        -- answers first, so a much bigger holder still answers after a small one (the asker follows the biggest); the
        -- more copies around, the longer the spread, so two equal holders rarely answer at once
        local peers = 0
        for _ in pairs(self.senders) do peers = peers + 1 end
        local spread = math.min(20, 4 + math.floor(peers / 4))
        local token = {}
        self.serving[sender] = { token = token, holding = holding }
        env.after(1 + env.random(0, spread * 1000) / 1000, function()
            local mine = self.serving[sender]
            if not mine or mine.token ~= token then return end
            self:Serve(sender, since, after, holding)
        end)
    elseif kind == "Y" then
        local target, count = P.DecodeServing(msg)
        if not target then b.bad = b.bad + 1 return end
        local mine = self.serving[target]
        -- a claim near this copy's own holding settles it; a much smaller one does not
        if mine and count >= mine.holding - math.max(5, math.floor(mine.holding / 10)) then self.serving[target] = nil end
        if target == env.me then
            self.lastHeard = env.now()
            self.helped[sender] = env.now()
            self.waiting = nil
            local round = self.round
            round.claims[sender] = true
            if count > round.bestCount then round.best, round.bestCount = sender, count end
        end
    elseif kind == "E" then
        local n, last = P.DecodeEnd(msg)
        if not n or dist ~= "WHISPER" then b.bad = b.bad + 1 return end
        -- only the biggest holder that claimed this ask steers the pages; late or smaller pages only add finds
        local round = self.round
        if not round.claims[sender] then return end
        round.claims[sender] = nil
        if round.best ~= sender then return end
        if n >= SERVE_LIMIT then
            -- a full page: the next one starts after its last item
            self.pageAfter = last
            env.after(PAGE_GAP, function()
                self.helloSent = false
                self:SayHello()
            end)
        else
            self:RunDone()
        end
    else
        b.bad = b.bad + 1
        if b.bad >= BAD_MAX then self:Mute(sender) end
    end
end

-- the WoW side: channel, prefix, lockdown, events
local S = {}
ns.Sync = S

local CHANNEL = "ForeverItemFinder"
local PASSWORD = "fif1"
S.CHANNEL = CHANNEL

local engine
local joinTries = 0
S.state = "starting"     -- starting / on / nochannel / paused

local function Me()
    local name = UnitName("player")
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" and not ns.Secret(realm) then return name .. "-" .. realm end
    return name
end

local function ChannelNumber()
    local id = GetChannelName(CHANNEL)
    if type(id) == "number" and id > 0 then return id end
end

local function HideChannel()
    for i = 1, tonumber(NUM_CHAT_WINDOWS) or 10 do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if frame.RemoveChannel then
                frame:RemoveChannel(CHANNEL)
            elseif ChatFrame_RemoveChannel then
                ChatFrame_RemoveChannel(frame, CHANNEL)
            end
        end
    end
end

-- nothing of the channel ever reaches a chat window, whatever someone types into it
local function Filter(_, _, _, _, _, _, _, _, _, _, channelName)
    if type(channelName) == "string" and not ns.Secret(channelName) and channelName:find(CHANNEL, 1, true) then
        return true
    end
end
local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
if addFilter then
    addFilter("CHAT_MSG_CHANNEL", Filter)
    addFilter("CHAT_MSG_CHANNEL_NOTICE", Filter)
    addFilter("CHAT_MSG_CHANNEL_NOTICE_USER", Filter)
    addFilter("CHAT_MSG_CHANNEL_JOIN", Filter)
    addFilter("CHAT_MSG_CHANNEL_LEAVE", Filter)
end

local function Join()
    if ChannelNumber() then
        HideChannel()
        S.state = "on"
        ns.Signal("SyncState")
        return true
    end
    joinTries = joinTries + 1
    local join = JoinTemporaryChannel or JoinChannelByName
    if join then join(CHANNEL, PASSWORD) end
    C_Timer.After(2, function()
        if ChannelNumber() then
            HideChannel()
            S.state = "on"
        elseif joinTries < 3 then
            C_Timer.After(30, Join)
        else
            S.state = "nochannel"
        end
        ns.Signal("SyncState")
    end)
end

local function CanSend()
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return false end
    if C_ChatInfo.AreOutgoingAddonChatMessagesRestricted and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted() then return false end
    return true
end

local RESULT = Enum and Enum.SendAddonMessageResult
local function Send(dist, target, msg)
    if dist == "CHANNEL" then
        local num = ChannelNumber()
        if not num then return "fail" end
        target = tostring(num)
    end
    local r = C_ChatInfo.SendAddonMessage(P.PREFIX, msg, dist, target)
    if r == nil or r == true or r == 0 or (RESULT and r == RESULT.Success) then return "ok" end
    if RESULT and (r == RESULT.AddonMessageThrottle or r == RESULT.ChannelThrottle or r == RESULT.AddOnMessageLockdown) then
        return "wait"
    end
    if r == 3 or r == 8 or r == 11 then return "wait" end
    return "fail"
end

-- a network find is accepted only if this copy's own data agrees it is new or changed,
-- and the game itself knows the item (its details always come from the game, never the message)
local function Accept(info, _, done)
    if ns.Detect.Judge(info.id, info) == false then return done(false) end
    -- the numbers that matter come from the game, never the message: wait for the item, then take them
    ns.Detect.WhenLoaded(info.id, function(ok)
        if not ok then return done(false) end
        local _, _, q, ilvl, req, _, _, _, _, _, _, cls, sub = C_Item.GetItemInfo(info.id)
        if q then
            info.q, info.ilvl, info.req = q, ilvl, req
            info.cls, info.sub = cls or info.cls, sub or info.sub
            info.inv = (C_Item.GetItemInventoryTypeByID and C_Item.GetItemInventoryTypeByID(info.id)) or info.inv
        end
        -- an old Classic item the client withholds counts only if the game shows it changed
        if ns.isForever and ns.Data.Classify(info.id) == "withheld" then
            local wq, wil, wrq = ns.Data.Withheld(info.id)
            if q == wq and ilvl == wil and req == wrq then return done(false) end
            info.kind = "c"
        end
        done(true)
    end)
end

function S.Announce(rec)
    if engine and S.state == "on" then engine:Announce(rec) end
end

function S.LastHeard()
    return engine and engine.lastHeard
end

-- the feed's Refresh: false while sharing is off or the last hello is under a minute old
function S.AskAgain()
    if not engine or S.state ~= "on" then return false end
    return engine:AskAgain()
end

function S.Engine()
    return engine
end

-- the developer build's button: pull every find this server's copies hold
function S.CollectAll()
    if not engine or S.state ~= "on" then return false end
    engine:CollectAll()
    return true
end

-- how far this copy is caught up, per server (each server has its own channel and its own finds)
local function ServerKey()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or "?"
end

ns.Listen("DBReady", function()
    if C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(P.PREFIX) end
    engine = Engine.New({
        now = GetTime,
        random = function(lo, hi) return math.random(lo, hi) end,
        after = function(s, fn) C_Timer.After(s, fn) end,
        send = Send,
        canSend = CanSend,
        me = Me(),
        finds = ns.Finds,
        accept = Accept,
        onRecorded = function(rec, status, info) ns.Signal("NetFind", rec, status, info) end,
        stamp = ns.Now,
        bookmark = function() return ns.db.sync and ns.db.sync[ServerKey()] end,
        setBookmark = function(t)
            ns.db.sync = ns.db.sync or {}
            ns.db.sync[ServerKey()] = t
        end,
    })
end)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if S.joined then return end
    S.joined = true
    -- the game's own channels join first; ours waits so it never takes their numbers
    C_Timer.After(8, function()
        Join()
        if engine then
            engine.env.me = Me()
            engine:OnLogin()
        end
    end)
end)

ns.On("CHAT_MSG_ADDON", function(prefix, msg, dist, sender)
    if ns.Secret(prefix) or ns.Secret(msg) or ns.Secret(dist) or ns.Secret(sender) then return end
    if prefix ~= P.PREFIX or not engine then return end
    if dist ~= "CHANNEL" and dist ~= "WHISPER" then return end
    engine:Receive(msg, dist, sender)
end)

-- a chat window the player adds later must not show the channel either
ns.On("UPDATE_CHAT_WINDOWS", function()
    if S.state == "on" then HideChannel() end
end)
