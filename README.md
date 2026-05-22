# SimWorld 1.0.0

Systemowa symulacja zyjacego swiata 2D napisana w Lua dla frameworka LÖVE. To nie jest gra z celami ani progresja gracza: ludzie przezywaja, zakladaja osady, tworza spolecznosci, dziela zasoby, migruja, rozmnazaja sie i walcza w wyniku potrzeb, presji srodowiska, pamieci, granic oraz niedoborow.

Uruchomienie:

```bash
love .
```

Tryb konsolowy high-performance, bez okna i grafiki:

```bash
lua headless.lua
```

Przydatne opcje:

```bash
lua headless.lua --ticks=5000 --report=250 --events=major
lua headless.lua --ticks=2000 --report=100 --events=all --seed=12345
lua headless.lua --agents=250 --cap=700 --width=260 --height=160
```

`--events=major` raportuje powstawanie/upadek spolecznosci i zmiany projektow, np. wojne. `--events=all` dodaje budowe i utrate struktur, a `--events=none` zostawia tylko okresowe statystyki swiata.

## Struktura Projektu

```text
main.lua                 graficzny punkt wejscia LÖVE
headless.lua             konsolowy punkt wejscia high-performance
conf.lua                 konfiguracja LÖVE
simulation_config.json   parametry swiata i symulacji
src/
  simulation.lua         glowna petla i orkiestracja systemow
  world.lua              mapa, generacja, indeksy, pathfinding i rendering swiata
  config.lua             loader JSON
  entities/              agenci, pamiec i spolecznosci
  systems/               zachowanie, budynki i zasoby
  ai/                    runtime AI oraz wyeksportowana polityka
  ui/                    debug UI i sprite'y
agent-ai/                trening PyTorch i dokumentacja modelu
assets/                  PNG dla agentow, zasobow i struktur
developer-tools/         narzedzia do generowania assetow
```

## Konfiguracja

Podstawowe parametry swiata sa w pliku `simulation_config.json`.

```json
{
  "version": "1.0.0",
  "map": {
    "width": 200,
    "height": 128,
    "continents": 4,
    "continentScale": 1.0,
    "archipelagos": 8,
    "shallowWaterDepth": 3,
    "rivers": 12,
    "lakes": 24,
    "seed": null
  },
  "simulation": {
    "initialAgents": 150,
    "populationCap": 420,
    "tickStep": 0.18
  },
  "resources": {
    "forest": 1.0,
    "rock": 0.75,
    "iron": 0.65,
    "animals": 0.55
  }
}
```

`seed: null` oznacza losowe ziarno przy starcie. Zwiekszanie mapy i populacji mocno podnosi koszt symulacji, bo agenci podejmuja decyzje, szukaja tras i oddzialuja ze strukturami oraz spolecznosciami.

## Aktualny Zakres

- Duza mapa kafelkowa z kontynentami, archipelagami, oceanem, plytka woda przybrzezna, rzekami, mini-jeziorami, plazami, lasami, lakami, skalami, sniegiem i biomami zaleznymi od szerokosci mapy.
- Ocean jest ciemniejszy i nieprzekraczalny nawet lodzia; plytka woda przybrzezna pozwala na zegluge, a zwykla woda sluzy do picia, farm i przepraw lodzia.
- Zasoby sa rzadsze i bardziej przestrzenne: lasy tworza zwarte obszary, a pomiedzy nimi zostaja otwarte laki.
- Autonomiczni agenci maja glod, pragnienie, energie, stres, potrzebe spoleczna, duchowosc, agresje, plodnosc, pamiec i relacje.
- Spolecznosci dzialaja jak proste panstwa: maja projekty grupowe, dobrostan, duchowosc, granice, relacje dyplomatyczne, magazyny i wspolne zasoby.
- Magazyny sa fizyczna logistyka: agent musi dojsc do magazynu, zeby odlozyc zebrane zasoby albo pobrac zasoby wspolne.
- Osady rozwijaja domy, farmy, zagrody, kopalnie, magazyny i miejsca kultu.
- Zasoby strategiczne obejmuja drewno, kamien, zelazo i zwierzeta.
- Kopalnie powstaja na zlozach kamienia lub zelaza i wydobywaja je z rezerw zamiast odnawiac surowiec naturalnie.
- Wojny wynikaja z relacji, zasobow i tarcia granicznego; obejmuja bron, zbroje, obrazenia, smierc i niszczenie konstrukcji.
- Kamera obsluguje przesuwanie i przyblizanie, a UI pokazuje populacje, zasoby, claimy, akcje i szczegoly kliknietej spolecznosci.
- Teren jest rysowany jako jednokolorowe kafle dla wydajnosci; pliki PNG w `assets` sa uzywane dla zasobow, budynkow, duzych struktur, agentow i ikon stanow.
- Decyzje agentow moga byc wspierane przez mala siec neuronowa trenowana w PyTorch w `agent-ai`; wyeksportowane wagi sa ladowane przez `src/ai/agent_ai_policy.lua`.
- `headless.lua` uruchamia te sama symulacje w konsoli, bez renderowania i bez LÖVE, wykonujac ticki tak szybko jak pozwala procesor.

