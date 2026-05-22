#!/usr/bin/env python3
import argparse
import json
import math
import os
import random
from dataclasses import dataclass

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
except ImportError as exc:
    raise SystemExit(
        "PyTorch is not installed for this Python interpreter. "
        "Install it with `python3 -m pip install torch` and run this script again."
    ) from exc


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_LUA = os.path.join(ROOT, "src", "ai", "agent_ai_policy.lua")

ACTIONS = [
    "searchFood",
    "searchWater",
    "rest",
    "gather",
    "useWarehouse",
    "buildHouse",
    "buildFarm",
    "buildPaddock",
    "buildMine",
    "buildWarehouse",
    "buildShrine",
    "worship",
    "socialize",
    "help",
    "formCommunity",
    "migrateCommunity",
    "reproduce",
    "craftGear",
    "attack",
    "attackBuilding",
    "explore",
]

PROJECTS = ["none", "stockpile", "housing", "develop", "buildWarehouse", "buildShrine", "armament", "war", "exploration"]
BASE_FEATURES = [
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
    "sameCommunityNear",
]

INPUT_SIZE = len(BASE_FEATURES) + len(PROJECTS) + len(ACTIONS)


class PolicyNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(INPUT_SIZE, 64)
        self.fc2 = nn.Linear(64, 48)
        self.out = nn.Linear(48, len(ACTIONS))

    def forward(self, x):
        x = F.relu(self.fc1(x))
        x = F.relu(self.fc2(x))
        return self.out(x)


@dataclass
class Sample:
    x: list
    y: int


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def one_hot(index, size):
    return [1.0 if i == index else 0.0 for i in range(size)]


def random_state():
    project = random.randrange(len(PROJECTS))
    hunger = random.betavariate(1.5, 2.2)
    thirst = random.betavariate(1.5, 2.0)
    energy = random.betavariate(2.0, 1.8)
    stress = random.betavariate(1.3, 2.5)
    prosperity = random.betavariate(1.5, 1.7)
    has_home = random.random() < prosperity * 0.85
    has_community = random.random() < 0.72
    community_members = random.random() ** 0.55
    housing_shortage = clamp(random.random() * (1.0 - prosperity * 0.45))
    local_water = clamp(random.random() + (0.28 if has_community else 0.0))
    local_food = clamp(random.random() * 0.8 + local_water * 0.28)
    local_wood = random.random()
    local_stone = random.random()
    local_iron = random.random() * random.random()
    local_animals = random.random() * random.random()
    inv_food = random.random() * max(0.15, prosperity)
    inv_wood = random.random() * (0.35 + prosperity)
    inv_stone = random.random() * (0.25 + prosperity)
    inv_iron = random.random() * prosperity
    inv_animals = random.random() * prosperity * 0.6
    scarcity = clamp((1.0 - local_food) * 0.48 + (1.0 - local_water) * 0.52)
    overcrowding = random.random() * (community_members + 0.3)
    trusted = random.random() * (0.25 + (0.65 if has_community else 0.2))
    same = random.random() * (0.2 + (0.75 if has_community else 0.0))

    state = {
        "hunger": hunger,
        "thirst": thirst,
        "energy": energy,
        "stress": stress,
        "socialNeed": random.random(),
        "spirituality": random.random(),
        "aggression": random.betavariate(1.0, 4.5),
        "fertility": random.random(),
        "health": clamp(1.0 - hunger * 0.25 - thirst * 0.28 - stress * 0.12 + random.random() * 0.18),
        "prosperity": prosperity,
        "hasHome": 1.0 if has_home else 0.0,
        "hasCommunity": 1.0 if has_community else 0.0,
        "communityProsperity": clamp(prosperity + random.uniform(-0.25, 0.25)),
        "communityMembers": community_members,
        "housingShortage": housing_shortage,
        "localFood": local_food,
        "localWater": local_water,
        "localWood": local_wood,
        "localStone": local_stone,
        "localIron": local_iron,
        "localAnimals": local_animals,
        "inventoryFood": inv_food,
        "inventoryWood": inv_wood,
        "inventoryStone": inv_stone,
        "inventoryIron": inv_iron,
        "inventoryAnimals": inv_animals,
        "scarcity": scarcity,
        "overcrowding": overcrowding,
        "trustedNear": trusted,
        "sameCommunityNear": same,
        "project": project,
    }
    return state


