local Building = require("src.systems.building")
local Resources = require("src.systems.resources")
local AgentAI = require("src.ai.agent_ai")

local Behavior = {}

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function resourceOrigin(sim, agent)
    local home = sim:getBuilding(agent.homeId)
    if home then
        return home.x, home.y
    end
    return agent.x, agent.y
end

local function behaviorCache(sim)
    if sim._behaviorCacheTick ~= sim.tick then
        sim._behaviorCacheTick = sim.tick
        sim._resourceTargetCache = {}
        sim._buildSiteCache = {}
        sim._resourcePressureCache = {}
    end
    return sim._resourceTargetCache, sim._buildSiteCache, sim._resourcePressureCache
end

local function cachedResourcePressure(sim, x, y, radius)
    local _, _, pressureCache = behaviorCache(sim)
    local qx = math.floor(x / 4)
    local qy = math.floor(y / 4)
    local key = radius .. ":" .. qx .. ":" .. qy
    local cached = pressureCache[key]
    if cached then
        return cached
    end
    local pressure = sim.world:resourcePressureAround(x, y, radius)
    pressureCache[key] = pressure
    return pressure
end

local function cachedResourceAt(sim, sx, sy, resource, radius)
    radius = radius or 20
    local resourceCache = behaviorCache(sim)
    local qx = math.floor(sx / 4)
    local qy = math.floor(sy / 4)
    local key = resource .. ":" .. qx .. ":" .. qy .. ":" .. radius

    if resourceCache[key] ~= nil then
        return resourceCache[key] or nil
    end

    local target = sim.world:nearestResourceIndexed(sx, sy, resource, radius, sim.tick)
    resourceCache[key] = target or false
    return target
end

local function nearestResource(sim, agent, resource, radius)
    local sx, sy = resourceOrigin(sim, agent)
    return cachedResourceAt(sim, sx, sy, resource, radius)
end

local function cachedBuildSite(sim, world, sx, sy, kind, communityId)
    local _, siteCache = behaviorCache(sim)
    local qx = math.floor(sx / 4)
    local qy = math.floor(sy / 4)
    local key = kind .. ":" .. tostring(communityId or 0) .. ":" .. qx .. ":" .. qy
    if siteCache[key] ~= nil then
        return siteCache[key] or nil
    end

    local site = world:nearestBuildSiteIndexed(sx, sy, kind, communityId, sim.tick)
    siteCache[key] = site or false
    return site
end

local function hasBetterSurvivalOption(sim, agent)
    if agent.thirst > 76 and nearestResource(sim, agent, "water") then
        return true
    end
    if agent.hunger > 76 and nearestResource(sim, agent, "food") then
        return true
    end
    return false
end

local function settlementAnchor(agent, sim)
    if agent.homeId then
        local home = sim:getBuilding(agent.homeId)
        if home then
            return home.x, home.y
        end
    end

    if agent.communityId then
        local house = sim:nearestHouse(agent.x, agent.y, agent.communityId, false)
        if house then
            return house.x, house.y
        end

        local community = sim.communities[agent.communityId]
        if community then
            return math.floor(community.x + 0.5), math.floor(community.y + 0.5)
        end
    end

    return agent.x, agent.y
end

local function isFamily(agent, other)
    return agent.parentA == other.id
        or agent.parentB == other.id
        or other.parentA == agent.id
        or other.parentB == agent.id
        or (agent.children and agent.children[other.id])
        or (other.children and other.children[agent.id])
end

local function protectedBond(agent, other)
    if isFamily(agent, other) then
        return true
    end
    return agent.communityId and other.communityId == agent.communityId
end

local function socialTrust(agent, other)
    local trust = agent.memory:trust(other.id)
    if protectedBond(agent, other) then
        trust = trust + 55
    end
    return trust
end

local function chooseTargetForHelp(agent, nearby)
    local best
    local bestNeed = 0
    for _, other in ipairs(nearby) do
        if other.alive and other.id ~= agent.id then
            local trust = socialTrust(agent, other)
            local need = math.max(other.hunger, other.thirst) + trust * 0.25
            if need > bestNeed and trust > -35 then
                best = other
                bestNeed = need
            end
        end
    end
    return best
end

local function chooseAttackTarget(agent, nearby)
    local best
    local bestScore = -math.huge
    for _, other in ipairs(nearby) do
        if other.alive and other.id ~= agent.id and not protectedBond(agent, other) then
            local trust = socialTrust(agent, other)
            local resourceTemptation = other.inventory.food * 0.9 + other.inventory.wood * 0.15 + other.inventory.stone * 0.1
            local score = -trust + resourceTemptation - other.energy * 0.15
            if score > bestScore then
                best = other
                bestScore = score
            end
        end
    end
    return best, bestScore
