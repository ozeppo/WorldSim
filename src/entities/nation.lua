local Nation = {}

local names = {

    "Aru", "Vaskor", "Tirak", "Meren", "Solun", "Kharim",
    "Velka", "Ordan", "Nerai", "Brakka", "Ishar", "Tovan",
    "Zereth", "Kaigan", "Morai", "Drevik", "Lunai", "Sarn",
    "Velun", "Korai", "Ashur", "Temar", "Rovak", "Nayem",
    "Tarkhan", "Eldu", "Veyra", "Omari", "Drav", "Suleth",
    "Korin", "Yaran", "Votan", "Selka", "Ardash", "Nohr"
}

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function claimCount(community)
    if community.claimCount then
        return community.claimCount
    end
    local count = 0
    for _ in pairs(community.claims or {}) do
        count = count + 1
    end
    return count
end

local function settlementWealth(community)
    local store = community.store or {}
    local food = (store.food or 0) + (store.animals or 0) * 1.8
    local material = (store.wood or 0) + (store.stone or 0) + (store.iron or 0) * 1.8
    local infrastructure = (community.houses or 0) * 5
        + (community.farms or 0) * 8
        + (community.paddocks or 0) * 8
        + (community.mines or 0) * 6
        + (community.shrines or 0) * 10
    return food, material, infrastructure
end

function Nation.canFound(community)
    if not community or community.nationId or not community.hasWarehouse then
        return false
    end
    local members = community.members or 0
    local food, material, infrastructure = settlementWealth(community)
    return members >= 16
        and (community.avgProsperity or 0) >= 30
        and food >= members * 1.2
        and material >= members * 0.6
        and ((community.houses or 0) >= math.max(3, math.floor(members / 6)) or infrastructure >= 28)
end

function Nation.joinScore(sim, community, nation)
    if not community or not nation or community.nationId then
        return -math.huge
    end
    if not community.hasWarehouse or (community.members or 0) <= 0 then
        return -math.huge
    end

    local relationSum = 0
    local relationCount = 0
    local nearestD2 = math.huge
    for _, settlementId in ipairs(nation.settlements or {}) do
        local settlement = sim.communities[settlementId]
        if settlement then
            relationSum = relationSum + (community.relations[settlementId] or settlement.relations[community.id] or 0)
            relationCount = relationCount + 1
            local dx = settlement.x - community.x
            local dy = settlement.y - community.y
            nearestD2 = math.min(nearestD2, dx * dx + dy * dy)
        end
    end
    local relation = relationCount > 0 and relationSum / relationCount or 0
    local distancePenalty = nearestD2 < math.huge and math.sqrt(nearestD2) * 0.12 or 0
    local prosperityFit = math.min(18, (community.avgProsperity or 0) * 0.22)
    local securityFit = math.min(14, (nation.dominance or 0) * 0.06)
    return relation + prosperityFit + securityFit - distancePenalty
end

function Nation.create(sim, founderCommunity)
    local id = sim.nextNationId
    sim.nextNationId = sim.nextNationId + 1

    local color = founderCommunity and founderCommunity.color or { 0.8, 0.8, 0.8 }
    sim.nations[id] = {
        id = id,
        name = names[((id - 1) % #names) + 1] .. " Nation " .. id,
        color = { color[1], color[2], color[3] },
        capitalCommunityId = founderCommunity and founderCommunity.id or nil,
        settlements = {},
        relations = {},
        project = { kind = "micro", timer = 0, targetNationId = nil, targetCommunityId = nil },
        assignments = {},
        members = 0,
        houses = 0,
        farms = 0,
        paddocks = 0,
        mines = 0,
        warehouses = 0,
        shrines = 0,
        ports = 0,
        avgProsperity = 0,
        avgSpirituality = 100,
        avgArmament = 0,
        dominance = 0,
        claims = 0,
        structures = 0,
        store = { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    }

    if founderCommunity then
        founderCommunity.nationId = id
    end
    return id
end

function Nation.ensureForCommunity(sim, community, parentNationId)
    if not community then
        return nil
    end
    if parentNationId and sim.nations[parentNationId] then
        community.nationId = parentNationId
        return parentNationId
    end
    if community.nationId and sim.nations[community.nationId] then
        return community.nationId
    end
    return nil
end

function Nation.recount(sim)
    for _, nation in pairs(sim.nations or {}) do
        nation.settlements = {}
        nation.members = 0
        nation.houses = 0
        nation.farms = 0
        nation.paddocks = 0
        nation.mines = 0
        nation.warehouses = 0
        nation.shrines = 0
        nation.ports = 0
        nation.structures = 0
        nation.avgProsperity = 0
        nation.avgSpirituality = 0
        nation.avgArmament = 0
        nation.claims = 0
        nation.store = { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    end

    for _, community in pairs(sim.communities or {}) do
        if community.nationId and not sim.nations[community.nationId] then
            community.nationId = nil
        end
        local nation = community.nationId and sim.nations[community.nationId]
        if nation then
            nation.settlements[#nation.settlements + 1] = community.id
            nation.members = nation.members + (community.members or 0)
            nation.houses = nation.houses + (community.houses or 0)
            nation.farms = nation.farms + (community.farms or 0)
            nation.paddocks = nation.paddocks + (community.paddocks or 0)
            nation.mines = nation.mines + (community.mines or 0)
            nation.warehouses = nation.warehouses + (community.warehouses or 0)
            nation.shrines = nation.shrines + (community.shrines or 0)
            nation.ports = nation.ports + (community.ports or 0)
            nation.structures = nation.structures
                + (community.houses or 0)
                + (community.farms or 0)
                + (community.paddocks or 0)
                + (community.mines or 0)
                + (community.warehouses or 0)
                + (community.shrines or 0)
                + (community.ports or 0)
            nation.claims = nation.claims + claimCount(community)
            nation.avgProsperity = nation.avgProsperity + (community.avgProsperity or 0) * (community.members or 0)
            nation.avgSpirituality = nation.avgSpirituality + (community.avgSpirituality or 100) * (community.members or 0)
            nation.avgArmament = nation.avgArmament + (community.avgArmament or 0) * (community.members or 0)
            for resource, amount in pairs(community.store or {}) do
                nation.store[resource] = (nation.store[resource] or 0) + amount
            end
        end
    end

    local empty = {}
    for id, nation in pairs(sim.nations or {}) do
        if nation.members > 0 then
            nation.avgProsperity = nation.avgProsperity / nation.members
            nation.avgSpirituality = nation.avgSpirituality / nation.members
            nation.avgArmament = nation.avgArmament / nation.members
            local claimsPerMember = (nation.claims or 0) / math.max(1, nation.members)
            nation.dominance = clamp(
                nation.avgProsperity * 0.42
                    + math.min(80, nation.members) * 0.42
                    + math.min(80, nation.structures * 3.2)
                    + math.min(85, (nation.claims or 0) * 0.32)
                    + math.min(45, claimsPerMember * 4.4)
                    + (nation.avgArmament or 0) * 38,
                0,
                220
            )
        else
            empty[#empty + 1] = id
        end
    end

    for _, id in ipairs(empty) do
        sim.nations[id] = nil
        for _, nation in pairs(sim.nations or {}) do
            nation.relations[id] = nil
        end
    end
end

function Nation.count(sim)
    local count = 0
    for _, nation in pairs(sim.nations or {}) do
        if (nation.members or 0) > 0 then
            count = count + 1
        end
    end
    return count
end

return Nation
