# Campaign Co-op — tryb fabularny dla 1–4 graczy

Gałąź `campaign-coop`: oryginalny CyberpunkMP (Tilted Phoques) + port na patch 2.31
z Night City Online (`c5f572b`, `9732c46`) + dodatek fabularny. Warstwy MMO z Night City
Online (świat-szablon, blokada zapisów, czysty start bez questów) celowo NIE są tu
wciągnięte — są przeciwieństwem trybu fabularnego. Ich repo jest pod remote `nco`, do
podbierania pojedynczych poprawek.

## Model: host jest autorytetem

- **Host** to pierwszy gracz, który wejdzie na serwer. Jego gra uruchamia questy, sceny
  i dialogi, a jego zapis gry jest zapisem kampanii.
- **Goście** odbijają stan hosta. Serwer przechowuje ostatni stan zgłoszony przez hosta,
  więc gracz, który dołączy później, dostaje cały stan od razu.
- Kiedy host wyjdzie, fabuła stoi do czasu, aż wejdzie nowy host. Nowy host zaczyna od
  czystego stanu na serwerze i wysyła własny zrzut.

## Co jest zsynchronizowane

| Element | Jak |
|---|---|
| Dziennik questów (questy, fazy, cele) | Host nasłuchuje `JournalManager` (`gameJournalListenerType.State`) i przy połączeniu wysyła pełny zrzut. Goście dostają `ChangeEntryStateByHash` z powiadomieniem. |
| Fakty questów | Domyślna lista (16 164 faktów: 11 083 bazy, 5 081 Phantom Liberty) jest wbudowana w plugin. Host rejestruje `QuestsSystem.RegisterListener` dla każdego faktu i wysyła wartości różne od zera. Goście dostają `SetFactStr` — także zera, więc fakty, których host nie ma, są u gościa kasowane. |
| Pozycja, wygląd, pojazdy | To, co już robi CyberpunkMP. |

### Przebieg sesji

1. Pierwszy gracz zostaje hostem: `SetRole(true)`, potem lista faktów w paczkach
   `WatchFacts(nazwy, last)`.
2. Host wysyła zrzut dziennika i faktów (`ReportJournalBatch`, `ReportFactBatch`), a po
   ostatniej paczce `ReportSnapshotDone`.
3. Dopiero wtedy serwer wysyła pełny stan gościom (`ApplyJournalBatch`, `ApplyFactBatch`).
   Gość, który wejdzie wcześniej, czeka na zrzut hosta.
4. Dalej idą pojedyncze zmiany: `ReportJournal`/`ReportFact` → `ApplyJournal`/`ApplyFact`.

Paczka to jeden `String` z parami `klucz:wartość` rozdzielonymi przecinkami, do 16 000
znaków. Bufor RPC ma 64 KB, a string do 65 535 bajtów, więc jest duży zapas. String zamiast
tablic, bo generator stubów C# źle nazywa tablice typów prostych.

### Lista faktów

Źródło: grafy questów i scen gry (`.quest`, `.questphase`, `.scene` z archiwów bazy i
`ep1`). Do listy trafia każdy fakt, który graf **zapisuje** (`questSetVar_NodeType`), bez
faktów deweloperskich (`*_test_def`, `debug`, `demo`). Fakty, które grafy tylko czytają,
ustawia kod gry, często per gracz (pojazd, walka, UI) — celowo pominięte.

Generowanie od nowa (np. po patchu gry), WolvenKit CLI 8.20+:

```
python tools/campaign/extract_facts.py --game "<Cyberpunk 2077>" ^
    --wolvenkit <WolvenKit.CLI.exe> --work <pusty katalog roboczy> ^
    --out code/server/scripting/CampaignSystem/campaign_facts.txt
```

Zmiany lokalne na serwerze: `config/campaign_facts.txt` — `nazwa` dodaje fakt,
`-nazwa` go usuwa.

## Znane ograniczenia

- Goście nadal mają własne grafy questów. Jeśli gość wczyta zapis z innego miejsca
  fabuły, jego gra może sama posuwać questy. Na razie: gość wczytuje zapis sprzed tego
  samego questa co host. Wyciszenie questów u gości to etap 3.
- Host rejestruje kilka tysięcy listenerów faktów naraz. Jeśli to okaże się za drogie,
  zamiennikiem jest natywny hook zapisu FactsDB (RED4ext).
- NPC, walka, sceny i dialogi nie są synchronizowane.

## Plan

1. **Szkielet sesji** (zrobione): rola hosta, dziennik, fakty z listy, stan dla
   spóźnionych graczy.
2. **Lista faktów z gry** (zrobione): nazwy faktów z grafów questów i scen (WolvenKit CLI),
   paczkowanie RPC.
