local Agent = require("src.entities.agent")
local Community = require("src.entities.community")
local World = require("src.world")

local Simulation = {}
Simulation.__index = Simulation

local CELL = 6
local MIN_ZOOM = 0.18
local PROJECT_DURATION = math.random(40, 80)
local PROJECT_CHECK_INTERVAL = 6

local function cellKey(x, y)
    return math.floor((x - 1) / CELL) .. ":" .. math.floor((y - 1) / CELL)
end

function Simulation.new(config)
    config = config or {}
    local self = setmetatable({
        world = World.new(config.width or 160, config.height or 100, config.seed or os.time(), config.world or {}),
        agents = {},
        nextId = 1,
        tick = 0,
        tickStep = config.tickStep or 0.18,
        accumulator = 0,
        populationCap = config.populationCap or 230,
        spatial = {},
        communities = {},
        nextCommunityId = 1,
        claims = {},
        claimEdges = {},
        borderPairs = {},
        buildingsByType = {},
        selectedCommunityId = nil,
        camera = {
            x = 0,
            y = 0,
            zoom = 0.55,
            dragging = false,
            lastX = 0,
            lastY = 0
        },
        stats = {
            births = 0,
            deaths = 0,
            foundings = 0,
            migrations = 0,
            claims = 0,
            actions = {}
        }
    }, Simulation)

    local initialAgents = config.initialAgents or 80
    local spawnClusters = math.max(4, math.min(16, math.floor(initialAgents / 12)))
    local anchors = {}
    for i = 1, spawnClusters do
        local x, y = self.world:findSettlementSpawn()
        anchors[i] = { x = x, y = y }
    end

    local occupied = {}
    for i = 1, initialAgents do
        local anchor = anchors[((i - 1) % #anchors) + 1]
        local x, y
        for _ = 1, 18 do
            x, y = self.world:findWalkableNear(anchor.x, anchor.y, 12)
            if x and not occupied[x .. ":" .. y] then
                break
            end
        end
        if not x then
            x, y = self.world:findRandomWalkable()
        end
        occupied[x .. ":" .. y] = true
        self:addAgent(x, y, true)
    end
    self:rebuildSpatial()
    self:rebuildBuildingLists()
    self:assignHomes()
    self:updateProsperity()
    self:updateClaims()
    self.world:rebuildInfluenceCaches()
    self:updateDiplomacy()
    self:updateCommunityProjects(true)
    self:centerCamera()
    return self
end

function Simulation:centerCamera()
    local ww, wh = love.graphics.getDimensions()
    local panelH = 146
    local mapW = self.world.width * World.TILE_SIZE
    local mapH = self.world.height * World.TILE_SIZE
    self.camera.zoom = math.min(0.9, math.max(MIN_ZOOM, math.min(ww / mapW, (wh - panelH) / mapH)))
    self.camera.x = math.max(0, (mapW - ww / self.camera.zoom) * 0.5)
    self.camera.y = math.max(0, (mapH - (wh - panelH) / self.camera.zoom) * 0.5)
end

function Simulation:clampCamera()
    local ww, wh = love.graphics.getDimensions()
    local panelH = 146
    local mapW = self.world.width * World.TILE_SIZE
    local mapH = self.world.height * World.TILE_SIZE
    local viewW = ww / self.camera.zoom
    local viewH = (wh - panelH) / self.camera.zoom
    self.camera.x = math.max(0, math.min(math.max(0, mapW - viewW), self.camera.x))
    self.camera.y = math.max(0, math.min(math.max(0, mapH - viewH), self.camera.y))
end

function Simulation:updateCamera(dt)
    local speed = 520 / self.camera.zoom
    if love.keyboard.isDown("left") or love.keyboard.isDown("a") then
        self.camera.x = self.camera.x - speed * dt
    end
    if love.keyboard.isDown("right") or love.keyboard.isDown("d") then
        self.camera.x = self.camera.x + speed * dt
    end
    if love.keyboard.isDown("up") or love.keyboard.isDown("w") then
        self.camera.y = self.camera.y - speed * dt
    end
    if love.keyboard.isDown("down") or love.keyboard.isDown("s") then
        self.camera.y = self.camera.y + speed * dt
    end
    self:clampCamera()
end

function Simulation:zoomAt(amount, sx, sy)
    local oldZoom = self.camera.zoom
    local newZoom = math.max(MIN_ZOOM, math.min(2.8, oldZoom * (amount > 0 and 1.18 or 1 / 1.18)))
    if newZoom == oldZoom then
        return
    end

    local wx = self.camera.x + sx / oldZoom
    local wy = self.camera.y + sy / oldZoom
    self.camera.zoom = newZoom
    self.camera.x = wx - sx / newZoom
    self.camera.y = wy - sy / newZoom
    self:clampCamera()
end

function Simulation:mousepressed(x, y, button)
    if button == 1 then
        self:selectCommunityAtScreen(x, y)
    elseif button == 2 or button == 3 then
        self.camera.dragging = true
        self.camera.lastX = x
        self.camera.lastY = y
    end
end

function Simulation:mousereleased(_, _, button)
    if button == 2 or button == 3 then
        self.camera.dragging = false
    end
end

function Simulation:mousemoved(x, y, dx, dy)
    if self.camera.dragging then
        self.camera.x = self.camera.x - dx / self.camera.zoom
        self.camera.y = self.camera.y - dy / self.camera.zoom
        self:clampCamera()
    end
end

function Simulation:screenToTile(x, y)
    local worldX = self.camera.x + x / self.camera.zoom
    local worldY = self.camera.y + y / self.camera.zoom
    return math.floor(worldX / World.TILE_SIZE) + 1, math.floor(worldY / World.TILE_SIZE) + 1
end

function Simulation:selectCommunityAtScreen(x, y)
    local _, wh = love.graphics.getDimensions()
    if y > wh - 146 then
        return
    end
    local tx, ty = self:screenToTile(x, y)
    local claim = self.claims[self:claimKey(tx, ty)]
    self.selectedCommunityId = claim and claim.communityId or nil
end

function Simulation:addAgent(x, y, initial)
    local agent = Agent.new(self.nextId, x, y)
    self.nextId = self.nextId + 1
    self.agents[#self.agents + 1] = agent
    if not initial then
        self.stats.births = self.stats.births + 1
    end
    return agent
end

function Simulation:getBuilding(id)
    if not id then
        return nil
    end
    return self.world.buildings[id]
end

function Simulation:rebuildBuildingLists()
    self.buildingsByType = { house = {}, farm = {}, paddock = {}, mine = {}, warehouse = {}, shrine = {} }
    for _, building in ipairs(self.world.buildings) do
        if building.active ~= false then
            local list = self.buildingsByType[building.type]
            if list then
                list[#list + 1] = building
            end
        end
    end
end

function Simulation:activeBuildings(kind)
    return self.buildingsByType[kind] or {}
end

function Simulation:nearestHouse(x, y, communityId, requireSpace)
    local best
    local bestD = math.huge
    for _, building in ipairs(self:activeBuildings("house")) do
        if building.active ~= false
            and (not communityId or building.communityId == communityId)
            and (not requireSpace or (building.occupants or 0) < (building.capacity or 4)) then
            local dx = building.x - x
            local dy = building.y - y
            local d = dx * dx + dy * dy
            if d < bestD then
                best = building
                bestD = d
            end
        end
    end
    return best
end

function Simulation:nearestBuilding(x, y, kind, communityId)
    local best
    local bestD = math.huge
    for _, building in ipairs(self:activeBuildings(kind)) do
        if building.active ~= false
            and (not communityId or building.communityId == communityId) then
            local dx = building.x - x
            local dy = building.y - y
            local d = dx * dx + dy * dy
            if d < bestD then
                best = building
                bestD = d
            end
        end
    end
    return best
end

function Simulation:canAccessWarehouse(agent)
    if not agent or not agent.communityId then
        return false
    end
    local warehouse = self:nearestBuilding(agent.x, agent.y, "warehouse", agent.communityId)
    if not warehouse then
        return false
    end
    local minX = warehouse.x
    local minY = warehouse.y
    local maxX = warehouse.x + (warehouse.width or 1) - 1
    local maxY = warehouse.y + (warehouse.height or 1) - 1
    local dx = 0
    if agent.x < minX then
        dx = minX - agent.x
    elseif agent.x > maxX then
        dx = agent.x - maxX
    end
    local dy = 0
    if agent.y < minY then
        dy = minY - agent.y
    elseif agent.y > maxY then
        dy = agent.y - maxY
    end
    return dx * dx + dy * dy <= 2
end

function Simulation:depositCommunityResources(agent)
    local community = agent and agent.communityId and self.communities[agent.communityId]
    if not community or not community.hasWarehouse or not community.store or not self:canAccessWarehouse(agent) then
        return 0
    end

    local moved = 0
    for _, resource in ipairs({ "food", "wood", "stone", "iron", "animals" }) do
        local amount = agent.inventory[resource] or 0
        if amount > 0 then
            community.store[resource] = (community.store[resource] or 0) + amount
            agent.inventory[resource] = 0
            moved = moved + amount
        end
    end
    return moved
end

function Simulation:assignHomes()
    for _, building in ipairs(self.world.buildings) do
        if building.type == "house" and building.active ~= false then
            building.occupants = 0
            building.residents = {}
        end
    end

    for _, agent in ipairs(self.agents) do
        agent.homeId = nil
        agent.homeX = nil
        agent.homeY = nil
    end

    local byId = {}
    for _, agent in ipairs(self.agents) do
        if agent.alive then
            byId[agent.id] = agent
        end
    end

    local function place(agent, building)
        if not agent or not building or building.type ~= "house" then
            return false
        end
        if building.communityId and agent.communityId and building.communityId ~= agent.communityId then
            return false
        end
        if (building.occupants or 0) >= (building.capacity or 4) then
            return false
        end
        building.occupants = (building.occupants or 0) + 1
        building.residents[#building.residents + 1] = agent.id
        agent.homeId = building.id
        agent.homeX = building.x
        agent.homeY = building.y
        if building.owner == agent.id then
            agent.ownHouseId = building.id
        end
        return true
    end

    for _, building in ipairs(self.world.buildings) do
        if building.type == "house" and building.active ~= false then
            place(byId[building.owner], building)
        end
    end

    for _, agent in ipairs(self.agents) do
        if agent.alive and not agent.homeId and (agent.parentA or agent.parentB) then
            local parent = byId[agent.parentA] or byId[agent.parentB]
            place(agent, parent and self:getBuilding(parent.homeId))
        end
    end

    for _, agent in ipairs(self.agents) do
        if agent.alive and not agent.homeId and agent.communityId then
            place(agent, self:nearestHouse(agent.x, agent.y, agent.communityId, true))
        end
    end
end

function Simulation:decayAbandonedHomes()
    local removed = false
    for _, building in ipairs(self.world.buildings) do
        if building.type == "house" and building.active ~= false then
            if (building.occupants or 0) <= 0 then
                building.abandonedTicks = (building.abandonedTicks or 0) + 1
                if building.abandonedTicks > 140 then
                    local tile = self.world:get(building.x, building.y)
                    if tile and tile.building == building then
                        tile.type = "grass"
                        tile.food = 0
                        tile.wood = 0
                        tile.stone = 0
                        tile.iron = 0
                        tile.animals = 0
                        tile.maxFood = 1
                        tile.maxWood = 0
                        tile.maxStone = 0
                        tile.maxIron = 0
                        tile.maxAnimals = 0
                        tile.building = nil
                    end
                    building.active = false
                    removed = true
                end
            else
                building.abandonedTicks = 0
            end
        end
    end
    return removed
end

function Simulation:destroyBuilding(building, attacker)
    if not building or building.active == false then
        return false
    end

    local oldCommunityId = building.communityId
    building.active = false
    for y = building.y, building.y + (building.height or 1) - 1 do
        for x = building.x, building.x + (building.width or 1) - 1 do
            local tile = self.world:get(x, y)
            if tile and tile.building == building then
                tile.type = building.type == "mine" and "rock" or "grass"
                tile.food = building.type == "farm" and 2 or 0
                tile.wood = 0
                tile.stone = building.type == "warehouse" and 2 or 0
                tile.iron = building.type == "warehouse" and 1 or 0
                tile.animals = building.type == "paddock" and 1 or 0
                tile.maxFood = 1
                tile.maxWood = 0
                tile.maxStone = building.type == "mine" and 4 or 0
                tile.maxIron = 0
                tile.maxAnimals = 0
                tile.mineResource = nil
                tile.mineReserve = nil
                tile.building = nil
            end
        end
    end

    for _, agent in ipairs(self.agents) do
        if agent.homeId == building.id then
            agent.homeId = nil
            agent.homeX = nil
            agent.homeY = nil
            agent.stress = math.min(100, agent.stress + 16)
        end
        if agent.ownHouseId == building.id then
            agent.ownHouseId = nil
        end
    end

    if attacker and attacker.communityId and oldCommunityId and attacker.communityId ~= oldCommunityId then
        self:adjustRelation(attacker.communityId, oldCommunityId, building.type == "farm" and -10 or -18)
    end

    self:rebuildBuildingLists()
    self:rebuildClaimsFromBuildings()
    self.world:rebuildInfluenceCaches()
    self.world:markIndexDirty("build")
    Community.recount(self)
    self.world:recount()
    return true
end

function Simulation:cleanupEmptyCommunities()
    local empty = {}
    for id, community in pairs(self.communities) do
        if (community.members or 0) <= 0 then
            empty[#empty + 1] = id
        end
    end
    if #empty == 0 then
        return false
    end

    local emptySet = {}
    for _, id in ipairs(empty) do
        emptySet[id] = true
    end

    local toDestroy = {}
    for _, building in ipairs(self.world.buildings) do
        if building.active ~= false and emptySet[building.communityId] then
            toDestroy[#toDestroy + 1] = building
        end
    end

    for _, building in ipairs(toDestroy) do
        self:destroyBuilding(building, nil)
    end

    for _, agent in ipairs(self.agents) do
        if emptySet[agent.communityId] then
            agent.communityId = nil
            agent.settleX = nil
            agent.settleY = nil
        end
    end

    for _, id in ipairs(empty) do
        self.communities[id] = nil
        for _, community in pairs(self.communities) do
            if community.relations then
                community.relations[id] = nil
            end
        end
    end

    self:rebuildBuildingLists()
    self:rebuildClaimsFromBuildings()
    self.world:rebuildInfluenceCaches()
    self.world:markIndexDirty("build")
    self.world:recount()
    return true
end

function Simulation:updateProsperity()
    for _, agent in ipairs(self.agents) do
        local survival = ((100 - agent.hunger) + (100 - agent.thirst) + agent.energy + agent.health + (100 - agent.stress)) / 5
        local inventory = math.min(100, agent.inventory.food * 6 + (agent.inventory.animals or 0) * 4.4 + agent.inventory.wood * 1.2 + agent.inventory.stone * 1.5 + (agent.inventory.iron or 0) * 2.0)
        local community = agent.communityId and self.communities[agent.communityId]
        if community and community.hasWarehouse and community.store then
            local members = math.max(1, community.members)
            inventory = math.min(100, inventory + (community.store.food * 5 + (community.store.animals or 0) * 4.2 + community.store.wood * 0.9 + community.store.stone * 1.1 + (community.store.iron or 0) * 1.7) / members)
        end
        local housing = agent.homeId and 100 or (agent.communityId and 35 or 0)
        local spiritualPenalty = math.max(0, 45 - (agent.spirituality or 100)) * 0.28
        agent.personalProsperity = math.max(0, math.min(70, survival * 0.46 + inventory * 0.14 + housing * 0.10 - spiritualPenalty))
    end

    Community.recount(self)
    if self:cleanupEmptyCommunities() then
        Community.recount(self)
    end

    for _, agent in ipairs(self.agents) do
        local community = agent.communityId and self.communities[agent.communityId]
        local communityBonus = community and community.prosperityBonus or 0
        agent.communityProsperity = communityBonus
        agent.prosperity = math.max(0, math.min(100, (agent.personalProsperity or 0) + communityBonus))
    end
end

function Simulation:rebuildSpatial()
    self.spatial = {}
    for _, agent in ipairs(self.agents) do
        if agent.alive then
            local key = cellKey(agent.x, agent.y)
            local bucket = self.spatial[key]
            if not bucket then
                bucket = {}
                self.spatial[key] = bucket
            end
            bucket[#bucket + 1] = agent
        end
    end
end

function Simulation:joinCommunity(agent, communityId)
    local oldCommunityId = agent.communityId
    local joined = Community.join(self, agent, communityId)
    if joined then
        if oldCommunityId and oldCommunityId ~= communityId then
            agent.migrationCooldown = 80
        end
        local nearby = self:nearAgents(agent.x, agent.y, 5, agent.id)
        for _, other in ipairs(nearby) do
            if other.communityId == communityId then
                agent.memory:record(other.id, "social", 0.5, self.tick)
                other.memory:record(agent.id, "social", 0.5, self.tick)
            end
        end
    end
    return joined
end

function Simulation:leaveCommunity(agent)
    Community.leave(self, agent)
    agent.migrationCooldown = 80
end

function Simulation:foundCommunityFromWarehouse(agent, building, contributors, parentCommunityId)
    if not agent or not building or building.type ~= "warehouse" then
        return nil
    end
    if building.communityId and self.communities[building.communityId] then
        return building.communityId
    end

    local communityId = Community.create(self, building.x, building.y, agent)
    building.communityId = communityId
    local community = self.communities[communityId]
    community.hasWarehouse = true
    community.warehouses = 1
    community.store = community.store or { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    community.project = { kind = "housing", timer = 0, targetCommunityId = nil }
    community.mood = "housing"
    if parentCommunityId and self.communities[parentCommunityId] then
        community.relations[parentCommunityId] = 72
        self.communities[parentCommunityId].relations[communityId] = 72
    end

    self:joinCommunity(agent, communityId)
    agent.expedition = nil
    local nearby = self:nearAgents(building.x, building.y, 6, agent.id)
    for _, other in ipairs(nearby) do
        local sameExpedition = parentCommunityId
            and other.expedition
            and other.expedition.parentCommunityId == parentCommunityId
        if sameExpedition or not other.communityId then
            self:joinCommunity(other, communityId)
            other.expedition = nil
            agent.memory:record(other.id, "social", 0.8, self.tick)
            other.memory:record(agent.id, "social", 0.8, self.tick)
        end
    end
    for _, other in ipairs(contributors or {}) do
        local sameExpedition = parentCommunityId
            and other.expedition
            and other.expedition.parentCommunityId == parentCommunityId
        if other.alive and (not other.communityId or sameExpedition) then
            self:joinCommunity(other, communityId)
            other.expedition = nil
        end
    end

    return communityId
end

function Simulation:formOrJoinCommunity(agent, target)
    if target and target.alive and target.communityId and target.communityId ~= agent.communityId then
        return self:joinCommunity(agent, target.communityId)
    end

    local communityId = agent.communityId
    if not communityId then
        local nearbyHouse = self:nearestHouse(agent.x, agent.y, nil, false)
        if nearbyHouse and nearbyHouse.communityId then
            local dx = nearbyHouse.x - agent.x
            local dy = nearbyHouse.y - agent.y
            if dx * dx + dy * dy <= 100 then
                return self:joinCommunity(agent, nearbyHouse.communityId)
            end
        end

        local nearby = self:nearAgents(agent.x, agent.y, 8, agent.id)
        local bestCommunity
        local bestScore = -math.huge
        for _, other in ipairs(nearby) do
            local community = other.communityId and self.communities[other.communityId]
            if community then
                local score = agent.memory:trust(other.id) + community.houses * 5 + community.farms * 2 - community.members * 0.8
                if score > bestScore then
                    bestCommunity = community.id
                    bestScore = score
                end
            end
        end
        if bestCommunity and bestScore > -10 then
            return self:joinCommunity(agent, bestCommunity)
        end

        return false
    end

    if target and target.alive and not target.communityId then
        self:joinCommunity(target, communityId)
        agent.memory:record(target.id, "help", 1.2, self.tick)
        target.memory:record(agent.id, "help", 1.2, self.tick)
    end

    local nearby = self:nearAgents(agent.x, agent.y, 4, agent.id)
    for _, other in ipairs(nearby) do
        if not other.communityId and (agent.memory:trust(other.id) > -8 or other.memory:trust(agent.id) > -8) then
            self:joinCommunity(other, communityId)
            agent.memory:record(other.id, "social", 0.7, self.tick)
            other.memory:record(agent.id, "social", 0.7, self.tick)
        end
    end

    Community.recount(self)
    return true
end

function Simulation:migrateAgent(agent, target)
    if target and target.alive and target.communityId and target.communityId ~= agent.communityId and agent.memory:trust(target.id) > -35 then
        return self:joinCommunity(agent, target.communityId)
    end

    local best
    local bestScore = -math.huge
    local nearby = self:nearAgents(agent.x, agent.y, 10, agent.id)
    for _, other in ipairs(nearby) do
        local community = other.communityId and self.communities[other.communityId]
        if community and other.communityId ~= agent.communityId then
            local score = agent.memory:trust(other.id) + community.houses * 6 + community.farms * 4 - community.members
            if score > bestScore then
                best = other
                bestScore = score
            end
        end
    end

    if best and bestScore > -20 then
        return self:joinCommunity(agent, best.communityId)
    end

    if agent.communityId then
        self:leaveCommunity(agent)
        return true
    end

    return false
end

function Simulation:communityCount()
    return Community.count(self)
end

function Simulation:claimKey(x, y)
    return x .. "," .. y
end

local function claimRadiusFor(building)
    if building.type == "warehouse" or building.type == "shrine" then
        return 5
    elseif building.type == "house" then
        return 3
    elseif building.type == "farm" or building.type == "paddock" or building.type == "mine" then
        return 1
    end
    return 0
end

local function claimStrengthFor(building)
    return claimRadiusFor(building) * 10 + ((building.width or 1) * (building.height or 1))
end

function Simulation:refreshClaimVisuals()
    self.claimEdges = {}
    self.borderPairs = {}
    local claimCount = 0
    for _, community in pairs(self.communities) do
        community.claims = {}
    end

    for key, claim in pairs(self.claims) do
        local community = self.communities[claim.communityId]
        if community then
            community.claims[key] = true
            claimCount = claimCount + 1
        end
    end

    local size = World.TILE_SIZE
    local dirs = {
        { dx = 0, dy = -1, x1 = 0, y1 = 0, x2 = 1, y2 = 0 },
        { dx = 1, dy = 0, x1 = 1, y1 = 0, x2 = 1, y2 = 1 },
        { dx = 0, dy = 1, x1 = 0, y1 = 1, x2 = 1, y2 = 1 },
        { dx = -1, dy = 0, x1 = 0, y1 = 0, x2 = 0, y2 = 1 }
    }
    for _, claim in pairs(self.claims) do
        local x = claim.x
        local y = claim.y
        local px = (x - 1) * size
        local py = (y - 1) * size
        for _, edge in ipairs(dirs) do
            local other = self.claims[self:claimKey(x + edge.dx, y + edge.dy)]
            if not other or other.communityId ~= claim.communityId then
                if not other or claim.communityId < other.communityId then
                    self.claimEdges[#self.claimEdges + 1] = {
                        communityId = claim.communityId,
                        x1 = px + edge.x1 * size,
                        y1 = py + edge.y1 * size,
                        x2 = px + edge.x2 * size,
                        y2 = py + edge.y2 * size
                    }
                end
                if other and other.communityId ~= claim.communityId then
                    local a = math.min(claim.communityId, other.communityId)
                    local b = math.max(claim.communityId, other.communityId)
                    local pair = a .. ":" .. b
                    self.borderPairs[pair] = (self.borderPairs[pair] or 0) + 1
                end
            end
        end
    end
    self.stats.claims = claimCount
end

function Simulation:applyStructureClaim(building, causeFriction)
    if not building or building.active == false or not building.communityId then
        return
    end

    local radius = claimRadiusFor(building)
    if radius <= 0 then
        return
    end

    local strength = claimStrengthFor(building)
    local minX = building.x - radius
    local minY = building.y - radius
    local maxX = building.x + (building.width or 1) - 1 + radius
    local maxY = building.y + (building.height or 1) - 1 + radius
    local overlaps = {}

    for y = minY, maxY do
        for x = minX, maxX do
            if self.world:inBounds(x, y) then
                local key = self:claimKey(x, y)
                local existing = self.claims[key]
                if existing and existing.communityId ~= building.communityId then
                    overlaps[existing.communityId] = (overlaps[existing.communityId] or 0) + 1
                end
                if not existing or existing.communityId == building.communityId or strength >= (existing.strength or 0) then
                    self.claims[key] = {
                        communityId = building.communityId,
                        strength = strength,
                        sourceBuildingId = building.id,
                        x = x,
                        y = y
                    }
                end
            end
        end
    end

    if causeFriction then
        for otherId, count in pairs(overlaps) do
            self:adjustRelation(building.communityId, otherId, -math.min(18, 1.5 + count * 0.28))
        end
    end
end

function Simulation:rebuildClaimsFromBuildings()
    self.claims = {}
    for _, building in ipairs(self.world.buildings) do
        self:applyStructureClaim(building, false)
    end
    self:refreshClaimVisuals()
end

function Simulation:updateClaims()
    self:rebuildClaimsFromBuildings()
end

function Simulation:onBuildingBuilt(building)
    self:rebuildBuildingLists()
    self:applyStructureClaim(building, true)
    self:refreshClaimVisuals()
    self.world:rebuildInfluenceCaches()
    self.world:markIndexDirty("build")
    Community.recount(self)
    local community = building.communityId and self.communities[building.communityId]
    if community and community.project then
        community.project.timer = 0
    end
end

function Simulation:relation(a, b)
    if not a or not b or a == b then
        return 100
    end
    local ca = self.communities[a]
    if not ca then
        return 0
    end
    ca.relations[b] = ca.relations[b] or 0
    return ca.relations[b]
end

function Simulation:adjustRelation(a, b, amount)
    if not a or not b or a == b then
        return
    end
    local ca = self.communities[a]
    local cb = self.communities[b]
    if not ca or not cb then
        return
    end
    ca.relations[b] = math.max(-100, math.min(100, (ca.relations[b] or 0) + amount))
    cb.relations[a] = math.max(-100, math.min(100, (cb.relations[a] or 0) + amount))
end

function Simulation:updateDiplomacy()
    for id, community in pairs(self.communities) do
        for otherId, other in pairs(self.communities) do
            if id ~= otherId then
                community.relations[otherId] = community.relations[otherId] or 0
                local dx = community.x - other.x
                local dy = community.y - other.y
                local d2 = dx * dx + dy * dy
                local a = math.min(id, otherId)
                local b = math.max(id, otherId)
                local border = self.borderPairs[a .. ":" .. b] or 0
                local pressure = d2 < 196 and -0.10 or 0.025
                pressure = pressure - math.min(border, 36) * 0.006
                local prosperity = ((community.avgProsperity or 0) + (other.avgProsperity or 0)) > 120 and 0.025 or 0
                community.relations[otherId] = math.max(-100, math.min(100, community.relations[otherId] + pressure + prosperity))
            end
        end
    end
end

function Simulation:chooseWarTarget(community)
    local targetId
    local worst = 0
    for otherId, relation in pairs(community.relations) do
        local other = self.communities[otherId]
        if other and relation < worst then
            worst = relation
            targetId = otherId
        end
    end
    return targetId, worst
end

function Simulation:prepareExplorationProject(community)
    local targetX, targetY
    local bestScore = -math.huge
    for _ = 1, 80 do
        local x, y = self.world:findRandomWalkable()
        local dx = x - community.x
        local dy = y - community.y
        local d2 = dx * dx + dy * dy
        local claim = self.claims[self:claimKey(x, y)]
        if d2 > 420 and (not claim or claim.communityId == community.id) then
            local pressure = self.world:resourcePressureAround(x, y, 7)
            local score = pressure.food + pressure.animals * 2 + pressure.wood * 0.25 + pressure.water * 12 + math.sqrt(d2) * 0.5
            if score > bestScore then
                bestScore = score
                targetX, targetY = x, y
            end
        end
    end

    if not targetX then
        targetX, targetY = self.world:findRandomWalkable()
    end

    local candidates = {}
    for _, agent in ipairs(self.agents) do
        if agent.alive and agent.communityId == community.id and agent.age > 16 and (agent.prosperity or 0) > 42 then
            candidates[#candidates + 1] = agent
        end
    end

    local explorers = {}
    local expeditionId = community.id .. ":" .. tostring(self.tick)
    local count = math.min(#candidates, math.random(2, 4))
    for _ = 1, count do
        local index = math.random(1, #candidates)
        local agent = table.remove(candidates, index)
        if agent then
            explorers[agent.id] = true
            agent.expedition = {
                id = expeditionId,
                parentCommunityId = community.id,
                targetX = targetX,
                targetY = targetY,
                expires = self.tick + PROJECT_DURATION * 3
            }
            self:leaveCommunity(agent)
            agent.homeId = nil
            agent.homeX = nil
            agent.homeY = nil
        end
    end

    return { x = targetX, y = targetY, explorers = explorers, expeditionId = expeditionId, parentCommunityId = community.id }
end

function Simulation:setCommunityProject(communityId, kind)
    local community = communityId and self.communities[communityId]
    if not community then
        return false
    end

    local target = nil
    if kind == "exploration" then
        target = self:prepareExplorationProject(community)
    elseif kind == "war" or kind == "armament" then
        target = self:chooseWarTarget(community)
        if not target then
            for otherId in pairs(self.communities) do
                if otherId ~= community.id then
                    target = otherId
                    break
                end
            end
        end
    end

    community.project = {
        kind = kind,
        targetCommunityId = type(target) == "number" and target or nil,
        targetX = type(target) == "table" and target.x or nil,
        targetY = type(target) == "table" and target.y or nil,
        explorers = type(target) == "table" and target.explorers or nil,
        expeditionId = type(target) == "table" and target.expeditionId or nil,
        parentCommunityId = type(target) == "table" and target.parentCommunityId or nil,
        timer = PROJECT_DURATION
    }
    community.mood = kind
    return true
end

function Simulation:updateCommunityProjects(force)
    for _, community in pairs(self.communities) do
        community.project.timer = (community.project.timer or 0) - PROJECT_CHECK_INTERVAL
        if force or community.project.timer <= 0 then
            local warTarget, relation = self:chooseWarTarget(community)
            local kind = "stockpile"
            local target = nil

            local members = math.max(1, community.members or 0)
            local storeFood = (community.store.food or 0) + (community.store.animals or 0) * 1.8
            local storeMaterial = (community.store.wood or 0) + (community.store.stone or 0) + (community.store.iron or 0) * 1.5
            local infrastructureReserve = ((community.farms or 0) * 12 + (community.paddocks or 0) * 14 + (community.houses or 0) * 2) / members
            local reserve = storeFood / members + storeMaterial / members * 0.45
            reserve = reserve + infrastructureReserve
            local structureCount = (community.houses or 0) + (community.farms or 0) + (community.paddocks or 0) + (community.mines or 0) + (community.warehouses or 0) + (community.shrines or 0)
            local housingShort = (community.houses or 0) * 2 < members + 4

            if not community.hasWarehouse then
                kind = "buildWarehouse"
            elseif reserve < 14 or storeFood < members * 5 then
                kind = "stockpile"
            elseif warTarget and relation < -42 and reserve > 20 and (community.avgProsperity or 0) > 38 then
                if (community.avgArmament or 0) < 0.38 and relation > -60 then
                    kind = "armament"
                    target = warTarget
                else
                    kind = "war"
                    target = warTarget
                end
            elseif reserve > 30 and (community.avgProsperity or 0) > 62 and members >= 14 and structureCount >= 8 then
                kind = "exploration"
                target = self:prepareExplorationProject(community)
            elseif (community.avgSpirituality or 100) < 48 and not community.hasShrine and community.members >= 8 then
                kind = "buildShrine"
            elseif reserve > 22 and (community.avgProsperity or 0) > 48 and housingShort then
                kind = "housing"
            elseif (community.avgProsperity or 0) > 66 then
                kind = "develop"
            else
                kind = "stockpile"
            end

            self:setCommunityProject(community.id, kind)
        end
    end
end

function Simulation:syncCommunityStores()
    for _, community in pairs(self.communities) do
        if community.hasWarehouse then
            community.store = community.store or { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
        end
    end
end

function Simulation:withdrawCommunityResource(agent, resource, amount)
    local community = agent.communityId and self.communities[agent.communityId]
    if not community or not community.hasWarehouse or not community.store or not self:canAccessWarehouse(agent) then
        return 0
    end
    local stored = community.store[resource] or 0
    local available = stored
    if resource == "food" then
        local reserve = math.max(0, community.members or 0) * 2
        if (agent.hunger or 0) < 58 then
            available = math.max(0, stored - reserve)
        elseif (agent.hunger or 0) < 78 then
            available = math.max(0, stored - reserve * 0.5)
        end
    elseif resource == "animals" then
        local reserve = math.max(0, community.members or 0) * 0.4
        if (agent.hunger or 0) < 82 then
            available = math.max(0, stored - reserve)
        end
    end
    local taken = math.min(available, amount)
    community.store[resource] = (community.store[resource] or 0) - taken
    return taken
end

function Simulation:nearAgents(x, y, radius, excludeId)
    local result = {}
    local minCellX = math.floor((x - radius - 1) / CELL)
    local maxCellX = math.floor((x + radius - 1) / CELL)
    local minCellY = math.floor((y - radius - 1) / CELL)
    local maxCellY = math.floor((y + radius - 1) / CELL)
    local r2 = radius * radius

    for cy = minCellY, maxCellY do
        for cx = minCellX, maxCellX do
            local bucket = self.spatial[cx .. ":" .. cy]
            if bucket then
                for _, agent in ipairs(bucket) do
                    if agent.id ~= excludeId then
                        local dx = agent.x - x
                        local dy = agent.y - y
                        if dx * dx + dy * dy <= r2 then
                            result[#result + 1] = agent
                        end
                    end
                end
            end
        end
    end

    return result
end

function Simulation:update(dt)
    self.accumulator = self.accumulator + dt
    local steps = 0
    local maxSteps = 3
    while self.accumulator >= self.tickStep and steps < maxSteps do
        self.accumulator = self.accumulator - self.tickStep
        self:step()
        steps = steps + 1
    end
    if steps >= maxSteps then
        self.accumulator = math.min(self.accumulator, self.tickStep)
    end
end

function Simulation:step()
    self.tick = self.tick + 1
    self:rebuildSpatial()

    if self.tick % 4 == 1 then
        self:rebuildBuildingLists()
        self:assignHomes()
        self:updateProsperity()
    end
    if self.tick % 30 == 0 then
        self:updateDiplomacy()
    end
    if self.tick % PROJECT_CHECK_INTERVAL == 1 then
        self:updateCommunityProjects(false)
    end
    self.stats.actions = {}

    for _, agent in ipairs(self.agents) do
        if agent.alive then
            agent:tick(self)
            self.stats.actions[agent.action] = (self.stats.actions[agent.action] or 0) + 1
        end
    end

    local alive = {}
    local deaths = 0
    for _, agent in ipairs(self.agents) do
        if agent.alive then
            alive[#alive + 1] = agent
        else
            deaths = deaths + 1
        end
    end
    self.agents = alive
    self.stats.deaths = self.stats.deaths + deaths

    if self.tick % 4 == 0 then
        self.world:update(true, 4)
    end
    self:rebuildSpatial()
    if self.tick % 4 == 0 then
        self:rebuildBuildingLists()
        self:assignHomes()
        local removedBuildings = self:decayAbandonedHomes()
        if removedBuildings then
            self:rebuildBuildingLists()
            self:rebuildClaimsFromBuildings()
            self.world:rebuildInfluenceCaches()
            self.world:markIndexDirty("build")
        end
        self:assignHomes()
        self:syncCommunityStores()
        self:updateProsperity()
    end
end

function Simulation:draw()
    love.graphics.push()
    love.graphics.scale(self.camera.zoom, self.camera.zoom)
    love.graphics.translate(-self.camera.x, -self.camera.y)
    self.world:draw(self.communities, self.claims, self.claimEdges, self.camera)
    for _, agent in ipairs(self.agents) do
        local community = agent.communityId and self.communities[agent.communityId]
        agent.currentDrawCommunityColor = community and community.color or nil
        agent:draw()
        agent.currentDrawCommunityColor = nil
    end
    love.graphics.pop()
end

return Simulation
