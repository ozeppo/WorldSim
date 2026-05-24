#!/usr/bin/env python3
import argparse
import csv
import json
import os
import random

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
OUT_LUA = os.path.join(ROOT, "src", "ai", "nation_ai_policy.lua")

TASKS = [
    "stockpileFood",
    "stockpileWood",
    "stockpileStone",
    "buildHouse",
    "buildFarm",
    "buildPaddock",
    "buildMine",
    "buildShrine",
    "craftGear",
    "raid",
    "attackBuilding",
    "explore",
    "reproduce",
    "deposit",
]

FEATURES = [
    "claimsPerMember",
    "totalClaims",
    "claimDensity",
    "expansionNeed",
    "members",
    "settlements",
    "housingShortage",
    "farmShortage",
    "paddockShortage",
    "mineShortage",
    "shrineNeed",
    "avgProsperity",
    "avgSpirituality",
    "avgArmament",
    "dominance",
    "enemyPressure",
    "localFood",
    "localWood",
    "localStone",
    "localIron",
    "localAnimals",
    "agentProsperity",
    "agentLoad",
    "hasHome",
]


class NationNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(len(FEATURES), 40)
        self.out = nn.Linear(40, len(TASKS))

    def forward(self, x):
        return self.out(F.relu(self.fc1(x)))


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def random_state():
    prosperity = random.betavariate(1.6, 1.7)
    members = random.random() ** 0.58
    settlements = random.random() ** 0.9
    structures = clamp(random.random() * 0.72 + members * 0.38)
    total_claims = clamp(structures * 0.62 + settlements * 0.25 + random.random() * 0.30)
    claims_per_member = clamp(total_claims * (0.45 + random.random() * 0.75))
    claim_density = clamp(total_claims / max(0.12, structures + 0.18))
    expansion_need = clamp(1.0 - claims_per_member * 0.75 + random.uniform(-0.12, 0.18))
    enemy = random.betavariate(0.9, 4.0)
    armament = random.betavariate(1.1, 2.6)
    local_food = random.random()
    local_wood = random.random()
    local_stone = random.random()
    local_iron = random.random() * random.random()
    local_animals = random.random() * random.random()
    housing = clamp(random.random() * (1.1 - prosperity * 0.45))
    farm = clamp((1.0 - local_food) * 0.45 + random.random() * 0.35)
    paddock = clamp((1.0 - local_food) * 0.25 + local_animals * 0.45)
    mine = clamp(enemy * 0.35 + local_iron * 0.45 + random.random() * 0.25)
    spirit = random.betavariate(1.8, 1.4)

    return {
        "claimsPerMember": claims_per_member,
        "totalClaims": total_claims,
        "claimDensity": claim_density,
        "expansionNeed": expansion_need,
        "members": members,
        "settlements": settlements,
        "housingShortage": housing,
        "farmShortage": farm,
        "paddockShortage": paddock,
        "mineShortage": mine,
        "shrineNeed": clamp((0.7 - spirit) / 0.7),
        "avgProsperity": prosperity,
        "avgSpirituality": spirit,
        "avgArmament": armament,
        "dominance": clamp(prosperity * 0.34 + members * 0.22 + settlements * 0.12 + total_claims * 0.24 + claims_per_member * 0.18 + armament * 0.16),
        "enemyPressure": enemy,
        "localFood": local_food,
        "localWood": local_wood,
        "localStone": local_stone,
        "localIron": local_iron,
        "localAnimals": local_animals,
        "agentProsperity": clamp(prosperity + random.uniform(-0.25, 0.25)),
        "agentLoad": random.betavariate(0.8, 2.6),
        "hasHome": 1.0 if random.random() < (0.35 + prosperity * 0.55 - housing * 0.3) else 0.0,
    }


