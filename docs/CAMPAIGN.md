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

## Co jest zsynchronizowane (etap 1)

| Element | Jak |
|---|---|
| Dziennik questów (questy, fazy, cele) | Host nasłuchuje `JournalManager` (`gameJournalListenerType.State`) i przy połączeniu wysyła pełny zrzut. Goście dostają `ChangeEntryStateByHash` z powiadomieniem. |
| Fakty questów | Lista nazw w `config/campaign_facts.txt` na serwerze. Host rejestruje `QuestsSystem.RegisterListener` dla każdej i wysyła aktualną wartość. Goście dostają `SetFactStr`. |
| Pozycja, wygląd, pojazdy | To, co już robi CyberpunkMP. |

Kod:
- `code/assets/redscript/Plugins/Campaign.reds` — klient (`CampaignSync`, RPC).
- `code/server/scripting/CampaignSystem/` — plugin serwera (`CampaignSession`).
- `Server/` i `Client/` w pluginie to kod generowany. Identyfikatory RPC to FNV1a64:
  klasa `CyberpunkMP.Plugins.<Klasa>`, funkcja serwera po krótkiej nazwie, funkcja klienta
  po nazwie zmangowanej (`ApplyJournal;Uint32Int32`). Uruchomienie gry z
  `-rpc -rpcdir="<ścieżka>"` generuje je od nowa.

## Znane ograniczenia etapu 1

- Goście nadal mają własne grafy questów. Jeśli gość wczyta zapis z innego miejsca
  fabuły, jego gra może sama posuwać questy. Na razie: gość wczytuje zapis sprzed tego
  samego questa co host. Wyciszenie questów u gości to etap 3.
- Lista faktów jest pusta, dopóki nie zostanie wyciągnięta z grafów questów (etap 2).
- NPC, walka, sceny i dialogi nie są synchronizowane.

## Plan

1. **Szkielet sesji** (ten etap): rola hosta, dziennik, fakty z listy, stan dla
   spóźnionych graczy.
2. **Lista faktów z gry**: wyciągnięcie nazw faktów z `.questphase` (WolvenKit CLI),
   osobno dla bazy i `ep1`.
3. **Wyciszenie questów u gości** i wspólny start: gość wchodzi do świata hosta zamiast
   własnego zapisu.
4. **Sceny i dialogi**: przy starcie sceny u hosta goście są przenoszeni do niego i
   oglądają. Wybory dialogowe robi host.
5. **NPC i walka**: AI liczona u hosta, klienci zgłaszają trafienia.
6. **Przejście kampanii misja po misji**, potem Phantom Liberty. Łatki na sceny, które
   zakładają jednego V (Johnny, braindance, Songbird).

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

W logu powinno być `[Plugin:Campaign] Campaign co-op ready`. Lista faktów do
synchronizacji: `build\windows\x64\release\config\campaign_facts.txt`.

Sprawdzenie skryptów przed wgraniem do gry:

```
.\tools\CheckScripts.ps1
```

## Licencja

CyberpunkMP jest na licencji Tilted Phoques (`LICENSE.md`): zmiany muszą być publiczne na
tych samych warunkach, dystrybucja tylko przez GitHub lub własną stronę, nie przez serwisy
z modami. Pluginy korzystające z SDK bez zmian w kodzie CyberpunkMP są z tego zwolnione —
dlatego tryb fabularny jest pisany jako plugin (`CampaignSystem` + `Plugins/Campaign.reds`).
