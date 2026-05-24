local Resources = require("src.systems.resources")

local Building = {}

local COSTS = {
    house = { wood = 16, stone = 4 },
    farm = { wood = 8, stone = 2 },
    paddock = { wood = 12, stone = 3, animals = 1 },
    mine = { wood = 22, stone = 0 },
    warehouse = { wood = 24, stone = 10 },
    shrine = { wood = 34, stone = 36 },
    port = { wood = 34, stone = 12 }
}

local HEALTH = {
    house = 90,
    farm = 48,
    paddock = 58,
    mine = 70,
    warehouse = 160,
    shrine = 140,
    port = 120
}

function Building.cost(kind)
    return COSTS[kind]
end

local function trustedContributor(agent, other)
    if not other or not other.alive or other.id == agent.id then
        return false
    end
    if agent.communityId and other.communityId == agent.communityId then
        return true
    end
    if agent.expedition and other.expedition
        and agent.expedition.id
        and agent.expedition.id == other.expedition.id then
        return true
    end
    return agent.memory:trust(other.id) > 30
end

function Building.canAfford(agent, kind, contributors)
    local cost = COSTS[kind]
    if not cost then
        return false
    end

    local wood = agent.inventory.wood
    local stone = agent.inventory.stone
    local animals = agent.inventory.animals or 0
    local community = agent.currentSim and agent.communityId and agent.currentSim.communities[agent.communityId]
    if community and community.hasWarehouse and community.store and agent.currentSim:canAccessWarehouse(agent) then
        wood = wood + (community.store.wood or 0)
        stone = stone + (community.store.stone or 0)
        animals = animals + (community.store.animals or 0)
    end
    for _, other in ipairs(contributors or {}) do
        if trustedContributor(agent, other) then
            wood = wood + other.inventory.wood
            stone = stone + other.inventory.stone
            animals = animals + (other.inventory.animals or 0)
        end
    end

    return wood >= (cost.wood or 0) and stone >= (cost.stone or 0) and animals >= (cost.animals or 0)
end

local function fitsBuilding(world, x, y, kind, communityId)
    local size = (kind == "warehouse" or kind == "shrine") and 2 or 1
    for yy = y, y + size - 1 do
        for xx = x, x + size - 1 do
            local tile = world:get(xx, yy)
            if kind == "mine" then
                if not tile or tile.type ~= Resources.TILE.rock or ((tile.stone or 0) <= 1 and (tile.iron or 0) <= 0 and (tile.maxStone or 0) <= 0 and (tile.maxIron or 0) <= 0) then
                    return false
                end
            elseif kind == "farm" then
                if not tile or tile.type ~= Resources.TILE.grass then
                    return false
                end
            elseif kind == "port" then
                if not tile or (tile.type ~= Resources.TILE.grass and tile.type ~= Resources.TILE.forest and tile.type ~= Resources.TILE.sand and tile.type ~= Resources.TILE.path) or not world:hasWaterNear(xx, yy) then
                    return false
                end
            elseif kind == "house" then
                if not tile or (tile.type ~= Resources.TILE.grass and tile.type ~= Resources.TILE.forest and tile.type ~= Resources.TILE.path) then
                    return false
                end
                for ny = math.max(1, yy - 1), math.min(world.height, yy + 1) do
                    for nx = math.max(1, xx - 1), math.min(world.width, xx + 1) do
                        if world.tiles[ny][nx].type == Resources.TILE.house then
                            return false
                        end
                    end
                end
            else
                if not tile or (tile.type ~= Resources.TILE.grass and tile.type ~= Resources.TILE.forest and tile.type ~= Resources.TILE.path) then
                    return false
                end
            end
        end
    end
    return true
end

function Building.findSite(world, sx, sy, kind, communityId)
    return world:findNearest(sx, sy, function(tile, x, y)
        return fitsBuilding(world, x, y, kind, communityId)
    end, kind == "mine" and 14 or 10)
end

local function spend(agent, contributors, resource, amount)
    local community = agent.currentSim and agent.communityId and agent.currentSim.communities[agent.communityId]
    if community and community.hasWarehouse and community.store and agent.currentSim:canAccessWarehouse(agent) then
        local take = math.min(community.store[resource] or 0, amount)
        community.store[resource] = (community.store[resource] or 0) - take
        amount = amount - take
    end

    local take = math.min(agent.inventory[resource] or 0, amount)
    agent.inventory[resource] = (agent.inventory[resource] or 0) - take
    amount = amount - take

    for _, other in ipairs(contributors or {}) do
        if amount <= 0 then
            break
        end
        if trustedContributor(agent, other) then
            take = math.min(other.inventory[resource] or 0, amount)
            other.inventory[resource] = (other.inventory[resource] or 0) - take
            amount = amount - take
        end
    end
end