def reward(s, task):
    r = 0.0
    civic_room = clamp((s["agentProsperity"] - 0.30) / 0.55)
    scarcity = clamp((1.0 - s["localFood"]) * 0.42 + s["farmShortage"] * 0.58)
    military_gap = clamp(s["enemyPressure"] * (1.0 - s["avgArmament"]))
    claim_power = clamp(s["claimsPerMember"] * 0.58 + s["totalClaims"] * 0.42)
    strategic_room = civic_room * clamp(claim_power * 0.7 + s["claimDensity"] * 0.3)

    if task == "stockpileFood":
        r += scarcity * 1.7 + s["localFood"] * 0.15
    elif task == "stockpileWood":
        r += s["expansionNeed"] * 0.75 + s["localWood"] * 0.35
    elif task == "stockpileStone":
        r += s["expansionNeed"] * 0.65 + s["localStone"] * 0.35
    elif task == "buildHouse":
        r += s["housingShortage"] * 4.4 + civic_room * 1.05 + s["members"] * 0.45 + s["expansionNeed"] * 0.65
    elif task == "buildFarm":
        r += s["farmShortage"] * 3.3 + scarcity * 1.3 + civic_room * 0.5
    elif task == "buildPaddock":
        r += s["paddockShortage"] * 2.4 + s["localAnimals"] * 1.2 + scarcity * 0.45
    elif task == "buildMine":
        r += s["mineShortage"] * 2.1 + s["localIron"] * 1.8 + military_gap * 0.8
    elif task == "buildShrine":
        r += s["shrineNeed"] * 3.6 + (1.0 - s["avgSpirituality"]) * 1.2
    elif task == "craftGear":
        r += military_gap * 3.4 + s["localIron"] * 0.7 + s["enemyPressure"] * 0.9 + strategic_room * 0.35
    elif task == "raid":
        r += s["enemyPressure"] * 3.2 + s["avgArmament"] * 1.45 + s["dominance"] * 0.45 + claim_power * 0.35
    elif task == "attackBuilding":
        r += s["enemyPressure"] * 3.5 + s["avgArmament"] * 1.25 + s["dominance"] * 0.35 + claim_power * 0.55
    elif task == "explore":
        r += s["dominance"] * 1.1 + s["settlements"] * 0.22 + strategic_room * 1.75 + s["claimDensity"] * 0.45
    elif task == "reproduce":
        r += civic_room * 2.2 + claim_power * 0.65 + (1.0 - s["housingShortage"]) * 1.2 + s["hasHome"] * 0.8
    elif task == "deposit":
        r += s["agentLoad"] * 4.0 + s["agentProsperity"] * 0.25

    if s["agentProsperity"] < 0.30 and task not in ("stockpileFood", "deposit"):
        r -= 3.2
    if s["agentProsperity"] < 0.45 and task in ("raid", "attackBuilding", "explore"):
        r -= 2.4
    if s["agentLoad"] > 0.55 and task != "deposit":
        r -= s["agentLoad"] * 2.4
    if s["enemyPressure"] < 0.26 and task in ("raid", "attackBuilding"):
        r -= 4.0
    if s["avgArmament"] < 0.28 and task in ("raid", "attackBuilding"):
        r -= 1.8
    if s["enemyPressure"] > 0.58 and s["avgArmament"] < 0.42 and task == "craftGear":
        r += 1.2
    if s["claimsPerMember"] < 0.22 and task in ("explore", "raid", "attackBuilding"):
        r -= 2.2
    if civic_room > 0.55 and s["expansionNeed"] > 0.45 and task.startswith("stockpile"):
        r -= 1.4
    return r + random.gauss(0.0, 0.05)


def make_dataset(samples):
    rows = []
    labels = []
    for _ in range(samples):
        state = random_state()
        rewards = [reward(state, task) for task in TASKS]
        rows.append([state[name] for name in FEATURES])
        labels.append(max(range(len(TASKS)), key=lambda i: rewards[i]))
    return torch.tensor(rows, dtype=torch.float32), torch.tensor(labels, dtype=torch.long)


def make_dataset_from_states(states):
    rows = []
    labels = []
    for state in states:
        rewards = [reward(state, task) for task in TASKS]
        rows.append([state[name] for name in FEATURES])
        labels.append(max(range(len(TASKS)), key=lambda i: rewards[i]))
    return torch.tensor(rows, dtype=torch.float32), torch.tensor(labels, dtype=torch.long)


