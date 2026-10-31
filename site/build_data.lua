-- Builds the website's item data from the addon itself: the addon is loaded offline and every item's detail page is
-- opened, so the site shows the same texts the game does. Zone names come from the client's UiMap table.
-- usage: lua build_data.lua   (writes public/data/meta.json, public/data/index.json, public/data/items/<n>.json)
local ROOT = "E:/WoWDev/projects/ArcDiscoveries"
local ADDON = ROOT .. "/ForeverItemFinder"
local OUT = ADDON .. "/site/public/data"
local SNAP = ROOT .. "/datamine/snapshots"
local BUCKETS = 64

local H = dofile("E:/WoWDev/tools/wow-harness/harness.lua")
H.quietStubs = true
function GetBuildInfo() return "1.60.1", "70685", "Oct 29 2026", 16001 end
function GetServerTime() return 1793000000 + math.floor(H.now) end
PixelUtil = { SetHeight = function(r, h) r:SetHeight(h) end, SetWidth = function(r, w) r:SetWidth(w) end }
NUM_CHAT_WINDOWS = 1
Enum = { TooltipDataType = { Item = 0 }, TooltipDataLineType = {}, SendAddonMessageResult = { Success = 0 } }
LOCALIZED_CLASS_NAMES_MALE = { DRUID = "Druid", HUNTER = "Hunter", MAGE = "Mage", PALADIN = "Paladin", PRIEST = "Priest",
    ROGUE = "Rogue", SHAMAN = "Shaman", WARLOCK = "Warlock", WARRIOR = "Warrior" }

-- the newest snapshot's UiMap names
local function NewestSnapshot()
    local p = io.popen('dir /b /ad "' .. SNAP:gsub("/", "\\") .. '"')
    local best
    -- a snapshot holding only the server's cache (its client tables not exported yet) is skipped
    for name in p:lines() do
        local f = name:match("^%d+%.%d+%.%d+%.%d+$") and (not best or name > best) and io.open(SNAP .. "/" .. name .. "/client/UiMap.csv", "rb")
        if f then
            f:close()
            best = name
        end
    end
    p:close()
    return best
