local Agent = require("src.entities.agent")
local Community = require("src.entities.community")
local Nation = require("src.entities.nation")
local NationAI = require("src.ai.nation_ai")
local Building = require("src.systems.building")
local Resources = require("src.systems.resources")
local World = require("src.world")

local Simulation = {}
Simulation.__index = Simulation

local CELL = 6
local MIN_ZOOM = 0.18
local PROJECT_DURATION = 200
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
        agentProductivity = config.agentProductivity or 1,
        diseaseEnabled = config.diseaseEnabled ~= false,
        economyEnabled = config.economyEnabled ~= false,
        accumulator = 0,
        populationCap = config.populationCap or 230,
        spatial = {},
        communities = {},
        nextCommunityId = 1,
        nations = {},
        nextNationId = 1,
        nextNationFoundingTick = 160,
        claims = {},
        claimEdges = {},
        borderPairs = {},
        buildingsByType = {},
        tradeRoutes = {},
        nextTradeRouteId = 1,
        selectedCommunityId = nil,
        selectedAgentId = nil,
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
        if not self:selectAgentAtScreen(x, y) then
            self.camera.dragging = true
            self.camera.lastX = x
            self.camera.lastY = y
        end
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

function Simulation:agentById(id)
    if not id then
        return nil
    end
    for _, agent in ipairs(self.agents) do
        if agent.id == id and agent.alive then
            return agent
        end
    end
    return nil
end

function Simulation:selectAgentAtScreen(x, y)
    local _, wh = love.graphics.getDimensions()
    if y > wh - 146 then
        return false
    end

    local tx, ty = self:screenToTile(x, y)
    local best
    local bestD = 2.25
    for _, agent in ipairs(self:nearAgents(tx, ty, 2, nil)) do
        if agent.alive then
            local dx = agent.x - tx
            local dy = agent.y - ty
            local d = dx * dx + dy * dy
            if d < bestD then
                best = agent
                bestD = d
            end
        end
    end

    self.selectedAgentId = best and best.id or nil
    return best ~= nil
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
    self.buildingsByType = { house = {}, farm = {}, paddock = {}, mine = {}, warehouse = {}, shrine = {}, port = {} }
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
    self.world:markIndexDirty()
    Community.recount(self)
    Nation.recount(self)
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
    self.world:markIndexDirty()
    self.world:recount()
    Nation.recount(self)
    return true
end

local function settlementFoundingScore(community)
    local store = community.store or {}
    local food = (store.food or 0) + (store.animals or 0) * 1.8
    local material = (store.wood or 0) + (store.stone or 0) + (store.iron or 0) * 1.8
    return (community.members or 0) * 2.2
        + (community.avgProsperity or 0) * 1.4
        + (community.houses or 0) * 5
        + (community.farms or 0) * 7
        + (community.paddocks or 0) * 7
        + (community.mines or 0) * 5
        + food * 0.22
        + material * 0.18
end

