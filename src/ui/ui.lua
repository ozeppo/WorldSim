local UI = {}
UI.__index = UI

local PANEL_H = 146

local actionLabels = {
    searchFood = "food",
    searchWater = "water",
    rest = "rest",
    gather = "gather",
    useWarehouse = "store",
    buildHouse = "house",
    buildFarm = "farm",
    buildPaddock = "pen",
    buildMine = "mine",
    buildWarehouse = "store",
    buildShrine = "shrine",
    worship = "pray",
    formCommunity = "settle",
    migrateCommunity = "move",
    reproduce = "birth",
    socialize = "social",
    help = "help",
    craftGear = "gear",
    attack = "attack",
    attackBuilding = "raze",
    explore = "explore"
}

local tabs = {
    { id = "world", label = "World" },
    { id = "agent", label = "Agent" },
    { id = "settlement", label = "Settlement" },
    { id = "resources", label = "Resources" }
}

local iconColors = {
    people = { 0.66, 0.86, 1.0 },
    birth = { 1.0, 0.64, 0.78 },
    death = { 0.62, 0.62, 0.68 },
    food = { 0.96, 0.40, 0.26 },
    animals = { 0.82, 0.58, 0.30 },
    water = { 0.25, 0.62, 1.0 },
    wood = { 0.52, 0.34, 0.18 },
    stone = { 0.62, 0.64, 0.66 },
    iron = { 0.72, 0.78, 0.86 },
    house = { 0.95, 0.76, 0.42 },
    farm = { 0.36, 0.82, 0.34 },
    paddock = { 0.78, 0.58, 0.34 },
    mine = { 0.54, 0.50, 0.48 },
    warehouse = { 0.92, 0.68, 0.28 },
    shrine = { 0.68, 0.70, 1.0 },
    claim = { 0.74, 0.92, 0.52 },
    migration = { 0.78, 0.72, 1.0 },
    boat = { 0.38, 0.72, 0.92 },
    plan = { 1.0, 0.92, 0.44 },
    hunger = { 0.95, 0.48, 0.12 },
    fullness = { 0.95, 0.48, 0.12 },
    thirst = { 0.22, 0.58, 1.0 },
    hydration = { 0.22, 0.58, 1.0 },
    energy = { 0.98, 0.86, 0.26 },
    health = { 0.32, 0.86, 0.44 },
    stress = { 0.72, 0.22, 0.90 },
    calm = { 0.40, 0.82, 0.72 },
    social = { 0.92, 0.62, 1.0 },
    spirit = { 0.55, 0.68, 1.0 },
    aggression = { 0.92, 0.18, 0.14 },
    peace = { 0.42, 0.82, 0.58 },
    prosperity = { 0.22, 0.82, 0.46 },
    purpose = { 1.0, 0.78, 0.36 },
    gear = { 0.84, 0.86, 0.92 },
    relation = { 0.95, 0.42, 0.42 }
}

function UI.new(sim)
    return setmetatable({
        sim = sim,
        activeTab = "world",
        tabButtons = {},
        projectButtons = {}
    }, UI)
end

function UI:update()
    self.sim = self.sim
end

