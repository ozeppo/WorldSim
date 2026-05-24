local ok, Policy = pcall(require, "src.ai.agent_ai_policy")
if not ok then
    Policy = { enabled = false }
end

local AgentAI = {}

local FALLBACK_ACTIONS = {
    "searchFood",
    "searchWater",
    "rest",
    "gather",
    "useWarehouse",
    "buildHouse",
    "buildFarm",
    "buildPaddock",
    "buildMine",
    "buildWarehouse",
    "buildShrine",
    "worship",
    "socialize",
    "help",
    "formCommunity",
    "migrateCommunity",
    "reproduce",
    "craftGear",
    "attack",
    "attackBuilding",
    "explore"
}

local ACTIONS = {}
local seenActions = {}
for _, action in ipairs(Policy.actions or FALLBACK_ACTIONS) do
    ACTIONS[#ACTIONS + 1] = action
    seenActions[action] = true
end
for _, action in ipairs(FALLBACK_ACTIONS) do
    if not seenActions[action] then
        ACTIONS[#ACTIONS + 1] = action
        seenActions[action] = true
    end
end
local PROJECT_INDEX = {}
for i, name in ipairs(Policy.projects or {}) do
    PROJECT_INDEX[name] = i
end

local TARGET_OPTIONAL = {
    rest = true,
    craftGear = true,
    formCommunity = true,
    migrateCommunity = true,
    searchFood = true,
    searchWater = true
}

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function norm(v, scale)
    return clamp((v or 0) / scale, 0, 1)
end

local function seededNoise(seed, tick, index)
    local n = math.sin((seed or 1) * 12.9898 + (tick or 0) * 78.233 + index * 37.719) * 43758.5453
    return n - math.floor(n)
end

local function validAction(action, scores, targets)
    local score = scores[action]
    if not score or score < 0 then
        return false
    end
    if targets[action] == nil and not TARGET_OPTIONAL[action] then
        return false
    end
    return true
end

local function projectVector(project)
    local result = {}
    local count = #(Policy.projects or {})
    local kind = project and project.kind or "none"
    local active = PROJECT_INDEX[kind] or PROJECT_INDEX.none or 1
    for i = 1, count do
        result[#result + 1] = i == active and 1 or 0
    end
    return result
end

local function buildFeatures(agent, sim, data, valid)
    local community = data.community
    local resources = data.localResources or {}
    local members = community and community.members or 0
    local houses = community and community.houses or 0
    local housingShortage = members > 0 and math.max(0, members - houses * 2) / math.max(1, members) or 0

    local features = {
        norm(agent.hunger, 100),
        norm(agent.thirst, 100),
        norm(agent.energy, 100),
        norm(agent.stress, 100),
        norm(agent.socialNeed, 100),
        norm(agent.spirituality, 100),
        norm(agent.aggression, 100),
        norm(agent.fertility, 100),
        norm(agent.health, 100),
        norm(agent.prosperity or agent.personalProsperity or 0, 100),
        agent.homeId and 1 or 0,
        agent.communityId and 1 or 0,
        norm(community and community.avgProsperity or 0, 100),
        norm(members, 80),
        clamp(housingShortage, 0, 1),
        norm(resources.food, 90),
        norm(resources.water, 6),
        norm(resources.wood, 140),
        norm(resources.stone, 90),
        norm(resources.iron, 24),
        norm(resources.animals, 18),
        norm(agent.inventory.food, 30),
        norm(agent.inventory.wood, 80),
        norm(agent.inventory.stone, 60),
        norm(agent.inventory.iron or 0, 30),
        norm(agent.inventory.animals or 0, 20),
        norm(data.scarcity, 14),
        norm(data.overcrowding, 16),
        norm(data.trustedNear, 8),
        norm(data.sameCommunity, 10)
    }

    for _, v in ipairs(projectVector(data.project)) do
        features[#features + 1] = v
    end
    for _, action in ipairs(ACTIONS) do
        features[#features + 1] = valid[action] and 1 or 0
    end
    return features
end

local function dense(input, weights, bias, relu)
    local out = {}
    for i = 1, #weights do
        local sum = bias[i] or 0
        local row = weights[i]
        for j = 1, #row do
            sum = sum + row[j] * (input[j] or 0)
        end
        if relu and sum < 0 then
            sum = 0
        end
        out[i] = sum
    end
    return out
end

local function trainedLogits(features)
    local w = Policy.weights
    if not w then
        return nil
    end
    local h1 = dense(features, w.fc1_w, w.fc1_b, true)
    local h2 = dense(h1, w.fc2_w, w.fc2_b, true)
    return dense(h2, w.out_w, w.out_b, false)
end

local function featureCacheKey(features)
    local parts = {}
    for i = 1, #features do
        parts[i] = tostring(math.floor((features[i] or 0) * 10 + 0.5))
    end
    return table.concat(parts, ":")
end

local function scoreLogits(agent, sim, scores, valid)
    local logits = {}
    for i, action in ipairs(ACTIONS) do
        if valid[action] then
            local base = clamp((scores[action] or 0) / 140, -1, 1)
            local noise = (seededNoise(agent.aiSeed, sim.tick, i) - 0.5) * (0.16 + (agent.aiVariance or 0.06))
            local repeatPenalty = action == agent.lastAiAction and math.min(0.28, (agent.aiRepeat or 0) * 0.045) or 0
            logits[i] = base + noise - repeatPenalty
        else
            logits[i] = -999
        end
    end
    return logits
end

local function chooseFromLogits(agent, sim, logits, scores, valid, fallbackAction)
    local bestAction = fallbackAction
    local bestValue = -math.huge
    local taskAction = ({
        deposit = "useWarehouse",
        stockpileFood = "searchFood",
        stockpileWood = "gather",
        stockpileStone = "gather",
        buildHouse = "buildHouse",
        buildFarm = "buildFarm",
        buildPaddock = "buildPaddock",
        buildMine = "buildMine",
        buildShrine = "buildShrine",
        craftGear = "craftGear",
        raid = "attack",
        attackBuilding = "attackBuilding",
        explore = "explore",
        reproduce = "reproduce"
    })[agent.projectTask]
    local survivalPressure = math.max(agent.hunger or 0, agent.thirst or 0, math.max(0, 26 - (agent.energy or 100)) * 3.2)
    for i, action in ipairs(ACTIONS) do
        if valid[action] then
            local value = logits[i]
            if value == nil then
                local base = clamp((scores[action] or 0) / 140, -1, 1)
                local noise = (seededNoise(agent.aiSeed, sim.tick, i) - 0.5) * (0.16 + (agent.aiVariance or 0.06))
                local repeatPenalty = action == agent.lastAiAction and math.min(0.28, (agent.aiRepeat or 0) * 0.045) or 0
                value = base + noise - repeatPenalty
            end
            -- The network ranks viable actions, but live simulation scores carry
            -- hard local context such as fatigue, reachable targets and current
            -- scarcity. Keep policy influence, while preventing stale training
            -- priors from drowning urgent world feedback.
            value = value * 0.75 + clamp((scores[action] or 0) / 85, -0.45, 1.5)
            if taskAction == action and survivalPressure < 74 then
                value = value + 2.4
            elseif taskAction == action and survivalPressure < 88 then
                value = value + 0.9
            end
            value = value + (seededNoise(agent.aiSeed + 17, sim.tick, i) - 0.5) * 0.035
            if value > bestValue then
                bestAction = action
                bestValue = value
            end
        end
    end

    if bestAction == agent.lastAiAction then
        agent.aiRepeat = (agent.aiRepeat or 0) + 1
    else
        agent.lastAiAction = bestAction
        agent.aiRepeat = 0
    end
    return bestAction
end

function AgentAI.choose(agent, sim, scores, targets, data, fallbackAction)
    if not Policy.enabled then
        return fallbackAction
    end

    local valid = {}
    local anyValid = false
    for _, action in ipairs(ACTIONS) do
        valid[action] = validAction(action, scores, targets)
        anyValid = anyValid or valid[action]
    end
    if not anyValid then
        return fallbackAction
    end

    local features = buildFeatures(agent, sim, data, valid)
    local logits = nil
    if Policy.trained then
        local key = featureCacheKey(features)
        local recent = agent._aiPolicyTick and sim.tick - agent._aiPolicyTick <= 3
        if agent._aiPolicyLogits and (recent or agent._aiPolicyKey == key) then
            logits = agent._aiPolicyLogits
        else
            logits = trainedLogits(features)
            agent._aiPolicyKey = key
            agent._aiPolicyLogits = logits
            agent._aiPolicyTick = sim.tick
        end
    end
    if not logits then
        logits = scoreLogits(agent, sim, scores, valid)
    end
    return chooseFromLogits(agent, sim, logits, scores, valid, fallbackAction)
end

return AgentAI
