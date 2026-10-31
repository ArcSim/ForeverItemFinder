local _, ns = ...

-- The item the Mark on Map button marked, until the button takes it off or another item is marked. FavPins.lua draws
-- it with the favorites, on the World Map and its continents and on the minimap; the player opens the map, the addon
-- never does.
local W = {}
ns.WorldPins = W

local marked

function W.Marked()
    return marked
end

function W.Mark(id)
    marked = id
    if ns.FavPins then ns.FavPins.Refresh() end
end

function W.Clear()
    marked = nil
    if ns.FavPins then ns.FavPins.Refresh() end
end
