local Memory = {}
Memory.__index = Memory

local MAX_EVENTS = 8

function Memory.new()
    return setmetatable({
        people = {},
        recent = {}
    }, Memory)
end

function Memory:_entry(id)
    local entry = self.people[id]
    if not entry then
        entry = {
            trust = 0,
            positive = 0,
            negative = 0,
            helped = 0,
            harmed = 0,
            lastTick = 0
        }
        self.people[id] = entry
    end
    return entry
end

function Memory:trust(id)
    local entry = self.people[id]
    return entry and entry.trust or 0
end

function Memory:record(id, kind, amount, tick)
    if not id then
        return
    end

    local entry = self:_entry(id)
    amount = amount or 1
    tick = tick or 0

    if kind == "help" then
        entry.positive = entry.positive + amount
        entry.helped = entry.helped + 1
        entry.trust = math.min(100, entry.trust + amount * 10)
    elseif kind == "social" then
        entry.positive = entry.positive + amount
        entry.trust = math.min(100, entry.trust + amount * 5)
    elseif kind == "harm" then
        entry.negative = entry.negative + amount
        entry.harmed = entry.harmed + 1
        entry.trust = math.max(-100, entry.trust - amount * 16)
    elseif kind == "refused" then
        entry.negative = entry.negative + amount
        entry.trust = math.max(-100, entry.trust - amount * 5)
    end

    entry.lastTick = tick
    self.recent[#self.recent + 1] = {
        id = id,
        kind = kind,
        tick = tick
    }

    while #self.recent > MAX_EVENTS do
        table.remove(self.recent, 1)
    end
end

function Memory:negativePressure()
    local pressure = 0
    for _, entry in pairs(self.people) do
        if entry.trust < 0 then
            pressure = pressure + math.min(8, -entry.trust / 14)
        end
    end
    return pressure
end

function Memory:bestBond(candidates)
    local best
    local bestTrust = -101
    for _, agent in ipairs(candidates) do
        local trust = self:trust(agent.id)
        if trust > bestTrust then
            best = agent
            bestTrust = trust
        end
    end
    return best, bestTrust
end

return Memory
