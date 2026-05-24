# AI Policies

Proste pipeline'y PyTorch do trenowania polityk decyzyjnych eksportowanych do Lua.

## Agent AI

Model dostaje stan agenta, spolecznosci i wykonalnosc akcji, a uczy sie wybierac akcje maksymalizujaca nagrode:

- dlugotrwaly dobrostan agenta liczony progami przezycia, nie prosta suma paskow,
- szanse na potomstwo,
- rozwoj spolecznosci,
- stabilne gromadzenie zasobow,
- fizyczna logistyke magazynowa (`useWarehouse`) po zebraniu zasobow,
- budowe magazynu jako akt zalozycielski spolecznosci,
- unikanie losowej agresji bez presji przetrwania lub realnego konfliktu,
- surowa kara za ignorowanie skrajnego glodu, pragnienia lub wyczerpania.
- warstwowe potrzeby: przetrwanie, odpoczynek/relacje/reprodukcja i nagrode cywilizacyjna za zadania narodu.

Runtime nie omija AI przy stanach krytycznych. Przetrwanie jest wymuszane przez trening i nagrode, nie przez reczny `if thirst > X then searchWater`.

Trening:

```bash
python3 -m pip install torch
lua agent-ai/collect_agent_rollouts.lua --runs=3 --ticks=420 --warmup=30 --sample-every=4 --agents=180 --cap=1000 --width=180 --height=180 --out=agent-ai/agent_real_states.csv --seed=73000
python3 agent-ai/train_policy.py --real-data=agent-ai/agent_real_states.csv --epochs=24 --batch-size=768 --seed=20260526 --synthetic-ratio=0.20
```

Skrypt eksportuje wagi do:

```text
src/ai/agent_ai_policy.lua
```

Runtime LÖVE nie wymaga PyTorcha. Gra laduje wyeksportowany modul Lua i wykonuje inference lokalnie.

`collect_agent_rollouts.lua` odpala prawdziwa symulacje headless i zapisuje realne wektory wejsc Agent AI do CSV. Ostatni lokalny trening: `57202` realnych stanow z rolloutow + domieszka syntetyczna, lacznie `68642` probki, `24` epoki, walidacja `0.9506`.

## Nation AI

Model narodowy dostaje syntetyczny stan narodu, osad, zapasow, presji wojennej, lokalnych zasobow i stanu agenta. Ta sama polityka jest uzywana jako lokalne AI samotnej osady, zanim osada zalozy narod albo dolaczy do istniejacego. Uczy sie przydzialu mikro-zadania dla agentow bioracych udzial w projekcie ponadjednostkowym:

- gromadzenie jedzenia, drewna i kamienia,
- budowe domow, farm, zagrod, kopalni i miejsc kultu,
- zbrojenia i dzialania wojenne,
- ekspansje przez nowe osady,
- reprodukcje przy wysokim dobrostanie,
- deponowanie zasobow w magazynie,
- stabilne kontrakty zadan: AI nie powinno co tick zmieniac priorytetu agenta.

Nagroda premiuje dominacje narodu liczona przez dobrostan, populacje, liczbe osad, claimy/terytorium, infrastrukture i przewage militarna wzgledem innych narodow. Zapasy magazynowe sa tylko logistyka przetrwania i budowy, nie samodzielnym zrodlem nagrody strategicznej.

Trening:

```bash
lua agent-ai/collect_nation_rollouts.lua --runs=3 --ticks=460 --sample-every=5 --agents=180 --cap=900 --width=180 --height=180 --out=agent-ai/nation_real_states.csv --seed=62000
python3 agent-ai/train_nation_policy.py --real-data=agent-ai/nation_real_states.csv --epochs=24 --batch-size=512 --seed=20260525
```

`collect_nation_rollouts.lua` odpala prawdziwa symulacje headless i zapisuje realne wektory wejsc Nation AI do CSV. Pliki `*_real_states.csv` sa lokalnymi artefaktami treningowymi i sa ignorowane przez git.

Skrypt eksportuje wagi do:

```text
src/ai/nation_ai_policy.lua
```

Ostatni lokalny trening: `12908` realnych stanow z rolloutow, `24` epoki, walidacja `0.9600`.