3. **Lobby, zapis kampanii i wspólny start** (szczegóły niżej): gracze zbierają się w
   lobby, host wybiera nową grę albo wczytanie kampanii. Goście nie uruchamiają własnych
   questów, tylko wchodzą do świata hosta.
4. **Sceny i dialogi**: przy starcie sceny u hosta goście są przenoszeni do niego i
   oglądają. **O opcjach dialogowych gracze głosują** (zasady niżej), wynik wybiera gra
   hosta.
5. **NPC i walka**: AI liczona u hosta, klienci zgłaszają trafienia.
6. **Przejście kampanii misja po misji**, potem Phantom Liberty. Łatki na sceny, które
   zakładają jednego V (Johnny, braindance, Songbird).

### Lobby (etap 3)

- Serwer trzyma stan lobby: lista graczy, gotowość, kto jest hostem, wybór hosta.
- Host wybiera:
  - **Nowa gra**: każdy gracz tworzy swoją postać w kreatorze gry. Ścieżkę życia (Korpo,
    Nomada, Dziecko ulicy) wybiera głosowanie, bo prolog jest jeden dla wszystkich —
    zwycięska ścieżka obowiązuje każdego gracza.
  - **Wczytaj kampanię**: zapis gry hosta + zapis kampanii na serwerze.
- **Zapis kampanii** = zapis gry hosta (świat i fabuła) + plik na serwerze
  `campaigns/<nazwa>.json` z postaciami wszystkich graczy: wygląd z kreatora, ścieżka
  życia, poziom, atrybuty, perki, ekwipunek, pieniądze, powiązany po nazwie gracza.
  Przy wczytaniu każdy gość dostaje swoją postać z powrotem; gracz spoza zapisu
  tworzy nową.
- Otwarte pytanie techniczne: CyberpunkMP łączy się z serwerem dopiero w świecie gry
  (HUD `MultiplayerGameController`), nie w menu głównym. Lobby albo dostanie połączenie
  w menu, albo będzie „poczekalnią” w lekkim świecie (wzór NCO: spawn `#q000_spwn_start`).

### Głosowanie (ścieżka życia i dialogi)

- Każdy gracz, także host, ma jeden głos. Wygrywa opcja z największą liczbą głosów.
- **Remis**: losowanie spośród remisujących opcji.
- Czas: 15 s na głos (ustawienie serwera). Przy dialogach na czas gry obowiązuje zegar
  gry. Po czasie liczą się oddane głosy; jeśli nikt nie zagłosował, wybór należy do hosta
  (przy ścieżce życia: losowanie spośród wszystkich trzech).
- Głos można zmienić do końca czasu. Wszyscy widzą głosy na żywo.
- Opcje widoczne w głosowaniu to opcje dostępne dla postaci hosta (testy umiejętności,
  opcje ścieżki życia) — to jego gra prowadzi dialog. Rozszerzenie na później: opcja
  dostępna, jeśli spełnia ją którykolwiek gracz.
- Do zbadania: jak gra hosta wybiera opcję bez wciśnięcia klawisza (`dialogUI.script`,
  blackboard `UIInteractions`), a kreator — ścieżkę
  (`characterCreationGenderBackstoryMenu.script`).

## Budowanie

Wymagania: VS 2022 Build Tools (MSVC 14.44), Windows SDK **10.0.22621.0** (26100 psuje
build), xmake, .NET 8 i 9, pnpm 9.

```
git submodule update --init
xmake f -y --vs_sdkver=10.0.22621.0
xmake -y -j 4
```

`-j 4` lub mniej — wyższa równoległość kończy się `C3859` (brak pamięci na PCH).

Uruchomienie serwera (build release wymaga danych do panelu admina):

```
set CYBERPUNKMP_ADMIN_USERNAME=admin
set CYBERPUNKMP_ADMIN_PASSWORD=<hasło>
build\windows\x64\release\Server.Loader.exe
```

W logu powinno być `[Plugin:Campaign] Campaign co-op ready, watching N quest fact(s)`.
Lokalne zmiany listy faktów: `build\windows\x64\release\config\campaign_facts.txt`.

Sprawdzenie skryptów przed wgraniem do gry:

```
.\tools\CheckScripts.ps1
```

## Licencja

CyberpunkMP jest na licencji Tilted Phoques (`LICENSE.md`): zmiany muszą być publiczne na
tych samych warunkach, dystrybucja tylko przez GitHub lub własną stronę, nie przez serwisy
z modami. Pluginy korzystające z SDK bez zmian w kodzie CyberpunkMP są z tego zwolnione —
dlatego tryb fabularny jest pisany jako plugin (`CampaignSystem` + `Plugins/Campaign.reds`).
