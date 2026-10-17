# Campaign Co-op — misje do przejścia

Lista kontrolna na fazę testową: co gra uruchamia jako questy (pliki `.quest` z archiwów
gry 2.31, `WolvenKit.CLI archive <archive\pc\content> <archive\pc\ep1> -l -w "*.quest"`, bez
plików testowych) i czego się spodziewać w co-opie. Kolumna „Stan” uzupełniana w testach:
`—` nietestowane, `OK`, `problem` (opis w notatkach pod tabelą).

Nazwy misji przy identyfikatorach podane tam, gdzie wynikają z nazw plików gry; oznaczone
„?” trzeba potwierdzić w grze (`/coop where` pokazuje klucz bieżącej sceny, dziennik —
nazwę misji).

## Jak testować misję

1. Host i co najmniej jeden gość w świecie, gość blisko hosta.
2. Przejść misję hostem; gość gra razem (walka, auto, dialogi z głosowaniem).
3. Sprawdzić: sceny i rozmowy u gościa (4b), statyści w scenach (4c), zdrowie/śmierć wrogów
   (5), powalenie i podnoszenie (5), przegrupowanie po szybkiej podróży (6), dziennik i
   fakty u gościa po misji (1–2).
4. Złe miejsca statystów w kluczowej scenie: w trakcie sceny `/coop scene`,
   `/coop move <n> <prawo> <przód> [góra] [obrót]`, `/coop save` (opis w `CAMPAIGN.md`,
   „Kampania (etap 6)”). Zapisane pozy z `config/campaign_scenes.txt` serwera przenieść do
   `code/server/scripting/CampaignSystem/campaign_scenes.txt`.

## Mechaniki, które zakładają jednego V

| Mechanika | Gdzie | Co robi co-op | Ryzyko |
|---|---|---|---|
| Braindance | q004, q105 (Disasterpiece), poboczne BD | goście czekają zatrzymani (tryb hosta 1) | brak podglądu BD u gości |
| Granie Johnnym | q101 (flashback 2013), q108?, q115, poboczne Johnny'ego | goście grają dalej jako jego ekipa (tryb 2) | kukła hosta u gości wygląda jak V, nie Johnny |
| Cyberprzestrzeń | q110 (Alt), q116 (Mikoshi), PL (Songbird) | sceny odtwarzane u gości | gracze rozdzieleni, statyści poza sceną |
| Pościgi i jazda | q001 (jazda z Jackiem), q005 (Delamain), q103 (Basilisk), q112 | 4c sadza innych w aucie ze sceny | sterowanie pojazdem ma tylko host |
| Śmierć V w fabule | q005 → q101 (Dex strzela do V) | scena u każdego | gość budzi się na wysypisku razem z hostem? |
| Sceny intymne/romanse | poboczne (romanse) | sceny u każdego, statyści stoją obok | w teście `/coop hide` w tej scenie — inni gracze znikają z niej |
| Wybór zakończenia | q116 / balkon, PL q306–q307 | dialog → głosowanie | „Punkt bez powrotu” to okno gry, nie dialog — decyduje host |
| Napisy końcowe | epilogi q201–q204, PL | u hosta, potem powrót do zapisu | goście wracają z hostem (nowy świat hosta) |
| Prolog ścieżki życia | q000 | goście startują bez prologu | goście dołączają po prologu hosta |

## Fabuła główna (baza)

