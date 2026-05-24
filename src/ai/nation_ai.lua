local ok, Policy = pcall(require, "src.ai.nation_ai_policy")
if not ok then
    Policy = { enabled = false }
end

local NationAI = {}
NationAI.features = Policy.features or {
    "claimsPerMember",
    "totalClaims",
    "claimDensity",
    "expansionNeed",
    "members",
    "settlements",
    "housingShortage",
    "farmShortage",
    "paddockShortage",
    "mineShortage",
    "shrineNeed",
    "avgProsperity",
    "avgSpirituality",
    "avgArmament",
    "dominance",
    "enemyPressure",
    "localFood",
    "localWood",
    "localStone",
    "localIron",
    "localAnimals",
    "agentProsperity",
    "agentLoad",
    "hasHome"
}

local TASKS = Policy.tasks or {
    "stockpileFood",
    "stockpileWood",
    "stockpileStone",
    "buildHouse",
    "buildFarm",
    "buildPaddock",
    "buildMine",
    "buildShrine",
    "craftGear",
    "raid",
    "attackBuilding",
    "explore",
    "reproduce",
    "deposit"
}
NationAI.tasks = TASKS

local TASK_INDEX = {}
for i, task in ipairs(TASKS) do
    TASK_INDEX[task] = i
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function norm(v, scale)
    return clamp((v or 0) / scale, 0, 1)
end

local function countClaims(community)
    if not community then
        return 0
    end
    if community.claimCount then
        return community.claimCount
    end
    local count = 0
    for _ in pairs(community.claims or {}) do
        count = count + 1
    end
    return count
end

local function seededNoise(seed, tick, index)
    local n = math.sin((seed or 1) * 17.231 + (tick or 0) * 41.771 + index * 91.17) * 18317.153
    return n - math.floor(n)
end

local function rebuildTaskCounts(sim)
    sim._civicTaskCountsTick = sim.tick
    sim._civicTaskCounts = {}
    for _, citizen in ipairs(sim.agents or {}) do
        local scopeId = citizen.nationTaskNationId
        local task = citizen.nationTask
        if citizen.alive and scopeId and task and (citizen.nationTaskExpires or 0) > sim.tick then
            local counts = sim._civicTaskCounts[scopeId]
            if not counts then
                counts = { total = 0, byTask = {} }
                sim._civicTaskCounts[scopeId] = counts
            end
            counts.total = counts.total + 1
            counts.byTask[task] = (counts.byTask[task] or 0) + 1
        end
    end
end

local function taskCountsFor(sim, scopeId)
    if sim._civicTaskCountsTick ~= sim.tick or not sim._civicTaskCounts then
        rebuildTaskCounts(sim)
    end
    local counts = sim._civicTaskCounts[scopeId]
    if not counts then
        counts = { total = 0, byTask = {} }
        sim._civicTaskCounts[scopeId] = counts
    end
    return counts
end

local function adjustTaskCount(sim, scopeId, task, amount)
    if not scopeId or not task then
        return
    end
    local counts = taskCountsFor(sim, scopeId)
    counts.total = math.max(0, (counts.total or 0) + amount)
    counts.byTask[task] = math.max(0, (counts.byTask[task] or 0) + amount)
end

local function clearAgentTask(agent, sim)
    if agent.nationTask and agent.nationTaskNationId and (agent.nationTaskExpires or 0) > sim.tick then
        adjustTaskCount(sim, agent.nationTaskNationId, agent.nationTask, -1)
    end
    agent.nationTask = nil
    agent.nationTaskTick = nil
    agent.nationTaskNationId = nil
    agent.nationTaskExpires = nil
end

local function worstNationRelation(sim, nation)
    local worst = 0
    local targetNationId = nil
    if nation.localSettlement and nation.settlements and nation.settlements[1] then
        local community = sim.communities[nation.settlements[1]]
        for otherId, relation in pairs(community and community.relations or {}) do
            if sim.communities[otherId] and relation < worst then
                worst = relation
                targetNationId = otherId
            end
        end
        return targetNationId, worst
    end
    for otherId, relation in pairs(nation.relations or {}) do
        if sim.nations[otherId] and relation < worst then
            worst = relation
            targetNationId = otherId
        end
    end
    return targetNationId, worst
