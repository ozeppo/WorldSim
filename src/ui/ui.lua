local UI = {}
UI.__index = UI

local actionLabels = {
    searchFood = "food",
    searchWater = "water",
    rest = "rest",
    gather = "gather",
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

local manualProjects = {
    { kind = "stockpile", label = "stock" },
    { kind = "housing", label = "housing" },
    { kind = "develop", label = "develop" },
    { kind = "exploration", label = "explore" },
    { kind = "buildShrine", label = "shrine" },
    { kind = "armament", label = "arms" },
    { kind = "war", label = "war" }
}

function UI.new(sim)
    return setmetatable({
        sim = sim,
        showDetails = true,
        selected = nil,
        projectButtons = {}
    }, UI)
end

function UI:update()
    self.sim = self.sim
end

local function avg(agents, field)
    if #agents == 0 then
        return 0
    end
    local sum = 0
    for _, agent in ipairs(agents) do
        sum = sum + agent[field]
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

local function drawBar(x, y, w, h, label, value, color)
    love.graphics.setColor(0, 0, 0, 0.42)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(color)
    love.graphics.rectangle("fill", x, y, w * math.min(1, value / 100), h)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(label .. ": " .. math.floor(value), x + 4, y + 2)
end

local function topCommunity(sim)
    local best
    for _, community in pairs(sim.communities) do
        if not best or community.members > best.members then
            best = community
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

local function countKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

function UI:draw(paused, speed)
    local sim = self.sim
    local _, wh = love.graphics.getDimensions()
    local panelY = wh - 146
    self.projectButtons = {}

    love.graphics.setColor(0.04, 0.05, 0.06, 0.92)
    love.graphics.rectangle("fill", 0, panelY, 1280, 146)
    love.graphics.setColor(1, 1, 1)

    local totals = sim.world.totals
    local boats, planned = countBoats(sim.agents)
    love.graphics.print("Tick " .. sim.tick .. "   Population " .. #sim.agents .. "   Communities " .. sim:communityCount() .. "   Births " .. sim.stats.births .. "   Deaths " .. sim.stats.deaths, 12, panelY + 10)
    love.graphics.print("Food " .. math.floor(totals.food) .. "   Animals " .. math.floor(totals.animals or 0) .. "   Wood " .. math.floor(totals.wood) .. "   Stone " .. math.floor(totals.stone) .. "   Iron " .. math.floor(totals.iron or 0) .. "   Farms " .. totals.farms .. "   Pens " .. (totals.paddocks or 0) .. "   Mines " .. (totals.mines or 0) .. "   Houses " .. totals.houses, 12, panelY + 30)
    love.graphics.print("Claims " .. (sim.stats.claims or 0) .. "   Migrations " .. sim.stats.migrations .. "   Boats " .. boats .. "   Plans " .. planned .. "   Wheel zoom   RMB drag/WASD pan   Home center   Speed " .. speed .. "x" .. (paused and "   PAUSED" or ""), 12, panelY + 50)

    drawBar(12, panelY + 76, 150, 18, "hunger", avg(sim.agents, "hunger"), { 0.95, 0.48, 0.12 })
    drawBar(172, panelY + 76, 150, 18, "thirst", avg(sim.agents, "thirst"), { 0.22, 0.58, 1.0 })
    drawBar(332, panelY + 76, 150, 18, "stress", avg(sim.agents, "stress"), { 0.72, 0.22, 0.9 })
    drawBar(492, panelY + 76, 150, 18, "aggr", avg(sim.agents, "aggression"), { 0.9, 0.15, 0.12 })
    drawBar(652, panelY + 76, 150, 18, "prosper", avg(sim.agents, "prosperity"), { 0.2, 0.78, 0.42 })
    drawBar(12, panelY + 102, 150, 18, "spirit", avg(sim.agents, "spirituality"), { 0.55, 0.68, 1.0 })

    local x = 820
    local y = panelY + 10
    love.graphics.print("Actions", x, y)
    y = y + 18
    local i = 0
    for action, label in pairs(actionLabels) do
        local count = sim.stats.actions[action] or 0
        love.graphics.print(label .. " " .. count, x + (i % 3) * 92, y + math.floor(i / 3) * 18)
        i = i + 1
    end

    if self.showDetails then
        local best = nil
        local worstNeed = -1
        for _, agent in ipairs(sim.agents) do
            local need = math.max(agent.hunger, agent.thirst, 100 - agent.energy, agent.stress, agent.aggression)
            if need > worstNeed then
                best = agent
                worstNeed = need
            end
        end

        if best then
            local sx = 1008
            local community = best.communityId and sim.communities[best.communityId]
            love.graphics.print("Most pressured agent #" .. best.id, sx, panelY + 10)
            love.graphics.print("Action " .. best.action .. "  Age " .. string.format("%.1f", best.age), sx, panelY + 30)
            love.graphics.print("H " .. math.floor(best.hunger) .. " T " .. math.floor(best.thirst) .. " E " .. math.floor(best.energy), sx, panelY + 50)
            love.graphics.print("S " .. math.floor(best.stress) .. " Soc " .. math.floor(best.socialNeed) .. " Spi " .. math.floor(best.spirituality or 0), sx, panelY + 70)
            love.graphics.print("P " .. math.floor(best.prosperity or 0) .. " (" .. math.floor(best.personalProsperity or 0) .. "+" .. math.floor(best.communityProsperity or 0) .. ") Home " .. tostring(best.homeId or "-"), sx, panelY + 90)
            love.graphics.print("C " .. tostring(best.communityId or "-") .. " " .. (community and community.project.kind or "-") .. " Inv F" .. best.inventory.food .. " A" .. (best.inventory.animals or 0) .. " W" .. best.inventory.wood .. " S" .. best.inventory.stone .. " I" .. (best.inventory.iron or 0) .. " " .. (best.sword and "Sw" or "--") .. "/" .. (best.armor and "Ar" or "--"), sx, panelY + 110)
        end
    end

    local community = topCommunity(sim)
    if community then
        love.graphics.setColor(community.color)
        love.graphics.rectangle("fill", 812, panelY + 118, 10, 10)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print("Top: " .. community.name .. " " .. community.project.kind .. "  P" .. math.floor(community.avgProsperity or 0) .. "  Arm" .. math.floor((community.avgArmament or 0) * 100) .. "  store F" .. math.floor(community.store.food or 0) .. " A" .. math.floor(community.store.animals or 0) .. " W" .. math.floor(community.store.wood or 0) .. " S" .. math.floor(community.store.stone or 0) .. " I" .. math.floor(community.store.iron or 0), 828, panelY + 114)
    end

    local selected = sim.selectedCommunityId and sim.communities[sim.selectedCommunityId]
    if selected then
        local x0 = 12
        local y0 = 132
        local worstName, worst = relationSummary(sim, selected)
        love.graphics.setColor(0.04, 0.05, 0.06, 0.88)
        love.graphics.rectangle("fill", x0, y0, 348, 196)
        love.graphics.setColor(selected.color)
        love.graphics.rectangle("fill", x0 + 8, y0 + 8, 14, 14)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(selected.name .. "  #" .. selected.id, x0 + 28, y0 + 7)
        love.graphics.print("Members " .. selected.members .. "  Houses " .. selected.houses .. "  Farms " .. selected.farms .. "  Pens " .. (selected.paddocks or 0) .. "  Mines " .. (selected.mines or 0), x0 + 10, y0 + 30)
        love.graphics.print("Stores " .. selected.warehouses .. "  Shrines " .. selected.shrines .. "  Claims " .. countKeys(selected.claims), x0 + 10, y0 + 48)
        love.graphics.print("Project " .. selected.project.kind .. "  Timer " .. selected.project.timer, x0 + 10, y0 + 66)
        love.graphics.print("Prosperity " .. math.floor(selected.avgProsperity or 0) .. "  Spirit " .. math.floor(selected.avgSpirituality or 0) .. "  Arm " .. math.floor((selected.avgArmament or 0) * 100), x0 + 10, y0 + 84)
        love.graphics.print("Store F" .. math.floor(selected.store.food or 0) .. " A" .. math.floor(selected.store.animals or 0) .. " W" .. math.floor(selected.store.wood or 0) .. " S" .. math.floor(selected.store.stone or 0) .. " I" .. math.floor(selected.store.iron or 0), x0 + 10, y0 + 102)
        love.graphics.print("Worst relation: " .. worstName .. " " .. math.floor(worst), x0 + 10, y0 + 120)
        love.graphics.print("Force project", x0 + 10, y0 + 142)

        for i, project in ipairs(manualProjects) do
            local col = (i - 1) % 4
            local row = math.floor((i - 1) / 4)
            local bx = x0 + 10 + col * 82
            local by = y0 + 162 + row * 22
            local active = selected.project and selected.project.kind == project.kind
            love.graphics.setColor(active and selected.color[1] or 0.16, active and selected.color[2] or 0.18, active and selected.color[3] or 0.20, 0.96)
            love.graphics.rectangle("fill", bx, by, 76, 18)
            love.graphics.setColor(1, 1, 1)
            love.graphics.rectangle("line", bx, by, 76, 18)
            love.graphics.print(project.label, bx + 6, by + 2)
            self.projectButtons[#self.projectButtons + 1] = {
                x = bx,
                y = by,
                w = 76,
                h = 18,
                kind = project.kind,
                communityId = selected.id
            }
        end
    end
end

function UI:mousepressed(x, y, button)
    if button ~= 1 then
        return false
    end
    for _, item in ipairs(self.projectButtons or {}) do
        if x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h then
            self.sim:setCommunityProject(item.communityId, item.kind)
            return true
        end
    end
    if self.sim.selectedCommunityId and x >= 12 and x <= 360 and y >= 132 and y <= 328 then
        return true
    end
    return false
end

return UI
