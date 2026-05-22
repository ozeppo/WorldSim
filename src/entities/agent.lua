local Behavior = require("src.systems.behavior")
local Building = require("src.systems.building")
local Memory = require("src.entities.memory")
local Sprites = require("src.ui.sprites")
local World = require("src.world")
local Resources = require("src.systems.resources")

local Agent = {}
Agent.__index = Agent

local SWORD_COST = { iron = 6, wood = 4 }
local ARMOR_COST = { iron = 10 }

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function dist(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

function Agent.new(id, x, y)
    local self = setmetatable({
        id = id,
        x = x,
        y = y,
        age = math.random(14, 42),
        hunger = math.random(12, 36),
        thirst = math.random(12, 36),
        energy = math.random(58, 94),
        stress = math.random(5, 26),
        socialNeed = math.random(10, 48),
        spirituality = math.random(55, 100),
        aggression = math.random(4, 20),
        fertility = math.random(24, 72),
        health = 100,
        injury = 0,
        communityId = nil,
        settleX = nil,
        settleY = nil,
        homeId = nil,
        ownHouseId = nil,
        homeX = nil,
        homeY = nil,
        personalProsperity = 0,
        communityProsperity = 0,
        prosperity = 0,
        parentA = nil,
        parentB = nil,
        children = {},
        migrationCooldown = 0,
        alive = true,
        action = "idle",
        target = nil,
        inventory = {
            food = math.random(2, 8),
            wood = math.random(0, 8),
            stone = math.random(0, 5),
            iron = 0,
            animals = 0
        },
        sword = false,
        armor = false,
        boatDurability = 0,
        planAction = nil,
        planTarget = nil,
        planTicks = 0,
        planPath = nil,
        planPathIndex = 1,
        planPathKey = nil,
        stuckTicks = 0,
        aiSeed = math.random(1, 100000000),
        aiVariance = 0.04 + math.random() * 0.08,
        lastAiAction = nil,
        aiRepeat = 0,
        memory = Memory.new(),
        lastContext = {},
        flash = 0
    }, Agent)
    return self
end

function Agent:availableResource(resource)
    local total = self.inventory[resource] or 0
    local community = self.currentSim and self.communityId and self.currentSim.communities[self.communityId]
    if community and community.hasWarehouse and community.store and self.currentSim:canAccessWarehouse(self) then
        total = total + (community.store[resource] or 0)
    end
    return total
end

function Agent:consumeResource(resource, amount)
    local community = self.currentSim and self.communityId and self.currentSim.communities[self.communityId]
    if community and community.hasWarehouse and community.store and self.currentSim:canAccessWarehouse(self) then
        local take = math.min(community.store[resource] or 0, amount)
        community.store[resource] = (community.store[resource] or 0) - take
        amount = amount - take
    end
    local take = math.min(self.inventory[resource] or 0, amount)
    self.inventory[resource] = (self.inventory[resource] or 0) - take
    amount = amount - take
    return amount <= 0
end

function Agent:canCraftSword()
    return not self.sword and self:availableResource("iron") >= SWORD_COST.iron and self:availableResource("wood") >= SWORD_COST.wood
end

function Agent:canCraftArmor()
    return not self.armor and self:availableResource("iron") >= ARMOR_COST.iron
end

function Agent:militaryPower()
    return (self.sword and 1 or 0) + (self.armor and 0.8 or 0)
end

function Agent:healthScore()
    return clamp(100 - self.hunger * 0.45 - self.thirst * 0.55 - self.stress * 0.25 - self.injury, 0, 100)
end

function Agent:updateNeeds(world, context)
    local comfort = world:comfortAt(self.x, self.y)
    local support = context.communitySupport or 0
    local borderPressure = context.foreignSettlementPressure or 0
    local homeStability = self.homeId and 1 or 0
    self.age = self.age + 0.02
    self.hunger = clamp(self.hunger + 0.84 - homeStability * 0.12 - self.inventory.food * 0.014, 0, 100)
    self.thirst = clamp(self.thirst + 1.05 - homeStability * 0.10, 0, 100)
    self.energy = clamp(self.energy - 0.76 - homeStability * 0.08 - self.injury * 0.015, 0, 100)
    self.socialNeed = clamp(self.socialNeed + 0.7 - support * 0.05, 0, 100)
    self.spirituality = clamp(self.spirituality - 0.28 - math.max(0, self.stress - 55) * 0.012, 0, 100)
    self.stress = clamp(self.stress + context.scarcity * 0.32 + context.overcrowding * 0.42 + borderPressure * 0.45 - comfort * 0.16 - support * 0.18, 0, 100)

    local survivalPressure = math.max(0, self.hunger - 82) * 0.18 + math.max(0, self.thirst - 86) * 0.22
    local memoryPressure = self.memory:negativePressure()
    local scarcityPressure = math.max(0, context.scarcity - 5) * 0.38
    local crowdPressure = math.max(0, context.overcrowding - 6) * 0.12
    self.aggression = clamp(self.aggression + survivalPressure * 0.75 + scarcityPressure * 0.7 + crowdPressure * 0.55 + borderPressure * 0.7 + memoryPressure * 0.08 - comfort * 0.13 - support * 0.24 - 1.35, 0, 100)

    if self.hunger > 88 or self.thirst > 90 then
        self.health = self.health - (math.max(0, self.hunger - 88) + math.max(0, self.thirst - 90)) * 0.065
    else
        self.health = math.min(100, self.health + 0.18)
    end

    if self.energy <= 0 then
        self.stress = clamp(self.stress + 2.5, 0, 100)
        self.health = self.health - 0.35
    end

    if self.health <= 0 or self.age > 90 + math.random() * 12 then
        self.alive = false
    end
end

function Agent:enterTile(world, x, y)
    local tile = world:get(x, y)
    if not tile or not world:canEnter(x, y, self) then
        return false
    end

    if tile.type == Resources.TILE.water or tile.type == Resources.TILE.shallowWater then
        if (self.boatDurability or 0) <= 0 then
            if self.inventory.wood < World.BOAT_COST and self.currentSim then
                self.inventory.wood = self.inventory.wood + self.currentSim:withdrawCommunityResource(self, "wood", World.BOAT_COST - self.inventory.wood)
            end
            if self.inventory.wood < World.BOAT_COST then
                return false
            end
            self.inventory.wood = self.inventory.wood - World.BOAT_COST
            self.boatDurability = World.BOAT_DURABILITY
        end
        self.boatDurability = math.max(0, self.boatDurability - 1)
        self.energy = clamp(self.energy - 1.15, 0, 100)
    else
        self.energy = clamp(self.energy - 0.8, 0, 100)
    end

    self.x = x
    self.y = y
    return true
end

function Agent:clearPath()
    self.planPath = nil
    self.planPathIndex = 1
    self.planPathKey = nil
end

function Agent:moveToward(world, tx, ty)
    if not tx or not ty then
        return false
    end
    if self.x == tx and self.y == ty then
        return true
    end

    local destX, destY = tx, ty
    if not world:canEnter(tx, ty, self) then
        if dist(self.x, self.y, tx, ty) <= 1.1 then
            return true
        end

        local best
        local bestD = math.huge
        for _, p in ipairs(world:neighbors(tx, ty)) do
            if world:canEnter(p.x, p.y, self) then
                local d = math.abs(self.x - p.x) + math.abs(self.y - p.y)
                if d < bestD then
                    best = p
                    bestD = d
                end
            end
        end
        if not best then
            return false
        end
        destX, destY = best.x, best.y
    end

    if self.x == destX and self.y == destY then
        return true
    end

    local key = destX .. "," .. destY .. ":" .. tostring((self.boatDurability or 0) > 0 or self.inventory.wood >= World.BOAT_COST)
    local manhattan = math.abs(self.x - destX) + math.abs(self.y - destY)
    if manhattan <= 10 then
        local best
        local bestD = manhattan
        for _, p in ipairs(world:neighbors(self.x, self.y)) do
            if world:canEnter(p.x, p.y, self) then
                local d = math.abs(p.x - destX) + math.abs(p.y - destY)
                if d < bestD then
                    best = p
                    bestD = d
                end
            end
        end
        if best and self:enterTile(world, best.x, best.y) then
            return false
        end
    end

    if self.planPathKey ~= key or not self.planPath or (self.planPathIndex or 1) > #self.planPath then
        self.planPath = world:findPath(self.x, self.y, destX, destY, self, 44)
        self.planPathIndex = 1
        self.planPathKey = key
    end

    if not self.planPath or #self.planPath == 0 or (self.planPathIndex or 1) > #self.planPath then
        local best
        local bestD = math.abs(self.x - destX) + math.abs(self.y - destY)
        for _, p in ipairs(world:neighbors(self.x, self.y)) do
            if world:canEnter(p.x, p.y, self) then
                local d = math.abs(p.x - destX) + math.abs(p.y - destY)
                if d < bestD then
                    best = p
                    bestD = d
                end
            end
        end
        if best and self:enterTile(world, best.x, best.y) then
            return false
        end
        return false
    end

    local step = self.planPath[self.planPathIndex or 1]
    self.planPathIndex = (self.planPathIndex or 1) + 1
    if not self:enterTile(world, step.x, step.y) then
        self:clearPath()
        return false
    end

    return self.x == destX and self.y == destY or dist(self.x, self.y, tx, ty) <= 1.1
end

function Agent:wander(world)
    local options = world:neighbors(self.x, self.y)
    for _ = 1, #options do
        local p = options[math.random(1, #options)]
        if world:canEnter(p.x, p.y, self) and self:enterTile(world, p.x, p.y) then
            return
        end
    end
end

function Agent:eat()
    if self.inventory.food <= 0 and self.currentSim and self.hunger > 44 then
        self.inventory.food = self.inventory.food + self.currentSim:withdrawCommunityResource(self, "food", 1)
    end
    if self.inventory.food > 0 and self.hunger > 34 then
        self.inventory.food = self.inventory.food - 1
        self.hunger = clamp(self.hunger - 38, 0, 100)
        self.stress = clamp(self.stress - 2, 0, 100)
        return true
    end
    if self.hunger > 68 then
        if (self.inventory.animals or 0) <= 0 and self.currentSim then
            self.inventory.animals = (self.inventory.animals or 0) + self.currentSim:withdrawCommunityResource(self, "animals", 1)
        end
        if (self.inventory.animals or 0) > 0 then
            self.inventory.animals = self.inventory.animals - 1
            self.hunger = clamp(self.hunger - 52, 0, 100)
            self.stress = clamp(self.stress - 1.4, 0, 100)
            return true
        end
    end
    return false
end

function Agent:performSearchFood(world, target)
    if self:eat() then
        return self.hunger < 35
    end

    if target then
        if dist(self.x, self.y, target.x, target.y) <= 1.1 or self:moveToward(world, target.x, target.y) then
            local resource = target.resource or "food"
            local amount = world:gather(target.x, target.y, resource, resource == "animals" and 3 or 12)
            self.inventory[resource] = (self.inventory[resource] or 0) + amount
            if amount > 0 then
                self:eat()
                self.stress = clamp(self.stress - 1.2, 0, 100)
                return self.hunger < 35 or self.inventory.food >= 4 or (self.inventory.animals or 0) >= 2
            end
        end
    else
        self:wander(world)
        self.stress = clamp(self.stress + 1.4, 0, 100)
    end
    return false
end

function Agent:performSearchWater(world, target)
    if target then
        if dist(self.x, self.y, target.x, target.y) <= 1.1 or self:moveToward(world, target.x, target.y) then
            self.thirst = clamp(self.thirst - 58, 0, 100)
            self.stress = clamp(self.stress - 3, 0, 100)
            return self.thirst < 25
        end
    else
        self:wander(world)
        self.stress = clamp(self.stress + 2.2, 0, 100)
    end
    return false
end

function Agent:performRest(world)
    if not self.homeId or not self.homeX or not self.homeY then
        self.stress = clamp(self.stress + 1.6, 0, 100)
        return false
    end
    if self.homeX and self.homeY and dist(self.x, self.y, self.homeX, self.homeY) > 1.2 then
        self:moveToward(world, self.homeX, self.homeY)
        return false
    end

    local tile = world:get(self.x, self.y)
    if not tile or tile.type ~= Resources.TILE.house then
        self:moveToward(world, self.homeX, self.homeY)
        return false
    end
    local houseBonus = 2.2
    local comfort = world:comfortAt(self.x, self.y)
    self.energy = clamp(self.energy + 9 * houseBonus, 0, 100)
    self.stress = clamp(self.stress - 2.5 * houseBonus - comfort * 0.05, 0, 100)
    self.injury = clamp(self.injury - 0.7 * houseBonus, 0, 100)
    return self.energy > 84 and self.stress < 35
end

function Agent:performGather(world, target)
    local needWood = self.inventory.wood < 36
    local resource = target and target.resource or (needWood and "wood" or "stone")
    if target and target.tile then
        if (target.tile[resource] or 0) > 2 then
            resource = resource
        elseif (target.tile.iron or 0) > 1 then
            resource = "iron"
        elseif (target.tile.wood or 0) > 2 then
            resource = "wood"
        elseif (target.tile.stone or 0) > 2 then
            resource = "stone"
        end
    end
    local sx = self.homeX or self.x
    local sy = self.homeY or self.y
    target = target or world:findNearest(sx, sy, function(tile)
        return (tile[resource] or 0) > 2
    end, 18)

    if target then
        if dist(self.x, self.y, target.x, target.y) <= 1.1 or self:moveToward(world, target.x, target.y) then
            local amount = world:gather(target.x, target.y, resource, 6)
            self.inventory[resource] = (self.inventory[resource] or 0) + amount
            self.energy = clamp(self.energy - amount * 0.4, 0, 100)
            return amount <= 0 or (self.inventory.wood >= 52 and self.inventory.stone >= 34 and (self.inventory.iron or 0) >= 12)
        end
    else
        self:wander(world)
    end
    return false
end

function Agent:performUseWarehouse(target, sim)
    local warehouse = target and target.building or (self.communityId and sim:nearestBuilding(self.x, self.y, "warehouse", self.communityId))
    if not warehouse then
        return true
    end

    local accessX = warehouse.x
    local accessY = warehouse.y
    if dist(self.x, self.y, accessX, accessY) > 1.2 and not sim:canAccessWarehouse(self) then
        self:moveToward(sim.world, accessX, accessY)
        return false
    end

    local deposited = sim:depositCommunityResources(self)
    local withdrawn = 0
    local request = target and target.withdraw
    if request then
        for resource, amount in pairs(request) do
            if amount > 0 then
                local taken = sim:withdrawCommunityResource(self, resource, amount)
                self.inventory[resource] = (self.inventory[resource] or 0) + taken
                withdrawn = withdrawn + taken
            end
        end
    end

    if target and target.eat then
        self:eat()
    end
    if deposited > 0 or withdrawn > 0 then
        self.stress = clamp(self.stress - 1.5, 0, 100)
    end
    return true
end

function Agent:performCraftGear()
    local crafted = false
    if self:canCraftSword() then
        self:consumeResource("iron", SWORD_COST.iron)
        self:consumeResource("wood", SWORD_COST.wood)
        self.sword = true
        crafted = true
    elseif self:canCraftArmor() then
        self:consumeResource("iron", ARMOR_COST.iron)
        self.armor = true
        crafted = true
    end
    if crafted then
        self.energy = clamp(self.energy - 8, 0, 100)
        self.stress = clamp(self.stress - 3, 0, 100)
        return true
    end
    return true
end

function Agent:performBuild(world, kind, site)
    if not site then
        self:wander(world)
        return false
    end
    if self:moveToward(world, site.x, site.y) then
        if self.currentSim and not self.communityId and kind ~= "warehouse" then
            self.currentSim:formOrJoinCommunity(self)
        end
        local contributors = self.currentSim and self.currentSim:nearAgents(self.x, self.y, 4, self.id) or {}
        local parentCommunityId = nil
        local oldCommunityId = nil
        if kind == "warehouse" and self.expedition and self.expedition.parentCommunityId then
            parentCommunityId = self.expedition.parentCommunityId
            oldCommunityId = self.communityId
            self.communityId = nil
        end
        local built, building = Building.build(world, self, kind, site.x, site.y, contributors)
        if not built and oldCommunityId then
            self.communityId = oldCommunityId
        end
        if built then
            if self.currentSim and kind == "warehouse" and building and not building.communityId then
                self.currentSim:foundCommunityFromWarehouse(self, building, contributors, parentCommunityId)
            end
            if self.currentSim and building then
                self.currentSim:onBuildingBuilt(building)
            end
            if kind == "house" and building then
                self.ownHouseId = building.id
                self.homeId = building.id
                self.homeX = building.x
                self.homeY = building.y
            end
            self.stress = clamp(self.stress - 8, 0, 100)
            self.energy = clamp(self.energy - 8, 0, 100)
            for _, other in ipairs(contributors) do
                if self.currentSim and other.communityId == self.communityId then
                    self.memory:record(other.id, "help", 0.4, self.currentSim.tick)
                    other.memory:record(self.id, "help", 0.5, self.currentSim.tick)
                end
            end
            return true
        end
    end
    return false
end

function Agent:performSocialize(other, sim)
    if not other or not other.alive then
        self:wander(sim.world)
        return true
    end
    if dist(self.x, self.y, other.x, other.y) > 1.2 then
        self:moveToward(sim.world, other.x, other.y)
        return false
    end

    self.socialNeed = clamp(self.socialNeed - 22, 0, 100)
    self.stress = clamp(self.stress - 4, 0, 100)
    other.socialNeed = clamp(other.socialNeed - 10, 0, 100)
    self.memory:record(other.id, "social", 1, sim.tick)
    other.memory:record(self.id, "social", 1, sim.tick)
    if self.communityId and not other.communityId and self.memory:trust(other.id) > 12 then
        sim:joinCommunity(other, self.communityId)
    elseif other.communityId and not self.communityId and other.memory:trust(self.id) > 12 then
        sim:joinCommunity(self, other.communityId)
    elseif not self.communityId and not other.communityId and self.memory:trust(other.id) > 18 then
        sim:formOrJoinCommunity(self, other)
    end
    return true
end

function Agent:performHelp(other, sim)
    if not other or not other.alive then
        return true
    end
    if dist(self.x, self.y, other.x, other.y) > 1.2 then
        self:moveToward(sim.world, other.x, other.y)
        return false
    end

    if self.inventory.food > 1 and other.hunger > 58 then
        self.inventory.food = self.inventory.food - 1
        other.inventory.food = other.inventory.food + 1
        other:eat()
        self.memory:record(other.id, "help", 1.2, sim.tick)
        other.memory:record(self.id, "help", 1.8, sim.tick)
        self.socialNeed = clamp(self.socialNeed - 8, 0, 100)
    else
        other.memory:record(self.id, "refused", 0.6, sim.tick)
    end
    return true
end

function Agent:performAttack(other, sim)
    if not other or not other.alive then
        return true
    end
    if (self.communityId and other.communityId == self.communityId)
        or self.parentA == other.id
        or self.parentB == other.id
        or other.parentA == self.id
        or other.parentB == self.id
        or self.children[other.id]
        or other.children[self.id] then
        self.aggression = clamp(self.aggression - 18, 0, 100)
        self.stress = clamp(self.stress + 4, 0, 100)
        sim:migrateAgent(self)
        return true
    end
    if dist(self.x, self.y, other.x, other.y) > 1.2 then
        self:moveToward(sim.world, other.x, other.y)
        return false
    end

    local myPower = self.energy + self:healthScore() + self.aggression * 0.6 - self.injury + (self.sword and 34 or 0) + (self.armor and 14 or 0)
    local theirPower = other.energy + other:healthScore() + other.aggression * 0.4 - other.injury + (other.sword and 28 or 0) + (other.armor and 24 or 0)
    local margin = myPower - theirPower + math.random(-18, 18)
    local winner = margin >= 0 and self or other
    local loser = margin >= 0 and other or self

    local attackBonus = winner.sword and 13 or 0
    local armorReduction = loser.armor and 11 or 0
    local wound = math.max(5, 18 + attackBonus - armorReduction + math.abs(margin) * 0.07)
    loser.injury = clamp(loser.injury + wound * 1.15, 0, 100)
    loser.health = loser.health - wound
    winner.energy = clamp(winner.energy - 18, 0, 100)
    winner.stress = clamp(winner.stress + 11, 0, 100)
    winner.aggression = clamp(winner.aggression - 12, 0, 100)
    loser.aggression = clamp(loser.aggression + 18, 0, 100)

    if loser.inventory.food > 0 then
        local stolen = math.min(loser.inventory.food, 2)
        loser.inventory.food = loser.inventory.food - stolen
        winner.inventory.food = winner.inventory.food + stolen
    end
    if loser.inventory.iron and loser.inventory.iron > 0 then
        local stolenIron = math.min(loser.inventory.iron, 2)
        loser.inventory.iron = loser.inventory.iron - stolenIron
        winner.inventory.iron = (winner.inventory.iron or 0) + stolenIron
    end

    self.memory:record(other.id, "harm", 2.0, sim.tick)
    other.memory:record(self.id, "harm", 2.4, sim.tick)
    if self.communityId and other.communityId and self.communityId ~= other.communityId then
        sim:adjustRelation(self.communityId, other.communityId, -8)
    end
    self.flash = 0.35
    other.flash = 0.35

    if loser.health <= 0 or loser.injury >= 100 then
        loser.alive = false
        winner.stress = clamp(winner.stress + 18, 0, 100)
    end
    return true
end

function Agent:performAttackBuilding(building, sim)
    if not building or building.active == false then
        return true
    end
    if self.communityId and building.communityId == self.communityId then
        self.aggression = clamp(self.aggression - 12, 0, 100)
        return true
    end
    if dist(self.x, self.y, building.x, building.y) > 1.6 then
        self:moveToward(sim.world, building.x, building.y)
        return false
    end

    local damage = 8 + self.aggression * 0.09 + (self.sword and 18 or 0)
    if building.type == "farm" then
        damage = damage + 8
    elseif building.type == "warehouse" or building.type == "shrine" then
        damage = damage * 0.82
    end
    building.health = (building.health or building.maxHealth or 80) - damage
    self.energy = clamp(self.energy - 10, 0, 100)
    self.stress = clamp(self.stress + 4, 0, 100)
    self.flash = 0.25

    if building.health <= 0 then
        sim:destroyBuilding(building, self)
        self.aggression = clamp(self.aggression - 10, 0, 100)
        self.stress = clamp(self.stress + 10, 0, 100)
        return true
    end
    return false
end

function Agent:performReproduce(partner, sim)
    if not partner or not partner.alive then
        return true
    end
    if dist(self.x, self.y, partner.x, partner.y) > 1.2 then
        self:moveToward(sim.world, partner.x, partner.y)
        return false
    end

    if sim.populationCap and #sim.agents >= sim.populationCap then
        self.stress = clamp(self.stress + 4, 0, 100)
        return true
    end

    local home = sim:getBuilding(self.homeId)
    local partnerHome = sim:getBuilding(partner.homeId)
    local familyHome = sim:nearestHouse(self.x, self.y, self.communityId or partner.communityId, true)
        or (home and (home.occupants or 0) < (home.capacity or 2) and home)
        or (partnerHome and (partnerHome.occupants or 0) < (partnerHome.capacity or 2) and partnerHome)
    local nearbyResources = sim.world:resourcePressureAround(self.homeX or self.x, self.homeY or self.y, 9)
    local storedFood = 0
    local community = (self.communityId or partner.communityId) and sim.communities[self.communityId or partner.communityId]
    if community and community.store then
        storedFood = (community.store.food or 0) + (community.store.animals or 0) * 1.8
    end
    if familyHome and (familyHome.occupants or 0) < (familyHome.capacity or 2) and (nearbyResources.food + nearbyResources.animals * 1.6 + storedFood) > 58 and nearbyResources.water > 0 and self.energy > 34 and partner.energy > 32 then
        local childX, childY = sim.world:findRandomWalkable()
        for _, p in ipairs(sim.world:neighbors(familyHome.x, familyHome.y)) do
            if sim.world:isWalkable(p.x, p.y) then
                childX, childY = p.x, p.y
                break
            end
        end

        local child = sim:addAgent(childX, childY)
        child.age = 0
        child.parentA = self.id
        child.parentB = partner.id
        child.communityId = self.communityId or partner.communityId
        child.homeId = familyHome.id
        child.homeX = familyHome.x
        child.homeY = familyHome.y
        child.settleX = familyHome.x
        child.settleY = familyHome.y
        self.children[child.id] = true
        partner.children[child.id] = true
        child.hunger = 28
        child.thirst = 28
        child.energy = 72
        child.stress = 8
        child.fertility = math.floor((self.fertility + partner.fertility) / 2 + math.random(-12, 12))
        child.inventory.food = math.floor((self.inventory.food + partner.inventory.food) * 0.12)
        child.inventory.animals = 0
        self.inventory.food = math.max(0, self.inventory.food - 2)
        partner.inventory.food = math.max(0, partner.inventory.food - 2)
        self.energy = clamp(self.energy - 14, 0, 100)
        partner.energy = clamp(partner.energy - 12, 0, 100)
        self.fertility = clamp(self.fertility - 11, 0, 100)
        partner.fertility = clamp(partner.fertility - 9, 0, 100)
        self.memory:record(partner.id, "help", 1, sim.tick)
        partner.memory:record(self.id, "help", 1, sim.tick)
        self.memory:record(child.id, "help", 4, sim.tick)
        partner.memory:record(child.id, "help", 4, sim.tick)
        child.memory:record(self.id, "help", 4, sim.tick)
        child.memory:record(partner.id, "help", 4, sim.tick)
        return true
    end
    return false
end

function Agent:performFormCommunity(target, sim)
    sim:formOrJoinCommunity(self, target)
    self.socialNeed = clamp(self.socialNeed - 18, 0, 100)
    self.stress = clamp(self.stress - 7, 0, 100)
    self.aggression = clamp(self.aggression - 10, 0, 100)
    return true
end

function Agent:performMigrateCommunity(target, sim)
    local joined = sim:migrateAgent(self, target)
    if joined then
        self.stress = clamp(self.stress - 9, 0, 100)
        self.aggression = clamp(self.aggression - 18, 0, 100)
        return true
    end

    local x, y = sim.world:findRandomWalkable()
    self:moveToward(sim.world, x, y)
    if math.random() < 0.25 then
        sim:leaveCommunity(self)
    end
    self.stress = clamp(self.stress - 2, 0, 100)
    self.aggression = clamp(self.aggression - 7, 0, 100)
    return true
end

function Agent:performWorship(shrine, sim)
    if not shrine or shrine.active == false then
        return true
    end
    if dist(self.x, self.y, shrine.x, shrine.y) > 1.6 then
        self:moveToward(sim.world, shrine.x, shrine.y)
        return false
    end

    self.spirituality = 100
    self.stress = clamp(self.stress - 12, 0, 100)
    self.aggression = clamp(self.aggression - 8, 0, 100)
    self.socialNeed = clamp(self.socialNeed - 6, 0, 100)
    return true
end

function Agent:shouldInterruptPlan()
    if not self.planAction or self.planTicks <= 0 then
        return true
    end
    if self.thirst > 88 and self.planAction ~= "searchWater" then
        return true
    end
    if self.hunger > 88 and self.inventory.food <= 0 and (self.inventory.animals or 0) <= 0 and self.planAction ~= "searchFood" then
        return true
    end
    if self.energy < 10 and self.planAction ~= "rest" then
        return true
    end
    if self.spirituality < 12 and self.planAction ~= "worship" then
        return true
    end
    local target = self.planTarget
    if target and target.alive == false then
        return true
    end
    return false
end

function Agent:setPlan(action, target, context)
    if action ~= self.planAction or target ~= self.planTarget then
        self:clearPath()
    end
    self.planAction = action
    self.planTarget = target
    self.planTicks = math.random(7, 18)
    self.lastContext = context or self.lastContext
end

function Agent:finishPlan()
    self.planAction = nil
    self.planTarget = nil
    self.planTicks = 0
    self.stuckTicks = 0
    self:clearPath()
end

function Agent:tick(sim)
    if not self.alive then
        return
    end

    if self.flash > 0 then
        self.flash = math.max(0, self.flash - sim.tickStep)
    end
    self.migrationCooldown = math.max(0, self.migrationCooldown - 1)

    self.currentSim = sim
    local action
    local target
    local context = self.lastContext
    if self:shouldInterruptPlan() then
        action, target, context = Behavior.choose(self, sim)
        self:setPlan(action, target, context)
    else
        action = self.planAction
        target = self.planTarget
        self.planTicks = self.planTicks - 1
    end

    context = context or { scarcity = 0, overcrowding = 0, nearby = 0, communitySupport = 0, foreignSettlementPressure = 0 }
    self.lastContext = context
    self:updateNeeds(sim.world, context)
    self.action = action
    self.target = target

    if not self.alive then
        return
    end

    local done = false
    local startX, startY = self.x, self.y
    if action == "searchFood" then
        done = self:performSearchFood(sim.world, target)
    elseif action == "searchWater" then
        done = self:performSearchWater(sim.world, target)
    elseif action == "rest" then
        done = self:performRest(sim.world)
    elseif action == "gather" then
        done = self:performGather(sim.world, target)
    elseif action == "useWarehouse" then
        done = self:performUseWarehouse(target, sim)
    elseif action == "craftGear" then
        done = self:performCraftGear()
    elseif action == "buildHouse" then
        done = self:performBuild(sim.world, "house", target)
    elseif action == "buildFarm" then
        done = self:performBuild(sim.world, "farm", target)
    elseif action == "buildPaddock" then
        done = self:performBuild(sim.world, "paddock", target)
    elseif action == "buildMine" then
        done = self:performBuild(sim.world, "mine", target)
    elseif action == "buildWarehouse" then
        done = self:performBuild(sim.world, "warehouse", target)
    elseif action == "buildShrine" then
        done = self:performBuild(sim.world, "shrine", target)
    elseif action == "worship" then
        done = self:performWorship(target, sim)
    elseif action == "formCommunity" then
        done = self:performFormCommunity(target, sim)
    elseif action == "migrateCommunity" then
        done = self:performMigrateCommunity(target, sim)
    elseif action == "socialize" then
        done = self:performSocialize(target, sim)
    elseif action == "help" then
        done = self:performHelp(target, sim)
    elseif action == "attack" then
        done = self:performAttack(target, sim)
    elseif action == "attackBuilding" then
        done = self:performAttackBuilding(target, sim)
    elseif action == "reproduce" then
        done = self:performReproduce(target, sim)
    elseif action == "explore" then
        done = target and self:moveToward(sim.world, target.x, target.y) or true
    else
        self:wander(sim.world)
    end

    if not done and self.x == startX and self.y == startY and action ~= "rest" and action ~= "craftGear" then
        self.stuckTicks = (self.stuckTicks or 0) + 1
        if self.stuckTicks >= 3 then
            self:wander(sim.world)
            done = true
        else
            self.planTicks = math.min(self.planTicks, 2)
        end
    else
        self.stuckTicks = 0
    end

    if done or self.planTicks <= 0 then
        self:finishPlan()
    end

    self.health = clamp(self.health, 0, 100)
    self.hunger = clamp(self.hunger, 0, 100)
    self.thirst = clamp(self.thirst, 0, 100)
    self.energy = clamp(self.energy, 0, 100)
    self.stress = clamp(self.stress, 0, 100)
    self.socialNeed = clamp(self.socialNeed, 0, 100)
    self.spirituality = clamp(self.spirituality, 0, 100)
    self.aggression = clamp(self.aggression, 0, 100)
    self.fertility = clamp(self.fertility + 0.12, 0, 100)
    self.currentSim = nil
end

function Agent:draw()
    local size = World.TILE_SIZE
    local px = (self.x - 1) * size
    local py = (self.y - 1) * size
    local communityColor = self.currentDrawCommunityColor

    if self.flash > 0 then
        communityColor = { 1, 1, 1 }
    end

    local actionIcon = self.action
    if self.aggression > 70 then
        actionIcon = "attack"
    elseif self.thirst > 72 then
        actionIcon = "searchWater"
    elseif self.hunger > 72 then
        actionIcon = "searchFood"
    elseif self.stress > 76 then
        actionIcon = "stress"
    end

    if not Sprites.drawAgent(actionIcon, px, py, communityColor, (self.boatDurability or 0) > 0) then
        love.graphics.setColor(communityColor or { 0.88, 0.88, 0.78 })
        love.graphics.rectangle("fill", px + 8, py + 8, 16, 16)
        love.graphics.setColor(0, 0, 0, 0.65)
        love.graphics.rectangle("line", px + 8, py + 8, 16, 16)
    end

    if self.armor then
        love.graphics.setColor(0.68, 0.72, 0.76, 0.9)
        love.graphics.rectangle("line", px + 9, py + 12, 14, 11)
    end
    if self.sword then
        love.graphics.setColor(0.9, 0.88, 0.72, 0.95)
        love.graphics.line(px + 23, py + 9, px + 29, py + 3)
        love.graphics.line(px + 22, py + 10, px + 25, py + 13)
    end

    love.graphics.setColor(0.1, 0.9, 0.25)
    love.graphics.rectangle("fill", px + 6, py + 27, 20 * (self.health / 100), 3)
end

return Agent