end

local function nearestAgentOfCommunity(agent, sim, communityId)
    local best
    local bestD = math.huge
    for _, other in ipairs(sim.agents) do
        if other.alive and other.communityId == communityId and other.id ~= agent.id then
            local dx = other.x - agent.x
            local dy = other.y - agent.y
            local d = dx * dx + dy * dy
            if d < bestD then
                best = other
                bestD = d
            end
        end
    end
    return best
end

local function nearestEnemyBuilding(agent, sim, communityId)
    local best
    local bestD = math.huge
    for _, building in ipairs(sim.world.buildings) do
        if building.active ~= false and building.communityId and building.communityId ~= agent.communityId then
            if not communityId or building.communityId == communityId then
                local dx = building.x - agent.x
                local dy = building.y - agent.y
                local d = dx * dx + dy * dy
                local value = building.type == "warehouse" and -20 or (building.type == "farm" and -8 or 0)
                if d + value < bestD then
                    best = building
                    bestD = d + value
                end
            end
        end
    end
    return best
end

local function communityOpportunity(agent, sim, nearby)
    local best
    local bestScore = -math.huge
    for _, other in ipairs(nearby) do
        if other.alive and other.id ~= agent.id and not isFamily(agent, other) then
            local trust = socialTrust(agent, other)
            local community = other.communityId and sim.communities[other.communityId]
            if community and other.communityId ~= agent.communityId and trust > -15 then
                local score = trust + community.houses * 8 + community.farms * 5 - community.members * 1.4
                if score > bestScore then
                    best = other
                    bestScore = score
                end
            end
        end
    end
    return best, bestScore
end

local function foreignSettlementPressure(agent, sim, x, y)
    if not agent.communityId then
        return 0
    end
    return sim.world:nearForeignHouse(x, y, agent.communityId) and 4.5 or 0
end