function Building.build(world, agent, kind, x, y, contributors)
    local community = agent.currentSim and agent.communityId and agent.currentSim.communities[agent.communityId]
    if kind == "warehouse" and community and community.hasWarehouse then
        return false
    end
    if kind == "shrine" and community and community.hasShrine then
        return false
    end
    if not Building.canAfford(agent, kind, contributors) then
        return false
    end

    local tile = world:get(x, y)
    if not tile
        or (kind == "mine" and tile.type ~= Resources.TILE.rock)
        or (kind == "farm" and tile.type ~= Resources.TILE.grass)
        or (kind == "port" and ((tile.type ~= Resources.TILE.grass and tile.type ~= Resources.TILE.forest and tile.type ~= Resources.TILE.sand and tile.type ~= Resources.TILE.path) or not world:hasWaterNear(x, y)))
        or (kind ~= "mine" and kind ~= "farm" and kind ~= "port" and tile.type ~= Resources.TILE.grass and tile.type ~= Resources.TILE.forest and tile.type ~= Resources.TILE.path) then
        return false
    end
    if kind == "house" then
        for yy = math.max(1, y - 1), math.min(world.height, y + 1) do
            for xx = math.max(1, x - 1), math.min(world.width, x + 1) do
                if world.tiles[yy][xx].type == Resources.TILE.house then
                    return false
                end
            end
        end
    end

    local cost = COSTS[kind]
    spend(agent, contributors, "wood", cost.wood)
    spend(agent, contributors, "stone", cost.stone)
    if cost.animals then
        spend(agent, contributors, "animals", cost.animals)
    end

    if kind == "house" then
        tile.type = Resources.TILE.house
        tile.food = 0
        tile.wood = 0
        tile.stone = 0
        tile.iron = 0
        tile.animals = 0
        tile.maxFood = 0
        tile.maxWood = 0
        tile.maxStone = 0
        tile.maxIron = 0
        tile.maxAnimals = 0
    elseif kind == "farm" then
        tile.type = Resources.TILE.farm
        tile.food = 20
        tile.wood = 0
        tile.stone = 0
        tile.iron = 0
        tile.animals = 0
        tile.maxFood = 54
        tile.maxWood = 0
        tile.maxStone = 0
        tile.maxIron = 0
        tile.maxAnimals = 0
    elseif kind == "paddock" then
        tile.type = Resources.TILE.paddock
        tile.food = 1
        tile.wood = 0
        tile.stone = 0
        tile.iron = 0
        tile.animals = 5
        tile.maxFood = 3
        tile.maxWood = 0
        tile.maxStone = 0
        tile.maxIron = 0
        tile.maxAnimals = 12
    elseif kind == "mine" then
        local mineResource = ((tile.iron or 0) + (tile.maxIron or 0)) > 0 and "iron" or "stone"
        local visible = mineResource == "iron" and (tile.iron or 0) or (tile.stone or 0)
        local capacity = mineResource == "iron" and math.max(tile.maxIron or 0, visible) or math.max(tile.maxStone or 0, visible)
        tile.type = Resources.TILE.mine
        tile.food = 0
        tile.wood = 0
        tile.animals = 0
        tile.stone = mineResource == "stone" and math.max(1, visible) or 0
        tile.iron = mineResource == "iron" and math.max(1, visible) or 0
        tile.maxFood = 0
        tile.maxWood = 0
        tile.maxAnimals = 0
        tile.maxStone = mineResource == "stone" and 8 or 0
        tile.maxIron = mineResource == "iron" and 4 or 0
        tile.mineResource = mineResource
        tile.mineReserve = math.max(18, capacity * (mineResource == "iron" and 4 or 5))
    elseif kind == "port" then
        tile.type = Resources.TILE.port
        tile.food = 0
        tile.wood = 0
        tile.stone = 0
        tile.iron = 0
        tile.animals = 0
        tile.maxFood = 0
        tile.maxWood = 0
        tile.maxStone = 0
        tile.maxIron = 0
        tile.maxAnimals = 0
    elseif kind == "warehouse" or kind == "shrine" then
        for yy = y, y + 1 do
            for xx = x, x + 1 do
                local part = world:get(xx, yy)
                part.type = kind == "warehouse" and Resources.TILE.warehouse or Resources.TILE.shrine
                part.food = 0
                part.wood = 0
                part.stone = 0
                part.iron = 0
                part.animals = 0
                part.maxFood = 0
                part.maxWood = 0
                part.maxStone = 0
                part.maxIron = 0
                part.maxAnimals = 0
            end
        end
    end

    local building = {
        id = #world.buildings + 1,
        type = kind,
        x = x,
        y = y,
        owner = agent.id,
        communityId = agent.communityId,
        capacity = kind == "house" and 2 or 0,
        occupants = 0,
        residents = {},
        active = true,
        abandonedTicks = 0,
        width = (kind == "warehouse" or kind == "shrine") and 2 or 1,
        height = (kind == "warehouse" or kind == "shrine") and 2 or 1,
        mineResource = kind == "mine" and tile.mineResource or nil,
        maxHealth = HEALTH[kind] or 80,
        health = HEALTH[kind] or 80
    }

    if kind == "warehouse" or kind == "shrine" then
        for yy = y, y + 1 do
            for xx = x, x + 1 do
                world:get(xx, yy).building = building
            end
        end
    else
        tile.building = building
    end
    world.buildings[#world.buildings + 1] = building
    if kind == "warehouse" and community then
        community.hasWarehouse = true
        community.warehouses = (community.warehouses or 0) + 1
        community.store = community.store or { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    elseif kind == "shrine" and community then
        community.hasShrine = true
        community.shrines = (community.shrines or 0) + 1
    elseif kind == "port" and community then
        community.ports = (community.ports or 0) + 1
        community.hasPort = true
    end
    return true, building
end

return Building