function Simulation:updateNationMembership()
    Nation.recount(self)

    local changed = false
    for _, community in pairs(self.communities) do
        if community.nationId and not self.nations[community.nationId] then
            community.nationId = nil
            changed = true
        end
    end

    Nation.recount(self)

    for _, community in pairs(self.communities) do
        if not community.nationId and community.hasWarehouse and (community.members or 0) > 0 then
            local bestNation
            local bestScore = -math.huge
            if community.parentNationCandidate and self.nations[community.parentNationCandidate] then
                bestNation = self.nations[community.parentNationCandidate]
                bestScore = Nation.joinScore(self, community, bestNation) + 16
            end
            for _, nation in pairs(self.nations) do
                local score = Nation.joinScore(self, community, nation)
                if score > bestScore then
                    bestNation = nation
                    bestScore = score
                end
            end
            if bestNation and bestScore >= 20 then
                community.nationId = bestNation.id
                community.parentNationCandidate = nil
                bestNation.project.timer = math.min(bestNation.project.timer or 0, 12)
                changed = true
            end
        end
    end

    if changed then
        Nation.recount(self)
    end

    if self.tick < (self.nextNationFoundingTick or 0) then
        return
    end

    local founder
    local bestFoundingScore = -math.huge
    for _, community in pairs(self.communities) do
        if Nation.canFound(community) then
            local score = settlementFoundingScore(community)
            if score > bestFoundingScore then
                founder = community
                bestFoundingScore = score
            end
        end
    end

    if founder then
        Nation.create(self, founder)
        self.nextNationFoundingTick = self.tick + 220
        Nation.recount(self)
    end
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
        local morale = ((agent.satisfaction or 50) * 0.62 + (agent.purpose or 35) * 0.38)
        agent.personalProsperity = math.max(0, math.min(70, survival * 0.40 + inventory * 0.13 + housing * 0.10 + morale * 0.08 - spiritualPenalty))
    end

    Community.recount(self)
    if self:cleanupEmptyCommunities() then
        Community.recount(self)
    end
    self:updateNationMembership()

    for _, agent in ipairs(self.agents) do
        local community = agent.communityId and self.communities[agent.communityId]
        local communityBonus = community and community.prosperityBonus or 0
        agent.communityProsperity = communityBonus
        agent.prosperity = math.max(0, math.min(100, (agent.personalProsperity or 0) + communityBonus))
    end
    self:updateNationMembership()
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

    local parentNationId = parentCommunityId
        and self.communities[parentCommunityId]
        and self.communities[parentCommunityId].nationId
        or nil
    local communityId = Community.create(self, building.x, building.y, agent, nil)
    building.communityId = communityId
    local community = self.communities[communityId]
    community.parentNationCandidate = parentNationId
    community.hasWarehouse = true
    community.warehouses = 1
    community.store = community.store or { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    community.project = { kind = "micro", timer = 0, targetCommunityId = nil }
    community.mood = "micro"
    if parentCommunityId and self.communities[parentCommunityId] then
        community.relations[parentCommunityId] = 72
        self.communities[parentCommunityId].relations[communityId] = 72
        if parentNationId and self.nations[parentNationId] then
            local nation = self.nations[parentNationId]
            nation.project.timer = 0
        end
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

    Community.recount(self)
    Nation.recount(self)
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
            if dx * dx + dy * dy <= 576 then
                return self:joinCommunity(agent, nearbyHouse.communityId)
            end
        end

        local nearby = self:nearAgents(agent.x, agent.y, 8, agent.id)
        local bestCommunity
        local bestScore = -math.huge
        for _, other in ipairs(nearby) do
            local community = other.communityId and self.communities[other.communityId]
            if community then
                local freeHousing = math.max(0, (community.houses or 0) * 2 - (community.members or 0))
                local score = agent.memory:trust(other.id) + community.houses * 5 + community.farms * 2 + freeHousing * 4 - community.members * 0.18
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
            local freeHousing = math.max(0, (community.houses or 0) * 2 - (community.members or 0))
            local score = agent.memory:trust(other.id) + community.houses * 6 + community.farms * 4 + freeHousing * 5 - community.members * 0.22
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
        local community = self.communities[agent.communityId]
        local crowded = #self:nearAgents(agent.x, agent.y, 7, agent.id) > 18
        if community
            and community.hasWarehouse
            and crowded
            and (community.members or 0) >= 18
            and (agent.prosperity or 0) > 38
            and self.startAgentExploration
            and self:startAgentExploration(agent) then
            return true
        end
        self:leaveCommunity(agent)
        return true
    end

    return false
end

function Simulation:communityCount()
    return Community.count(self)
end

function Simulation:nationCount()
    return Nation.count(self)
end

function Simulation:nationForCommunity(communityId)
    local community = communityId and self.communities[communityId]
    return community and community.nationId and self.nations[community.nationId] or nil
end

function Simulation:assignNationTask(agent, data)
    local community = agent and agent.communityId and self.communities[agent.communityId]
    if not community then
        return nil
    end
    local nation = community.nationId and self.nations[community.nationId]
    if nation then
        return NationAI.assignAgent(agent, self, nation, data or {})
    end
    return NationAI.assignSettlementAgent(agent, self, community, data or {})
end

function Simulation:releaseCivicTask(agent)
    if NationAI.releaseAgentTask then
        NationAI.releaseAgentTask(agent, self)
    end
end

function Simulation:claimKey(x, y)
    return x .. "," .. y
end

local function claimRadiusFor(building)
    if building.type == "warehouse" or building.type == "shrine" then
        return 5
    elseif building.type == "port" then
        return 4
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
        community.claimCount = 0
    end

    for key, claim in pairs(self.claims) do
        local community = self.communities[claim.communityId]
        if community then
            community.claims[key] = true
            community.claimCount = (community.claimCount or 0) + 1
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
    Nation.recount(self)
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

function Simulation:borderConflict(a, b)
    if not a or not b or a == b then
        return 0
    end
    local left = math.min(a, b)
    local right = math.max(a, b)
    return self.borderPairs[left .. ":" .. right] or 0
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
    if ca.nationId and cb.nationId and ca.nationId ~= cb.nationId then
        local na = self.nations[ca.nationId]
        local nb = self.nations[cb.nationId]
        if na and nb then
            na.relations[cb.nationId] = math.max(-100, math.min(100, (na.relations[cb.nationId] or 0) + amount * 0.7))
            nb.relations[ca.nationId] = math.max(-100, math.min(100, (nb.relations[ca.nationId] or 0) + amount * 0.7))
        end
    end
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
                pressure = pressure - math.min(border, 80) * 0.018
                local prosperity = ((community.avgProsperity or 0) + (other.avgProsperity or 0)) > 120 and 0.025 or 0
                community.relations[otherId] = math.max(-100, math.min(100, community.relations[otherId] + pressure + prosperity))
                if border > 0 and community.nationId and other.nationId and community.nationId ~= other.nationId then
                    local nation = self.nations[community.nationId]
                    if nation then
                        nation.relations[other.nationId] = math.max(-100, math.min(100, (nation.relations[other.nationId] or 0) - math.min(border, 80) * 0.008))
                    end
                end
            end
        end
    end

    for id, nation in pairs(self.nations) do
        for otherId, other in pairs(self.nations) do
            if id ~= otherId then
                nation.relations[otherId] = nation.relations[otherId] or 0
                local dominanceGap = (nation.dominance or 0) - (other.dominance or 0)
                local pressure = dominanceGap > 35 and -0.018 or 0.012
                local prosperity = ((nation.avgProsperity or 0) + (other.avgProsperity or 0)) > 126 and 0.018 or 0
                nation.relations[otherId] = math.max(-100, math.min(100, nation.relations[otherId] + pressure + prosperity))
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

function Simulation:chooseConflictTarget(community)
    if not community then
        return nil, 0
    end
    local bestId = nil
    local bestScore = 0
    for otherId, other in pairs(self.communities) do
        if otherId ~= community.id then
            local relation = community.relations[otherId] or 0
            local border = self:borderConflict(community.id, otherId)
            local sameNation = community.nationId and other.nationId and community.nationId == other.nationId
            if not sameNation then
                local score = math.max(0, -relation) + border * 1.15
                if border > 0 and relation < 8 then
                    score = score + 14
                end
                if score > bestScore then
                    bestScore = score
                    bestId = otherId
                end
            end
        end
    end
    return bestId, bestScore
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

function Simulation:startAgentExploration(agent)
    local community = agent and agent.communityId and self.communities[agent.communityId]
    if not community or not community.hasWarehouse or agent.expedition then
        return false
    end

    local targetX, targetY
    local bestScore = -math.huge
    for _ = 1, 64 do
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

    agent.expedition = {
        id = community.id .. ":" .. tostring(self.tick) .. ":" .. tostring(agent.id),
        parentCommunityId = community.id,
        targetX = targetX,
        targetY = targetY,
        expires = self.tick + PROJECT_DURATION * 3
    }
    self:leaveCommunity(agent)
    agent.homeId = nil
    agent.homeX = nil
    agent.homeY = nil
    return true
end

function Simulation:setCommunityProject(communityId, kind)
    local community = communityId and self.communities[communityId]
    if not community then
        return false
    end

    community.project = {
        kind = "micro",
        targetCommunityId = nil,
        timer = 0
    }
    community.mood = "micro"
    local nation = community.nationId and self.nations[community.nationId]
    if nation then
        nation.project = {
            kind = "micro",
            targetNationId = nil,
            targetCommunityId = nil,
            timer = 0
        }
        nation.assignments = {}
    end
    return true
end

function Simulation:updateCommunityProjects(force)
    Nation.recount(self)

    for _, nation in pairs(self.nations) do
        nation.project = nation.project or {}
        nation.project.kind = (nation.members or 0) > 0 and "micro" or "none"
        nation.project.targetNationId = nil
        nation.project.targetCommunityId = nil
        nation.project.timer = 0
    end

    for _, community in pairs(self.communities) do
        local nation = community.nationId and self.nations[community.nationId]
        community.project = {
            kind = community.hasWarehouse and "micro" or "founding",
            targetCommunityId = nil,
            timer = 0,
            nationId = nation and nation.id or nil,
            targetNationId = nil
        }
        community.mood = community.project.kind
    end
end

function Simulation:updateOvercrowdingMigration()
    for _, community in pairs(self.communities) do
        if not community.dead
            and community.hasWarehouse
            and (community.members or 0) >= 32
            and self.tick >= (community.nextOvercrowdingMigrationTick or 0) then
            local checked = 0
            local crowdSum = 0
            for _, agent in ipairs(self.agents) do
                if agent.alive and agent.communityId == community.id then
                    crowdSum = crowdSum + #self:nearAgents(agent.x, agent.y, 6, agent.id)
                    checked = checked + 1
                    if checked >= 18 then
                        break
                    end
                end
            end

            local avgCrowding = checked > 0 and crowdSum / checked or 0
            local housingDeficit = math.max(0, (community.members or 0) - (community.houses or 0) * 2)
            local store = community.store or {}
            local storedFood = (store.food or 0) + (store.animals or 0) * 1.6
            local materials = (store.wood or 0) + (store.stone or 0)
            local stableEnough = (community.avgProsperity or 0) >= 34
                and storedFood >= (community.members or 0) * 0.65
                and materials >= 18

            if stableEnough and (avgCrowding >= 22 or housingDeficit >= 10) then
                self:prepareExplorationProject(community)
                community.nextOvercrowdingMigrationTick = self.tick + 180
            else
                community.nextOvercrowdingMigrationTick = self.tick + 48
            end
        end
    end
end

local function routeKey(a, b)
    if a > b then
        a, b = b, a
    end
    return tostring(a) .. ":" .. tostring(b)
end

local function storeCanPay(store, cost)
    for resource, amount in pairs(cost or {}) do
        if (store[resource] or 0) < amount then
            return false
        end
    end
    return true
end

local function spendStore(store, cost)
    for resource, amount in pairs(cost or {}) do
        store[resource] = (store[resource] or 0) - amount
    end
end

function Simulation:updateDisease()
    if not self.diseaseEnabled then
        return
    end

    for _, community in pairs(self.communities) do
        if not community.dead and (community.members or 0) > 0 then
            local sample = 0
            local crowd = 0
            for _, agent in ipairs(self.agents) do
                if agent.alive and agent.communityId == community.id then
                    crowd = crowd + #self:nearAgents(agent.x, agent.y, 5, agent.id)
                    sample = sample + 1
                    if sample >= 20 then
                        break
                    end
                end
            end
            local avgCrowd = sample > 0 and crowd / sample or 0
            local infectedRatio = (community.infected or 0) / math.max(1, community.members or 1)
            local housingDeficit = math.max(0, (community.members or 0) - (community.houses or 0) * 2)
            community.diseasePressure = math.max(0, avgCrowd - 13) * 2.2
                + infectedRatio * 42
                + housingDeficit * 0.65
                - (community.shrines or 0) * 1.2
                - (community.ports or 0) * 0.5
            community.diseasePressure = math.max(0, math.min(100, community.diseasePressure))
        elseif community then
            community.diseasePressure = 0
        end
    end
end

function Simulation:findPortSite(community)
    if not community then
        return nil
    end
    local best, bestD
    for radius = 4, 18, 2 do
        for yy = math.max(1, math.floor(community.y - radius)), math.min(self.world.height, math.ceil(community.y + radius)) do
            for xx = math.max(1, math.floor(community.x - radius)), math.min(self.world.width, math.ceil(community.x + radius)) do
                local tile = self.world:get(xx, yy)
                if tile and not tile.building
                    and (tile.type == Resources.TILE.grass or tile.type == Resources.TILE.forest or tile.type == Resources.TILE.sand or tile.type == Resources.TILE.path)
                    and self.world:hasWaterNear(xx, yy) then
                    local dx = xx - community.x
                    local dy = yy - community.y
                    local d = dx * dx + dy * dy
                    if not bestD or d < bestD then
                        best = { x = xx, y = yy }
                        bestD = d
                    end
                end
            end
        end
        if best then
            return best
        end
    end
    return nil
end

function Simulation:buildSettlementPort(community)
    if not community or community.hasPort or not community.store then
        return false
    end
    local cost = Building.cost("port")
    if not storeCanPay(community.store, cost) then
        return false
    end
    local site = self:findPortSite(community)
    if not site then
        return false
    end
    spendStore(community.store, cost)
    local tile = self.world:get(site.x, site.y)
    tile.type = Resources.TILE.port
    tile.food, tile.wood, tile.stone, tile.iron, tile.animals = 0, 0, 0, 0, 0
    tile.maxFood, tile.maxWood, tile.maxStone, tile.maxIron, tile.maxAnimals = 0, 0, 0, 0, 0
    local building = {
        id = #self.world.buildings + 1,
        type = "port",
        x = site.x,
        y = site.y,
        owner = nil,
        communityId = community.id,
        capacity = 0,
        occupants = 0,
        residents = {},
        active = true,
        abandonedTicks = 0,
        width = 1,
        height = 1,
        maxHealth = 120,
        health = 120
    }
    tile.building = building
    self.world.buildings[#self.world.buildings + 1] = building
    community.hasPort = true
    community.ports = (community.ports or 0) + 1
    self:rebuildBuildingLists()
    self:onBuildingBuilt(building)
    return true
end

function Simulation:buildLandRoute(a, b)
    if not a or not b or not a.store then
        return false
    end
    local dx = b.x - a.x
    local dy = b.y - a.y
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 4 or steps > 80 then
        return false
    end
    local cost = { wood = math.ceil(steps * 0.7), stone = math.ceil(steps * 0.3) }
    if not storeCanPay(a.store, cost) then
        return false
    end
    local points = {}
    for i = 0, steps do
        local x = math.floor(a.x + dx * (i / steps) + 0.5)
        local y = math.floor(a.y + dy * (i / steps) + 0.5)
        local tile = self.world:get(x, y)
        if tile and not tile.building and (tile.type == Resources.TILE.grass or tile.type == Resources.TILE.forest or tile.type == Resources.TILE.sand or tile.type == Resources.TILE.snow or tile.type == Resources.TILE.path) then
            points[#points + 1] = { x = x, y = y }
        end
    end
    if #points < math.max(3, steps * 0.55) then
        return false
    end
    spendStore(a.store, cost)
    for _, p in ipairs(points) do
        local tile = self.world:get(p.x, p.y)
        if tile and not tile.building then
            tile.type = Resources.TILE.path
            tile.food = 0
            tile.wood = 0
            tile.animals = 0
            tile.maxFood = 0
            tile.maxWood = 0
            tile.maxAnimals = 0
        end
    end
    self.world:markIndexDirty()
    return true
end

function Simulation:ensureTradeRoute(a, b)
    if not a or not b or a.id == b.id then
        return nil
    end
    local key = routeKey(a.id, b.id)
    if self.tradeRoutes[key] then
        return self.tradeRoutes[key]
    end
    local relation = (a.relations and a.relations[b.id]) or (b.relations and b.relations[a.id]) or 0
    if a.nationId and b.nationId and a.nationId == b.nationId then
        relation = relation + 35
    end
    if relation < 12 then
        return nil
    end

    local dx = a.x - b.x
    local dy = a.y - b.y
    local distance = math.sqrt(dx * dx + dy * dy)
    local kind = nil
    if distance <= 70 and self:buildLandRoute(a, b) then
        kind = "path"
    elseif distance <= 140 then
        if not a.hasPort then
            self:buildSettlementPort(a)
        end
        if not b.hasPort then
            self:buildSettlementPort(b)
        end
        if a.hasPort and b.hasPort then
            kind = "port"
        end
    end
    if not kind then
        return nil
    end
    local route = { id = self.nextTradeRouteId, a = a.id, b = b.id, kind = kind, createdTick = self.tick }
    self.nextTradeRouteId = self.nextTradeRouteId + 1
    self.tradeRoutes[key] = route
    return route
end

function Simulation:tradeBetween(a, b, route)
    local relation = (a.relations and a.relations[b.id]) or (b.relations and b.relations[a.id]) or 0
    local trust = math.max(0, relation + ((a.nationId and b.nationId and a.nationId == b.nationId) and 45 or 0))
    if trust <= 0 then
        return
    end
    local capacity = route.kind == "port" and 14 or 8
    capacity = capacity * math.min(2.0, 0.65 + trust / 80)
    local resources = { "food", "wood", "stone", "iron", "animals" }
    for _, resource in ipairs(resources) do
        local sa = a.store and (a.store[resource] or 0) or 0
        local sb = b.store and (b.store[resource] or 0) or 0
        local needA = (resource == "food" and (a.members or 0) * 2.2 or (a.members or 0) * 0.35)
        local needB = (resource == "food" and (b.members or 0) * 2.2 or (b.members or 0) * 0.35)
        if sa > needA and sb < needB then
            local moved = math.min(capacity, sa - needA, needB - sb)
            a.store[resource] = sa - moved
            b.store[resource] = sb + moved
        elseif sb > needB and sa < needA then
            local moved = math.min(capacity, sb - needB, needA - sa)
            b.store[resource] = sb - moved
            a.store[resource] = sa + moved
        end
    end
end

function Simulation:updateTradeEconomy()
    if not self.economyEnabled then
        return
    end
    local list = {}
    for _, community in pairs(self.communities) do
        if not community.dead and community.hasWarehouse and (community.members or 0) > 0 then
            list[#list + 1] = community
        end
    end
    table.sort(list, function(a, b) return (a.members or 0) > (b.members or 0) end)
    local checked = 0
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            local dx = a.x - b.x
            local dy = a.y - b.y
            local d2 = dx * dx + dy * dy
            if d2 <= 19600 then
                local route = self:ensureTradeRoute(a, b)
                if route then
                    self:tradeBetween(a, b, route)
                end
                checked = checked + 1
                if checked >= 18 then
                    return
                end
            end
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
    if self.tick % 18 == 0 then
        self:updateDisease()
    end
    if self.tick % 60 == 15 then
        self:updateTradeEconomy()
    end
    if self.tick % PROJECT_CHECK_INTERVAL == 1 then
        self:updateCommunityProjects(false)
    end
    if self.tick % 24 == 5 then
        self:updateOvercrowdingMigration()
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
        agent.currentDrawSelected = agent.id == self.selectedAgentId
        agent:draw()
        agent.currentDrawCommunityColor = nil
        agent.currentDrawSelected = nil
    end
    love.graphics.pop()
end

return Simulation
