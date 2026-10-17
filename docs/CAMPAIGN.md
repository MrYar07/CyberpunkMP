# Campaign Co-op — tryb fabularny dla 1–4 graczy

Gałąź `campaign-coop`: oryginalny CyberpunkMP (Tilted Phoques) + port na patch 2.31
z Night City Online (`c5f572b`, `9732c46`) + dodatek fabularny. Warstwy MMO z Night City
Online (świat-szablon, blokada zapisów, czysty start bez questów) celowo NIE są tu
wciągnięte — są przeciwieństwem trybu fabularnego. Ich repo jest pod remote `nco`, do
podbierania pojedynczych poprawek.

## Jak grać

1. Każdy gracz uruchamia grę z `-online -ip <adres> -port <port> -username <nazwa>`.
   Nazwa wiąże gracza z jego postacią w zapisie kampanii, więc trzeba używać tej samej.
2. W menu głównym: **CO-OP CAMPAIGN** łączy z serwerem i otwiera lobby (panel po prawej:
   host, wybór, gracze). Pierwszy gracz w lobby jest hostem.
3. Host wybiera **NEW CAMPAIGN** albo **LOAD <nazwa>** (kolejne kliknięcia przełączają
   zapisane kampanie), goście klikają **READY**, host **START**.
4. Nowa kampania: wszyscy przechodzą do nowej gry (start, trudność). Na ekranie
   „Przeszłość postaci” kliknięcie kafelka to głos (można go zmienić), przy kafelkach
   licznik `głosy/gracze`. Gdy zagłosują wszyscy (albo 15 s po pierwszym głosie), wygrana
   ścieżka ustawia się każdemu i ekran przechodzi dalej do kreatora. Host gra
   normalny start (przycisk gry podstawowej), goście start „Phantom Liberty”, który mod
   podmienia na pusty świat bez questów (patrz niżej).
5. Wczytanie kampanii: host wczytuje swój zapis gry w zwykłym menu „Wczytaj”. Goście
   dostają swoją postać z zapisu kampanii (wygląd, poziom, atrybuty, perki, punkty,
   pieniądze, przedmioty); kto jej nie ma, tworzy nową.
6. Po powrocie do menu w trakcie kampanii: **JOIN THE CAMPAIGN** (host — wczytanie
   zapisu, gość — postać z kampanii).

## Model: host jest autorytetem

- **Host** to pierwszy gracz, który wejdzie do lobby. Jego gra uruchamia questy, sceny
  i dialogi, a jego zapis gry jest zapisem kampanii.
- **Goście** odbijają stan hosta. Serwer przechowuje ostatni stan zgłoszony przez hosta,
  więc gracz, który dołączy później, dostaje cały stan od razu.
- Kiedy host wyjdzie przed startem, hostem zostaje następny gracz z lobby. Po starcie
  kampanii fabuła stoi, aż wróci ten sam host (po nazwie) — tylko jego zapis gry ma
  fabułę. Zrzut stanu jest wysyłany od nowa za każdym wejściem hosta do świata.
- **Goście nie uruchamiają własnych questów.** Działającego questa nie da się zatrzymać,
  można tylko nie dopuścić do jego startu. Dlatego goście startują z
  `ep1\quest\ep1_standalone.gamedef` podmienionego przez archiwum
  `zz_CampaignCoop_GuestStart.archive` (czysty start z Night City Online, `nco 9e1832f`,
  sprawdzony w grze): Night City bez prologu, świat EP1 bez fabuły, bez questów w
  dzienniku. Koszt: z modem przycisk „Phantom Liberty” w nowej grze zawsze daje ten pusty
  start; gość potrzebuje zainstalowanego Phantom Liberty.

## Co jest zsynchronizowane

| Element | Jak |
|---|---|
| Dziennik questów (questy, fazy, cele) | Host nasłuchuje `JournalManager` (`gameJournalListenerType.State`) i przy połączeniu wysyła pełny zrzut. Goście dostają `ChangeEntryStateByHash` z powiadomieniem. |
| Fakty questów | Domyślna lista (16 164 faktów: 11 083 bazy, 5 081 Phantom Liberty) jest wbudowana w plugin. Host rejestruje `QuestsSystem.RegisterListener` dla każdego faktu i wysyła wartości różne od zera. Goście dostają `SetFactStr` — także zera, więc fakty, których host nie ma, są u gościa kasowane. |
| Pozycja, wygląd, pojazdy | To, co już robi CyberpunkMP. |