end

local function nearestEnemyCommunity(sim, nation, targetNationId)
    local best
    local bestD = math.huge
    for _, ownId in ipairs(nation.settlements or {}) do
        local own = sim.communities[ownId]
        if own then
            for _, other in pairs(sim.communities) do
                if other.nationId == targetNationId then
                    local dx = own.x - other.x
                    local dy = own.y - other.y
                    local d = dx * dx + dy * dy
                    if d < bestD then
                        best = other
                        bestD = d
                    end
                end
            end
        end
    end
    return best
end

local function settlementDominance(community)
    local members = math.max(1, community.members or 0)
    local claims = countClaims(community)
    local structures = (community.houses or 0)
        + (community.farms or 0)
        + (community.paddocks or 0)
        + (community.mines or 0)
        + (community.warehouses or 0)
        + (community.shrines or 0)
    local claimsPerMember = claims / members
    return clamp(
        (community.avgProsperity or 0) * 0.42
            + math.min(60, members) * 0.42
            + math.min(60, structures * 3.2)
            + math.min(70, claims * 0.34)
            + math.min(35, claimsPerMember * 4.1)
            + (community.avgArmament or 0) * 32,
        0,
        180
    )
end

local function settlementDecisionState(community)
    local store = community.store or {}
    return {
        id = -community.id,
        localSettlement = true,
        settlements = { community.id },
        members = community.members or 0,
        houses = community.houses or 0,
        farms = community.farms or 0,
        paddocks = community.paddocks or 0,
        mines = community.mines or 0,
        warehouses = community.warehouses or 0,
        shrines = community.shrines or 0,
        structures = (community.houses or 0)
            + (community.farms or 0)
            + (community.paddocks or 0)
            + (community.mines or 0)
            + (community.warehouses or 0)
            + (community.shrines or 0),
        avgProsperity = community.avgProsperity or 0,
        avgSpirituality = community.avgSpirituality or 100,
        avgArmament = community.avgArmament or 0,
        dominance = settlementDominance(community),
        claims = countClaims(community),
        store = {
            food = store.food or 0,
            wood = store.wood or 0,
            stone = store.stone or 0,
            iron = store.iron or 0,
            animals = store.animals or 0
        },
        relations = {}
    }
end