def valid_actions(state):
    valid = {a: 0.0 for a in ACTIONS}
    valid["searchFood"] = 1.0
    valid["searchWater"] = 1.0 if state["localWater"] > 0.08 else 0.0
    valid["rest"] = 1.0
    valid["gather"] = 1.0 if max(state["localWood"], state["localStone"], state["localIron"], state["localAnimals"]) > 0.12 else 0.0
    valid["useWarehouse"] = 1.0 if state["hasCommunity"] and (state["inventoryFood"] > 0.12 or state["inventoryWood"] > 0.18 or state["inventoryStone"] > 0.18 or state["hunger"] > 0.54) else 0.0
    valid["buildHouse"] = 1.0 if state["hasCommunity"] and state["inventoryWood"] > 0.36 and state["inventoryStone"] > 0.16 else 0.0
    valid["buildFarm"] = 1.0 if state["hasCommunity"] and state["inventoryWood"] > 0.22 and state["inventoryStone"] > 0.08 and state["localWater"] > 0.18 else 0.0
    valid["buildPaddock"] = 1.0 if state["hasCommunity"] and state["inventoryWood"] > 0.28 and state["inventoryStone"] > 0.10 and state["inventoryAnimals"] > 0.08 else 0.0
    valid["buildMine"] = 1.0 if state["hasCommunity"] and state["inventoryWood"] > 0.35 and (state["localStone"] > 0.35 or state["localIron"] > 0.18) and (PROJECTS[state["project"]] in ("armament", "war") or state["prosperity"] > 0.62) else 0.0
    valid["buildWarehouse"] = 1.0 if state["inventoryWood"] > 0.38 and state["inventoryStone"] > 0.24 and (not state["hasCommunity"] or PROJECTS[state["project"]] == "buildWarehouse") else 0.0
    valid["buildShrine"] = 1.0 if state["hasCommunity"] and state["inventoryWood"] > 0.45 and state["inventoryStone"] > 0.62 else 0.0
    valid["worship"] = 1.0 if state["hasCommunity"] and state["spirituality"] < 0.72 else 0.0
    valid["socialize"] = 1.0 if state["trustedNear"] + state["sameCommunityNear"] > 0.14 else 0.0
    valid["help"] = 1.0 if state["inventoryFood"] > 0.28 and state["trustedNear"] > 0.18 else 0.0
    valid["formCommunity"] = 1.0 if not state["hasCommunity"] and state["trustedNear"] > 0.42 and state["localWater"] > 0.12 else 0.0
    valid["migrateCommunity"] = 1.0 if state["hasCommunity"] and (state["stress"] > 0.72 or state["overcrowding"] > 0.72) else 0.0
    valid["reproduce"] = 1.0 if state["hasHome"] and state["fertility"] > 0.46 and state["prosperity"] > 0.42 and state["stress"] < 0.68 else 0.0
    valid["craftGear"] = 1.0 if state["inventoryIron"] > 0.45 and (PROJECTS[state["project"]] in ("armament", "war") or state["prosperity"] > 0.68) else 0.0
    valid["attack"] = 1.0 if state["aggression"] > 0.82 and PROJECTS[state["project"]] == "war" else 0.0
    valid["attackBuilding"] = 1.0 if state["aggression"] > 0.72 and PROJECTS[state["project"]] == "war" else 0.0
    valid["explore"] = 1.0 if state["prosperity"] > 0.66 and PROJECTS[state["project"]] == "exploration" else 0.0
    return valid