### Przebieg sesji

1. Klient zgłasza wejście do świata (`EnterWorld`; wyjście: `LeaveWorld`). Host dostaje
   `SetRole(true)`, potem listę faktów w paczkach `WatchFacts(nazwy, last)`; gość
   `SetRole(false)`.
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

## Lobby i zapis kampanii

- Połączenie z serwerem działa w menu głównym. Zmiany w rdzeniu CyberpunkMP (minimalne):
  nazwa gracza z `-username` (wcześniej na sztywno `testuser`), autoryzacja bez świata —
  postać na serwerze powstaje dopiero, gdy jest gracz w świecie, i powstaje od nowa po
  przeładowaniu świata (serwer usuwa wtedy starą kukłę), natywy dla skryptu
  (`IsEnabled`, `IsConnected`, `GetUsername`, `Export/ImportCustomizationState`,
  `TweakDBIDFromNumber`).
- Stan lobby trzyma serwer (`CampaignLobby.cs`) i wysyła go w całości jednym stringiem
  (`LobbyState`) przy każdej zmianie. Klient trzyma go w serwisie Codeware
  `CampaignLobby` (żyje w menu i w grze, w przeciwieństwie do ScriptableSystemów).
- Głosowanie (`CampaignVote.cs`): wspólne dla ścieżki życia i (etap 4) dialogów. RPC
  `VoteOpened`/`VoteTally`/`VoteClosed`, głos `CastVote`. Kończy się po 15 s albo gdy
  zagłosują wszyscy; głosowanie nad ścieżką życia liczy czas dopiero od pierwszego głosu.
- „W grze” = zdarzenie Codeware `Session/Ready` z `IsPreGame() == false`. Menu główne też
  jest światem z graczem, więc `OnWorldAttached`/`OnPlayerAttach` się do tego nie nadają.
- Zapis kampanii: `campaigns/<nazwa>.json` obok serwera (nazwa: `<host>-<data>`). Pola:
  `Host`, `LifePath`, `Players[nazwa]` = słownik pól postaci od klienta. Klient wysyła
  postać co 2 minuty gry (`ReportCharacterPart` + `ReportCharacterDone`, długie pola w
  kawałkach po 15 000 znaków), a wygląd od razu po kreatorze. Przy wczytaniu dostaje ją z
  powrotem (`RequestCharacter` → `CharacterPart`… → `CharacterDone`).
- Pola postaci: `appearance` (stan kreatora, base64), `level`, `streetcred`,
  `attributes`, `points` (niewydane punkty), `perks`, `money`, `items` (id rekordu
  TweakDB jako liczba: ilość). Jeszcze nie: założone przedmioty, modyfikacje i jakość
  przedmiotów, sloty cyberwszczepów.

## Znane ograniczenia

- Fakty od hosta trafiają do świata gościa, w którym działa korzeń bazowej gry
  (`cyberpunk2077_ep1_standalone.quest`). Jeśli jakaś faza czeka na fakt, który host
  ustawi, może ruszyć u gościa. Do sprawdzenia w fazie testowej.
- Host rejestruje kilka tysięcy listenerów faktów naraz. Jeśli to okaże się za drogie,
  zamiennikiem jest natywny hook zapisu FactsDB (RED4ext).
- NPC, walka, sceny i dialogi nie są synchronizowane.

## Plan

1. **Szkielet sesji** (zrobione): rola hosta, dziennik, fakty z listy, stan dla
   spóźnionych graczy.
2. **Lista faktów z gry** (zrobione): nazwy faktów z grafów questów i scen (WolvenKit CLI),
   paczkowanie RPC.
3. **Lobby, zapis kampanii i wspólny start** (zrobione): gracze zbierają się w lobby w
   menu głównym, host wybiera nową grę albo wczytanie kampanii, głosowanie nad ścieżką
   życia, goście startują w świecie bez questów, postacie gości w zapisie kampanii.
4. **Sceny i dialogi**: przy starcie sceny u hosta goście są przenoszeni do niego i
   oglądają. **O opcjach dialogowych gracze głosują** (zasady niżej), wynik wybiera gra
   hosta.
5. **NPC i walka**: AI liczona u hosta, klienci zgłaszają trafienia.
6. **Przejście kampanii misja po misji**, potem Phantom Liberty. Łatki na sceny, które
   zakładają jednego V (Johnny, braindance, Songbird).

### Lobby (etap 3, zrobione — opis działania wyżej w „Jak grać” i „Lobby i zapis kampanii”)

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
