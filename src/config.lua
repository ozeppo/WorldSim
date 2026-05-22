local Config = {}

local defaults = {
    version = "1.0.0",
    map = {
        width = 200,
        height = 128,
        continents = 4,
        continentScale = 1.0,
        archipelagos = 8,
        shallowWaterDepth = 3,
        rivers = 12,
        lakes = 24,
        seed = nil
    },
    simulation = {
        initialAgents = 150,
        populationCap = 420,
        tickStep = 0.18
    },
    resources = {
        forest = 1.0,
        rock = 0.75,
        iron = 0.65,
        animals = 0.55
    }
}

local function clone(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for k, v in pairs(value) do
        result[k] = clone(v)
    end
    return result
end

local function merge(base, override)
    if type(override) ~= "table" then
        return base
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(base[k]) == "table" then
            merge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

local function parseJson(text)
    local index = 1

    local function skipSpace()
        while true do
            local c = text:sub(index, index)
            if c == "" or not c:match("%s") then
                break
            end
            index = index + 1
        end
    end

    local parseValue

    local function parseString()
        index = index + 1
        local result = {}
        while index <= #text do
            local c = text:sub(index, index)
            if c == '"' then
                index = index + 1
                return table.concat(result)
            elseif c == "\\" then
                local n = text:sub(index + 1, index + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                result[#result + 1] = map[n] or n
                index = index + 2
            else
                result[#result + 1] = c
                index = index + 1
            end
        end
        error("Unterminated JSON string")
    end

    local function parseNumber()
        local start = index
        while text:sub(index, index):match("[%d%+%-%.eE]") do
            index = index + 1
        end
        return tonumber(text:sub(start, index - 1))
    end

    local function parseArray()
        index = index + 1
        local result = {}
        skipSpace()
        if text:sub(index, index) == "]" then
            index = index + 1
            return result
        end
        while true do
            result[#result + 1] = parseValue()
            skipSpace()
            local c = text:sub(index, index)
            if c == "]" then
                index = index + 1
                return result
            end
            if c ~= "," then
                error("Expected ',' or ']' in JSON array")
            end
            index = index + 1
        end
    end

    local function parseObject()
        index = index + 1
        local result = {}
        skipSpace()
        if text:sub(index, index) == "}" then
            index = index + 1
            return result
        end
        while true do
            skipSpace()
            if text:sub(index, index) ~= '"' then
                error("Expected JSON object key")
            end
            local key = parseString()
            skipSpace()
            if text:sub(index, index) ~= ":" then
                error("Expected ':' after JSON key")
            end
            index = index + 1
            result[key] = parseValue()
            skipSpace()
            local c = text:sub(index, index)
            if c == "}" then
                index = index + 1
                return result
            end
            if c ~= "," then
                error("Expected ',' or '}' in JSON object")
            end
            index = index + 1
        end
    end

    function parseValue()
        skipSpace()
        local c = text:sub(index, index)
        if c == "{" then
            return parseObject()
        elseif c == "[" then
            return parseArray()
        elseif c == '"' then
            return parseString()
        elseif c == "t" and text:sub(index, index + 3) == "true" then
            index = index + 4
            return true
        elseif c == "f" and text:sub(index, index + 4) == "false" then
            index = index + 5
            return false
        elseif c == "n" and text:sub(index, index + 3) == "null" then
            index = index + 4
            return nil
        end
        return parseNumber()
    end

    return parseValue()
end

function Config.load(path)
    local cfg = clone(defaults)
    path = path or "simulation_config.json"
    if love and love.filesystem and love.filesystem.getInfo(path) then
        local ok, parsed = pcall(parseJson, love.filesystem.read(path))
        if ok and parsed then
            merge(cfg, parsed)
        end
    end
    cfg.map.seed = cfg.map.seed or (os.time() % 100000)
    return cfg
end

return Config