def reward(state, action):
    p = PROJECTS[state["project"]]
    r = 0.0
    hunger = state["hunger"]
    thirst = state["thirst"]
    energy_need = 1.0 - state["energy"]
    poverty = 1.0 - state["prosperity"]
    survival = max(hunger, thirst, energy_need)
    death_risk = clamp(max(hunger - 0.86, thirst - 0.86, energy_need - 0.90) / 0.14)
    civilization_room = clamp((state["prosperity"] - 0.34) / 0.46) * clamp(1.0 - survival / 0.92)
    community_scale = state["hasCommunity"] * (0.45 + state["communityMembers"] * 0.75)

    if action == "searchWater":
        r += thirst * 4.2 + (1.6 if thirst > 0.72 else 0.0)
    elif action == "searchFood":
        r += hunger * 3.7 + poverty * 0.8 + state["scarcity"] * 1.2
    elif action == "rest":
        r += energy_need * 3.1 + state["stress"] * 1.3
    elif action == "gather":
        r += poverty * 1.6 + state["scarcity"] * 1.4 + (0.55 if p == "stockpile" else 0.0)
        r += max(0.0, 0.55 - state["inventoryWood"]) + max(0.0, 0.45 - state["inventoryStone"])
        if not state["hasCommunity"]:
            r += max(0.0, 0.42 - state["inventoryWood"]) * 2.2 + max(0.0, 0.28 - state["inventoryStone"]) * 2.8
        elif max(state["inventoryFood"], state["inventoryWood"], state["inventoryStone"], state["inventoryIron"], state["inventoryAnimals"]) > 0.34:
            r -= 1.7
    elif action == "useWarehouse":
        carried = max(state["inventoryFood"], state["inventoryWood"], state["inventoryStone"], state["inventoryIron"], state["inventoryAnimals"])
        r += state["hasCommunity"] * (state["hunger"] * 1.4 + poverty * 0.8 + state["inventoryFood"] * 1.4)
        r += state["hasCommunity"] * carried * 4.2
        if p == "stockpile":
            r += state["hasCommunity"] * carried * 1.4
    elif action == "buildHouse":
        r += state["housingShortage"] * 4.0 + state["prosperity"] * 1.2 + civilization_room * (1.7 + community_scale) + (1.0 if p in ("housing", "develop", "exploration") else 0.0)
    elif action == "buildFarm":
        r += state["scarcity"] * 3.0 + state["communityMembers"] * 0.9 + civilization_room * (1.25 + community_scale) + (0.8 if p in ("housing", "develop", "stockpile") else 0.0)
    elif action == "buildPaddock":
        r += state["scarcity"] * 1.7 + state["localAnimals"] * 1.4 + civilization_room * 0.8 + (0.45 if p in ("stockpile", "housing") else 0.0)
    elif action == "buildMine":
        r += state["localIron"] * 1.4 + state["localStone"] * 0.45 + civilization_room * 0.35 + (2.2 if p in ("armament", "war") else -0.6)
    elif action == "buildWarehouse":
        if state["hasCommunity"]:
            r += state["communityMembers"] * 1.3 + state["prosperity"] * 1.0 + civilization_room * (1.4 + community_scale) + (1.4 if p == "buildWarehouse" else 0.0)
        else:
            r += 5.2 + state["trustedNear"] * 1.4 + state["localWater"] * 0.9 + state["inventoryWood"] * 0.8 + state["inventoryStone"] * 1.2
    elif action == "buildShrine":
        r += (1.0 - state["spirituality"]) * 2.8 + state["communityMembers"] * 0.8 + civilization_room * (1.0 + community_scale) + (2.0 if p == "buildShrine" else 0.0)
    elif action == "worship":
        r += (1.0 - state["spirituality"]) * 3.2 + state["stress"] * 0.9
    elif action == "socialize":
        r += state["socialNeed"] * 2.1 + state["trustedNear"] * 1.0 + state["sameCommunityNear"] * 1.0
    elif action == "help":
        r += state["trustedNear"] * 2.4 + state["inventoryFood"] * 0.6 + state["communityProsperity"] * 0.4 + civilization_room * 0.8
    elif action == "formCommunity":
        r += (1.0 - state["hasCommunity"]) * 1.0 + state["trustedNear"] * 1.4 + state["localWater"] * 0.5
        if state["inventoryWood"] > 0.38 and state["inventoryStone"] > 0.24:
            r -= 1.8
    elif action == "migrateCommunity":
        r += state["stress"] * 1.6 + state["overcrowding"] * 1.8 + state["scarcity"] * 1.0
    elif action == "reproduce":
        r += state["fertility"] * 1.7 + state["prosperity"] * 1.7 + state["hasHome"] * 1.2 + civilization_room * 0.9 - state["stress"] * 1.1
        if p == "housing":
            r += 0.45
    elif action == "craftGear":
        r += state["inventoryIron"] * 1.8 + (2.2 if p in ("armament", "war") else 0.1)
    elif action == "attack":
        r += (3.2 if p == "war" else -3.2) + state["aggression"] * 1.1 - max(0.0, 0.72 - survival) * 2.5
    elif action == "attackBuilding":
        r += (3.0 if p == "war" else -3.0) + state["aggression"] * 0.8
    elif action == "explore":
        r += state["prosperity"] * 1.8 + state["communityMembers"] * 1.2 + civilization_room * 2.0 + (2.2 if p == "exploration" else -0.4)

    if death_risk > 0 and action not in ("searchFood", "searchWater", "rest", "migrateCommunity", "help"):
        r -= 6.5 * death_risk
    if thirst > 0.90 and action != "searchWater":
        r -= 5.8 * clamp((thirst - 0.90) / 0.10)
    if hunger > 0.90 and action not in ("searchFood", "help"):
        r -= 4.9 * clamp((hunger - 0.90) / 0.10)
    if energy_need > 0.92 and action != "rest":
        r -= 4.3 * clamp((energy_need - 0.92) / 0.08)
    if state["prosperity"] < 0.30 and action.startswith("build") and action != "buildWarehouse":
        r -= 1.8
    if not state["hasCommunity"] and action not in ("searchFood", "searchWater", "rest", "gather", "buildWarehouse", "socialize", "help"):
        r -= 2.6
    if action in ("attack", "attackBuilding") and p != "war":
        r -= 4.0
    return r