function UI:nextTab()
    local index = 1
    for i, tab in ipairs(tabs) do
        if tab.id == self.activeTab then
            index = i
            break
        end
    end
    self.activeTab = tabs[index % #tabs + 1].id
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function avg(agents, field)
    if #agents == 0 then
        return 0
    end
    local sum = 0
    for _, agent in ipairs(agents) do
        sum = sum + (agent[field] or 0)
    end
    return sum / #agents
end

local function wellbeing(agent, field)
    if agent.wellbeing then
        return agent:wellbeing(field)
    end
    if field == "fullness" then
        return 100 - (agent.hunger or 0)
    elseif field == "hydration" then
        return 100 - (agent.thirst or 0)
    elseif field == "calm" then
        return 100 - (agent.stress or 0)
    elseif field == "social" then
        return 100 - (agent.socialNeed or 0)
    elseif field == "peace" then
        return 100 - (agent.aggression or 0)
    end
    return agent[field] or 0
end

local function avgWellbeing(agents, field)
    if #agents == 0 then
        return 0
    end
    local sum = 0
    for _, agent in ipairs(agents) do
        sum = sum + wellbeing(agent, field)
    end
    return sum / #agents
end

local function countBoats(agents)
    local count = 0
    local planned = 0
    for _, agent in ipairs(agents) do
        if (agent.boatDurability or 0) > 0 then
            count = count + 1
        end
        if agent.planAction then
            planned = planned + 1
        end
    end
    return count, planned
end

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

local function selectedAgent(sim)
    return sim.agentById and sim:agentById(sim.selectedAgentId) or nil
end

local function selectedCommunity(sim)
    return sim.selectedCommunityId and sim.communities[sim.selectedCommunityId] or nil
end

local function topCommunity(sim)
    local best
    for _, community in pairs(sim.communities) do
        if not best or (community.members or 0) > (best.members or 0) then
            best = community
        end
    end
    return best
end

local function topNation(sim)
    local best
    for _, nation in pairs(sim.nations or {}) do
        if not best or (nation.dominance or 0) > (best.dominance or 0) then
            best = nation
        end
    end
    return best
end

local function relationSummary(sim, community)
    local worstName = "-"
    local worst = 0
    for otherId, relation in pairs(community.relations or {}) do
        if relation < worst and sim.communities[otherId] then
            worst = relation
            worstName = sim.communities[otherId].name
        end
    end
    return worstName, worst
end

local function rankedActions(sim)
    local ranked = {}
    for action, count in pairs(sim.stats.actions or {}) do
        ranked[#ranked + 1] = { action = actionLabels[action] or action, count = count }
    end
    table.sort(ranked, function(a, b)
        return a.count > b.count
    end)
    return ranked
end

local function taskMixLine(sim, community)
    if not community then
        return "-"
    end
    local scopeId = community.nationId or -community.id
    local counts = {}
    for _, agent in ipairs(sim.agents or {}) do
        if agent.alive and agent.nationTaskNationId == scopeId and agent.nationTask and (agent.nationTaskExpires or 0) > sim.tick then
            counts[agent.nationTask] = (counts[agent.nationTask] or 0) + 1
        end
    end
    local ranked = {}
    for task, count in pairs(counts) do
        ranked[#ranked + 1] = { task = task, count = count }
    end
    table.sort(ranked, function(a, b)
        return a.count > b.count
    end)
    local parts = {}
    for i = 1, math.min(4, #ranked) do
        parts[#parts + 1] = ranked[i].task .. " " .. ranked[i].count
    end
    return #parts > 0 and table.concat(parts, "   ") or "-"
end

local function setColor(color, alpha)
    love.graphics.setColor(color[1], color[2], color[3], alpha or color[4] or 1)
end

local function drawIcon(x, y, name, scale)
    scale = scale or 1
    local s = 14 * scale
    local c = iconColors[name] or { 1, 1, 1 }
    setColor(c)

    if name == "people" then
        love.graphics.circle("fill", x + s * 0.34, y + s * 0.32, s * 0.20)
        love.graphics.circle("fill", x + s * 0.68, y + s * 0.34, s * 0.18)
        love.graphics.rectangle("fill", x + s * 0.18, y + s * 0.58, s * 0.66, s * 0.28)
    elseif name == "birth" then
        love.graphics.circle("fill", x + s * 0.5, y + s * 0.36, s * 0.20)
        love.graphics.rectangle("fill", x + s * 0.36, y + s * 0.58, s * 0.28, s * 0.28)
    elseif name == "death" then
        love.graphics.setLineWidth(2)
        love.graphics.line(x + s * 0.25, y + s * 0.25, x + s * 0.75, y + s * 0.75)
        love.graphics.line(x + s * 0.75, y + s * 0.25, x + s * 0.25, y + s * 0.75)
        love.graphics.setLineWidth(1)
    elseif name == "food" or name == "fullness" then
        love.graphics.circle("fill", x + s * 0.44, y + s * 0.55, s * 0.28)
        love.graphics.rectangle("fill", x + s * 0.56, y + s * 0.24, s * 0.16, s * 0.42)
    elseif name == "animals" then
        love.graphics.ellipse("fill", x + s * 0.50, y + s * 0.58, s * 0.34, s * 0.22)
        love.graphics.circle("fill", x + s * 0.78, y + s * 0.48, s * 0.14)
    elseif name == "water" or name == "thirst" or name == "hydration" then
        love.graphics.polygon("fill", x + s * 0.5, y + s * 0.12, x + s * 0.78, y + s * 0.58, x + s * 0.5, y + s * 0.90, x + s * 0.22, y + s * 0.58)
    elseif name == "wood" then
        love.graphics.rectangle("fill", x + s * 0.30, y + s * 0.18, s * 0.42, s * 0.68)
        love.graphics.setColor(0.26, 0.16, 0.08)
        love.graphics.line(x + s * 0.44, y + s * 0.22, x + s * 0.44, y + s * 0.82)
    elseif name == "stone" then
        love.graphics.polygon("fill", x + s * 0.18, y + s * 0.72, x + s * 0.36, y + s * 0.32, x + s * 0.68, y + s * 0.20, x + s * 0.86, y + s * 0.66, x + s * 0.58, y + s * 0.86)
    elseif name == "iron" or name == "gear" then
        love.graphics.polygon("fill", x + s * 0.50, y + s * 0.12, x + s * 0.84, y + s * 0.50, x + s * 0.50, y + s * 0.88, x + s * 0.16, y + s * 0.50)
    elseif name == "house" then
        love.graphics.polygon("fill", x + s * 0.12, y + s * 0.48, x + s * 0.50, y + s * 0.16, x + s * 0.88, y + s * 0.48)
        love.graphics.rectangle("fill", x + s * 0.24, y + s * 0.48, s * 0.52, s * 0.38)
    elseif name == "farm" then
        love.graphics.rectangle("fill", x + s * 0.18, y + s * 0.22, s * 0.64, s * 0.60)
        love.graphics.setColor(0.16, 0.46, 0.16)
        love.graphics.line(x + s * 0.30, y + s * 0.24, x + s * 0.30, y + s * 0.82)
        love.graphics.line(x + s * 0.50, y + s * 0.24, x + s * 0.50, y + s * 0.82)
        love.graphics.line(x + s * 0.70, y + s * 0.24, x + s * 0.70, y + s * 0.82)
    elseif name == "warehouse" then
        love.graphics.rectangle("fill", x + s * 0.18, y + s * 0.34, s * 0.64, s * 0.48)
        love.graphics.polygon("fill", x + s * 0.16, y + s * 0.34, x + s * 0.50, y + s * 0.14, x + s * 0.84, y + s * 0.34)
    elseif name == "shrine" or name == "spirit" then
        love.graphics.rectangle("fill", x + s * 0.44, y + s * 0.18, s * 0.12, s * 0.62)
        love.graphics.rectangle("fill", x + s * 0.24, y + s * 0.34, s * 0.52, s * 0.12)
    elseif name == "calm" then
        love.graphics.circle("line", x + s * 0.50, y + s * 0.50, s * 0.34)
        love.graphics.circle("fill", x + s * 0.50, y + s * 0.50, s * 0.12)
    elseif name == "stress" then
        love.graphics.setLineWidth(2)
        love.graphics.line(x + s * 0.20, y + s * 0.28, x + s * 0.48, y + s * 0.50, x + s * 0.34, y + s * 0.50, x + s * 0.74, y + s * 0.82)
        love.graphics.setLineWidth(1)
    elseif name == "peace" then
        love.graphics.circle("fill", x + s * 0.50, y + s * 0.50, s * 0.32)
        love.graphics.setColor(0.08, 0.09, 0.10)
        love.graphics.rectangle("fill", x + s * 0.32, y + s * 0.45, s * 0.36, s * 0.10)
    elseif name == "aggression" then
        love.graphics.polygon("fill", x + s * 0.5, y + s * 0.12, x + s * 0.78, y + s * 0.82, x + s * 0.22, y + s * 0.82)
    elseif name == "energy" then
        love.graphics.polygon("fill", x + s * 0.58, y + s * 0.08, x + s * 0.28, y + s * 0.52, x + s * 0.52, y + s * 0.52, x + s * 0.40, y + s * 0.92, x + s * 0.78, y + s * 0.42, x + s * 0.54, y + s * 0.42)
    elseif name == "health" then
        love.graphics.rectangle("fill", x + s * 0.42, y + s * 0.16, s * 0.16, s * 0.68)
        love.graphics.rectangle("fill", x + s * 0.18, y + s * 0.42, s * 0.64, s * 0.16)
    elseif name == "prosperity" or name == "purpose" then
        love.graphics.circle("fill", x + s * 0.50, y + s * 0.50, s * 0.34)
        love.graphics.setColor(0.08, 0.09, 0.10)
        love.graphics.circle("line", x + s * 0.50, y + s * 0.50, s * 0.22)
    else
        love.graphics.rectangle("fill", x + s * 0.22, y + s * 0.22, s * 0.56, s * 0.56)
    end
    love.graphics.setColor(1, 1, 1)
end

local function drawMetric(x, y, w, icon, label, value, maxValue)
    maxValue = maxValue or 100
    love.graphics.setColor(0.08, 0.09, 0.10, 0.78)
    love.graphics.rectangle("fill", x, y, w, 22)
    drawIcon(x + 4, y + 4, icon, 0.85)
    love.graphics.setColor(0.20, 0.22, 0.24, 1)
    love.graphics.rectangle("fill", x + 24, y + 13, w - 30, 5)
    setColor(iconColors[icon] or { 1, 1, 1 })
    love.graphics.rectangle("fill", x + 24, y + 13, (w - 30) * clamp((value or 0) / maxValue, 0, 1), 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(label .. " " .. math.floor(value or 0), x + 24, y + 2)
end

local function drawPill(x, y, icon, text, w)
    w = w or 96
    love.graphics.setColor(0.08, 0.09, 0.10, 0.78)
    love.graphics.rectangle("fill", x, y, w, 22)
    drawIcon(x + 5, y + 4, icon, 0.82)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(text, x + 25, y + 4)
end

local function drawTabs(self, panelY, ww)
    self.tabButtons = {}
    local x = 12
    for _, tab in ipairs(tabs) do
        local w = math.max(72, love.graphics.getFont():getWidth(tab.label) + 24)
        local active = self.activeTab == tab.id
        love.graphics.setColor(active and 0.18 or 0.09, active and 0.22 or 0.11, active and 0.25 or 0.13, 0.96)
        love.graphics.rectangle("fill", x, panelY + 7, w, 22)
        love.graphics.setColor(active and 0.88 or 0.42, active and 0.94 or 0.46, active and 1.0 or 0.50, 1)
        love.graphics.rectangle("line", x, panelY + 7, w, 22)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(tab.label, x + 12, panelY + 11)
        self.tabButtons[#self.tabButtons + 1] = { id = tab.id, x = x, y = panelY + 7, w = w, h = 22 }
        x = x + w + 6
    end
    love.graphics.setColor(0.46, 0.50, 0.54)
    love.graphics.printf("LMB settlement   RMB agent / drag   Wheel zoom   WASD pan   Space pause   Tab panel", x + 10, panelY + 12, ww - x - 22, "right")
end

function UI:drawWorldPanel(x, y, w, paused, speed)
    local sim = self.sim
    local boats, planned = countBoats(sim.agents)
    local topSettle = topCommunity(sim)
    local nation = topNation(sim)

    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Tick " .. sim.tick .. "   Speed " .. speed .. "x" .. (paused and "   PAUSED" or ""), x, y, w)
    drawPill(x, y + 22, "people", tostring(#sim.agents), 84)
    drawPill(x + 92, y + 22, "birth", tostring(sim.stats.births), 84)
    drawPill(x + 184, y + 22, "death", tostring(sim.stats.deaths), 84)
    drawPill(x + 276, y + 22, "warehouse", tostring(sim:communityCount()), 100)
    drawPill(x + 384, y + 22, "claim", tostring(sim.stats.claims or 0), 94)
    drawPill(x + 486, y + 22, "boat", tostring(boats), 84)
    drawPill(x + 578, y + 22, "plan", tostring(planned), 84)

    local barW = math.max(82, math.floor((w - 30) / 6))
    local by = y + 52
    drawMetric(x, by, barW, "fullness", "Full", avgWellbeing(sim.agents, "fullness"))
    drawMetric(x + (barW + 6), by, barW, "hydration", "Water", avgWellbeing(sim.agents, "hydration"))
    drawMetric(x + (barW + 6) * 2, by, barW, "calm", "Calm", avgWellbeing(sim.agents, "calm"))
    drawMetric(x + (barW + 6) * 3, by, barW, "social", "Social", avgWellbeing(sim.agents, "social"))
    drawMetric(x + (barW + 6) * 4, by, barW, "prosperity", "Prosper", avg(sim.agents, "prosperity"))
    drawMetric(x + (barW + 6) * 5, by, barW, "spirit", "Spirit", avg(sim.agents, "spirituality"))

    local textY = y + 82
    local topLabel = topSettle and (topSettle.name .. " / micro AI") or "-"
    local nationLabel = nation and (nation.name .. " D" .. math.floor(nation.dominance or 0)) or "No nation"
    love.graphics.setColor(0.86, 0.90, 0.94)
    love.graphics.printf("Top settlement: " .. topLabel .. "     Strongest nation: " .. nationLabel, x, textY, w)
end

function UI:drawAgentPanel(x, y, w)
    local sim = self.sim
    local agent = selectedAgent(sim)
    if not agent then
        love.graphics.setColor(0.74, 0.78, 0.82)
        love.graphics.printf("Right-click an agent to inspect needs, task, memory-facing state and inventory.", x, y + 28, w, "center")
        return
    end

    local community = agent.communityId and sim.communities[agent.communityId]
    local nation = community and community.nationId and sim.nations[community.nationId]
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Agent #" .. agent.id .. "   " .. tostring(agent.action or "-") .. "   task " .. tostring(agent.projectTask or agent.nationTask or "-"), x, y, w)

    local colW = math.max(112, math.floor((w - 18) / 4))
    drawMetric(x, y + 22, colW, "fullness", "Full", wellbeing(agent, "fullness"))
    drawMetric(x + colW + 6, y + 22, colW, "hydration", "Water", wellbeing(agent, "hydration"))
    drawMetric(x + (colW + 6) * 2, y + 22, colW, "energy", "Rested", agent.energy)
    drawMetric(x + (colW + 6) * 3, y + 22, colW, "health", "Health", agent.health)
    drawMetric(x, y + 50, colW, "calm", "Calm", wellbeing(agent, "calm"))
    drawMetric(x + colW + 6, y + 50, colW, "social", "Social", wellbeing(agent, "social"))
    drawMetric(x + (colW + 6) * 2, y + 50, colW, "spirit", "Spirit", agent.spirituality or 0)
    drawMetric(x + (colW + 6) * 3, y + 50, colW, "peace", "Peace", wellbeing(agent, "peace"))
    drawMetric(x, y + 78, colW, "prosperity", "Prosper", agent.prosperity or 0)
    drawMetric(x + colW + 6, y + 78, colW, "purpose", "Purpose", agent.purpose or 0)

    local invX = x + (colW + 6) * 2
    drawPill(invX, y + 78, "food", tostring(agent.inventory.food or 0), 72)
    drawPill(invX + 78, y + 78, "animals", tostring(agent.inventory.animals or 0), 72)
    drawPill(invX + 156, y + 78, "wood", tostring(agent.inventory.wood or 0), 72)
    drawPill(invX + 234, y + 78, "stone", tostring(agent.inventory.stone or 0), 72)
    drawPill(invX + 312, y + 78, "iron", tostring(agent.inventory.iron or 0), 72)

    love.graphics.setColor(0.84, 0.88, 0.92)
    love.graphics.printf("Home " .. tostring(agent.homeId or "-") .. "   Age " .. string.format("%.1f", agent.age) .. "   Settlement " .. (community and community.name or "-") .. "   " .. (nation and nation.name or "local settlement AI"), x, y + 107, w)
end

function UI:drawSettlementPanel(x, y, w)
    local sim = self.sim
    local selected = selectedCommunity(sim)
    self.projectButtons = {}
    if not selected then
        love.graphics.setColor(0.74, 0.78, 0.82)
        love.graphics.printf("Left-click claimed land to inspect a settlement and force its strategy while testing.", x, y + 28, w, "center")
        return
    end

    local nation = selected.nationId and sim.nations and sim.nations[selected.nationId]
    local worstName, worst = relationSummary(sim, selected)
    love.graphics.setColor(selected.color)
    love.graphics.rectangle("fill", x, y + 2, 12, 12)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(selected.name .. " #" .. selected.id .. "   " .. (nation and nation.name or "Local micro AI"), x + 18, y, w - 18)

    drawPill(x, y + 22, "people", tostring(selected.members or 0), 78)
    drawPill(x + 84, y + 22, "house", tostring(selected.houses or 0), 78)
    drawPill(x + 168, y + 22, "farm", tostring(selected.farms or 0), 78)
    drawPill(x + 252, y + 22, "animals", tostring(selected.paddocks or 0), 78)
    drawPill(x + 336, y + 22, "mine", tostring(selected.mines or 0), 78)
    drawPill(x + 420, y + 22, "warehouse", tostring(selected.warehouses or 0), 84)
    drawPill(x + 510, y + 22, "shrine", tostring(selected.shrines or 0), 78)
    drawPill(x + 594, y + 22, "water", tostring(selected.ports or 0), 78)
    drawPill(x + 678, y + 22, "claim", tostring(countKeys(selected.claims)), 84)

    local barW = math.max(96, math.floor((w - 24) / 5))
    drawMetric(x, y + 50, barW, "prosperity", "Prosper", selected.avgProsperity or 0)
    drawMetric(x + barW + 6, y + 50, barW, "spirit", "Spirit", selected.avgSpirituality or 0)
    drawMetric(x + (barW + 6) * 2, y + 50, barW, "gear", "Arms", (selected.avgArmament or 0) * 100)
    drawMetric(x + (barW + 6) * 3, y + 50, barW, "relation", worstName .. " " .. math.floor(worst), math.abs(worst), 100)
    drawMetric(x + (barW + 6) * 4, y + 50, barW, "stress", "Disease", selected.diseasePressure or 0)

    drawPill(x, y + 78, "food", tostring(math.floor(selected.store.food or 0)), 78)
    drawPill(x + 84, y + 78, "animals", tostring(math.floor(selected.store.animals or 0)), 78)
    drawPill(x + 168, y + 78, "wood", tostring(math.floor(selected.store.wood or 0)), 78)
    drawPill(x + 252, y + 78, "stone", tostring(math.floor(selected.store.stone or 0)), 78)
    drawPill(x + 336, y + 78, "iron", tostring(math.floor(selected.store.iron or 0)), 78)

    love.graphics.setColor(0.78, 0.82, 0.86)
    love.graphics.printf("Active tasks: " .. taskMixLine(sim, selected), x, y + 108, w)
end

function UI:drawResourcesPanel(x, y, w)
    local sim = self.sim
    local totals = sim.world.totals
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("World stock, structures and current action mix", x, y, w)

    drawPill(x, y + 24, "food", tostring(math.floor(totals.food or 0)), 92)
    drawPill(x + 100, y + 24, "animals", tostring(math.floor(totals.animals or 0)), 92)
    drawPill(x + 200, y + 24, "wood", tostring(math.floor(totals.wood or 0)), 92)
    drawPill(x + 300, y + 24, "stone", tostring(math.floor(totals.stone or 0)), 92)
    drawPill(x + 400, y + 24, "iron", tostring(math.floor(totals.iron or 0)), 92)
    drawPill(x + 510, y + 24, "house", tostring(totals.houses or 0), 78)
    drawPill(x + 594, y + 24, "farm", tostring(totals.farms or 0), 78)
    drawPill(x + 678, y + 24, "warehouse", tostring(totals.warehouses or 0), 84)
    drawPill(x + 768, y + 24, "shrine", tostring(totals.shrines or 0), 78)
    drawPill(x + 852, y + 24, "water", tostring(totals.ports or 0), 78)

    local ranked = rankedActions(sim)
    local ax = x
    local ay = y + 62
    for i = 1, math.min(8, #ranked) do
        local item = ranked[i]
        local label = item.action .. " " .. item.count
        drawPill(ax, ay, item.action == "food" and "food" or "plan", label, 112)
        ax = ax + 120
        if ax + 112 > x + w then
            ax = x
            ay = ay + 26
        end
    end
end

function UI:draw(paused, speed)
    local ww, wh = love.graphics.getDimensions()
    local panelY = wh - PANEL_H
    self.projectButtons = {}

    love.graphics.setColor(0.04, 0.05, 0.06, 0.94)
    love.graphics.rectangle("fill", 0, panelY, ww, PANEL_H)
    drawTabs(self, panelY, ww)

    local x = 12
    local y = panelY + 36
    local w = ww - 24
    if self.activeTab == "agent" then
        self:drawAgentPanel(x, y, w)
    elseif self.activeTab == "settlement" then
        self:drawSettlementPanel(x, y, w)
    elseif self.activeTab == "resources" then
        self:drawResourcesPanel(x, y, w)
    else
        self:drawWorldPanel(x, y, w, paused, speed)
    end
end

function UI:mousepressed(x, y, button)
    if button ~= 1 then
        return false
    end
    for _, tab in ipairs(self.tabButtons or {}) do
        if x >= tab.x and x <= tab.x + tab.w and y >= tab.y and y <= tab.y + tab.h then
            self.activeTab = tab.id
            return true
        end
    end
    for _, item in ipairs(self.projectButtons or {}) do
        if x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h then
            self.sim:setCommunityProject(item.communityId, item.kind)
            return true
        end
    end
    return y >= love.graphics.getHeight() - PANEL_H
end

return UI