def load_real_states(path):
    states = []
    with open(path, "r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = [name for name in FEATURES if name not in (reader.fieldnames or [])]
        if missing:
            raise SystemExit(f"Real-state CSV is missing features: {', '.join(missing)}")
        for row in reader:
            state = {}
            for name in FEATURES:
                try:
                    state[name] = clamp(float(row[name]))
                except (TypeError, ValueError):
                    state[name] = 0.0
            states.append(state)
    if not states:
        raise SystemExit(f"No real states found in {path}")
    return states


def lua_number(v):
    return f"{float(v):.7g}"


def lua_matrix(matrix):
    return "{" + ",".join("{" + ",".join(lua_number(v) for v in row) + "}" for row in matrix) + "}"


def lua_vector(vector):
    return "{" + ",".join(lua_number(v) for v in vector) + "}"


def write_lua(model, metrics):
    state = model.state_dict()
    tasks = "{" + ",".join(json.dumps(t) for t in TASKS) + "}"
    features = "{" + ",".join(json.dumps(f) for f in FEATURES) + "}"
    metrics_lua = "{" + ",".join(f"{key}={json.dumps(value)}" for key, value in metrics.items()) + "}"
    lua = f"""-- Generated by agent-ai/train_nation_policy.py
local Policy = {{}}
Policy.enabled = true
Policy.trained = true
Policy.tasks = {tasks}
Policy.features = {features}
Policy.metrics = {metrics_lua}
Policy.weights = {{
    fc1_w = {lua_matrix(state["fc1.weight"].tolist())},
    fc1_b = {lua_vector(state["fc1.bias"].tolist())},
    out_w = {lua_matrix(state["out.weight"].tolist())},
    out_b = {lua_vector(state["out.bias"].tolist())}
}}
return Policy
"""
    with open(OUT_LUA, "w", encoding="utf-8") as handle:
        handle.write(lua)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=40000)
    parser.add_argument("--epochs", type=int, default=14)
    parser.add_argument("--batch-size", type=int, default=512)
    parser.add_argument("--seed", type=int, default=20260524)
    parser.add_argument("--real-data", default=None, help="CSV produced by collect_nation_rollouts.lua")
    parser.add_argument("--synthetic-samples", type=int, default=0, help="Optional synthetic samples mixed with real rollout states")
    args = parser.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    source = "synthetic"
    if args.real_data:
        states = load_real_states(args.real_data)
        x, y = make_dataset_from_states(states)
        source = os.path.basename(args.real_data)
        if args.synthetic_samples > 0:
            sx, sy = make_dataset(args.synthetic_samples)
            x = torch.cat([x, sx], dim=0)
            y = torch.cat([y, sy], dim=0)
            source = f"{source}+synthetic:{args.synthetic_samples}"
        args.samples = int(x.size(0))
    else:
        x, y = make_dataset(args.samples)
    split = int(args.samples * 0.88)
    train_x, train_y = x[:split], y[:split]
    val_x, val_y = x[split:], y[split:]

    model = NationNet()
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    for epoch in range(args.epochs):
        order = torch.randperm(train_x.size(0))
        total = 0.0
        for start in range(0, train_x.size(0), args.batch_size):
            idx = order[start:start + args.batch_size]
            loss = F.cross_entropy(model(train_x[idx]), train_y[idx])
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss.item()) * idx.numel()
        with torch.no_grad():
            acc = (model(val_x).argmax(dim=1) == val_y).float().mean().item()
        print(f"epoch={epoch + 1:02d} loss={total / train_x.size(0):.4f} val_acc={acc:.3f}")

    with torch.no_grad():
        acc = (model(val_x).argmax(dim=1) == val_y).float().mean().item()
    metrics = {"samples": args.samples, "epochs": args.epochs, "val_accuracy": round(acc, 4), "seed": args.seed, "source": source}
    write_lua(model, metrics)
    print("exported", OUT_LUA, metrics)


if __name__ == "__main__":
    main()