## Agent AI

Model treningowy znajduje sie w `agent-ai/train_policy.py`. Uczy polityke decyzyjna premiujaca dobrostan/dostatek agenta, dzietnosc, rozwoj spolecznosci, gromadzenie zasobow oraz unikanie agresji bez projektu wojny lub realnej presji przetrwania. AI nie jest omijane w stanach krytycznych; ignorowanie glodu, pragnienia lub wyczerpania jest karane w nagrodzie treningowej.

```bash
python3 agent-ai/train_policy.py --epochs 22 --samples 100000 --batch-size 768 --seed 20260524
```

Eksport trafia do `src/ai/agent_ai_policy.lua`. Runtime LÖVE nie wymaga PyTorcha, bo inference odbywa sie w Lua. Kazdy agent ma wlasny `aiSeed` i drobna wariancje decyzyjna, zeby ograniczyc powtarzanie tych samych czynnosci. Ostatni trening: `100000` probek, `22` epoki, walidacja `0.8671`.

## Projekty Spoleczne

- `stockpile`: niski zapas zasobow i ryzyko problemow w kolejnej fazie; dostepne dopiero po zbudowaniu magazynu.
- `housing`: dobre zasoby i dobrostan; budowa domow, farm, zagrod oraz szybsze rozmnazanie.
- `armament`: wrogosc wobec innej spolecznosci, ale za slabe wyposazenie wojenne.
- `war`: srednio-wysokie zasoby oraz wrogosc; ataki na agentow i infrastrukture.
- `exploration`: wysokie zasoby, duzo konstrukcji i wielu czlonkow; 2-4 agentow zaklada odlegla kolonie.
- `buildWarehouse`: budowa magazynu i przejscie na wspolne zasoby.
- `buildShrine`: niski poziom duchowosci kieruje spolecznosc ku miejscu kultu.
- `develop`: wysoki dobrostan bez pilnej presji; rozbudowa osady.

## Changelog Do 1.0.0

- Scalono dotychczasowe funkcje w wersje `1.0.0`.
- Dodano plik `simulation_config.json` i loader konfiguracji w `src/config.lua`.
- Powiekszono domyslna mape do `200x128` oraz podniesiono domyslna populacje startowa do `150`.
- Przebudowano generator swiata z archipelagu na kontynenty.
- Dodano biomy inspirowane ukladem planety: wiecej roslinnosci w srodkowych pasach, mniej na gorze i dole oraz snieg przy biegunach mapy.
- Dodano rzeki, mini-jeziora, ocean oraz piasek w pasie 1-3 kafli przy wodzie.
- Rozdzielono ocean, plytka wode i zwykla wode: ocean jest bariera, plytka woda jest zeglowna, a rzeki i jeziora pozostaja zasobem strategicznym.
- Dodano generowanie malych wysp i archipelagow.
- Ujednolicono rendering obiektow na assetach PNG: `building_tiles.png`, `resource_states.png`, `warehouse_large.png`, `shrine_large.png` oraz arkusze agenta. Teren pozostaje prostymi kolorowymi kaflami.
- Poprawiono zachowanie agentow na duzej mapie: rozproszony start w klastrach, wiekszy zasieg szukania tras i zasobow, fallback dla utknietych planow oraz mniejsza sklonnosc do desperackich atakow.
- Dodano pipeline PyTorch dla polityki agentow, eksport wag do Lua i runtime inference bez zaleznosci od Pythona.
- Dodano tryb konsolowy high-performance w `headless.lua` z okresowymi statystykami i raportowaniem wydarzen spolecznosci.
- Urealniono magazyny: zasoby nie teleportuja sie do wspolnego store, a pobieranie i deponowanie wymaga fizycznej obecnosci agenta przy magazynie.
- Zachowano systemy osad, spolecznosci, claimow strukturalnych, magazynow, duchowosci, kopalni, zwierzat, zbrojen i wojen.
