package.path = "./?.lua;" .. package.path

local function fract(value)
    return value - math.floor(value)
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

local function hash2(x, y)
    return fract(math.sin(x * 127.1 + y * 311.7) * 43758.5453123)
end

local function valueNoise(x, y)
    local x0 = math.floor(x)
    local y0 = math.floor(y)
    local tx = smoothstep(x - x0)
    local ty = smoothstep(y - y0)
    local a = hash2(x0, y0)
    local b = hash2(x0 + 1, y0)
    local c = hash2(x0, y0 + 1)
    local d = hash2(x0 + 1, y0 + 1)
    return lerp(lerp(a, b, tx), lerp(c, d, tx), ty)
end

love = love or {}
love.math = love.math or {}
love.math.noise = love.math.noise or valueNoise
love.graphics = love.graphics or {
    getDimensions = function()
        return 1280, 800
    end
}
love.filesystem = love.filesystem or {
    getInfo = function(path)
        local file = io.open(path, "r")
        if file then
            file:close()
            return true
        end
        return nil
    end,
    read = function(path)
        local file = assert(io.open(path, "r"))
        local content = file:read("*a")
        file:close()
        return content
    end
}

local Config = require("src.config")
local Simulation = require("src.simulation")

local FEATURES = {
    "hunger",
    "thirst",
    "energy",
    "stress",
    "socialNeed",
    "spirituality",
    "aggression",
    "fertility",
    "health",
    "prosperity",
    "hasHome",
    "hasCommunity",
    "communityProsperity",
    "communityMembers",
    "housingShortage",
    "localFood",
    "localWater",
    "localWood",
    "localStone",
    "localIron",
    "localAnimals",
    "inventoryFood",
    "inventoryWood",
    "inventoryStone",
    "inventoryIron",
    "inventoryAnimals",
    "scarcity",
    "overcrowding",
    "trustedNear",
    "sameCommunityNear"
}

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function norm(v, scale)
    return clamp((v or 0) / scale, 0, 1)
end

local function parseArgs(raw)
    local options = {
        out = "agent-ai/agent_real_states.csv",
        config = "simulation_config.json",
        runs = 4,
        ticks = 520,
        warmup = 30,
        sample_every = 3,
        seed = os.time() % 100000,
        agents = 180,
        cap = 1000,
        width = 180,
        height = 180
    }
    for _, item in ipairs(raw) do
        local key, value = item:match("^%-%-([%w%-_]+)=(.+)$")
        if key then
            key = key:gsub("-", "_")
            if key == "out" or key == "config" then
                options[key] = value
            else
                options[key] = tonumber(value) or value
            end
        end
    end
    return options
end

local function makeSimulation(config, options, seed)
    return Simulation.new({
        width = options.width or config.map.width,
        height = options.height or config.map.height,
        initialAgents = options.agents or config.simulation.initialAgents,
        populationCap = options.cap or config.simulation.populationCap,
        tickStep = config.simulation.tickStep,
        seed = seed,
        world = {
            continents = config.map.continents,
            continentScale = config.map.continentScale,
            archipelagos = config.map.archipelagos,
            shallowWaterDepth = config.map.shallowWaterDepth,
            rivers = config.map.rivers,
            lakes = config.map.lakes,
            resources = config.resources
        }
    })
end

local function sameFamily(a, b)
    return a.parentA == b.id
        or a.parentB == b.id
        or b.parentA == a.id
        or b.parentB == a.id
        or (a.children and a.children[b.id])
        or (b.children and b.children[a.id])
end

local function rowFor(sim, agent)
    local community = agent.communityId and sim.communities[agent.communityId] or nil
    local members = community and (community.members or 0) or 0
    local houses = community and (community.houses or 0) or 0
    local housingShortage = members > 0 and math.max(0, members - houses * 2) / math.max(1, members) or 0
    local x = agent.homeX or agent.x
    local y = agent.homeY or agent.y
    local localResources = sim.world:resourcePressureAround(x, y, 5)
    local nearby = sim:nearAgents(agent.x, agent.y, 6, agent.id)
    local sameCommunityNear = 0
    local trustedNear = 0

    for _, other in ipairs(nearby) do
        if other.alive then
            local protected = sameFamily(agent, other) or (agent.communityId and agent.communityId == other.communityId)
            if protected then
                sameCommunityNear = sameCommunityNear + 1
            end
            local trust = agent.memory and agent.memory:trust(other.id) or 0
            if protected then
                trust = trust + 55
            end
            if trust > 20 then
                trustedNear = trustedNear + 1
            end
        end
    end

    local scarcity = clamp((80 - (localResources.food or 0)) / 18, 0, 8) + clamp((2 - (localResources.water or 0)) * 2, 0, 6)
    local overcrowding = math.max(0, #nearby - 7)

    return {
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
        norm(localResources.food, 90),
        norm(localResources.water, 6),
        norm(localResources.wood, 140),
        norm(localResources.stone, 90),
        norm(localResources.iron, 24),
        norm(localResources.animals, 18),
        norm(agent.inventory.food, 30),
        norm(agent.inventory.wood, 80),
        norm(agent.inventory.stone, 60),
        norm(agent.inventory.iron or 0, 30),
        norm(agent.inventory.animals or 0, 20),
        norm(scarcity, 14),
        norm(overcrowding, 16),
        norm(trustedNear, 8),
        norm(sameCommunityNear, 10)
    }
end

local function writeRow(file, row)
    for i, value in ipairs(row) do
        if i > 1 then
            file:write(",")
        end
        file:write(string.format("%.7g", value or 0))
    end
    file:write("\n")
end

local function collect(sim, file)
    local written = 0
    for _, agent in ipairs(sim.agents) do
        if agent.alive then
            writeRow(file, rowFor(sim, agent))
            written = written + 1
        end
    end
    return written
end

local options = parseArgs(arg or {})
local config = Config.load(options.config)
local out = assert(io.open(options.out, "w"))
out:write(table.concat(FEATURES, ","), "\n")

local total = 0
local started = os.clock()
for run = 1, options.runs do
    local seed = (options.seed or 1) + run * 7919
    local sim = makeSimulation(config, options, seed)
    local runRows = 0
    for _ = 1, options.ticks do
        sim:step()
        if sim.tick >= options.warmup and sim.tick % options.sample_every == 0 then
            runRows = runRows + collect(sim, out)
        end
    end
    total = total + runRows
    io.stderr:write(string.format("run=%d seed=%d rows=%d total=%d tick=%d people=%d births=%d deaths=%d settlements=%d nations=%d\n", run, seed, runRows, total, sim.tick, #sim.agents, sim.stats.births, sim.stats.deaths, sim:communityCount(), sim.nationCount and sim:nationCount() or 0))
end

out:close()
io.stderr:write(string.format("wrote %d rows to %s in %.1fs\n", total, options.out, os.clock() - started))
