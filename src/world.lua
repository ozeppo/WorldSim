local Resources = require("src.systems.resources")
local Sprites = require("src.ui.sprites")

local World = {}
World.__index = World

World.TILE_SIZE = 32
World.BOAT_COST = 10
World.BOAT_DURABILITY = 28
World.INDEX_SECTOR_SIZE = 8

local function dist2(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return dx * dx + dy * dy
end

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function randomRange(minValue, maxValue)
    return minValue + math.random() * (maxValue - minValue)
end

local DIRS = {
    { 1, 0 },
    { -1, 0 },
    { 0, 1 },
    { 0, -1 }
}

local function tileKey(width, x, y)
    return (y - 1) * width + x
end

local function sectorKey(x, y, sectorSize)
    return math.floor((x - 1) / sectorSize) .. ":" .. math.floor((y - 1) / sectorSize)
end

local function addIndexed(index, x, y, tile, sectorSize)
    local key = sectorKey(x, y, sectorSize)
    local bucket = index[key]
    if not bucket then
        bucket = {}
        index[key] = bucket
    end
    bucket[#bucket + 1] = { x = x, y = y, tile = tile }
end

local function tileHasResource(tile, resource)
    if not tile then
        return false
    end
    if resource == "water" then
        return tile.type == Resources.TILE.water
    elseif resource == "animals" then
        return (tile.animals or 0) >= 1
    end
    return (tile[resource] or 0) >= 2
end

local function fitsBuildCandidate(world, x, y, kind)
    local size = (kind == "warehouse" or kind == "shrine") and 2 or 1
    for yy = y, y + size - 1 do
        for xx = x, x + size - 1 do
            local tile = world:get(xx, yy)
            if kind == "mine" then
                if not tile or tile.type ~= Resources.TILE.rock or ((tile.stone or 0) <= 1 and (tile.iron or 0) <= 0 and (tile.maxStone or 0) <= 0 and (tile.maxIron or 0) <= 0) then
                    return false
                end
            elseif kind == "farm" then
                if not tile or tile.type ~= Resources.TILE.grass or not world:hasWaterNear(xx, yy) then
                    return false
                end
            else
                if not tile or (tile.type ~= Resources.TILE.grass and tile.type ~= Resources.TILE.forest) then
                    return false
                end
            end
        end
    end
    return true
end

local function generatedTile(kind, rockScale, animalScale)
    local tile = Resources.makeTile(kind)
    if kind == Resources.TILE.rock then
        tile.maxStone = math.max(1, math.floor((tile.maxStone or 0) * rockScale + 0.5))
        tile.stone = math.min(tile.maxStone, math.floor((tile.stone or 0) * rockScale + 0.5))
    end
    if (tile.maxAnimals or 0) > 0 then
        local scaledAnimals = tile.maxAnimals * animalScale
        tile.maxAnimals = math.max(0, math.floor(scaledAnimals))
        if math.random() < scaledAnimals - tile.maxAnimals then
            tile.maxAnimals = tile.maxAnimals + 1
        end
        tile.animals = math.min(tile.animals or 0, tile.maxAnimals)
        if tile.animals > 0 and math.random() > animalScale then
            tile.animals = 0
        end
    end
    return tile
end

function World.new(width, height, seed, config)
    config = config or {}
    local self = setmetatable({
        width = width,
        height = height,
        seed = seed or 1,
        config = config,
        tiles = {},
        buildings = {},
        comfortCache = {},
        foreignHouseCache = {},
        waterNearCache = {},
        index = {
            sectorSize = World.INDEX_SECTOR_SIZE,
            resources = {},
            buildSites = {},
            resourceTick = -9999,
            buildTick = -9999,
            resourceDirty = true,
            buildDirty = true
        },
        totals = { food = 0, wood = 0, stone = 0, iron = 0, animals = 0, farms = 0, paddocks = 0, mines = 0, houses = 0, warehouses = 0, shrines = 0 }
    }, World)

    self:generate(config)
    self:seedIronDeposits()
    self:buildTerrainCaches()
    self:rebuildInfluenceCaches()
    self:markIndexDirty("all")
    self:recount()
    return self
end

function World:seedIronDeposits()
    local resources = self.config.resources or {}
    local ironScale = resources.iron or 1
    local deposits = math.max(4, math.floor((self.width * self.height) / 1200 * ironScale))
    for _ = 1, deposits do
        self:spawnIronDeposit()
    end
end

function World:spawnIronDeposit()
    local bestX, bestY
    for _ = 1, 80 do
        local x = math.random(1, self.width)
        local y = math.random(1, self.height)
        local tile = self.tiles[y][x]
        if tile.type == Resources.TILE.rock and (tile.maxIron or 0) <= 0 then
            bestX, bestY = x, y
            break
        end
    end
    if not bestX then
        return false
    end

    local radius = math.random(1, 2)
    for y = math.max(1, bestY - radius), math.min(self.height, bestY + radius) do
        for x = math.max(1, bestX - radius), math.min(self.width, bestX + radius) do
            local tile = self.tiles[y][x]
            if tile.type == Resources.TILE.rock and math.random() < 0.62 then
                tile.maxIron = math.max(tile.maxIron or 0, math.random(4, 9))
                tile.iron = math.max(tile.iron or 0, math.floor(tile.maxIron * (0.35 + math.random() * 0.35)))
            end
        end
    end
    return true
end

function World:generate(config)
    math.randomseed(self.seed)
    config = config or self.config or {}
    local resourceConfig = config.resources or {}
    local forestScale = resourceConfig.forest or 1
    local rockScale = resourceConfig.rock or 1
    local animalScale = resourceConfig.animals or 1
    local continentCount = math.max(1, config.continents or 4)
    local continentScale = config.continentScale or 1

    local continents = {}
    local marginX = math.max(14, math.floor(self.width * 0.08))
    local marginY = math.max(10, math.floor(self.height * 0.08))
    for _ = 1, continentCount do
        continents[#continents + 1] = {
            x = math.random(marginX, self.width - marginX),
            y = math.random(marginY, self.height - marginY),
            rx = math.max(10, math.floor(randomRange(self.width * 0.14, self.width * 0.25) * continentScale)),
            ry = math.max(8, math.floor(randomRange(self.height * 0.16, self.height * 0.29) * continentScale))
        }
    end

    for y = 1, self.height do
        self.tiles[y] = {}
        for x = 1, self.width do
            local landScore = -math.huge
            for _, continent in ipairs(continents) do
                local dx = (x - continent.x) / continent.rx
                local dy = (y - continent.y) / continent.ry
                local score = 1 - (dx * dx + dy * dy)
                if score > landScore then
                    landScore = score
                end
            end

            local coastNoise = love.math.noise((x + self.seed) * 0.038, (y - self.seed) * 0.038)
            local detailNoise = love.math.noise((x - self.seed) * 0.105, (y + self.seed) * 0.105)
            landScore = landScore + (coastNoise - 0.5) * 0.56 + (detailNoise - 0.5) * 0.16

            local kind = Resources.TILE.ocean
            if landScore > -0.03 then
                local latitude = math.abs(((y - 0.5) / self.height) - 0.5) * 2
                local warmth = 1 - latitude
                local forestNoise = love.math.noise((x + self.seed * 3) * 0.033, (y - self.seed * 2) * 0.033)
                local rockNoise = love.math.noise((x - self.seed * 5) * 0.072, (y + self.seed * 4) * 0.072)
                local snowNoise = love.math.noise((x + self.seed) * 0.062, (y + self.seed) * 0.062)
                local forestThreshold = 0.60 - warmth * 0.22 - (forestScale - 1) * 0.12
                local rockThreshold = 0.80 + (1 - rockScale) * 0.08

                if warmth < 0.18 or (warmth < 0.26 and snowNoise > 0.56) then
                    kind = Resources.TILE.snow
                elseif rockNoise > rockThreshold then
                    kind = Resources.TILE.rock
                elseif forestNoise > forestThreshold then
                    kind = Resources.TILE.forest
                else
                    kind = Resources.TILE.grass
                end
            end

            self.tiles[y][x] = generatedTile(kind, rockScale, animalScale)
        end
    end

    self:addArchipelagos(config.archipelagos or math.max(4, continentCount + 3), forestScale, rockScale, animalScale)
    self:addLakes(config.lakes or 24)
    self:addRivers(config.rivers or 12, continents)
    self:addShallowWater(config.shallowWaterDepth or 3)
    self:addBeaches()
end

function World:replaceTile(x, y, kind)
    local old = self.tiles[y] and self.tiles[y][x]
    if not old or old.building then
        return false
    end
    self.tiles[y][x] = Resources.makeTile(kind)
    return true
end

function World:isLandType(tile)
    return tile and tile.type ~= Resources.TILE.water and tile.type ~= Resources.TILE.shallowWater and tile.type ~= Resources.TILE.ocean
end

function World:landKindFor(x, y, forestScale, rockScale, islandBias)
    local latitude = math.abs(((y - 0.5) / self.height) - 0.5) * 2
    local warmth = 1 - latitude
    local forestNoise = love.math.noise((x + self.seed * 7) * 0.05, (y - self.seed * 3) * 0.05)
    local rockNoise = love.math.noise((x - self.seed * 11) * 0.09, (y + self.seed * 5) * 0.09)
    local forestThreshold = 0.63 - warmth * 0.18 - (forestScale - 1) * 0.10 + (islandBias or 0)
    local rockThreshold = 0.82 + (1 - rockScale) * 0.07

    if warmth < 0.15 then
        return Resources.TILE.snow
    elseif rockNoise > rockThreshold then
        return Resources.TILE.rock
    elseif forestNoise > forestThreshold then
        return Resources.TILE.forest
    end
    return Resources.TILE.grass
end

function World:addIslandPatch(cx, cy, rx, ry, forestScale, rockScale, animalScale)
    for y = math.max(2, cy - ry - 1), math.min(self.height - 1, cy + ry + 1) do
        for x = math.max(2, cx - rx - 1), math.min(self.width - 1, cx + rx + 1) do
            local dx = (x - cx) / rx
            local dy = (y - cy) / ry
            local edgeNoise = love.math.noise((x + self.seed) * 0.24, (y - self.seed) * 0.24)
            if dx * dx + dy * dy <= 1.0 + (edgeNoise - 0.5) * 0.42 then
                local tile = self.tiles[y][x]
                if tile and tile.type == Resources.TILE.ocean then
                    local kind = self:landKindFor(x, y, forestScale, rockScale, 0.08)
                    self.tiles[y][x] = generatedTile(kind, rockScale, animalScale)
                end
            end
        end
    end
end

function World:addArchipelagos(count, forestScale, rockScale, animalScale)
    for _ = 1, count do
        local cx, cy
        for _ = 1, 120 do
            local x = math.random(8, self.width - 7)
            local y = math.random(7, self.height - 6)
            if self.tiles[y][x].type == Resources.TILE.ocean then
                cx, cy = x, y
                break
            end
        end
        if cx then
            local islands = math.random(3, 7)
            for _ = 1, islands do
                local ox = math.random(-11, 11)
                local oy = math.random(-8, 8)
                local x = clamp(cx + ox, 3, self.width - 2)
                local y = clamp(cy + oy, 3, self.height - 2)
                if self.tiles[y][x].type == Resources.TILE.ocean then
                    self:addIslandPatch(x, y, math.random(2, 6), math.random(2, 5), forestScale, rockScale, animalScale)
                end
            end
        end
    end
end

function World:addShallowWater(depth)
    depth = math.max(1, depth or 3)
    local shallow = {}
    for y = 1, self.height do
        for x = 1, self.width do
            local tile = self.tiles[y][x]
            if tile.type == Resources.TILE.ocean then
                local coastal = false
                for yy = math.max(1, y - depth), math.min(self.height, y + depth) do
                    for xx = math.max(1, x - depth), math.min(self.width, x + depth) do
                        local dx = xx - x
                        local dy = yy - y
                        local d2 = dx * dx + dy * dy
                        local other = self.tiles[yy][xx]
                        if d2 <= depth * depth and self:isLandType(other) then
                            local d = math.sqrt(d2)
                            local irregular = love.math.noise((x + self.seed) * 0.18, (y - self.seed) * 0.18)
                            if d <= 1.5 or irregular > 0.30 + d * 0.11 then
                                coastal = true
                                break
                            end
                        end
                    end
                    if coastal then
                        break
                    end
                end
                if coastal then
                    shallow[#shallow + 1] = { x = x, y = y }
                end
            end
        end
    end

    for _, pos in ipairs(shallow) do
        self:replaceTile(pos.x, pos.y, Resources.TILE.shallowWater)
    end
end

function World:randomLandTile()
    for _ = 1, 900 do
        local x = math.random(2, self.width - 1)
        local y = math.random(2, self.height - 1)
        local tile = self.tiles[y][x]
        if self:isLandType(tile) and tile.type ~= Resources.TILE.rock then
            return x, y
        end
    end
    return nil, nil
end

function World:addLakes(count)
    for _ = 1, count do
        local cx, cy = self:randomLandTile()
        if cx then
            local rx = math.random(1, 4)
            local ry = math.random(1, 3)
            for y = math.max(2, cy - ry), math.min(self.height - 1, cy + ry) do
                for x = math.max(2, cx - rx), math.min(self.width - 1, cx + rx) do
                    local dx = (x - cx) / rx
                    local dy = (y - cy) / ry
                    local ripple = love.math.noise((x + self.seed) * 0.4, (y - self.seed) * 0.4) * 0.35
                    if dx * dx + dy * dy <= 1 + ripple then
                        self:replaceTile(x, y, Resources.TILE.water)
                    end
                end
            end
        end
    end
end

function World:nearestOceanDirection(x, y)
    local left = x
    local right = self.width - x
    local top = y
    local bottom = self.height - y
    local best = math.min(left, right, top, bottom)
    if best == left then
        return 1, math.random(2, self.height - 1)
    elseif best == right then
        return self.width, math.random(2, self.height - 1)
    elseif best == top then
        return math.random(2, self.width - 1), 1
    end
    return math.random(2, self.width - 1), self.height
end

function World:addRivers(count, continents)
    for i = 1, count do
        local continent = continents[((i - 1) % #continents) + 1]
        local sx, sy
        for _ = 1, 80 do
            local angle = math.random() * math.pi * 2
            local radius = math.random() * 0.35
            sx = clamp(math.floor(continent.x + math.cos(angle) * continent.rx * radius), 2, self.width - 1)
            sy = clamp(math.floor(continent.y + math.sin(angle) * continent.ry * radius), 2, self.height - 1)
            if self:isLandType(self.tiles[sy][sx]) then
                break
            end
        end

        local tx, ty = self:nearestOceanDirection(sx, sy)
        local x, y = sx, sy
        local lastDx, lastDy = 0, 0
        for step = 1, self.width + self.height do
            if not self:inBounds(x, y) then
                break
            end
            local tile = self.tiles[y][x]
            if tile.type == Resources.TILE.ocean and step > 3 then
                break
            end
            if tile.type ~= Resources.TILE.ocean then
                self:replaceTile(x, y, Resources.TILE.water)
                if math.random() < 0.28 then
                    local nx = clamp(x + (math.random(0, 1) == 0 and -1 or 1), 1, self.width)
                    self:replaceTile(nx, y, Resources.TILE.water)
                elseif math.random() < 0.28 then
                    local ny = clamp(y + (math.random(0, 1) == 0 and -1 or 1), 1, self.height)
                    self:replaceTile(x, ny, Resources.TILE.water)
                end
            end

            local dx = tx > x and 1 or (tx < x and -1 or 0)
            local dy = ty > y and 1 or (ty < y and -1 or 0)
            local meander = love.math.noise((x + self.seed + i * 17) * 0.16, (y - self.seed) * 0.16)
            if meander < 0.28 then
                dx, dy = -lastDy, lastDx
            elseif meander > 0.72 then
                dx, dy = lastDy, -lastDx
            elseif math.random() < 0.45 then
                if math.abs(tx - x) > math.abs(ty - y) then
                    dy = 0
                else
                    dx = 0
                end
            end
            if dx == 0 and dy == 0 then
                break
            end
            lastDx, lastDy = dx, dy
            x = clamp(x + dx, 1, self.width)
            y = clamp(y + dy, 1, self.height)
        end
    end
end

function World:addBeaches()
    local beaches = {}
    for y = 1, self.height do
        for x = 1, self.width do
            local tile = self.tiles[y][x]
            if tile.type == Resources.TILE.grass or tile.type == Resources.TILE.forest then
                local latitude = math.abs(((y - 0.5) / self.height) - 0.5) * 2
                local nearWater = false
                for yy = math.max(1, y - 3), math.min(self.height, y + 3) do
                    for xx = math.max(1, x - 3), math.min(self.width, x + 3) do
                        local dx = xx - x
                        local dy = yy - y
                        local other = self.tiles[yy][xx]
                        if dx * dx + dy * dy <= 9 and (other.type == Resources.TILE.water or other.type == Resources.TILE.shallowWater or other.type == Resources.TILE.ocean) then
                            local d = math.sqrt(dx * dx + dy * dy)
                            if d <= 1.5 or love.math.noise((x + self.seed) * 0.21, (y - self.seed) * 0.21) > 0.54 + d * 0.08 then
                                nearWater = true
                                break
                            end
                        end
                    end
                    if nearWater then
                        break
                    end
                end
                if nearWater and latitude < 0.84 then
                    beaches[#beaches + 1] = { x = x, y = y }
                end
            end
        end
    end

    for _, pos in ipairs(beaches) do
        self:replaceTile(pos.x, pos.y, Resources.TILE.sand)
    end
end

function World:inBounds(x, y)
    return x >= 1 and y >= 1 and x <= self.width and y <= self.height
end

function World:get(x, y)
    if not self:inBounds(x, y) then
        return nil
    end
    return self.tiles[y][x]
end

function World:isWalkable(x, y)
    local tile = self:get(x, y)
    return tile ~= nil and tile.type ~= Resources.TILE.water and tile.type ~= Resources.TILE.shallowWater and tile.type ~= Resources.TILE.ocean and tile.type ~= Resources.TILE.rock
end

function World:canEnter(x, y, agent)
    local tile = self:get(x, y)
    if not tile or tile.type == Resources.TILE.rock or tile.type == Resources.TILE.ocean then
        return false
    end
    if tile.type ~= Resources.TILE.water and tile.type ~= Resources.TILE.shallowWater then
        return true
    end
    return agent and ((agent.boatDurability or 0) > 0 or (agent.inventory and agent.inventory.wood >= World.BOAT_COST))
end

function World:neighbors(x, y)
    return {
        { x = x + 1, y = y },
        { x = x - 1, y = y },
        { x = x, y = y + 1 },
        { x = x, y = y - 1 }
    }
end

function World:buildTerrainCaches()
    self.waterNearCache = {}
    for y = 1, self.height do
        for x = 1, self.width do
            local hasWater = false
            for yy = math.max(1, y - 9), math.min(self.height, y + 9) do
                for xx = math.max(1, x - 9), math.min(self.width, x + 9) do
                    local dx = xx - x
                    local dy = yy - y
                    if dx * dx + dy * dy <= 81 and self.tiles[yy][xx].type == Resources.TILE.water then
                        hasWater = true
                        break
                    end
                end
                if hasWater then
                    break
                end
            end
            self.waterNearCache[tileKey(self.width, x, y)] = hasWater
        end
    end
end

function World:hasWaterNear(x, y)
    if not self:inBounds(x, y) then
        return false
    end
    return self.waterNearCache[tileKey(self.width, x, y)] == true
end

function World:markIndexDirty(kind)
    self.index = self.index or {
        sectorSize = World.INDEX_SECTOR_SIZE,
        resources = {},
        buildSites = {},
        resourceTick = -9999,
        buildTick = -9999,
        resourceDirty = true,
        buildDirty = true
    }
    if kind == "resources" then
        self.index.resourceDirty = true
    elseif kind == "build" then
        self.index.buildDirty = true
    else
        self.index.resourceDirty = true
        self.index.buildDirty = true
    end
end

function World:rebuildResourceIndex(tick)
    local sectorSize = self.index.sectorSize or World.INDEX_SECTOR_SIZE
    local resources = { food = {}, water = {}, wood = {}, stone = {}, iron = {}, animals = {} }

    for y = 1, self.height do
        for x = 1, self.width do
            local tile = self.tiles[y][x]
            if (tile.food or 0) >= 2 then
                addIndexed(resources.food, x, y, tile, sectorSize)
            end
            if tile.type == Resources.TILE.water then
                addIndexed(resources.water, x, y, tile, sectorSize)
            end
            if (tile.wood or 0) >= 2 then
                addIndexed(resources.wood, x, y, tile, sectorSize)
            end
            if (tile.stone or 0) >= 2 then
                addIndexed(resources.stone, x, y, tile, sectorSize)
            end
            if (tile.iron or 0) >= 2 then
                addIndexed(resources.iron, x, y, tile, sectorSize)
            end
            if (tile.animals or 0) >= 1 then
                addIndexed(resources.animals, x, y, tile, sectorSize)
            end
        end
    end

    self.index.resources = resources
    self.index.resourceTick = tick or 0
    self.index.resourceDirty = false
end

function World:rebuildBuildSiteIndex(tick)
    local sectorSize = self.index.sectorSize or World.INDEX_SECTOR_SIZE
    local sites = { house = {}, farm = {}, paddock = {}, mine = {}, warehouse = {}, shrine = {} }
    local kinds = { "house", "farm", "paddock", "mine", "warehouse", "shrine" }

    for y = 1, self.height do
        for x = 1, self.width do
            for _, kind in ipairs(kinds) do
                if fitsBuildCandidate(self, x, y, kind) then
                    addIndexed(sites[kind], x, y, self.tiles[y][x], sectorSize)
                end
            end
        end
    end

    self.index.buildSites = sites
    self.index.buildTick = tick or 0
    self.index.buildDirty = false
end

function World:ensureResourceIndex(tick)
    tick = tick or 0
    if not self.index or not self.index.resources then
        self:markIndexDirty("resources")
    end
    local stale = tick - (self.index.resourceTick or -9999) >= 12
    if self.index.resourceDirty or stale then
        self:rebuildResourceIndex(tick)
    end
end

function World:ensureBuildSiteIndex(tick)
    tick = tick or 0
    if not self.index or not self.index.buildSites then
        self:markIndexDirty("build")
    end
    local neverBuilt = (self.index.buildTick or -9999) < 0
    local staleDirty = self.index.buildDirty and tick - (self.index.buildTick or -9999) >= 16
    if neverBuilt or staleDirty then
        self:rebuildBuildSiteIndex(tick)
    end
end

function World:nearestIndexed(list, sx, sy, radius, validator)
    local sectorSize = self.index.sectorSize or World.INDEX_SECTOR_SIZE
    local minSx = math.floor((sx - radius - 1) / sectorSize)
    local maxSx = math.floor((sx + radius - 1) / sectorSize)
    local minSy = math.floor((sy - radius - 1) / sectorSize)
    local maxSy = math.floor((sy + radius - 1) / sectorSize)
    local best
    local bestD = math.huge
    local r2 = radius * radius

    for cy = minSy, maxSy do
        for cx = minSx, maxSx do
            local bucket = list and list[cx .. ":" .. cy]
            if bucket then
                for _, entry in ipairs(bucket) do
                    local dx = entry.x - sx
                    local dy = entry.y - sy
                    local d = dx * dx + dy * dy
                    if d <= r2 and d < bestD and validator(entry) then
                        best = entry
                        bestD = d
                    end
                end
            end
        end
    end

    if best then
        return { x = best.x, y = best.y, tile = self.tiles[best.y][best.x], distance = math.sqrt(bestD) }
    end
    return nil
end

function World:nearestResourceIndexed(sx, sy, resource, radius, tick)
    radius = radius or 20
    self:ensureResourceIndex(tick)

    local target = self:nearestIndexed(self.index.resources[resource], sx, sy, radius, function(entry)
        return tileHasResource(self.tiles[entry.y][entry.x], resource)
    end)
    if target then
        target.resource = resource
        return target
    end

    if resource == "food" then
        target = self:nearestIndexed(self.index.resources.animals, sx, sy, math.min(radius, 14), function(entry)
            return tileHasResource(self.tiles[entry.y][entry.x], "animals")
        end)
        if target then
            target.resource = "animals"
            return target
        end
    end

    if self.index.resourceDirty then
        self:rebuildResourceIndex(tick)
        return self:nearestResourceIndexed(sx, sy, resource, radius, tick)
    end
    return nil
end

function World:nearestBuildSiteIndexed(sx, sy, kind, communityId, tick)
    self:ensureBuildSiteIndex(tick)
    local radius = kind == "mine" and 14 or 10
    return self:nearestIndexed(self.index.buildSites[kind], sx, sy, radius, function(entry)
        return fitsBuildCandidate(self, entry.x, entry.y, kind)
    end)
end

function World:findNearest(sx, sy, predicate, radius)
    radius = radius or 12
    local best
    local bestD = math.huge

    for y = math.max(1, sy - radius), math.min(self.height, sy + radius) do
        for x = math.max(1, sx - radius), math.min(self.width, sx + radius) do
            local tile = self.tiles[y][x]
            if predicate(tile, x, y) then
                local d = dist2(sx, sy, x, y)
                if d < bestD then
                    bestD = d
                    best = { x = x, y = y, tile = tile, distance = math.sqrt(d) }
                end
            end
        end
    end

    return best
end

function World:findPath(sx, sy, tx, ty, agent, radius)
    sx, sy, tx, ty = math.floor(sx), math.floor(sy), math.floor(tx), math.floor(ty)
    if not self:inBounds(sx, sy) or not self:inBounds(tx, ty) then
        return nil
    end
    if sx == tx and sy == ty then
        return {}
    end

    radius = radius or 36
    local minX = math.max(1, math.min(sx, tx) - radius)
    local maxX = math.min(self.width, math.max(sx, tx) + radius)
    local minY = math.max(1, math.min(sy, ty) - radius)
    local maxY = math.min(self.height, math.max(sy, ty) + radius)
    local width = self.width
    local startKey = tileKey(width, sx, sy)
    local targetKey = tileKey(width, tx, ty)
    local queueX = { sx }
    local queueY = { sy }
    local queueK = { startKey }
    local head = 1
    local tail = 1
    local cameFrom = { [startKey] = 0 }

    local maxVisited = math.min(9000, (maxX - minX + 1) * (maxY - minY + 1))
    while head <= tail and tail < maxVisited do
        local cx = queueX[head]
        local cy = queueY[head]
        local currentKey = queueK[head]
        head = head + 1

        for i = 1, 4 do
            local nx = cx + DIRS[i][1]
            local ny = cy + DIRS[i][2]
            if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY and self:canEnter(nx, ny, agent) then
                local key = tileKey(width, nx, ny)
                if cameFrom[key] == nil then
                    cameFrom[key] = currentKey
                    if key == targetKey then
                        local path = {}
                        local trace = key
                        while trace and trace ~= startKey do
                            path[#path + 1] = {
                                x = ((trace - 1) % width) + 1,
                                y = math.floor((trace - 1) / width) + 1
                            }
                            trace = cameFrom[trace]
                        end
                        local ordered = {}
                        for i = #path, 1, -1 do
                            ordered[#ordered + 1] = path[i]
                        end
                        return ordered
                    end
                    tail = tail + 1
                    queueX[tail] = nx
                    queueY[tail] = ny
                    queueK[tail] = key
                end
            end
        end
    end

    return nil
end

function World:findRandomWalkable()
    for _ = 1, 600 do
        local x = math.random(1, self.width)
        local y = math.random(1, self.height)
        if self:isWalkable(x, y) then
            return x, y
        end
    end
    return 2, 2
end

function World:findWalkableNear(cx, cy, radius)
    radius = radius or 8
    local candidates = {}
    for y = math.max(1, cy - radius), math.min(self.height, cy + radius) do
        for x = math.max(1, cx - radius), math.min(self.width, cx + radius) do
            if self:isWalkable(x, y) then
                local d = math.abs(cx - x) + math.abs(cy - y)
                local tile = self.tiles[y][x]
                local score = -d + (tile.type == Resources.TILE.grass and 4 or 0) + (tile.type == Resources.TILE.forest and 2 or 0)
                if score > -radius * 1.8 then
                    candidates[#candidates + 1] = { x = x, y = y, score = score }
                end
            end
        end
    end
    if #candidates > 0 then
        table.sort(candidates, function(a, b)
            return a.score > b.score
        end)
        local index = math.random(1, math.min(#candidates, 18))
        return candidates[index].x, candidates[index].y
    end
    return nil, nil
end

function World:findSettlementSpawn()
    local best
    local bestScore = -math.huge
    for _ = 1, 900 do
        local x = math.random(1, self.width)
        local y = math.random(1, self.height)
        if self:isWalkable(x, y) then
            local tile = self.tiles[y][x]
            local pressure = self:resourcePressureAround(x, y, 7)
            local score = pressure.food * 0.45 + pressure.wood * 0.16 + pressure.stone * 0.08 + pressure.water * 12
            score = score + (tile.type == Resources.TILE.grass and 10 or 0) + (tile.type == Resources.TILE.forest and 4 or 0)
            score = score - (tile.type == Resources.TILE.snow and 18 or 0) - (tile.type == Resources.TILE.sand and 6 or 0)
            if pressure.water > 0 and score > bestScore then
                best = { x = x, y = y }
                bestScore = score
            end
        end
    end
    if best then
        return best.x, best.y
    end
    return self:findRandomWalkable()
end

function World:gather(x, y, resource, amount)
    local tile = self:get(x, y)
    if not tile then
        return 0
    end

    local available = tile[resource] or 0
    local taken = math.min(amount, available)
    tile[resource] = available - taken
    return taken
end

function World:drinkableNear(x, y)
    return self:findNearest(x, y, function(tile)
        return tile.type == Resources.TILE.water
    end, 18)
end

function World:resourcePressureAround(x, y, radius)
    local food = 0
    local water = 0
    local wood = 0
    local stone = 0
    local iron = 0
    local animals = 0

    for yy = math.max(1, y - radius), math.min(self.height, y + radius) do
        for xx = math.max(1, x - radius), math.min(self.width, x + radius) do
            local tile = self.tiles[yy][xx]
            food = food + (tile.food or 0)
            wood = wood + (tile.wood or 0)
            stone = stone + (tile.stone or 0)
            iron = iron + (tile.iron or 0)
            animals = animals + (tile.animals or 0)
            if tile.type == Resources.TILE.water then
                water = water + 1
            end
        end
    end

    return { food = food, water = water, wood = wood, stone = stone, iron = iron, animals = animals }
end

function World:comfortAt(x, y)
    if not self:inBounds(x, y) then
        return 0
    end
    return self.comfortCache[tileKey(self.width, x, y)] or 0
end

function World:nearForeignHouse(x, y, communityId)
    if not communityId or not self:inBounds(x, y) then
        return false
    end
    local owner = self.foreignHouseCache[tileKey(self.width, x, y)]
    return owner ~= nil and owner ~= communityId
end

function World:rebuildInfluenceCaches()
    self.comfortCache = {}
    self.foreignHouseCache = {}
    for _, building in ipairs(self.buildings) do
        if building.active ~= false then
            local comfortRadius = 0
            local comfortScale = 0
            if building.type == "house" then
                comfortRadius = 5
                comfortScale = 2.2
            elseif building.type == "farm" then
                comfortRadius = 5
                comfortScale = 0.6
            elseif building.type == "paddock" then
                comfortRadius = 5
                comfortScale = 0.7
            elseif building.type == "warehouse" then
                comfortRadius = 6
                comfortScale = 1.0
            elseif building.type == "shrine" then
                comfortRadius = 6
                comfortScale = 1.2
            end

            if comfortRadius > 0 then
                for yy = math.max(1, building.y - comfortRadius), math.min(self.height, building.y + comfortRadius) do
                    for xx = math.max(1, building.x - comfortRadius), math.min(self.width, building.x + comfortRadius) do
                        local d = math.sqrt(dist2(xx, yy, building.x, building.y))
                        if d <= comfortRadius then
                            local key = tileKey(self.width, xx, yy)
                            self.comfortCache[key] = (self.comfortCache[key] or 0) + (comfortRadius - d) * comfortScale
                        end
                    end
                end
            end

            if building.type == "house" and building.communityId then
                local radius = 8
                for yy = math.max(1, building.y - radius), math.min(self.height, building.y + radius) do
                    for xx = math.max(1, building.x - radius), math.min(self.width, building.x + radius) do
                        local dx = xx - building.x
                        local dy = yy - building.y
                        if dx * dx + dy * dy <= radius * radius then
                            local key = tileKey(self.width, xx, yy)
                            local current = self.foreignHouseCache[key]
                            if current == nil then
                                self.foreignHouseCache[key] = building.communityId
                            elseif current ~= building.communityId then
                                self.foreignHouseCache[key] = 0
                            end
                        end
                    end
                end
            end
        end
    end
end

function World:update(recountNow, growthSteps)
    growthSteps = growthSteps or 1
    for y = 1, self.height do
        for x = 1, self.width do
            Resources.regrow(self.tiles[y][x], growthSteps)
        end
    end
    for _, building in ipairs(self.buildings) do
        if building.active ~= false and building.type == "mine" then
            local tile = self:get(building.x, building.y)
            if tile and tile.type == Resources.TILE.mine and (tile.mineReserve or 0) > 0 then
                local resource = tile.mineResource or building.mineResource or "stone"
                local maxKey = resource == "iron" and "maxIron" or "maxStone"
                local visible = tile[resource] or 0
                local maxVisible = tile[maxKey] or (resource == "iron" and 4 or 8)
                if visible < maxVisible then
                    local produced = math.min(tile.mineReserve, (resource == "iron" and 0.11 or 0.18) * growthSteps, maxVisible - visible)
                    tile[resource] = visible + produced
                    tile.mineReserve = tile.mineReserve - produced
                end
            end
        end
    end
    if recountNow ~= false then
        self:recount()
    end
end

function World:recount()
    local totals = { food = 0, wood = 0, stone = 0, iron = 0, animals = 0, farms = 0, paddocks = 0, mines = 0, houses = 0, warehouses = 0, shrines = 0 }
    for y = 1, self.height do
        for x = 1, self.width do
            local tile = self.tiles[y][x]
            totals.food = totals.food + (tile.food or 0)
            totals.wood = totals.wood + (tile.wood or 0)
            totals.stone = totals.stone + (tile.stone or 0)
            totals.iron = totals.iron + (tile.iron or 0)
            totals.animals = totals.animals + (tile.animals or 0)
            if tile.type == Resources.TILE.farm then
                totals.farms = totals.farms + 1
            elseif tile.type == Resources.TILE.paddock then
                totals.paddocks = totals.paddocks + 1
            elseif tile.type == Resources.TILE.mine then
                totals.mines = totals.mines + 1
            elseif tile.type == Resources.TILE.house then
                totals.houses = totals.houses + 1
            end
        end
    end
    for _, building in ipairs(self.buildings) do
        if building.active ~= false and building.type == "warehouse" then
            totals.warehouses = totals.warehouses + 1
        elseif building.active ~= false and building.type == "shrine" then
            totals.shrines = totals.shrines + 1
        end
    end
    self.totals = totals
end

local function drawCommunityBand(community, px, py, w)
    if community then
        love.graphics.setColor(community.color)
        love.graphics.rectangle("fill", px + 8, py + 52, w - 16, 4)
    end
end

local function drawWarehouseBuilding(building, community, size)
    local px = (building.x - 1) * size
    local py = (building.y - 1) * size
    local w = (building.width or 2) * size
    local h = (building.height or 2) * size

    if Sprites.drawLargeStructure("warehouse", px, py) then
        drawCommunityBand(community, px, py, w)
        return
    end

    love.graphics.setColor(0.18, 0.12, 0.08)
    love.graphics.rectangle("fill", px + 5, py + 18, w - 10, h - 23)
    love.graphics.setColor(0.45, 0.30, 0.18)
    love.graphics.rectangle("fill", px + 9, py + 23, w - 18, h - 31)
    love.graphics.setColor(0.30, 0.18, 0.10)
    love.graphics.polygon("fill", px + 2, py + 20, px + w * 0.5, py + 4, px + w - 2, py + 20)
    love.graphics.setColor(0.62, 0.42, 0.23)
    love.graphics.polygon("fill", px + 8, py + 19, px + w * 0.5, py + 9, px + w - 8, py + 19)

    love.graphics.setColor(0.23, 0.14, 0.08)
    love.graphics.rectangle("fill", px + 25, py + 35, 14, 20)
    love.graphics.setColor(0.68, 0.48, 0.27)
    for i = 0, 3 do
        love.graphics.line(px + 12 + i * 10, py + 27, px + 12 + i * 10, py + 49)
    end
    love.graphics.setColor(0.76, 0.58, 0.33)
    love.graphics.rectangle("fill", px + 12, py + 42, 11, 9)
    love.graphics.rectangle("fill", px + 42, py + 40, 10, 11)
    love.graphics.rectangle("fill", px + 43, py + 28, 9, 8)
    love.graphics.setColor(0.22, 0.13, 0.08, 0.85)
    love.graphics.rectangle("line", px + 12, py + 42, 11, 9)
    love.graphics.rectangle("line", px + 42, py + 40, 10, 11)
    love.graphics.rectangle("line", px + 43, py + 28, 9, 8)

    drawCommunityBand(community, px, py, w)
end

local function drawShrineBuilding(building, community, size)
    local px = (building.x - 1) * size
    local py = (building.y - 1) * size
    local w = (building.width or 2) * size
    local h = (building.height or 2) * size

    if Sprites.drawLargeStructure("shrine", px, py) then
        drawCommunityBand(community, px, py, w)
        return
    end

    love.graphics.setColor(0.18, 0.17, 0.24)
    love.graphics.rectangle("fill", px + 8, py + 47, w - 16, 10)
    love.graphics.setColor(0.44, 0.42, 0.56)
    love.graphics.rectangle("fill", px + 12, py + 39, w - 24, 8)
    love.graphics.setColor(0.24, 0.22, 0.34)
    love.graphics.polygon("fill", px + 5, py + 22, px + w * 0.5, py + 6, px + w - 5, py + 22)
    love.graphics.setColor(0.66, 0.62, 0.82)
    love.graphics.polygon("fill", px + 12, py + 21, px + w * 0.5, py + 11, px + w - 12, py + 21)

    love.graphics.setColor(0.58, 0.56, 0.72)
    for i = 0, 3 do
        local cx = px + 16 + i * 11
        love.graphics.rectangle("fill", cx, py + 24, 5, 23)
        love.graphics.setColor(0.34, 0.32, 0.46)
        love.graphics.rectangle("fill", cx - 2, py + 23, 9, 3)
        love.graphics.rectangle("fill", cx - 2, py + 46, 9, 3)
        love.graphics.setColor(0.58, 0.56, 0.72)
    end

    love.graphics.setColor(0.92, 0.84, 0.42, 0.9)
    love.graphics.circle("fill", px + w * 0.5, py + 32, 6)
    love.graphics.setColor(1.0, 0.94, 0.62, 0.35)
    love.graphics.circle("fill", px + w * 0.5, py + 32, 12)
    love.graphics.setColor(0.18, 0.16, 0.24)
    love.graphics.rectangle("line", px + 8, py + 47, w - 16, 10)

    drawCommunityBand(community, px, py, w)
end

function World:drawLargeBuildings(communities, minX, minY, maxX, maxY)
    local size = World.TILE_SIZE
    for _, building in ipairs(self.buildings) do
        if building.active ~= false and (building.type == "warehouse" or building.type == "shrine") then
            local bx2 = building.x + (building.width or 1) - 1
            local by2 = building.y + (building.height or 1) - 1
            if bx2 >= minX and building.x <= maxX and by2 >= minY and building.y <= maxY then
                local community = building.communityId and communities and communities[building.communityId]
                if building.type == "warehouse" then
                    drawWarehouseBuilding(building, community, size)
                else
                    drawShrineBuilding(building, community, size)
                end

                if (building.health or 0) < (building.maxHealth or 1) then
                    local px = (building.x - 1) * size
                    local py = (building.y - 1) * size
                    local w = (building.width or 2) * size
                    local ratio = math.max(0, (building.health or 0) / (building.maxHealth or 1))
                    love.graphics.setColor(0.18, 0.02, 0.02, 0.82)
                    love.graphics.rectangle("fill", px + 8, py + 3, w - 16, 4)
                    love.graphics.setColor(0.95, 0.18, 0.12, 0.92)
                    love.graphics.rectangle("fill", px + 8, py + 3, (w - 16) * ratio, 4)
                end
            end
        end
    end
    love.graphics.setLineWidth(1)
end

function World:draw(communities, claims, claimEdges, camera)
    local size = World.TILE_SIZE
    local minX, minY, maxX, maxY = 1, 1, self.width, self.height
    local lowDetail = false
    if camera and love and love.graphics then
        local ww, wh = love.graphics.getDimensions()
        local panelH = 146
        local viewW = ww / camera.zoom
        local viewH = (wh - panelH) / camera.zoom
        minX = math.max(1, math.floor(camera.x / size) + 1)
        minY = math.max(1, math.floor(camera.y / size) + 1)
        maxX = math.min(self.width, math.ceil((camera.x + viewW) / size) + 1)
        maxY = math.min(self.height, math.ceil((camera.y + viewH) / size) + 1)
        lowDetail = camera.zoom < 0.34
    end

    for y = minY, maxY do
        for x = minX, maxX do
            local tile = self.tiles[y][x]
            local color = Resources.colors[tile.type]
            local px = (x - 1) * size
            local py = (y - 1) * size
            love.graphics.setColor(color)
            love.graphics.rectangle("fill", px, py, size, size)

            if not lowDetail then
                if tile.type == Resources.TILE.forest and tile.wood > 4 then
                    love.graphics.setColor(1, 1, 1)
                    Sprites.drawResource("tree", px, py, 2)
                elseif tile.type == Resources.TILE.forest then
                    love.graphics.setColor(1, 1, 1)
                    Sprites.drawResource("stump", px, py, 2)
                elseif tile.type == Resources.TILE.rock then
                    love.graphics.setColor(0.23, 0.23, 0.25)
                    Sprites.drawResource(tile.stone > 3 and "rock" or "rubble", px, py, 2)
                    if (tile.iron or 0) > 1 then
                        Sprites.drawResource("iron", px + 8, py + 10, 1)
                    end
                elseif tile.type == Resources.TILE.mine then
                    Sprites.drawBuilding((tile.mineResource or "stone") == "iron" and "mineIron" or "mineStone", px, py)
                elseif tile.type == Resources.TILE.farm then
                    Sprites.drawBuilding(tile.food > tile.maxFood * 0.45 and "farmFull" or "farmEmpty", px, py)
                elseif tile.type == Resources.TILE.paddock then
                    Sprites.drawBuilding("paddock", px, py)
                elseif tile.type == Resources.TILE.house then
                    Sprites.drawBuilding("house", px, py)
                    local building = tile.building
                    local community = building and building.active ~= false and building.communityId and communities and communities[building.communityId]
                    if building and (building.abandonedTicks or 0) > 40 then
                        love.graphics.setColor(1, 1, 1)
                        Sprites.drawResource("abandoned", px, py, 2)
                    end
                    if community then
                        love.graphics.setColor(community.color)
                        love.graphics.rectangle("fill", px + 7, py + 24, 18, 3)
                        love.graphics.rectangle("fill", px + 14, py + 14, 4, 8)
                    end
                elseif tile.type == Resources.TILE.warehouse or tile.type == Resources.TILE.shrine then
                    -- 2x2 structures are drawn once in a building pass below.
                elseif tile.food and tile.food > 7 and tile.type == Resources.TILE.grass then
                    love.graphics.setColor(1, 1, 1)
                    Sprites.drawResource("berries", px, py, 2)
                elseif (tile.animals or 0) > 1 and (tile.type == Resources.TILE.grass or tile.type == Resources.TILE.forest) then
                    Sprites.drawResource("animal", px + 8, py + 12, 1)
                elseif tile.type == Resources.TILE.water then
                    love.graphics.setColor(1, 1, 1)
                    Sprites.drawResource("water", px, py, 2)
                end

                if tile.building and tile.building.active ~= false and tile.building.width == 1 and (tile.building.health or 0) < (tile.building.maxHealth or 1) then
                    local ratio = math.max(0, (tile.building.health or 0) / (tile.building.maxHealth or 1))
                    love.graphics.setColor(0.18, 0.02, 0.02, 0.82)
                    love.graphics.rectangle("fill", px + 5, py + 4, 22, 3)
                    love.graphics.setColor(0.95, 0.18, 0.12, 0.92)
                    love.graphics.rectangle("fill", px + 5, py + 4, 22 * ratio, 3)
                end
            end
        end
    end

    if not lowDetail then
        self:drawLargeBuildings(communities, minX, minY, maxX, maxY)
    end

    if claims and communities then
        for _, claim in pairs(claims) do
            local x = claim.x
            local y = claim.y
            local community = communities[claim.communityId]
            if community and x >= minX and x <= maxX and y >= minY and y <= maxY then
                love.graphics.setColor(community.color[1], community.color[2], community.color[3], 0.14)
                love.graphics.rectangle("fill", (x - 1) * size, (y - 1) * size, size, size)
            end
        end

        love.graphics.setLineWidth(4)
        local minPx = (minX - 1) * size
        local minPy = (minY - 1) * size
        local maxPx = maxX * size
        local maxPy = maxY * size
        for _, edge in ipairs(claimEdges or {}) do
            local community = communities[edge.communityId]
            if community
                and math.max(edge.x1, edge.x2) >= minPx
                and math.min(edge.x1, edge.x2) <= maxPx
                and math.max(edge.y1, edge.y2) >= minPy
                and math.min(edge.y1, edge.y2) <= maxPy then
                love.graphics.setColor(community.color[1], community.color[2], community.color[3], 0.9)
                love.graphics.line(edge.x1, edge.y1, edge.x2, edge.y2)
            end
        end
        love.graphics.setLineWidth(1)
    end

    if not lowDetail and (not camera or camera.zoom >= 0.45) then
        love.graphics.setColor(0, 0, 0, 0.18)
        for x = minX - 1, maxX do
            love.graphics.line(x * size, (minY - 1) * size, x * size, maxY * size)
        end
        for y = minY - 1, maxY do
            love.graphics.line((minX - 1) * size, y * size, maxX * size, y * size)
        end
    end
end

return World
