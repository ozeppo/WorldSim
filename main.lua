local Simulation = require("src.simulation")
local Sprites = require("src.ui.sprites")
local UI = require("src.ui.ui")
local Config = require("src.config")

local sim
local ui
local config
local paused = false
local speed = 1

local function newSimulation()
    return Simulation.new({
        width = config.map.width,
        height = config.map.height,
        initialAgents = config.simulation.initialAgents,
        populationCap = config.simulation.populationCap,
        tickStep = config.simulation.tickStep,
        seed = config.map.seed or (os.time() % 100000),
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

function love.load()
    love.window.setTitle("Emergent World Simulation")
    love.window.setMode(1280, 800, { resizable = true, minwidth = 1280, minheight = 720 })
    love.graphics.setDefaultFilter("nearest", "nearest")
    Sprites.load()
    config = Config.load("simulation_config.json")

    sim = newSimulation()
    ui = UI.new(sim)
end

function love.update(dt)
    sim:updateCamera(dt)
    if not paused then
        sim:update(dt * speed)
    end
    ui:update(dt)
end

function love.draw()
    sim:draw()
    ui:draw(paused, speed)
end

function love.keypressed(key)
    if key == "space" then
        paused = not paused
    elseif key == "=" or key == "+" then
        speed = math.min(8, speed * 2)
    elseif key == "-" then
        speed = math.max(0.25, speed / 2)
    elseif key == "r" then
        config.map.seed = os.time() % 100000
        sim = newSimulation()
        ui = UI.new(sim)
    elseif key == "tab" then
        ui.showDetails = not ui.showDetails
    elseif key == "home" then
        sim:centerCamera()
    end
end

function love.wheelmoved(_, y)
    if y ~= 0 then
        local mx, my = love.mouse.getPosition()
        sim:zoomAt(y, mx, my)
    end
end

function love.mousepressed(x, y, button)
    if not ui:mousepressed(x, y, button) then
        sim:mousepressed(x, y, button)
    end
end

function love.mousereleased(x, y, button)
    sim:mousereleased(x, y, button)
end

function love.mousemoved(x, y, dx, dy)
    sim:mousemoved(x, y, dx, dy)
end
