# Agent AI Policy

Prosty pipeline PyTorch do trenowania polityki decyzyjnej agentow.

Model dostaje syntetyczny stan agenta, spolecznosci i wykonalnosc akcji, a uczy sie wybierac akcje maksymalizujaca nagrode:

- dobrostan i dostatek agenta,
- szanse na potomstwo,
- rozwoj spolecznosci,
- stabilne gromadzenie zasobow,
- fizyczna logistyke magazynowa (`useWarehouse`) po zebraniu zasobow,
- budowe magazynu jako akt zalozycielski spolecznosci,
- unikanie losowej agresji bez presji przetrwania lub projektu wojny.
- surowa kara za ignorowanie skrajnego glodu, pragnienia lub wyczerpania.

Runtime nie omija AI przy stanach krytycznych. Przetrwanie jest wymuszane przez trening i nagrode, nie przez reczny `if thirst > X then searchWater`.

Trening:

```bash
python3 -m pip install torch
python3 agent-ai/train_policy.py --epochs 22 --samples 100000 --batch-size 768 --seed 20260524
```

Skrypt eksportuje wagi do:

```text
src/ai/agent_ai_policy.lua
```

Runtime LÖVE nie wymaga PyTorcha. Gra laduje wyeksportowany modul Lua i wykonuje inference lokalnie.

Ostatni lokalny trening: `100000` probek, `22` epoki, walidacja `0.8671`.