def make_sample():
    state = random_state()
    valid = valid_actions(state)
    rewards = []
    for action in ACTIONS:
        if valid[action] <= 0:
            rewards.append(-999.0)
        else:
            rewards.append(reward(state, action) + random.gauss(0.0, 0.07))
    label = max(range(len(ACTIONS)), key=lambda i: rewards[i])
    features = [state[name] for name in BASE_FEATURES]
    features += one_hot(state["project"], len(PROJECTS))
    features += [valid[action] for action in ACTIONS]
    return Sample(features, label)


def dataset(samples):
    rows = [make_sample() for _ in range(samples)]
    x = torch.tensor([row.x for row in rows], dtype=torch.float32)
    y = torch.tensor([row.y for row in rows], dtype=torch.long)
    return x, y


def lua_number(v):
    return f"{float(v):.7g}"


def lua_matrix(matrix):
    rows = []
    for row in matrix:
        rows.append("{" + ",".join(lua_number(v) for v in row) + "}")
    return "{" + ",".join(rows) + "}"


def lua_vector(vector):
    return "{" + ",".join(lua_number(v) for v in vector) + "}"


def write_lua_model(model, metrics):
    state = model.state_dict()
    actions_lua = "{" + ",".join(f'"{a}"' for a in ACTIONS) + "}"
    projects_lua = "{" + ",".join(f'"{p}"' for p in PROJECTS) + "}"
    features_lua = "{" + ",".join(f'"{f}"' for f in BASE_FEATURES) + "}"
    weights = {
        "fc1_w": state["fc1.weight"].tolist(),
        "fc1_b": state["fc1.bias"].tolist(),
        "fc2_w": state["fc2.weight"].tolist(),
        "fc2_b": state["fc2.bias"].tolist(),
        "out_w": state["out.weight"].tolist(),
        "out_b": state["out.bias"].tolist(),
    }
    metrics_lua = "{" + ",".join(f"{key}={json.dumps(value)}" for key, value in metrics.items()) + "}"
    lua = f"""-- Generated by agent-ai/train_policy.py
local Policy = {{}}
Policy.enabled = true
Policy.trained = true
Policy.actions = {actions_lua}
Policy.projects = {projects_lua}
Policy.baseFeatures = {features_lua}
Policy.metrics = {metrics_lua}
Policy.weights = {{
    fc1_w = {lua_matrix(weights["fc1_w"])},
    fc1_b = {lua_vector(weights["fc1_b"])},
    fc2_w = {lua_matrix(weights["fc2_w"])},
    fc2_b = {lua_vector(weights["fc2_b"])},
    out_w = {lua_matrix(weights["out_w"])},
    out_b = {lua_vector(weights["out_b"])}
}}
return Policy
"""
    with open(OUT_LUA, "w", encoding="utf-8") as handle:
        handle.write(lua)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=60000)
    parser.add_argument("--epochs", type=int, default=18)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--seed", type=int, default=20260522)
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    x, y = dataset(args.samples)
    split = int(args.samples * 0.88)
    train_x, train_y = x[:split], y[:split]
    val_x, val_y = x[split:], y[split:]

    model = PolicyNet()
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)

    for epoch in range(args.epochs):
        order = torch.randperm(train_x.size(0))
        total_loss = 0.0
        for start in range(0, train_x.size(0), args.batch_size):
            idx = order[start:start + args.batch_size]
            logits = model(train_x[idx])
            loss = F.cross_entropy(logits, train_y[idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
            total_loss += float(loss.item()) * idx.numel()

        with torch.no_grad():
            logits = model(val_x)
            acc = (logits.argmax(dim=1) == val_y).float().mean().item()
        print(f"epoch={epoch + 1:02d} loss={total_loss / train_x.size(0):.4f} val_acc={acc:.3f}")

    with torch.no_grad():
        val_acc = (model(val_x).argmax(dim=1) == val_y).float().mean().item()
    metrics = {"samples": args.samples, "epochs": args.epochs, "val_accuracy": round(val_acc, 4), "seed": args.seed}
    write_lua_model(model, metrics)
    print("exported", OUT_LUA, metrics)


if __name__ == "__main__":
    main()
