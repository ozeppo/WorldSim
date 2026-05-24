local Resources = {}

Resources.TILE = {
    grass = "grass",
    sand = "sand",
    snow = "snow",
    forest = "forest",
    water = "water",
    shallowWater = "shallowWater",
    ocean = "ocean",
    rock = "rock",
    mine = "mine",
    path = "path",
    port = "port",
    farm = "farm",
    paddock = "paddock",
    house = "house",
    warehouse = "warehouse",
    shrine = "shrine"
}

Resources.colors = {
    grass = { 0.22, 0.48, 0.22 },
    sand = { 0.70, 0.63, 0.38 },
    snow = { 0.82, 0.88, 0.88 },
    forest = { 0.08, 0.32, 0.13 },
    water = { 0.09, 0.34, 0.75 },
    shallowWater = { 0.06, 0.47, 0.68 },
    ocean = { 0.02, 0.12, 0.30 },
    rock = { 0.34, 0.34, 0.36 },
    mine = { 0.22, 0.21, 0.20 },
    path = { 0.50, 0.43, 0.28 },
    port = { 0.36, 0.28, 0.18 },
    farm = { 0.54, 0.42, 0.17 },
    paddock = { 0.47, 0.36, 0.18 },
    house = { 0.45, 0.26, 0.17 },
    warehouse = { 0.38, 0.30, 0.24 },
    shrine = { 0.34, 0.32, 0.42 }
}

function Resources.tileCapacity(kind)
    if kind == "forest" then
        return { food = 7, wood = 14, stone = 0, iron = 0, animals = 4 }
    elseif kind == "rock" then
        return { food = 0, wood = 0, stone = 10, iron = 0, animals = 0 }
    elseif kind == "farm" then
        return { food = 54, wood = 0, stone = 0, iron = 0, animals = 0 }
    elseif kind == "paddock" then
        return { food = 3, wood = 0, stone = 0, iron = 0, animals = 12 }
    elseif kind == "grass" then
        return { food = 1, wood = 0, stone = 0, iron = 0, animals = 3 }
    elseif kind == "sand" then
        return { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    elseif kind == "snow" then
        return { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    elseif kind == "shallowWater" or kind == "ocean" then
        return { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
    end
    return { food = 0, wood = 0, stone = 0, iron = 0, animals = 0 }
end

function Resources.makeTile(kind)
    local cap = Resources.tileCapacity(kind)
    return {
        type = kind,
        food = math.floor(cap.food * (0.20 + math.random() * 0.45)),
        wood = math.floor(cap.wood * (0.20 + math.random() * 0.45)),
        stone = math.floor(cap.stone * (0.20 + math.random() * 0.45)),
        iron = math.floor(cap.iron * (0.20 + math.random() * 0.45)),
        animals = cap.animals > 0 and (math.random() < 0.24 and 1 or 0) or 0,
        maxFood = cap.food,
        maxWood = cap.wood,
        maxStone = cap.stone,
        maxIron = cap.iron,
        maxAnimals = cap.animals,
        building = nil
    }
end

function Resources.regrow(tile, steps)
    steps = steps or 1
    if tile.type == "forest" then
        tile.food = math.min(tile.maxFood, tile.food + 0.032 * steps)
        tile.wood = math.min(tile.maxWood, tile.wood + 0.018 * steps)
        tile.animals = math.min(tile.maxAnimals or 0, (tile.animals or 0) + 0.010 * steps)
    elseif tile.type == "grass" then
        tile.food = math.min(tile.maxFood, tile.food + 0.008 * steps)
        tile.animals = math.min(tile.maxAnimals or 0, (tile.animals or 0) + 0.004 * steps)
    elseif tile.type == "snow" then
        tile.food = math.min(tile.maxFood, tile.food + 0.001 * steps)
    elseif tile.type == "farm" then
        tile.food = math.min(tile.maxFood, tile.food + 0.36 * steps)
    elseif tile.type == "paddock" then
        tile.food = math.min(tile.maxFood, tile.food + 0.025 * steps)
        tile.animals = math.min(tile.maxAnimals or 0, (tile.animals or 0) + 0.045 * steps)
    end
end

return Resources