| Quest | Plik | Misje | Uwagi co-op | Stan |
|---|---|---|---|---|
| q000 | `prologue/q000/q000.quest` | prolog ścieżki życia (Korpo / Nomada / Dziecko ulicy) | goście startują bez prologu; host gra go sam albo z gośćmi w lobby | — |
| q001 | `prologue/q001/q001.quest` | The Rescue, The Ripperdoc, The Ride (z plików: rescue_girl, ripperdoc, ride_to_mb) | Jackie jako towarzysz, auto (4c) | — |
| q003 | `prologue/q003/q003.quest` | The Pickup (Maelstrom) | walka z bossem, wybór dialogowy | — |
| q004 | `prologue/q004/q004.quest` | The Information (braindance z Judy, Lizzie's) | braindance — goście czekają | — |
| q005 | `prologue/q005/q005_heist.quest` | The Heist (Konpeki, ucieczka, No-Tell Motel) | Delamain (4c), Yorinobu, śmierć V w scenie | — |
| q101 | `part1/q101/q101.quest` | Playing for Time; flashback Johnny'ego 2013 | granie Johnnym (tryb 2) | — |
| q103 | `part1/q103/q103.quest` | wątek Panam? | Basilisk, pościgi | — |
| q104 | `part1/q104/q104.quest` | ? | | — |
| q105 | `part1/q105/q105_main.quest` + `definitions/q105_{dollhouse,fingers,braindance,jigjig}` | wątek Evelyn (Clouds, Fingers, braindance, Jig-Jig Street) | braindance — goście czekają | — |
| q108 | `part1/q108/q108_johnny.quest` | wątek Johnny'ego? | | — |
| q110 | `part1/q110/q110.quest` | Voodoo Boys (Placide, cyberprzestrzeń Alt) | cyberprzestrzeń | — |
| q112 | `part1/q112/q112_abduction.quest` | parada, porwanie Hanako | pościg | — |
| q113 | `part1/q113/q113.quest` | ? (boss, Takemura) | | — |
| q114 | `part1/q114/q114_nomads.quest` | zakończenie z Aldecaldos? | | — |
| q115 | `part1/q115/q115_afterlife.quest` | zakończenie z Afterlife / Rogue? | granie Johnnym | — |
| q116 | `part1/q116/q116_mikoshi.quest` | Mikoshi | cyberprzestrzeń, wybór zakończenia | — |
| q201 | `epilogue/q201/q201_heir.quest` | epilog „heir” | napisy końcowe | — |
| q202 | `epilogue/q202/q202.quest` | epilog ? | napisy końcowe | — |
| q203 | `epilogue/q203/q203_legend.quest` | epilog „legend” | napisy końcowe | — |
| q204 | `epilogue/q204/q204_reborn.quest` | epilog „reborn” | napisy końcowe | — |

Korzeń całej gry: `base/quest/cyberpunk2077.quest`; korzeń startu PL standalone (używany
przez gości): `ep1/quest/cyberpunk2077_ep1_standalone.quest`.

## Phantom Liberty

| Quest | Plik | Uwagi co-op | Stan |
|---|---|---|---|
| q301 | `ep1/quest/main_quests/q301/q301.quest` | wejście do Dogtown (fakt `ep1_side_content`) | — |
| q302 | `ep1/quest/main_quests/q302/q302.quest` | (w plikach: spider tank) | — |
| q303 | `ep1/quest/main_quests/q303/q303.quest` | | — |
| q304 | `ep1/quest/main_quests/q304/q304.quest` | (w plikach: stadion, granica, pościg, porwanie auta) | — |
| q305 | `ep1/quest/main_quests/q305/q305.quest` | | — |
| q306 | `ep1/quest/main_quests/q306/q306.quest` | wybór ścieżki zakończenia PL? | — |
| q307 | `ep1/quest/main_quests/q307/q307.quest` | zakończenie PL? | — |

Mniejsze questy PL: `ep1/quest/minor_quests/mq300…mq306` (6). Otwarty świat Dogtown:
`ep1/openworld/` — sandbox_activities 16, mini_world_stories 15, street_stories 9,
world_stories 6, world_encounters 5, minor_activities 5.

## Questy poboczne i mniejsze (baza)

- Poboczne `base/quest/side_quests/`: sq004 (riders), sq006, sq011, sq012 (the law), sq017,
  sq018, sq021, sq023, sq024, sq025, sq026, sq027 (queen of the highway), sq028, sq029,
  sq030, sq031, sq032 — 17 (wątki towarzyszy i romanse; sceny intymne → `/coop hide`).
- Mniejsze `base/quest/minor_quests/`: mq000–mq060 — 50 (m.in. mq003 orbitals, mq015
  wizardbook, mq016 bartmoss, mq017 streetkid, mq019 paparazzi, mq023 bootleg, mq025 psycho
  brawl, mq029 tourist, mq032 sacrum, mq033 tarot, mq034 stash, mq035 ozob, mq036 overload,
  mq037 brendan, mq040 biosculpt, mq041 corpo, mq042 nomad).
- Otwarty świat `base/open_world/`: minor_activities 175, street_stories 90 (zlecenia
  fixerów), mini_world_stories 51, community 20, combat_events 11 — działają u hosta, goście
  widzą je przez odtwarzane węzły i walczą razem (5).

## Notatki z testów

(puste — dopisywać: quest, co się stało, log `[Campaign]`, klucz sceny)
