local Sprites = {
    loaded = false,
    agentStates = {
        idle = 1,
        searchFood = 2,
        searchWater = 3,
        rest = 4,
        gather = 5,
        useWarehouse = 5,
        craftGear = 5,
        buildHouse = 6,
        buildFarm = 6,
        buildPaddock = 6,
        buildMine = 6,
        buildWarehouse = 6,
        buildShrine = 6,
        worship = 13,
        formCommunity = 7,
        migrateCommunity = 10,
        explore = 10,
        socialize = 7,
        reproduce = 8,
        attack = 9,
        attackBuilding = 9,
        boat = 10,
        stress = 11,
        help = 12
    },
    resources = {
        tree = 1,
        stump = 2,
        berries = 3,
        rock = 4,
        rubble = 5,
        farmFull = 6,
        farmEmpty = 7,
        water = 8,
        boat = 9,
        abandoned = 10,
        warehouse = 11,
        shrine = 12,
        animal = 13,
        iron = 14
    },
    buildings = {
        house = 1,
        farmFull = 2,
        farmEmpty = 3,
        paddock = 4,
        mineStone = 5,
        mineIron = 6
    }
}

local function quads(image, size, count)
    local result = {}
    local width, height = image:getDimensions()
    for i = 1, count do
        result[i] = love.graphics.newQuad((i - 1) * size, 0, size, size, width, height)
    end
    return result
end

function Sprites.load()
    if Sprites.loaded then
        return
    end

    Sprites.agentBase = love.graphics.newImage("assets/agent_base.png")
    Sprites.agentClothes = love.graphics.newImage("assets/agent_clothes.png")
    Sprites.agentIcons = love.graphics.newImage("assets/agent_states.png")
    Sprites.resourceIcons = love.graphics.newImage("assets/resource_states.png")
    Sprites.buildingTiles = love.graphics.newImage("assets/building_tiles.png")
    Sprites.warehouseLarge = love.graphics.newImage("assets/warehouse_large.png")
    Sprites.shrineLarge = love.graphics.newImage("assets/shrine_large.png")

    Sprites.agentBase:setFilter("nearest", "nearest")
    Sprites.agentClothes:setFilter("nearest", "nearest")
    Sprites.agentIcons:setFilter("nearest", "nearest")
    Sprites.resourceIcons:setFilter("nearest", "nearest")
    Sprites.buildingTiles:setFilter("nearest", "nearest")
    Sprites.warehouseLarge:setFilter("nearest", "nearest")
    Sprites.shrineLarge:setFilter("nearest", "nearest")

    Sprites.agentIconQuads = quads(Sprites.agentIcons, 16, 13)
    Sprites.resourceQuads = quads(Sprites.resourceIcons, 16, 14)
    Sprites.buildingQuads = quads(Sprites.buildingTiles, 32, 6)
    Sprites.loaded = true
end

function Sprites.drawBuilding(name, x, y)
    if not Sprites.loaded then
        return false
    end
    local index = Sprites.buildings[name]
    if not index then
        return false
    end
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(Sprites.buildingTiles, Sprites.buildingQuads[index], x, y)
    return true
end

function Sprites.drawLargeStructure(name, x, y)
    if not Sprites.loaded then
        return false
    end
    local image = name == "warehouse" and Sprites.warehouseLarge or (name == "shrine" and Sprites.shrineLarge or nil)
    if not image then
        return false
    end
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(image, x, y)
    return true
end

function Sprites.drawResource(name, x, y, scale)
    if not Sprites.loaded then
        return false
    end
    local index = Sprites.resources[name]
    if not index then
        return false
    end
    love.graphics.draw(Sprites.resourceIcons, Sprites.resourceQuads[index], x, y, 0, scale or 1, scale or 1)
    return true
end

function Sprites.drawAgent(action, x, y, color, onBoat)
    if not Sprites.loaded then
        return false
    end

    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(Sprites.agentBase, x, y, 0, 2, 2)

    local shirt = color or { 0.82, 0.82, 0.76 }
    love.graphics.setColor(shirt[1], shirt[2], shirt[3], 1)
    love.graphics.draw(Sprites.agentClothes, x, y, 0, 2, 2)

    local iconName = onBoat and "boat" or action or "idle"
    local index = Sprites.agentStates[iconName] or Sprites.agentStates.idle
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(Sprites.agentIcons, Sprites.agentIconQuads[index], x + 16, y, 0, 1, 1)
    return true
end

return Sprites