local function nationFeatures(agent, sim, nation, data)
    local members = math.max(1, nation.members or 0)
    local localResources = data and data.localResources or {}
    local community = agent.communityId and sim.communities[agent.communityId] or nil
    local carried = (agent.inventory.food or 0)
        + (agent.inventory.wood or 0)
        + (agent.inventory.stone or 0)
        + (agent.inventory.iron or 0)
        + (agent.inventory.animals or 0)
    local claims = nation.claims or 0
    if nation.localSettlement and nation.settlements and nation.settlements[1] then
        claims = countClaims(sim.communities[nation.settlements[1]])
    end
    local structures = math.max(1, nation.structures or 0)
    local claimTarget = math.max(20, members * 8 + structures * 7)
    local claimsPerMember = claims / members
    local claimDensity = claims / math.max(1, structures * 14)
    local expansionNeed = clamp((claimTarget - claims) / claimTarget, 0, 1)
    local houses = nation.houses or 0
    local farms = nation.farms or 0
    local paddocks = nation.paddocks or 0
    local mines = nation.mines or 0
    local shrines = nation.shrines or 0
    local targetNationId, worstRelation = worstNationRelation(sim, nation)

    return {
        norm(claimsPerMember, 16),
        norm(claims, 720),
        clamp(claimDensity, 0, 1),
        expansionNeed,
        norm(members, 120),
        norm(#(nation.settlements or {}), 12),
        clamp(math.max(0, members - houses * 2) / members, 0, 1),
        clamp(math.max(0, members - farms * 7) / members, 0, 1),
        clamp(math.max(0, members - paddocks * 8) / members, 0, 1),
        clamp(math.max(0, math.ceil(members / 10) - mines) / math.max(1, math.ceil(members / 10)), 0, 1),
        (community and community.hasShrine) and 0 or norm(math.max(0, 72 - (nation.avgSpirituality or 100)), 72),
        norm(nation.avgProsperity or 0, 100),
        norm(nation.avgSpirituality or 100, 100),
        norm((nation.avgArmament or 0) * 100, 100),
        norm(nation.dominance or 0, 220),
        norm(math.max(0, -worstRelation), 100),
        norm(localResources.food, 90),
        norm(localResources.wood, 140),
        norm(localResources.stone, 90),
        norm(localResources.iron, 24),
        norm(localResources.animals, 18),
        norm(agent.prosperity or 0, 100),
        norm(carried, 90),
        agent.homeId and 1 or 0,
        targetNationId or 0
    }
end

local function validTasks(agent, sim, nation, data)
    local valid = {}
    local community = agent.communityId and sim.communities[agent.communityId] or nil
    local carried = (agent.inventory.food or 0)
        + (agent.inventory.wood or 0)
        + (agent.inventory.stone or 0)
        + (agent.inventory.iron or 0)
        + (agent.inventory.animals or 0)

    for _, task in ipairs(TASKS) do
        valid[task] = true
    end

    valid.deposit = carried > 0 and community and community.hasWarehouse
    valid.buildHouse = data and data.scores and (data.scores.buildHouse or -1) > 0
    valid.buildFarm = data and data.scores and (data.scores.buildFarm or -1) > 0
    valid.buildPaddock = data and data.scores and (data.scores.buildPaddock or -1) > 0
    valid.buildMine = data and data.scores and (data.scores.buildMine or -1) > 0
    valid.buildShrine = data and data.scores and (data.scores.buildShrine or -1) > 0
    valid.craftGear = data and data.scores and (data.scores.craftGear or -1) > 0
    valid.reproduce = data and data.scores and (data.scores.reproduce or -1) > 0
    valid.raid = data and data.scores and (data.scores.attack or -1) > 0
    valid.attackBuilding = data and data.scores and (data.scores.attackBuilding or -1) > 0
    local claimsPerMember = (nation.claims or 0) / math.max(1, nation.members or 1)
    valid.explore = not agent.expedition
        and community
        and community.hasWarehouse
        and (nation.members or community.members or 0) >= 16
        and (nation.avgProsperity or community.avgProsperity or 0) > 58
        and claimsPerMember > 6.4
    return valid
end

local function taskStillUsable(task, valid)
    if not task then
        return false
    end
    -- Long-running assignments can require preparatory work. Keep them stable
    -- even when the immediate action score briefly disappears.
    if task == "buildHouse"
        or task == "buildFarm"
        or task == "buildPaddock"
        or task == "buildMine"
        or task == "buildShrine"
        or task == "craftGear"
        or task == "stockpileFood"
        or task == "stockpileWood"
        or task == "stockpileStone"
        or task == "explore" then
        return true
    end
    return valid[task] == true
end

local function dense(input, weights, bias, relu)
    local out = {}
    for i = 1, #weights do
        local sum = bias[i] or 0
        local row = weights[i]
        for j = 1, #row do
            sum = sum + row[j] * (input[j] or 0)
        end
        out[i] = relu and math.max(0, sum) or sum
    end
    return out
end

local function trainedLogits(features)
    if not (Policy.trained and Policy.weights) then
        return nil
    end
    local h1 = dense(features, Policy.weights.fc1_w, Policy.weights.fc1_b, true)
    return dense(h1, Policy.weights.out_w, Policy.weights.out_b, false)
end

local function heuristicLogits(agent, sim, nation, features)
    local claimsPerMember = features[1]
    local totalClaims = features[2]
    local claimDensity = features[3]
    local expansionNeed = features[4]
    local housingShortage = features[7]
    local farmShortage = features[8]
    local paddockShortage = features[9]
    local mineShortage = features[10]
    local shrineNeed = features[11]
    local prosperity = features[12]
    local armament = features[14]
    local enemyPressure = features[16]
    local localFood = features[17]
    local localWood = features[18]
    local localStone = features[19]
    local localIron = features[20]
    local localAnimals = features[21]
    local load = features[23]

    local values = {
        stockpileFood = farmShortage * 0.75 + localFood * 0.10,
        stockpileWood = expansionNeed * 0.38 + localWood * 0.16,
        stockpileStone = expansionNeed * 0.34 + localStone * 0.16,
        buildHouse = housingShortage * 4.1 + prosperity * 1.0 + expansionNeed * 0.55,
        buildFarm = farmShortage * 3.8 + localFood * 0.12,
        buildPaddock = paddockShortage * 2.1 + localAnimals,
        buildMine = mineShortage * 1.8 + localIron * 1.7,
        buildShrine = shrineNeed * 2.5,
        craftGear = enemyPressure * 1.6 + (1 - armament) * 1.1 + localIron * 0.45,
        raid = enemyPressure * 2.3 + armament * 1.1,
        attackBuilding = enemyPressure * 2.1 + armament,
        explore = prosperity * 1.25 + totalClaims * 0.65 + claimDensity * 0.45,
        reproduce = prosperity * 2.3 + (1 - housingShortage) * 1.25 + claimsPerMember * 0.25,
        deposit = load * 3.4
    }

    local logits = {}
    for i, task in ipairs(TASKS) do
        logits[i] = values[task] or 0
    end
    return logits
end

local function desiredTaskShare(task, nation, features)
    local expansionNeed = features[4]
    local housingShortage = features[7]
    local farmShortage = features[8]
    local paddockShortage = features[9]
    local mineShortage = features[10]
    local shrineNeed = features[11]
    local prosperity = features[12]
    local armament = features[14]
    local enemyPressure = features[16]
    local localIron = features[20]
    local load = features[23]

    if task == "deposit" then
        return 0.06 + load * 0.30
    elseif task == "stockpileFood" then
        return 0.02 + farmShortage * 0.08
    elseif task == "stockpileWood" then
        return 0.02 + expansionNeed * 0.05
    elseif task == "stockpileStone" then
        return 0.02 + expansionNeed * 0.05
    elseif task == "buildHouse" then
        return 0.12 + housingShortage * 0.34 + expansionNeed * 0.06
    elseif task == "buildFarm" then
        return 0.09 + farmShortage * 0.30
    elseif task == "buildPaddock" then
        return 0.05 + paddockShortage * 0.20
    elseif task == "buildMine" then
        return 0.04 + mineShortage * 0.18 + localIron * 0.06
    elseif task == "buildShrine" then
        return 0.02 + shrineNeed * 0.20
    elseif task == "craftGear" then
        return 0.04 + enemyPressure * 0.16 + (enemyPressure > 0.28 and (1 - armament) * 0.10 or 0)
    elseif task == "raid" then
        return enemyPressure > 0.35 and (0.04 + enemyPressure * 0.20 + armament * 0.07) or 0.005
    elseif task == "attackBuilding" then
        return enemyPressure > 0.30 and (0.04 + enemyPressure * 0.18 + armament * 0.08) or 0.005
    elseif task == "explore" then
        return prosperity > 0.62 and expansionNeed < 0.32 and 0.08 + prosperity * 0.10 or 0.01
    elseif task == "reproduce" then
        return 0.12 + prosperity * 0.18 + (1 - housingShortage) * 0.12
    end
    return 0.06
end

local function assignmentAdjustment(task, nation, features, counts)
    local members = math.max(1, nation.members or 1)
    local assigned = counts.byTask[task] or 0
    local desiredShare = clamp(desiredTaskShare(task, nation, features), 0, 0.55)
    local desiredSlots = math.max(task == "deposit" and 0 or 1, math.floor(members * desiredShare + 0.5))
    local currentShare = assigned / members
    local over = math.max(0, assigned - desiredSlots)
    local under = math.max(0, desiredSlots - assigned)
    local penalty = over * 0.34 + math.max(0, currentShare - desiredShare) * 1.45
    local bonus = math.min(0.36, under * 0.08)

    if task == "stockpileFood" or task == "stockpileWood" or task == "stockpileStone" then
        penalty = penalty * 1.45
        bonus = bonus * 0.55
    elseif task == "buildHouse" or task == "buildFarm" or task == "buildPaddock" or task == "buildMine" or task == "buildShrine" then
        if assigned == 0 and desiredSlots > 0 then
            bonus = bonus + 0.18
        end
    elseif task == "deposit" and assigned > math.max(1, math.floor(members * 0.32)) then
        penalty = penalty + 0.35
    end
    return bonus - penalty
end

local function chooseTask(agent, sim, nation, logits, valid, features, counts)
    local bestTask = nil
    local bestValue = -math.huge
    for i, task in ipairs(TASKS) do
        if valid[task] then
            local noise = (seededNoise(agent.aiSeed or agent.id, sim.tick, i) - 0.5) * 0.12
            local value = (logits[i] or 0) + assignmentAdjustment(task, nation, features, counts) + noise
            if task == agent.nationTask then
                value = value + 0.15
            end
            if value > bestValue then
                bestValue = value
                bestTask = task
            end
        end
    end
    return bestTask or "stockpileFood"
end

function NationAI.assignAgent(agent, sim, nation, data)
    if not Policy.enabled or not nation then
        return nil
    end
    if agent.prosperity and agent.prosperity <= 30 then
        clearAgentTask(agent, sim)
        return nil
    end

    local features = nationFeatures(agent, sim, nation, data)
    local valid = validTasks(agent, sim, nation, data)
    local counts = taskCountsFor(sim, nation.id)
    if agent.nationTask
        and agent.nationTaskNationId == nation.id
        and (agent.nationTaskExpires or 0) > sim.tick
        and taskStillUsable(agent.nationTask, valid) then
        return agent.nationTask
    end
    if agent.nationTask and agent.nationTaskNationId == nation.id and (agent.nationTaskExpires or 0) > sim.tick then
        adjustTaskCount(sim, nation.id, agent.nationTask, -1)
    end

    local logits = trainedLogits(features) or heuristicLogits(agent, sim, nation, features)
    local task = chooseTask(agent, sim, nation, logits, valid, features, counts)
    agent.nationTask = task
    agent.nationTaskTick = sim.tick
    agent.nationTaskNationId = nation.id
    agent.nationTaskExpires = sim.tick + 120
    adjustTaskCount(sim, nation.id, task, 1)
    if task == "explore" and sim.startAgentExploration then
        sim:startAgentExploration(agent)
    end
    return task
end

function NationAI.assignSettlementAgent(agent, sim, community, data)
    if not community or community.nationId or not community.hasWarehouse then
        return nil
    end
    local state = settlementDecisionState(community)
    return NationAI.assignAgent(agent, sim, state, data)
end

function NationAI.featureRow(agent, sim, data)
    local community = agent and agent.communityId and sim.communities[agent.communityId]
    if not community or not community.hasWarehouse then
        return nil
    end
    local state = community.nationId and sim.nations[community.nationId] or settlementDecisionState(community)
    if not state then
        return nil
    end
    return nationFeatures(agent, sim, state, data or {})
end

function NationAI.releaseAgentTask(agent, sim)
    if not agent or not sim then
        return
    end
    clearAgentTask(agent, sim)
end

function NationAI.chooseMacro(nation, sim)
    return { kind = (nation and (nation.members or 0) > 0) and "micro" or "none" }
end

function NationAI.chooseSettlementMacro(community, sim)
    return { kind = (community and (community.members or 0) > 0) and "micro" or "none" }
end

return NationAI