end
local snap = assert(NewestSnapshot(), "no datamine snapshot")
local ZONES = {}
do
    local f = assert(io.open(SNAP .. "/" .. snap .. "/client/UiMap.csv", "rb"))
    local header = f:read("*l")
    local nameCol, idCol
    local i = 0
    for col in (header .. ","):gmatch("([^,]*),") do
        i = i + 1
        if col == "Name_lang" then nameCol = i elseif col == "ID" then idCol = i end
    end
    for line in f:lines() do
        -- names with commas are quoted
        local fields, rest = {}, line
        while #rest > 0 do
            local q = rest:match('^"(.-)",') or rest:match('^"(.-)"$')
            if q then
                fields[#fields + 1] = q
                rest = rest:sub(#q + 4)
            else
                local v = rest:match("^([^,]*)")
                fields[#fields + 1] = v
                rest = rest:sub(#v + 2)
            end
        end
        local id = tonumber(fields[idCol])
        if id then ZONES[id] = fields[nameCol] end
    end
    f:close()
end

-- the maps the game can draw, with their art's size: UiMapXMapArt (base phase) -> UiMapArt -> its style's first layer
local MAP_TABLES = ROOT .. "/datamine/forever_maps/1.60.1.70685"
local ART = {}
do
    local function Rows(name)
        local f = assert(io.open(MAP_TABLES .. "/" .. name .. ".csv", "rb"))
        local head, rows, i = {}, {}, 0
        for col in (f:read("*l"):gsub("\r$", "") .. ","):gmatch("([^,]*),") do
            i = i + 1
            head[col] = i
        end
        for line in f:lines() do
            local t, n = {}, 0
            for v in (line:gsub("\r$", "") .. ","):gmatch("([^,]*),") do
                n = n + 1
                t[n] = v
            end
            rows[#rows + 1] = t
        end
        f:close()
        return head, rows
    end
    local sh, styleRows = Rows("UiMapArtStyleLayer")
    local size = {}
    for _, r in ipairs(styleRows) do
        if r[sh.LayerIndex] == "0" then size[r[sh.UiMapArtStyleID]] = { tonumber(r[sh.LayerWidth]), tonumber(r[sh.LayerHeight]) } end
    end
    local ah, artRows = Rows("UiMapArt")
    local style = {}
    for _, r in ipairs(artRows) do style[r[ah.ID]] = r[ah.UiMapArtStyleID] end
    local xh, mapRows = Rows("UiMapXMapArt")
    for _, r in ipairs(mapRows) do
        local s = r[xh.PhaseID] == "0" and size[style[r[xh.UiMapArtID]]]
        if s then ART[tonumber(r[xh.UiMapID])] = s end
    end
end

-- every item's icon file id from the client's Item table; the addon's own data covers new items the table lacks
local ITEM_ICONS = {}
do
    local f = assert(io.open(SNAP .. "/" .. snap .. "/client/Item.csv", "rb"))
    local header = f:read("*l")
    local idCol, iconCol
    local i = 0
    for col in (header .. ","):gmatch("([^,]*),") do
        i = i + 1
        if col == "ID" then idCol = i elseif col == "IconFileDataID" then iconCol = i end
    end
    for line in f:lines() do
        local fields, n = {}, 0
        for v in (line .. ","):gmatch("([^,]*),") do
            n = n + 1
            fields[n] = v
        end
        local id, icon = tonumber(fields[idCol]), tonumber(fields[iconCol])
        if id and icon and icon > 0 then ITEM_ICONS[id] = icon end
    end
    f:close()
end

C_Item = {
    GetItemInfo = function() return nil end,
    GetItemInfoInstant = function(id) return id end,
    GetItemIconByID = function() return 134400 end,
    GetItemInventoryTypeByID = function() return nil end,
    GetItemStats = function() return nil end,
    RequestLoadItemDataByID = function() end,
}
C_TooltipInfo = { GetItemByID = function() return nil end }
TooltipDataProcessor = { AddTooltipPostCall = function() end }
-- the addon's map needs only the art's size; the site draws its own pictures of it
C_Map = { GetBestMapForUnit = function() return nil end,
    GetMapArtLayers = function(id)
        local s = ART[id]
        return s and { { layerWidth = s[1], layerHeight = s[2], tileWidth = 256, tileHeight = 256 } } or {}
    end,
    GetMapArtLayerTextures = function()
        local t = {}
        for i = 1, 12 do t[i] = 1 end
        return t
    end,
    GetMapInfo = function(id) return ZONES[id] and { name = ZONES[id] } or nil end }
C_Container = { GetContainerNumSlots = function() return 0 end }
ChatFrameUtil = { AddMessageEventFilter = function() end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() return 0 end, SendAddonMessage = function() return 0 end,
    InChatMessagingLockdown = function() return false end, AreOutgoingAddonChatMessagesRestricted = function() return false end }
function JoinTemporaryChannel() end
function GetChannelName() return 0 end

local ns = H.LoadToc(ADDON, "ForeverItemFinder.toc")
H.Login()
local D, T, U = ns.Data, ns.Theme, ns.Theme.U
ns.UI.Show("db")
-- the detail side at the size the site's lines are fitted to; its anchors size it, so the window is sized to give it that
local wantW, wantH = U(860) - 6 - U(24) - U(458) - 3, U(560) - 6 - U(80) - 2
local winF = _G.ForeverItemFinderFrame
winF:SetSize(winF:GetWidth() - (ns.UI.detailPane:GetWidth() - wantW), winF:GetHeight() - (ns.UI.detailPane:GetHeight() - wantH))
assert(math.abs(ns.UI.detailPane:GetWidth() - wantW) < 0.01 and math.abs(ns.UI.detailPane:GetHeight() - wantH) < 0.01,
    "the detail side is not at the site's size: " .. ns.UI.detailPane:GetWidth() .. " x " .. ns.UI.detailPane:GetHeight() .. " want " .. wantW .. " x " .. wantH)
local det = ns.UI.detail

-- JSON
local function J(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v == math.floor(v) then return ("%d"):format(v) end
        return (("%.2f"):format(v):gsub("0+$", ""):gsub("%.$", ""))
    end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n" end
            return ("\\u%04x"):format(c:byte())
        end) .. '"'
    end
    local parts = {}
    if #v > 0 or next(v) == nil then
        for i = 1, #v do parts[i] = J(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do parts[#parts + 1] = J(tostring(k)) .. ":" .. J(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function Write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    return #text
end
local function Hex(r, g, b)
    return ("%02X%02X%02X"):format(math.floor((r or 1) * 255 + 0.5), math.floor((g or 1) * 255 + 0.5), math.floor((b or 1) * 255 + 0.5))
end

-- the datamined tooltip as [text, colour, right text]
local function TipLines(id)
    local lines = {}
    local tip = {}
    function tip:ClearLines() lines = {} end
    function tip:AddLine(text, r, g, b) lines[#lines + 1] = { text, Hex(r, g, b) } end
    function tip:AddDoubleLine(a, b2, r, g, bl) lines[#lines + 1] = { a, Hex(r, g, bl), b2 } end
    if not T.DataTip(tip, id) then return nil end
    return lines
end

-- each mob's or object's spots, kept once for every item it gives: "n<npc>" / "o<object>" -> { { map, { x, y, ... } }, ... }
-- in the addon's pin order (the first spot in a pin's cell wins it). PLACE_MAPS: every map a pin stands on.
local SPOTS, SPOT_COUNT, PLACE_MAPS = {}, {}, {}
local function PinList(pins)
    local out, cur = {}, nil
    for _, p in ipairs(pins) do
        if not cur or cur[1] ~= p.m then
            cur = { p.m, {} }
            out[#out + 1] = cur
        end
        cur[2][#cur[2] + 1] = p.x
        cur[2][#cur[2] + 1] = p.y
        PLACE_MAPS[p.m] = true
    end
    return out
end
-- the addon's map entries as the site draws them: look, role, who { name, level, rank }, dungeon, a header (a world
-- drop's count line), the line's own right text, and the pins, by place key (s) or inline (p)
local function MapEntries(entries)
    local out = {}
    for i, en in ipairs(entries) do
        local who = en.who
        local o = { k = en.look, r = en.role, d = en.dungeon, h = en.header and 1 or nil, t = en.rightText }
        if who then o.w = { who.name or en.left, who.lv or "", who.rank or 0 } end
        local key = who and who.id and en.look ~= "entrance" and #en.pins > 0 and #en.pins == #(who.pins or {}) and
            ((who.npc and "n" or "o") .. who.id)
        -- one line for a node under several records: each record's spots by its own key, in the line's order
        local keys, at = en.places and #en.places > 1 and {}, 0
        for _, place in ipairs(keys and en.places or {}) do
            local k = place.id and ("o" .. place.id)
            local n = #(place.pins or {})
            if not k or at + n > #en.pins then keys = nil break end
            local part = {}
            for j = at + 1, at + n do part[#part + 1] = en.pins[j] end
            if not SPOTS[k] then SPOTS[k], SPOT_COUNT[k] = PinList(part), n end
            keys[#keys + 1] = k
            at = at + n
        end
        if keys and at == #en.pins then
            o.s = keys
        elseif key then
            if not SPOTS[key] then
                SPOTS[key], SPOT_COUNT[key] = PinList(en.pins), #en.pins
            end
            assert(SPOT_COUNT[key] == #en.pins, "place " .. key .. " has two different spot lists")
            o.s = key
        elseif #en.pins > 0 then
            o.p = PinList(en.pins)
        end
        out[i] = o
    end
    return out
end

local index, buckets, nItems = {}, {}, 0
D.ForEachSeed(function(id, kind)
    local row = D.Seed(id)
    if not row then return end
    ns.UI.Select(id)
    -- the texts the game shows on this item's page
    local status = {}
    for _, r in ipairs(det.rows) do
        if r.key._shown then status[#status + 1] = { r.key._text, r.value._text } end
    end
    -- each where line and its spot: a world drop's zone line names its mob, its count line has none, any other line
    -- its zone and spot (or how many spots)
    -- (no map) and which map entry it lights (0: none, as for "and N more")
    local where, spots, lineOf = {}, {}, {}
    for i, line in ipairs(det.whereLines) do
        if line._shown and (line.left._text or "") ~= "" then
            where[#where + 1] = line.left._text
            local en, spot = det.entries and det.entries[i], ""
            if en and not en.header and not line.dot._shown then en = nil end
            lineOf[#lineOf + 1] = line.dot._shown and i or 0
            if en and en.rightText then
                spot = en.rightText
            elseif en and not en.header and en.pins[1] and ZONES[en.pins[1].m] then
                -- the spots of the zone it names, as the addon's line counts them
                local p, n = en.pins[1], 0
                for _, q in ipairs(en.pins) do if q.m == p.m then n = n + 1 end end
                spot = n == 1 and ("%s %.1f, %.1f"):format(ZONES[p.m], p.x / 10, p.y / 10) or (ZONES[p.m] .. ", " .. n .. " spots")
            end
            spots[#spots + 1] = spot
        end
    end
    -- the zones and dungeon the database list names and searches
    local zones, dungeon = {}, ""
    for _, s in ipairs(D.Sources(id)) do
        for _, p in ipairs(s.pins) do
            if ZONES[p.m] then zones[ZONES[p.m]] = true end
        end
        if s.dungeon then
            zones[s.dungeon.name] = true
            if dungeon == "" then dungeon = s.dungeon.name end
        end
    end
    local canUse = 0
    for i, file in ipairs(D.CLASS_ORDER) do
        if D.CanUse(file, 60, row.cls, row.sub, row.ac) then canUse = canUse + 2 ^ (i - 1) end
    end
    local zoneText = {}
    for z in pairs(zones) do zoneText[#zoneText + 1] = z end
    table.sort(zoneText)
    local name = det.name._text
    -- then the addon's Not Found mark, the item's icon file id, and its category and subcategory in the tree (trade
    -- goods sit under Reagent, D.CatOf)
    local ic, isc = D.CatOf(row.cls, row.sub)
    index[#index + 1] = { id, name, row.q or -1, kind, row.req or 0, row.ilvl or 0, D.SlotGroup(row.inv) or 0, canUse,
        D.SourceMask(id), dungeon, table.concat(zoneText, "|"), D.IsNotFound(id) and 1 or 0, D.IconOf(id) or ITEM_ICONS[id] or 0,
        ic or -1, isc or -1 }
    -- what it is and its level, as the addon's item box read before its full tooltip took the box over
    local hidden = row.kind == "x"
    local req = (row.req or 0) > 0 and ("Requires level " .. row.req) or (hidden and "Level unknown") or "No level needed"
    local b = id % BUCKETS
    buckets[b] = buckets[b] or {}
    buckets[b][tostring(id)] = { line = D.ItemLine(row.cls, row.sub, row.inv, row.ilvl), req = req, status = status, where = where,
        spots = spots, lines = lineOf, map = MapEntries(det.entries or {}), tip = TipLines(id), beta = row.beta or nil }
    nItems = nItems + 1
end)

local slots = {}
for _, inv in ipairs(D.SLOTS) do
    local g = D.SlotGroup(inv)
    local seen = false
    for _, s in ipairs(slots) do if s[1] == g then seen = true end end
    if not seen then slots[#slots + 1] = { g, D.SlotName(inv) } end
end
local classes = {}
for _, file in ipairs(D.CLASS_ORDER) do classes[#classes + 1] = LOCALIZED_CLASS_NAMES_MALE[file] end
local sourceKinds = {}
for _, k in ipairs(D.SOURCE_KINDS) do sourceKinds[#sourceKinds + 1] = { k.bit, k.text } end
-- the addon's category tree: { class, name, { { subclass, name }, ... } }
local categories = {}
for _, c in ipairs(D.CATEGORIES) do
    local subs = {}
    for _, sb in ipairs(c.subs) do subs[#subs + 1] = { sb[1], sb[2] } end
    categories[#categories + 1] = { c.cls, c.name, subs }
end
-- every map a pin stands on, by name, and the ones the site has a picture of (maps/<id>.jpg) with the art's size
local zoneNames, art, nArt = {}, {}, 0
for m in pairs(PLACE_MAPS) do
    zoneNames[tostring(m)] = ZONES[m] or ("Zone " .. m)
    if ART[m] then
        art[tostring(m)] = ART[m]
        nArt = nArt + 1
    end
end
local meta = { version = D.version, made = D.made, snapshot = snap, items = nItems, buckets = BUCKETS, slots = slots, categories = categories,
    classes = classes, sources = sourceKinds, dungeons = D.DungeonNames(false), raids = D.DungeonNames(true),
    quality = { "9D9D9D", "FFFFFF", "1EFF00", "0070DD", "A335EE", "FF8000" }, zones = zoneNames, art = art }
os.execute('mkdir "' .. (OUT .. "/items"):gsub("/", "\\") .. '" 2>nul')
os.execute('mkdir "' .. (OUT .. "/spots"):gsub("/", "\\") .. '" 2>nul')
local total = Write(OUT .. "/meta.json", J(meta)) + Write(OUT .. "/index.json", J(index))
local indexBytes = total
for b = 0, BUCKETS - 1 do total = total + Write(OUT .. "/items/" .. b .. ".json", J(buckets[b] or {})) end
-- a place's spots go in the bucket of its id, so an item's few places cost a few small files
local spotBuckets, nPlaces, spotBytes = {}, 0, 0
for key, list in pairs(SPOTS) do
    local b = tonumber(key:sub(2)) % BUCKETS
    spotBuckets[b] = spotBuckets[b] or {}
    spotBuckets[b][key] = list
    nPlaces = nPlaces + 1
end
for b = 0, BUCKETS - 1 do spotBytes = spotBytes + Write(OUT .. "/spots/" .. b .. ".json", J(spotBuckets[b] or {})) end
io.write(("site data: %d items, index %d KB, all files %d KB, %d places' spots %d KB, %d maps with art, zones from snapshot %s\n"):format(nItems,
    math.floor(indexBytes / 1024), math.floor(total / 1024), nPlaces, math.floor(spotBytes / 1024), nArt, snap))
