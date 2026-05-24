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

local function usage()
    print([[
Headless high-performance simulation.

Usage:
  lua headless.lua [options]

Options:
  --ticks=N       Stop after N ticks. Default: 0, run forever.
  --report=N      Print world summary every N ticks. Default: 100.
  --seed=N        Override map seed.
  --agents=N      Override initial agent count.
  --cap=N         Override population cap.
  --width=N       Override map width.
  --height=N      Override map height.
  --events=major  major, all, or none. Default: major.
  --config=PATH   Config file path. Default: simulation_config.json.
]])
end

local function parseArgs(raw)
    local options = {
        ticks = 0,
        report = 100,
        events = "major",
        config = "simulation_config.json"
    }

    for _, item in ipairs(raw) do
        if item == "--help" or item == "-h" then
            options.help = true
        else
            local key, value = item:match("^%-%-([%w%-_]+)=(.+)$")
            if key then
                key = key:gsub("-", "_")
                if key == "events" or key == "config" then
                    options[key] = value
                else
                    options[key] = tonumber(value) or value
                end
            end
        end
    end

    return options
end

local function makeSimulation(config, options)
    return Simulation.new({
        width = options.width or config.map.width,
        height = options.height or config.map.height,
        initialAgents = options.agents or config.simulation.initialAgents,
        populationCap = options.cap or config.simulation.populationCap,
        tickStep = config.simulation.tickStep,
        agentProductivity = config.simulation.agentProductivity,
        diseaseEnabled = config.simulation.diseaseEnabled,
        economyEnabled = config.simulation.economyEnabled,
        seed = options.seed or config.map.seed or (os.time() % 100000),
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

local function communityName(sim, id)
    local community = id and sim.communities[id]
    return community and community.name or ("Settlement " .. tostring(id or "?"))
end

local function projectKey(project)
    if not project then
        return "-"
    end
    return table.concat({
        project.kind or "-",
        tostring(project.targetCommunityId or "-"),
        tostring(project.targetX or "-"),
        tostring(project.targetY or "-")
    }, ":")
end

local function describeProject(sim, community)
    local project = community.project or {}
    local kind = project.kind or "none"

    if kind == "micro" then
        return community.name .. " - micro-management"
    elseif kind == "founding" then
        return community.name .. " - founding warehouse"
    elseif kind == "war" then
        return community.name .. " - war with " .. communityName(sim, project.targetCommunityId)
    elseif kind == "armament" then
        return community.name .. " - arming against " .. communityName(sim, project.targetCommunityId)
    elseif kind == "exploration" then
        return string.format("%s - exploration toward %d,%d", community.name, project.targetX or 0, project.targetY or 0)
    elseif kind == "buildWarehouse" then
        return community.name .. " - building warehouse"
    elseif kind == "buildShrine" then
        return community.name .. " - building shrine"
    elseif kind == "housing" then
        return community.name .. " - housing expansion"
    elseif kind == "develop" then
        return community.name .. " - settlement development"
    elseif kind == "stockpile" then
        return community.name .. " - stockpiling resources"
    end

    return community.name .. " - project " .. kind
end

local function structureCounts(world)
    local counts = {
        total = 0,
        house = 0,
        farm = 0,
        paddock = 0,
        mine = 0,
        warehouse = 0,
        shrine = 0
    }

    for _, building in ipairs(world.buildings) do
        if building.active ~= false then
            counts.total = counts.total + 1
            counts[building.type] = (counts[building.type] or 0) + 1
        end
    end

    return counts
end

local function printSummary(sim, startClock, lastReport)
    local now = os.clock()
    local elapsed = math.max(0.001, now - startClock)
    local windowElapsed = math.max(0.001, now - lastReport.clock)
    local windowTicks = sim.tick - lastReport.tick
    local structures = structureCounts(sim.world)

    print(string.format(
        "[tick %d | %.1fs | %.1f ticks/s, %.1f recent] people=%d births=%d deaths=%d settlements=%d nations=%d structures=%d houses=%d farms=%d pens=%d mines=%d stores=%d shrines=%d ports=%d routes=%d",
        sim.tick,
        elapsed,
        sim.tick / elapsed,
        windowTicks / windowElapsed,
        #sim.agents,
        sim.stats.births,
        sim.stats.deaths,
        sim:communityCount(),
        sim.nationCount and sim:nationCount() or 0,
        structures.total,
        structures.house,
        structures.farm,
        structures.paddock,
        structures.mine,
        structures.warehouse,
        structures.shrine,
        structures.port or 0,
        sim.tradeRoutes and (function(routes)
            local count = 0
            for _ in pairs(routes) do
                count = count + 1
            end
            return count
        end)(sim.tradeRoutes) or 0
    ))

    lastReport.tick = sim.tick
    lastReport.clock = now
end

local function printEvent(tick, message)
    print(string.format("[tick %d] %s", tick, message))
end

local function monitorEvents(sim, state, mode)
    if mode == "none" then
        return
    end

    for id, community in pairs(sim.communities) do
        if community.members and community.members > 0 then
            local key = projectKey(community.project)
            local old = state.communities[id]
            if not old then
                local nation = community.nationId and sim.nations and sim.nations[community.nationId]
                printEvent(sim.tick, "New settlement: " .. community.name .. " nation=" .. tostring(nation and nation.name or "-") .. " members=" .. tostring(community.members))
                printEvent(sim.tick, describeProject(sim, community))
                state.communities[id] = { name = community.name, project = key }
            elseif old.project ~= key then
                printEvent(sim.tick, describeProject(sim, community))
                old.project = key
                old.name = community.name
            end
        end
    end

    for id, old in pairs(state.communities) do
        local community = sim.communities[id]
        if not community or (community.members or 0) <= 0 then
            printEvent(sim.tick, "Settlement collapsed: " .. old.name)
            state.communities[id] = nil
        end
    end

    if mode == "all" then
        for _, building in ipairs(sim.world.buildings) do
            if building.active ~= false and not state.buildings[building.id] then
                state.buildings[building.id] = {
                    type = building.type,
                    communityId = building.communityId
                }
                printEvent(sim.tick, string.format(
                    "%s built %s at %d,%d",
                    communityName(sim, building.communityId),
                    building.type,
                    building.x,
                    building.y
                ))
            elseif building.active == false and state.buildings[building.id] and not state.buildings[building.id].destroyed then
                state.buildings[building.id].destroyed = true
                printEvent(sim.tick, string.format(
                    "%s lost %s #%d",
                    communityName(sim, state.buildings[building.id].communityId),
                    state.buildings[building.id].type,
                    building.id
                ))
            end
        end
    end
end

local options = parseArgs({ ... })
if options.help then
    usage()
    os.exit(0)
end

io.stdout:setvbuf("line")
collectgarbage("setpause", 140)
collectgarbage("setstepmul", 400)

local config = Config.load(options.config)
local sim = makeSimulation(config, options)
local startClock = os.clock()
local lastReport = { tick = 0, clock = startClock }
local state = { communities = {}, buildings = {} }

print(string.format(
    "Headless simulation started: map=%dx%d agents=%d cap=%d seed=%s report=%d events=%s",
    sim.world.width,
    sim.world.height,
    #sim.agents,
    sim.populationCap,
    tostring(options.seed or config.map.seed),
    options.report,
    options.events
))

while options.ticks <= 0 or sim.tick < options.ticks do
    sim:step()
    monitorEvents(sim, state, options.events)

    if options.report > 0 and sim.tick % options.report == 0 then
        printSummary(sim, startClock, lastReport)
    end
end

if options.report <= 0 or sim.tick % options.report ~= 0 then
    printSummary(sim, startClock, lastReport)
end