function Behavior.choose(agent, sim)
    local world = sim.world
    local nearby = sim:nearAgents(agent.x, agent.y, 6, agent.id)
    local rx, ry = resourceOrigin(sim, agent)
    local localResources = cachedResourcePressure(sim, rx, ry, 5)
    local overcrowding = math.max(0, #nearby - 7)
    local scarcity = clamp((80 - localResources.food) / 18, 0, 8) + clamp((2 - localResources.water) * 2, 0, 6)
    local prosperity = agent.prosperity or agent.personalProsperity or 0
    local sameCommunity = 0
    local familyNear = 0
    local trustedNear = 0

    for _, other in ipairs(nearby) do
        if protectedBond(agent, other) then
            sameCommunity = sameCommunity + 1
        end
        if isFamily(agent, other) then
            familyNear = familyNear + 1
        end
        if socialTrust(agent, other) > 20 then
            trustedNear = trustedNear + 1
        end
    end

    local communitySupport = sameCommunity * 1.8 + familyNear * 2.6 + trustedNear * 0.8

    local scores = {}
    local targets = {}

    scores.searchWater = agent.thirst * 1.55 + (localResources.water == 0 and 25 or 0)
    targets.searchWater = scores.searchWater > 45 and nearestResource(sim, agent, "water") or nil

    local community = agent.communityId and sim.communities[agent.communityId]
    local warehouse = community and sim:nearestBuilding(agent.x, agent.y, "warehouse", agent.communityId) or nil
    local members = math.max(1, community and (community.members or 1) or 1)
    local localFoodValue = localResources.food + localResources.animals * 1.7
    local foodPerCapita = localFoodValue / math.max(1, math.min(members, 18))
    local richForaging = foodPerCapita > 8 or localFoodValue > 92
    local poorForaging = foodPerCapita < 4 or localFoodValue < 42
    local homeless = not agent.homeId

    scores.searchFood = agent.hunger * 1.25 + scarcity * 4 + (richForaging and 18 or 0)
    targets.searchFood = scores.searchFood > 42 and nearestResource(sim, agent, "food") or nil

    scores.rest = agent.homeId and ((100 - agent.energy) * 1.05 + agent.stress * 0.42 + world:comfortAt(agent.x, agent.y) * 0.22) or -1

    local project = community and community.project or nil
    local expedition = agent.expedition
    if expedition and expedition.expires and expedition.expires < sim.tick then
        agent.expedition = nil
        expedition = nil
    end
    local isExplorer = (project and project.kind == "exploration" and project.explorers and project.explorers[agent.id])
        or (expedition and expedition.parentCommunityId and sim.communities[expedition.parentCommunityId])
    local exploreTargetX = (expedition and expedition.targetX) or (project and project.targetX)
    local exploreTargetY = (expedition and expedition.targetY) or (project and project.targetY)
    local foundingColony = expedition and expedition.parentCommunityId and exploreTargetX and exploreTargetY
        and math.abs(agent.x - exploreTargetX) + math.abs(agent.y - exploreTargetY) <= 10
    if isExplorer and exploreTargetX and exploreTargetY then
        rx, ry = exploreTargetX, exploreTargetY
    end
    local hasSettlementCore = community and community.hasWarehouse and not foundingColony
    local needsSettlementCore = not hasSettlementCore
    local wantsSettlement = needsSettlementCore or community.houses < math.ceil((community.members or 1) / 2) or community.farms + (community.paddocks or 0) < math.ceil((community.members or 1) / 7)
    local wantsGear = project and (project.kind == "armament" or project.kind == "war") and (not agent.sword or not agent.armor)
    local gatherResource = agent.inventory.wood < 52 and "wood" or "stone"
    local animalReserve = agent:availableResource("animals")
    local needsHerd = community and ((community.paddocks or 0) < math.ceil((community.members or 1) / 10) or ((community.store.animals or 0) < (community.members or 1) * 1.5))
    local warehouseCost = Building.cost("warehouse")
    local warehouseMissingWood = math.max(0, (warehouseCost.wood or 0) - agent:availableResource("wood"))
    local warehouseMissingStone = math.max(0, (warehouseCost.stone or 0) - agent:availableResource("stone"))
    if needsSettlementCore then
        gatherResource = warehouseMissingStone > 0 and "stone" or "wood"
    elseif wantsGear and (agent:availableResource("iron") < 16 or (agent.inventory.iron or 0) < 8) then
        gatherResource = "iron"
    elseif community and needsHerd and animalReserve < 6 and (community.project.kind == "stockpile" or community.project.kind == "housing" or community.project.kind == "exploration") then
        gatherResource = "animals"
    end
    scores.gather = 24 + math.max(0, 52 - agent.inventory.wood) * 0.48 + math.max(0, 34 - agent.inventory.stone) * 0.55 + math.max(0, 14 - (agent.inventory.iron or 0)) * (wantsGear and 1.4 or 0.25) + math.max(0, 6 - animalReserve) * (needsHerd and 2.4 or 0.35) + (wantsSettlement and 14 or 0) + (needsSettlementCore and (warehouseMissingWood * 0.9 + warehouseMissingStone * 1.35 + 42) or 0)
    targets.gather = scores.gather > 30 and cachedResourceAt(sim, rx, ry, gatherResource, 26) or nil
    if agent.hunger > 78 or agent.thirst > 78 or agent.energy < 22 then
        scores.gather = scores.gather * 0.55
    end

    local sx, sy = settlementAnchor(agent, sim)
    if isExplorer and exploreTargetX and exploreTargetY then
        sx, sy = exploreTargetX, exploreTargetY
    end
    local foreignPressure = foreignSettlementPressure(agent, sim, sx, sy)
    local shrine = agent.communityId and sim:nearestBuilding(agent.x, agent.y, "shrine", agent.communityId) or nil
    local housingNeed = community and math.max(0, community.members - community.houses * 2) or (agent.homeId and 0 or 2)
    local farmNeed = community and math.max(0, community.members - math.floor(localFoodValue / 11) - community.farms * 7) or (poorForaging and 6 or 0)
    local paddockNeed = community and math.max(0, community.members - (community.paddocks or 0) * 8) or 5
    local miningNeed = math.max(0, 24 - agent:availableResource("stone")) + math.max(0, 10 - agent:availableResource("iron")) * (wantsGear and 2.2 or 0.8)

    local mineLimit = community and (math.ceil(members / 10) + (wantsGear and 3 or 1)) or 0
    local canBuildHouse = hasSettlementCore and Building.canAfford(agent, "house", nearby)
    local canBuildFarm = hasSettlementCore and (farmNeed > 0 or scarcity > 4 or poorForaging) and Building.canAfford(agent, "farm", nearby)
    local canBuildPaddock = hasSettlementCore and (paddockNeed > 0 or scarcity > 3) and Building.canAfford(agent, "paddock", nearby)
    local canBuildMine = hasSettlementCore and ((community.mines or 0) < mineLimit) and (miningNeed > 0 or wantsGear) and Building.canAfford(agent, "mine", nearby)
    local canBuildWarehouse = (((community and not community.hasWarehouse) or not community) or foundingColony) and Building.canAfford(agent, "warehouse", nearby)
    local canBuildShrine = community and not community.hasShrine and Building.canAfford(agent, "shrine", nearby)

    local comfortDeficit = homeless and 42 or math.max(0, 18 - world:comfortAt(agent.x, agent.y)) * 0.4
    local houseScore = canBuildHouse and (agent.stress * 0.26 + #nearby * 1.9 + (agent.communityId and 38 or 28) + housingNeed * 5.5 + (homeless and 82 or -18) + comfortDeficit - foreignPressure * 3) or -1
    local farmScore = canBuildFarm and (agent.hunger * 0.16 + scarcity * 5 + (agent.communityId and 26 or 18) + farmNeed * 2.2 + (poorForaging and 38 or 0) - (richForaging and 34 or 0)) or -1
    local paddockScore = canBuildPaddock and (34 + scarcity * 4 + paddockNeed * 2.4 + math.max(0, 8 - animalReserve) * 1.5) or -1
    local mineScore = canBuildMine and (28 + miningNeed * 1.4 + (wantsGear and 30 or 0)) or -1
    local warehouseScore = canBuildWarehouse and ((foundingColony and 230 or (community and 88 or 172)) + (community and community.members or (#nearby + 1)) * 2.2 + prosperity * 0.35 + warehouseMissingWood * 0.7 + warehouseMissingStone * 1.1) or -1
    local shrineScore = canBuildShrine and (32 + math.max(0, 70 - (community.avgSpirituality or 100)) * 1.1 + community.members * 0.9) or -1

    local houseSite = houseScore > 18 and cachedBuildSite(sim, world, sx, sy, "house", agent.communityId) or nil
    local farmSite = farmScore > 18 and cachedBuildSite(sim, world, sx, sy, "farm", agent.communityId) or nil
    local paddockSite = paddockScore > 18 and cachedBuildSite(sim, world, sx, sy, "paddock", agent.communityId) or nil
    local mineSite = mineScore > 18 and cachedBuildSite(sim, world, sx, sy, "mine", agent.communityId) or nil
    local warehouseSite = warehouseScore > 18 and cachedBuildSite(sim, world, sx, sy, "warehouse", foundingColony and nil or agent.communityId) or nil
    local shrineSite = shrineScore > 18 and cachedBuildSite(sim, world, sx, sy, "shrine", agent.communityId) or nil

    scores.buildHouse = houseSite and houseScore or -1
    scores.buildFarm = farmSite and farmScore or -1
    scores.buildPaddock = paddockSite and paddockScore or -1
    scores.buildMine = mineSite and mineScore or -1
    scores.buildWarehouse = warehouseSite and warehouseScore or -1
    scores.buildShrine = shrineSite and shrineScore or -1
    scores.worship = shrine and (math.max(0, 72 - (agent.spirituality or 100)) * 1.7 + agent.stress * 0.22) or -1
    targets.buildHouse = houseSite
    targets.buildFarm = farmSite
    targets.buildPaddock = paddockSite
    targets.buildMine = mineSite
    targets.buildWarehouse = warehouseSite
    targets.buildShrine = shrineSite
    targets.worship = shrine

    local inventoryLoad = (agent.inventory.food or 0) + (agent.inventory.wood or 0) + (agent.inventory.stone or 0) + (agent.inventory.iron or 0) + (agent.inventory.animals or 0)
    local depotScore = -1
    local depotTarget = nil

    local function setWarehouseNeed(score, withdraw, eat)
        if warehouse and score > depotScore then
            depotScore = score
            depotTarget = { x = warehouse.x, y = warehouse.y, building = warehouse, withdraw = withdraw, eat = eat }
        end
    end

    if warehouse and inventoryLoad > 0 then
        setWarehouseNeed(42 + inventoryLoad * 1.15, nil, false)
    end
    if warehouse and agent.hunger > 52 and agent.inventory.food <= 0 and (community.store.food or 0) > math.max(2, members * 0.5) then
        setWarehouseNeed(70 + agent.hunger * 0.55, { food = 1 }, true)
    end
    if warehouse and agent.hunger > 76 and (agent.inventory.animals or 0) <= 0 and (community.store.animals or 0) > math.max(1, members * 0.25) then
        setWarehouseNeed(76 + agent.hunger * 0.5, { animals = 1 }, true)
    end

    local function missingFromInventory(cost)
        local missing = {}
        local total = 0
        for resource, amount in pairs(cost or {}) do
            local need = math.max(0, amount - (agent.inventory[resource] or 0))
            if need > 0 then
                missing[resource] = need
                total = total + need
            end
        end
        return missing, total
    end

    local function storeCovers(missing)
        if not community or not community.store then
            return false
        end
        for resource, amount in pairs(missing or {}) do
            if (community.store[resource] or 0) < amount then
                return false
            end
        end
        return true
    end

    if warehouse then
        local houseCost = Building.cost("house")
        local houseMissing, houseTotal = missingFromInventory(houseCost)
        if homeless and houseTotal > 0 and storeCovers(houseMissing) then
            setWarehouseNeed(118 + houseTotal * 2.2, houseCost, false)
        end

        local farmCost = Building.cost("farm")
        local farmMissing, farmTotal = missingFromInventory(farmCost)
        if poorForaging and farmTotal > 0 and storeCovers(farmMissing) then
            setWarehouseNeed(86 + farmTotal * 1.8, farmCost, false)
        end

        local paddockCost = Building.cost("paddock")
        local paddockMissing, paddockTotal = missingFromInventory(paddockCost)
        if needsHerd and paddockTotal > 0 and storeCovers(paddockMissing) then
            setWarehouseNeed(92 + paddockTotal * 2.1, paddockCost, false)
        end

        if wantsGear then
            local gearMissing = {}
            local gearCost = {}
            if not agent.sword then
                gearCost = { iron = 6, wood = 4 }
                gearMissing.iron = math.max(0, gearCost.iron - (agent.inventory.iron or 0))
                gearMissing.wood = math.max(0, gearCost.wood - (agent.inventory.wood or 0))
            elseif not agent.armor then
                gearCost = { iron = 10 }
                gearMissing.iron = math.max(0, gearCost.iron - (agent.inventory.iron or 0))
            end
            local total = 0
            for _, amount in pairs(gearMissing) do
                total = total + amount
            end
            if total > 0 and storeCovers(gearMissing) then
                setWarehouseNeed(82 + total * 2, gearCost, false)
            end
        end
    end

    scores.useWarehouse = depotTarget and depotScore or -1
    targets.useWarehouse = depotTarget

    local helpTarget = chooseTargetForHelp(agent, nearby)
    scores.help = helpTarget and (agent.inventory.food > 8 and (helpTarget.hunger - 55) or -3) or -1
    targets.help = helpTarget

    local socialTarget, bond = agent.memory:bestBond(nearby)
    if not socialTarget and #nearby > 0 then
        socialTarget = nearby[math.random(1, #nearby)]
        bond = socialTrust(agent, socialTarget)
    end
    scores.socialize = socialTarget and (agent.socialNeed * 0.72 + math.max(0, socialTrust(agent, socialTarget)) * 0.28 + communitySupport * 1.3 - agent.stress * 0.1) or -1
    targets.socialize = socialTarget

    local joinTarget, joinScore = communityOpportunity(agent, sim, nearby)
    scores.formCommunity = (not agent.communityId and joinTarget) and (42 + math.max(0, joinScore) * 0.35 + trustedNear * 8 + #nearby * 2) or -1
    targets.formCommunity = joinTarget

    local mate = nil
    local mateTrust = -math.huge
    for _, other in ipairs(nearby) do
        local trust = socialTrust(agent, other)
        if other.alive and other.id ~= agent.id and not isFamily(agent, other) and trust > mateTrust then
            mate = other
            mateTrust = trust
        end
    end
    local home = sim:getBuilding(agent.homeId)
    local partnerHome = mate and sim:getBuilding(mate.homeId)
    local hasFamilySpace = (home and (home.occupants or 0) < (home.capacity or 2)) or (partnerHome and (partnerHome.occupants or 0) < (partnerHome.capacity or 2)) or (community and community.houses * 2 > community.members)
    local selfStable = agent.hunger < 42 and agent.thirst < 42 and agent.energy > 45 and agent.stress < 62
    local partnerStable = mate and mate.hunger < 45 and mate.thirst < 45 and mate.energy > 38 and mate.stress < 66
    local fertile = agent.age > 18 and agent.homeId and agent.fertility > 38 and agent.hunger < 58 and agent.thirst < 58 and agent.stress < 72 and agent.energy > 32
    local partnerReady = mate and mate.age > 18 and mate.homeId and mate.fertility > 34 and mate.hunger < 60 and mate.thirst < 60 and mate.stress < 76
    local settlementResources = cachedResourcePressure(sim, rx, ry, 9)
    local storedFood = community and ((community.store.food or 0) + (community.store.animals or 0) * 1.8) or 0
    local reproductionFood = settlementResources.food + settlementResources.animals * 1.6 + storedFood
    local resourcesReady = reproductionFood > 58 and settlementResources.water > 0
    local fertilityReadiness = math.min(agent.fertility or 0, mate and mate.fertility or 0)
    local stabilityBonus = (selfStable and 30 or 0) + (partnerStable and 22 or 0)
    local foodReserveBonus = clamp((reproductionFood - 58) / 4, 0, 22)
    scores.reproduce = fertile and partnerReady and hasFamilySpace and resourcesReady and (fertilityReadiness * 0.82 + mateTrust * 0.42 + localResources.food * 0.05 + localResources.animals * 0.10 + communitySupport * 0.9 + prosperity * 0.30 + stabilityBonus + foodReserveBonus) or -1
    targets.reproduce = mate

    local housingShortage = community and community.members > community.houses * 2 + community.farms * 3 + (community.paddocks or 0) * 2
    local migrationReady = (agent.migrationCooldown or 0) <= 0
    local migrationStress = agent.communityId and migrationReady and ((agent.stress > 72 or agent.aggression > 62) or (overcrowding > 9 and scarcity > 5 and housingShortage))
    scores.migrateCommunity = migrationStress and (joinTarget or scarcity > 6 or overcrowding > 9) and (46 + agent.stress * 0.28 + agent.aggression * 0.35 + math.max(0, joinScore) * 0.18) or -1
    targets.migrateCommunity = joinTarget

    local attackTarget, attackScore = chooseAttackTarget(agent, nearby)
    if project and project.kind == "war" and project.targetCommunityId and prosperity > 30 then
        attackTarget = nearestAgentOfCommunity(agent, sim, project.targetCommunityId) or attackTarget
        attackScore = (attackScore or 0) + 80
    end
    local enemyBuilding = project and (project.kind == "war" or project.kind == "armament") and nearestEnemyBuilding(agent, sim, project.targetCommunityId) or nil
    scores.craftGear = ((not agent.sword and agent:canCraftSword()) or (not agent.armor and agent:canCraftArmor())) and (42 + (project and (project.kind == "war" or project.kind == "armament") and 46 or 0)) or -1
    targets.craftGear = agent
    local desperate = agent.aggression > 98 and (agent.hunger > 94 or agent.thirst > 95 or scarcity > 12)
    local canStillMove = scores.migrateCommunity > 0 or scores.formCommunity > 0
    local warDriven = project and project.kind == "war" and prosperity > 30 and attackTarget
    scores.attack = ((desperate and attackTarget and not canStillMove and not hasBetterSurvivalOption(sim, agent)) or warDriven) and (agent.aggression + attackScore * 0.25 + (warDriven and 70 or 0)) or -1
    targets.attack = attackTarget
    scores.attackBuilding = (project and project.kind == "war" and prosperity > 30 and enemyBuilding) and (70 + agent.aggression * 0.25 + (agent.sword and 24 or -10)) or -1
    targets.attackBuilding = enemyBuilding
    scores.explore = isExplorer and exploreTargetX and exploreTargetY and not foundingColony and (70 + prosperity * 0.25) or -1
    targets.explore = isExplorer and exploreTargetX and exploreTargetY and { x = exploreTargetX, y = exploreTargetY } or nil
    if isExplorer and exploreTargetX and exploreTargetY and math.abs(agent.x - exploreTargetX) + math.abs(agent.y - exploreTargetY) < 8 then
        scores.explore = -1
        if foundingColony then
            scores.buildWarehouse = scores.buildWarehouse > 0 and scores.buildWarehouse + 160 or scores.buildWarehouse
            scores.gather = scores.gather + 50
        else
            scores.buildHouse = scores.buildHouse > 0 and scores.buildHouse + 58 or scores.buildHouse
            scores.buildFarm = scores.buildFarm > 0 and scores.buildFarm + 36 or scores.buildFarm
            scores.buildPaddock = scores.buildPaddock > 0 and scores.buildPaddock + 34 or scores.buildPaddock
            scores.reproduce = scores.reproduce > 0 and scores.reproduce + 40 or scores.reproduce
        end
    end

    if prosperity <= 30 then
        scores.searchFood = scores.searchFood + math.max(0, agent.hunger - 35) * 1.2 + 28
        scores.searchWater = scores.searchWater + math.max(0, agent.thirst - 35) * 1.2 + 28
        scores.rest = scores.rest + math.max(0, 55 - agent.energy) * 0.9 + math.max(0, agent.stress - 35) * 0.8
        scores.help = scores.help + 10
        scores.gather = scores.gather * 0.72
        scores.buildHouse = scores.buildHouse > 0 and scores.buildHouse * 0.65 or scores.buildHouse
        scores.buildFarm = scores.buildFarm > 0 and scores.buildFarm * 0.65 or scores.buildFarm
        scores.buildPaddock = scores.buildPaddock > 0 and scores.buildPaddock * 0.65 or scores.buildPaddock
        scores.buildMine = scores.buildMine > 0 and scores.buildMine * 0.7 or scores.buildMine
        scores.buildWarehouse = scores.buildWarehouse > 0 and (needsSettlementCore and scores.buildWarehouse + 82 or scores.buildWarehouse * 0.45) or scores.buildWarehouse
        scores.buildShrine = scores.buildShrine > 0 and scores.buildShrine * 0.7 or scores.buildShrine
        scores.worship = scores.worship > 0 and scores.worship + 38 or scores.worship
        scores.craftGear = scores.craftGear > 0 and scores.craftGear * 0.35 or scores.craftGear
        scores.attackBuilding = -1
        scores.reproduce = -1
    elseif prosperity <= 60 then
        scores.gather = scores.gather + 22 + math.max(0, 10 - agent.inventory.food) * 2.2
        scores.searchFood = scores.searchFood + math.max(0, 8 - agent.inventory.food) * 2.4
        scores.buildHouse = scores.buildHouse > 0 and scores.buildHouse + (agent.homeId and -8 or 10) or scores.buildHouse
        scores.buildFarm = scores.buildFarm > 0 and scores.buildFarm + scarcity * 2 or scores.buildFarm
        scores.buildPaddock = scores.buildPaddock > 0 and scores.buildPaddock + scarcity * 2 or scores.buildPaddock
        scores.buildMine = scores.buildMine > 0 and scores.buildMine + 12 or scores.buildMine
        scores.buildWarehouse = scores.buildWarehouse > 0 and scores.buildWarehouse + 8 or scores.buildWarehouse
        scores.buildShrine = scores.buildShrine > 0 and scores.buildShrine + math.max(0, 55 - (agent.spirituality or 100)) * 0.9 or scores.buildShrine
        scores.worship = scores.worship > 0 and scores.worship + 12 or scores.worship
        scores.craftGear = scores.craftGear > 0 and scores.craftGear + (wantsGear and 32 or 0) or scores.craftGear
    else
        scores.gather = scores.gather + 12 + math.max(0, 22 - agent.inventory.food) * 1.2
        scores.buildHouse = scores.buildHouse > 0 and scores.buildHouse + housingNeed * 2 + 12 or scores.buildHouse
        scores.buildFarm = scores.buildFarm > 0 and scores.buildFarm + 14 + (community and community.prosperityBonus or 0) * 0.25 or scores.buildFarm
        scores.buildPaddock = scores.buildPaddock > 0 and scores.buildPaddock + 14 + (community and community.prosperityBonus or 0) * 0.22 or scores.buildPaddock
        scores.buildMine = scores.buildMine > 0 and scores.buildMine + 10 or scores.buildMine
        scores.buildWarehouse = scores.buildWarehouse > 0 and scores.buildWarehouse + 16 or scores.buildWarehouse
        scores.buildShrine = scores.buildShrine > 0 and scores.buildShrine + 10 or scores.buildShrine
        scores.craftGear = scores.craftGear > 0 and scores.craftGear + (wantsGear and 40 or 6) or scores.craftGear
        scores.reproduce = scores.reproduce > 0 and scores.reproduce + 18 or scores.reproduce
    end

    local projectDrive = 0
    if prosperity > 30 and project then
        local personalDrive = 0.28 + (math.sin((agent.aiSeed or agent.id or 1) * 0.017) * 0.5 + 0.5) * 0.38
        local welfareDrive = clamp((prosperity - 28) / 55, 0, 1)
        local pressurePenalty = 1
        if agent.hunger > 65 or agent.thirst > 65 or agent.energy < 30 or agent.stress > 76 then
            pressurePenalty = 0.42
        elseif agent.hunger > 52 or agent.thirst > 52 or agent.energy < 42 or agent.stress > 62 then
            pressurePenalty = 0.68
        end
        projectDrive = clamp(personalDrive * welfareDrive * pressurePenalty, 0.12, 0.72)
    end

    local function projectAdd(action, amount)
        scores[action] = scores[action] > 0 and scores[action] + amount * projectDrive or scores[action]
    end

    local function projectScale(action, factor)
        if scores[action] > 0 then
            scores[action] = scores[action] * (1 - (1 - factor) * projectDrive)
        end
    end

    if projectDrive > 0 then
        if project.kind == "stockpile" then
            scores.gather = scores.gather + 16 * projectDrive
            scores.searchFood = scores.searchFood + math.max(0, 10 - agent.inventory.food) * 1.1 * projectDrive
            projectAdd("buildFarm", 12 + scarcity * 1.4)
            projectAdd("buildPaddock", 8)
            projectAdd("buildMine", 8)
            projectAdd("reproduce", 10)
        elseif project.kind == "develop" then
            projectAdd("buildHouse", 12)
            projectAdd("buildFarm", 13)
            projectAdd("buildPaddock", 11)
            projectAdd("buildMine", 9)
            projectAdd("buildWarehouse", 8)
        elseif project.kind == "housing" then
            projectAdd("buildHouse", 28)
            projectAdd("buildFarm", 16)
            projectAdd("buildPaddock", 16)
            projectAdd("reproduce", 12)
            scores.gather = scores.gather + 8 * projectDrive
        elseif project.kind == "buildWarehouse" then
            projectAdd("buildWarehouse", 70)
            scores.gather = scores.gather + 26 * projectDrive
        elseif project.kind == "buildShrine" then
            projectAdd("buildShrine", 48)
            scores.gather = scores.gather + 10 * projectDrive
        elseif project.kind == "armament" then
            scores.gather = scores.gather + 18 * projectDrive
            projectAdd("buildMine", 18)
            projectAdd("craftGear", 44)
            projectScale("reproduce", 0.88)
        elseif project.kind == "war" then
            projectScale("socialize", 0.72)
            projectScale("reproduce", 0.72)
            projectAdd("craftGear", 34)
            projectAdd("attackBuilding", 16)
        elseif project.kind == "exploration" then
            scores.gather = scores.gather + 8 * projectDrive
        end
    end

    if homeless then
        local houseCost = Building.cost("house")
        local missingWood = math.max(0, (houseCost.wood or 0) - agent:availableResource("wood"))
        local missingStone = math.max(0, (houseCost.stone or 0) - agent:availableResource("stone"))
        scores.rest = -1
        scores.reproduce = -1
        scores.buildHouse = scores.buildHouse > 0 and scores.buildHouse + 120 or scores.buildHouse
        scores.gather = scores.gather + 34 + missingWood * 0.9 + missingStone * 1.2
    end

    if needsSettlementCore then
        scores.buildWarehouse = scores.buildWarehouse > 0 and scores.buildWarehouse + 160 or scores.buildWarehouse
        scores.gather = scores.gather + 58 + warehouseMissingWood * 1.2 + warehouseMissingStone * 1.6
        scores.buildHouse = -1
        scores.buildFarm = -1
        scores.buildPaddock = -1
        scores.buildMine = -1
        scores.buildShrine = -1
        scores.reproduce = -1
        scores.craftGear = -1
    end

    if richForaging then
        scores.searchFood = scores.searchFood + 14
        scores.buildFarm = scores.buildFarm > 0 and scores.buildFarm * 0.45 or scores.buildFarm
    elseif poorForaging then
        scores.buildFarm = scores.buildFarm > 0 and scores.buildFarm + 44 or scores.buildFarm
    end

    local bestAction = "rest"
    local bestScore = scores.rest
    for action, score in pairs(scores) do
        if score > bestScore then
            bestAction = action
            bestScore = score
        end
    end

    bestAction = AgentAI.choose(agent, sim, scores, targets, {
        localResources = localResources,
        community = community,
        project = project,
        scarcity = scarcity,
        overcrowding = overcrowding,
        trustedNear = trustedNear,
        sameCommunity = sameCommunity
    }, bestAction)

    return bestAction, targets[bestAction], {
        scarcity = scarcity,
        overcrowding = overcrowding,
        nearby = #nearby,
        communitySupport = communitySupport,
        foreignSettlementPressure = foreignPressure
    }
end

Behavior.Resources = Resources

return Behavior
