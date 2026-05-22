local Community = {}

local names = {
    "Ash", "Brook", "Cedar", "Dawn", "Ember", "Field", "Grove", "Hill",
    "Iris", "Juniper", "Kiln", "Lake", "Moss", "North", "Oak", "Pine"
}

local function colorFor(id)
    local hue = ((id * 0.61803398875) % 1)
    local r = 0.45 + 0.45 * math.sin((hue + 0.00) * 6.28318)
    local g = 0.45 + 0.45 * math.sin((hue + 0.33) * 6.28318)
    local b = 0.45 + 0.45 * math.sin((hue + 0.66) * 6.28318)
    return { math.max(0.15, r), math.max(0.15, g), math.max(0.15, b) }
end

function Community.create(sim, x, y, founder)
    local id = sim.nextCommunityId
    sim.nextCommunityId = sim.nextCommunityId + 1

    sim.communities[id] = {
        id = id,
        name = names[((id - 1) % #names) + 1] .. " " .. id,
        x = x,
        y = y,
        members = 0,
        houses = 0,
        farms = 0,
        paddocks = 0,
        mines = 0,
        warehouses = 0,
        shrines = 0,
        hasWarehouse = false,
        hasShrine = false,
        store = { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 },
        housed = 0,
        prosperous = 0,
        avgProsperity = 0,
        avgSpirituality = 100,
        prosperityBonus = 0,
        armed = 0,
        armored = 0,
        avgArmament = 0,
        cohesion = 55,
        relations = {},
        claims = {},
        project = { kind = "buildWarehouse", timer = 80, targetCommunityId = nil },
        mood = "buildWarehouse",
        color = colorFor(id),
        founder = founder and founder.id or nil
    }
    sim.stats.foundings = sim.stats.foundings + 1
    return id
end

function Community.join(sim, agent, communityId)
    if not communityId or not sim.communities[communityId] then
        return false
    end
    if agent.communityId == communityId then
        return true
    end

    if agent.communityId and sim.communities[agent.communityId] then
        sim.stats.migrations = sim.stats.migrations + 1
    end

    agent.communityId = communityId
    local community = sim.communities[communityId]
    agent.settleX = community.x
    agent.settleY = community.y
    return true
end

function Community.leave(sim, agent)
    if agent.communityId then
        sim.stats.migrations = sim.stats.migrations + 1
    end
    agent.communityId = nil
    agent.settleX = nil
    agent.settleY = nil
end

function Community.recount(sim)
    for _, community in pairs(sim.communities) do
        community.members = 0
        community.houses = 0
        community.farms = 0
        community.paddocks = 0
        community.mines = 0
        community.warehouses = 0
        community.shrines = 0
        community.hasWarehouse = false
        community.hasShrine = false
        community.housed = 0
        community.prosperous = 0
        community.avgProsperity = 0
        community.avgSpirituality = 0
        community.prosperityBonus = 0
        community.armed = 0
        community.armored = 0
        community.avgArmament = 0
        community.sumX = 0
        community.sumY = 0
    end

    for _, agent in ipairs(sim.agents) do
        local community = agent.alive and agent.communityId and sim.communities[agent.communityId]
        if community then
            community.members = community.members + 1
            community.sumX = community.sumX + agent.x
            community.sumY = community.sumY + agent.y
            if agent.homeId then
                community.housed = community.housed + 1
            end
            if (agent.personalProsperity or 0) >= 50 then
                community.prosperous = community.prosperous + 1
            end
            if agent.sword then
                community.armed = community.armed + 1
            end
            if agent.armor then
                community.armored = community.armored + 1
            end
            community.avgProsperity = community.avgProsperity + (agent.prosperity or agent.personalProsperity or 0)
            community.avgSpirituality = community.avgSpirituality + (agent.spirituality or 100)
        end
    end

    for _, building in ipairs(sim.world.buildings) do
        local community = building.communityId and sim.communities[building.communityId]
        if community and building.active ~= false then
            if building.type == "house" then
                community.houses = community.houses + 1
            elseif building.type == "farm" then
                community.farms = community.farms + 1
            elseif building.type == "paddock" then
                community.paddocks = community.paddocks + 1
            elseif building.type == "mine" then
                community.mines = community.mines + 1
            elseif building.type == "warehouse" then
                community.warehouses = community.warehouses + 1
                community.hasWarehouse = true
            elseif building.type == "shrine" then
                community.shrines = community.shrines + 1
                community.hasShrine = true
            end
        end
    end

    for id, community in pairs(sim.communities) do
        if community.members > 0 then
            community.x = community.sumX / community.members
            community.y = community.sumY / community.members
            community.avgProsperity = community.avgProsperity / community.members
            community.avgSpirituality = community.avgSpirituality / community.members
            community.prosperityBonus = 30 * (community.prosperous / community.members)
            community.avgArmament = (community.armed + community.armored * 0.8) / (community.members * 1.8)
            community.cohesion = math.max(20, math.min(100, 45 + community.houses * 4 + community.farms * 2 + community.paddocks * 2.4 + community.mines * 1.4 + community.warehouses * 10 + community.shrines * 8 + community.prosperityBonus * 0.4 + community.avgSpirituality * 0.08 - math.max(0, community.members - community.houses * 2) * 0.9))
        elseif community.houses == 0 and community.farms == 0 and community.paddocks == 0 and community.mines == 0 and community.warehouses == 0 and community.shrines == 0 then
            sim.communities[id] = nil
        end
    end
end

function Community.count(sim)
    local count = 0
    for _, community in pairs(sim.communities) do
        if community.members > 0 then
            count = count + 1
        end
    end
    return count
end

return Community
