# SimWorld 1.2.0

A systems-driven 2D living-world simulation written in Lua for the LÖVE framework.

This is not a goal-based game and it has no player progression. Autonomous humans survive, settle, migrate, reproduce, form settlements and nations, share resources, trade, fight, collapse and recover through needs, memory, scarcity, proximity, claims and social pressure.

Run the visual version:

```bash
love .
```

Run the high-performance console simulation:

```bash
lua headless.lua
```

Useful headless options:

```bash
lua headless.lua --ticks=5000 --report=250 --events=major
lua headless.lua --ticks=2000 --report=100 --events=all --seed=12345
lua headless.lua --agents=250 --cap=700 --width=260 --height=160
```

`--events=major` reports settlement and nation events. `--events=all` adds construction/destruction events. `--events=none` keeps only periodic world summaries.

## Project Layout

```text
main.lua                 LÖVE visual entry point
headless.lua             high-performance console entry point
conf.lua                 LÖVE configuration
simulation_config.json   world and simulation parameters
src/
  simulation.lua         main simulation loop and system orchestration
  world.lua              map generation, indexes, pathfinding and world rendering
  config.lua             JSON config loader
  entities/              agents, memory, settlements and nations
  systems/               behavior, buildings and resources
  ai/                    runtime AI and exported policies
  ui/                    debug UI and sprites
agent-ai/                PyTorch training and rollout collectors
assets/                  PNG sprites for agents, resources and structures
developer-tools/         asset generation tools
```

## Configuration

Core parameters live in `simulation_config.json`.

```json
{
  "version": "1.2.0",
  "map": {
    "width": 200,
    "height": 200,
    "continents": 4,
    "continentScale": 1.0,
    "archipelagos": 8,
    "shallowWaterDepth": 3,
    "rivers": 12,
    "lakes": 14,
    "seed": null
  },
  "simulation": {
    "initialAgents": 100,
    "populationCap": 600,
    "tickStep": 0.18,
    "agentProductivity": 2.0,
    "diseaseEnabled": true,
    "economyEnabled": true
  },
  "resources": {
    "forest": 1.0,
    "rock": 0.75,
    "iron": 0.65,
    "animals": 0.30
  }
}
```

`seed: null` means a random seed on startup. Higher map size and population cap increase CPU cost because agents plan, pathfind, interact with memory, settlement AI, structures, claims and trade.

## Current Scope

- Large tile world with continents, archipelagos, shallow coastal water, deep ocean, rivers, lakes, beaches, forests, grasslands, rock, snow and latitude-inspired biomes.
- Terrain is rendered as flat-color tiles for performance. PNG assets in `assets` are used for agents, resources, structures and UI/state icons.
- Autonomous agents have hunger, thirst, energy, stress, social need, spirituality, aggression, fertility, health, injury, disease, memory, relationships, satisfaction and purpose.
- Agent needs are layered: survival first, then rest/social/reproduction, then higher-order reward from civic or national tasks.
- Agents use a Lua-exported neural policy trained with PyTorch, combined with live simulation scores so urgent local context can override stale training priors.
- Settlements are warehouse-centered. A warehouse creates a settlement; agents must physically reach a warehouse to deposit or withdraw shared resources.
- Nations contain multiple settlements. A rich settlement can found a nation, and other settlements can join based on relation and benefit.
- Settlement AI manages unaffiliated settlements. Nation AI manages all settlements that belong to a nation.
- Micro-management replaced macro projects: AI assigns stable tasks to agents, such as `deposit`, `buildHouse`, `buildFarm`, `buildPaddock`, `buildMine`, `craftGear`, `raid`, `attackBuilding`, `explore` and `reproduce`.
- Structures include houses, farms, paddocks, mines, warehouses, shrines and ports.
- Strategic resources include food, animals, wood, stone and iron. Mines extract finite stone or iron reserves.
- War emerges from bad relations, border claim friction, armament and resource pressure. Combat includes weapons, armor, injury, death and structure destruction.
- Structural claims define borders: warehouses/shrines claim wider areas, houses claim medium areas, farms/paddocks/mines claim local areas.
- Overcrowded but stable settlements can push small expedition groups outward, creating distant colonies and reducing local clustering.
- Disease is a density-control system: crowded settlements build disease pressure, infect agents and reduce health/energy.
- Proto-economy exists between settlements: settlements can build land paths or coastal ports, then exchange surplus resources depending on needs and relations.
- Paths reduce land movement energy cost; ports enable sea-based trade between coastal settlements.
- Deep ocean can be crossed with more expensive ocean boats, allowing island settlement and inter-island trade.
- The visual UI supports camera pan/zoom, settlement and agent inspection, and tabbed debug views.
- `headless.lua` runs the same simulation without rendering as fast as the CPU allows.

## Agent AI

The agent policy is trained in `agent-ai/train_policy.py`. It rewards long-term survival margins, reproduction and settlement development without simply summing every wellbeing meter. The model can accept temporary hunger, fatigue or discomfort if it supports a stronger long-term outcome.

```bash
lua agent-ai/collect_agent_rollouts.lua --runs=3 --ticks=420 --warmup=30 --sample-every=4 --agents=180 --cap=1000 --width=180 --height=180 --out=agent-ai/agent_real_states.csv --seed=73000
python3 agent-ai/train_policy.py --real-data=agent-ai/agent_real_states.csv --epochs=24 --batch-size=768 --seed=20260526 --synthetic-ratio=0.20
```

The exported policy is loaded from `src/ai/agent_ai_policy.lua`. Runtime inference is pure Lua and does not require PyTorch.

## Nation AI

The national micro-management policy is trained in `agent-ai/train_nation_policy.py`. It assigns civic tasks based on settlement resources, population, infrastructure, claims, nearby resources, enemies and already-assigned tasks.

```bash
lua agent-ai/collect_nation_rollouts.lua --runs=3 --ticks=460 --sample-every=5 --agents=180 --cap=900 --width=180 --height=180 --out=agent-ai/nation_real_states.csv --seed=62000
python3 agent-ai/train_nation_policy.py --real-data=agent-ai/nation_real_states.csv --epochs=24 --batch-size=512 --seed=20260525
```

The exported policy is loaded from `src/ai/nation_ai_policy.lua`. Nation AI does not directly move agents; it assigns stable tasks, and the agent behavior system converts those tasks into concrete actions.

## Changelog

### 1.2.0

- Added configurable `agentProductivity`. One simulated agent can now represent more economic output, allowing similar development with fewer live agents.
- Added disease as a population-density control system. Crowded settlements build disease pressure, agents can become sick, and sickness reduces health and energy.
- Added settlement-level disease stats: pressure and infected count.
- Added roads/paths as intentional infrastructure between settlements. Paths are carved into terrain and reduce land movement energy cost.
- Added ports as coastal structures.
- Added proto-economy: settlements connected by paths, or by ports, can exchange surplus resources based on need and relationship level.
- Added trade-route tracking and headless reporting for ports/routes.
- Added economic route construction that consumes settlement warehouse resources.
- Added stronger pressure for overcrowded, stable settlements to send expedition groups outward.
- Adjusted settlement joining/founding behavior so agents prefer nearby viable settlements but can still found distant new cores.
- Relaxed farm placement consistency so farm indexing and farm construction use the same rules.
- Reduced default population pressure by setting the default simulation to fewer starting agents and lower cap, balanced by higher productivity.
- Updated README to English and promoted the project documentation to version `1.2.0`.

### 1.1.0

- Added nations above settlements. A settlement is a warehouse-centered local population; a nation can own multiple settlements.
- Exploration now creates colonies that can remain positively related to their parent settlement/nation.
- Added separate Nation AI in `src/ai/nation_ai.lua` for micro-management.
- Added `src/ai/nation_ai_policy.lua` and PyTorch training in `agent-ai/train_nation_policy.py`.
- Replaced settlement macro-projects with stable micro-task assignment.
- Added local settlement AI for settlements without a nation.
- Nations no longer appear automatically with the first warehouse. They form only after a settlement is wealthy and populated enough.
- Other settlements can join existing nations based on relation and practical benefit.
- Added deeper agent need/reward logic: need clocks for food, water, rest, social interaction and reproduction, plus satisfaction and purpose.
- Reworked agent decision flow toward `Idle > decide > execute > Idle`.
- Retrained Agent AI and Nation AI after the need/reward and micro-task changes.
- Nation AI now considers already-assigned citizen tasks to avoid flooding one role.
- Nation AI reward moved away from raw warehouse stockpiles and toward claims/territorial control.
- Border conflicts can trigger armament, structure attacks and raids without a manual war project.
- Added real-rollout collection for Nation AI and Agent AI.
- Improved UI readability with tabs, icons, agent inspection and settlement inspection.
- Added ocean travel with more expensive ocean boats.
- Added responsive LÖVE window behavior.
- Improved logistics: agents must physically reach warehouses to deposit or withdraw shared resources.
- Improved population stability after Nation AI changes by allowing housing pressure to emerge naturally from children.
- Added headless high-performance console simulation.

### 1.0.0

- Added configurable world generation through `simulation_config.json`.
- Added continents, archipelagos, rivers, lakes, shallow water, deep ocean, beaches, forests, grasslands, rocks, snow and latitude-inspired biomes.
- Added autonomous agents with needs, memory, trust, relationships, fertility, aggression and social behavior.
- Added settlements, structural claims, warehouses, houses, farms, paddocks, mines, shrines, spirituality and shared storage.
- Added animals, iron, stone, wood and food resources.
- Added finite stone/iron deposits with mine construction.
- Added weapons, armor, combat, injuries, death and building destruction.
- Added camera zoom/pan and debug overlays.
- Added asset-based sprites for agents, resources and structures while keeping terrain color-only for performance.
- Added PyTorch training pipeline and Lua policy export for Agent AI.
- Added high-performance `headless.lua` mode.
