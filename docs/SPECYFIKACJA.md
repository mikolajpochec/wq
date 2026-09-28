# WindowQueue — specyfikacja funkcjonalna

Pełny opis działania WindowQueue (macOS) na potrzeby ponownej implementacji na innym systemie, w
szczególności jako rozszerzenia GNOME Shell na GNU/Linux. Opisuje zachowanie, a nie kod: reguły,
algorytmy, liczby, teksty komunikatów i przypadki brzegowe, tak aby dało się je odtworzyć bez
dostępu do źródeł Swift. Stan na commit `face354` plus zmiany skrótów wolnych od
polskich liter (⌥R, ⌥W, ⌥⇧W, ⌥V, ⌥P).

Tam, gdzie oryginał zachowuje się dziwnie lub niespójnie, rozdziały mówią to wprost i podają
zalecenie dla nowej implementacji — szukaj akapitów o „dziwactwach”, „rozbieżnościach” i
„niespójnościach”.

## Spis treści

1. [Czym jest WindowQueue](#czym-jest-windowqueue) — pojęcia, zasady nadrzędne, architektura
2. [Model kolejki](#model-kolejki) — kolejka, zaznaczenie, celowanie, grupy, tryb fullscreen, pusty slot, trwałość, wyszukiwanie
3. [Interfejs: strip, panele i nakładki](#interfejs-strip-panele-i-nakładki) — wygląd, metryki, animacje, interakcje myszą
4. [Akcje, skróty i tryb celowania](#akcje-skróty-i-tryb-celowania) — każda akcja w każdym kontekście, kafelkowanie, komunikaty
5. [Warstwa systemowa](#warstwa-systemowa) — okna, workspace'y, fokus, skróty globalne, rezerwacja miejsca, odpowiedniki w GNOME
6. [Ustawienia](#ustawienia) — wszystkie opcje, domyślne wartości, skróty, trwałość
7. [Plan portu na GNOME](#plan-portu-na-gnome) — architektura rozszerzenia, różnice modelu, kolejność prac


---

## Czym jest WindowQueue

WindowQueue to menedżer okien „w stylu linuksowego WM” nałożony na zwykły pulpit systemu. Nie
zastępuje menedżera okien — działa obok niego i daje trzy rzeczy:

1. **Kolejkę okien** — jedną uporządkowaną listę wszystkich okien wszystkich aplikacji (albo tylko
   bieżącego workspace'u), po której chodzi się z klawiatury. Kolejność jest *stabilna*: ustala ją
   użytkownik, nie system, i nie zmienia się od samego przełączania fokusu.
2. **Strip** — wąski pasek przyklejony do krawędzi ekranu, zawsze na wierzchu, pokazujący ikony okien
   w kolejności kolejki, zaznaczenie i numer bieżącego workspace'u. Przez przełączanie workspace'ów
   strip się nie przesuwa ani nie miga: pulpity przesuwają się pod nim.
3. **Obsługę workspace'ów po numerze** — przełączanie na workspace N i przenoszenie na niego okien
   skrótami super+N / super+⇧+N, z numeracją zgodną z systemową.

Na tym zbudowane są: **tryb celowania** (wybór okna lub grupy okien bez przenoszenia fokusu, potem
akcja na wybranych), **kafelkowanie** wybranych okien w układy, **grupy** okien, **tryb fullscreen**
skupiający kolejkę na jednym oknie, **wyszukiwarka okien**, **focus follows mouse**, nagrywanie
ekranu i zdjęcia okien.

Program jest aplikacją menu-bar (bez ikony w Docku) sterowaną prawie wyłącznie klawiaturą, z
myszą jako drugą drogą do wszystkiego (klik, przeciąganie, kółko, środkowy przycisk na stripie).

### Słownik pojęć

Terminy używane w całej specyfikacji (w nawiasach nazwy z kodu):

| Pojęcie | Znaczenie |
|---|---|
| **okno** (`ManagedWindow`) | Standardowe okno aplikacji, które kwalifikuje się do kolejki: identyfikator systemowy, PID aplikacji, nazwa i ikona aplikacji, tytuł, stan zminimalizowania, workspace. Panele, menu, popupy, dymki, własne nakładki WindowQueue — nie. |
| **kolejka** (`windows`) | Uporządkowana lista wszystkich znanych okien. Jedyne źródło kolejności. |
| **zakres** (`scope`) | `global` — strip i cykl obejmują wszystkie okna; `currentSpace` — tylko okna bieżącego workspace'u. To *widok* na tę samą kolejkę; ukryte okna zachowują swoje miejsca. |
| **widoczny wycinek** (`visibleWindows`) | Okna kolejki, które przepuszcza zakres, w kolejności kolejki. Wszystkie pozycje na stripie i przy przeciąganiu liczone są w tym wycinku. |
| **zaznaczenie** (`selectedID`) | Okno, które kolejka uważa za bieżące. Zwykle to okno z fokusem. Może być puste (np. na pustym workspace). |
| **workspace** (w macOS: Space/desktop) | Wirtualny pulpit. Numerowane od 1 w kolejności Mission Control, *przez wszystkie monitory* (monitor 1: 1–3, monitor 2: 4–5 itd.). Pełnoekranowe przestrzenie aplikacji nie mają numeru. |
| **pusty slot** (`emptySlot`) | Znacznik na stripie, gdy bieżący workspace nie ma okien: pokazuje miejsce w kolejce, w którym pojawiłyby się jego okna. Nic nie jest wtedy zaznaczone. |
| **super** | Klawisz-modyfikator wszystkich skrótów (domyślnie ⌥ Option; może być ⌃, ⌘, ⌃⌥, ⌘⌥). Samo *stuknięcie* supera (bez innego klawisza) otwiera tryb celowania. |
| **tryb celowania** (aiming) | Tryb, w którym klawiatura przesuwa **celownik** (`aimingID`) po stripie bez fokusowania czegokolwiek; zatwierdzenie fokusuje wycelowane okno albo otwiera akcje dla kilku okien. |
| **seria** (run) | Ciągły zakres sąsiednich okien objętych celownikiem, od **kotwicy** (`aimAnchorID`) do celownika. |
| **przypięte** (`aimPinnedIDs`) | Okna dołożone do celu pojedynczo (Shift+klik), niekoniecznie sąsiednie. |
| **grupa** (`WindowGroup`) | Zbiór okien pokazywany na stripie jako jeden wpis; wejście do grupy otwiera obok **panel grupy** — drugi strip z jej oknami. Kolejka się nie zmienia. |
| **grupa kafelkowa** (`TiledGroup`) | Okna ułożone razem w układ (np. obok siebie). Trzyma układ; zmiana ich kolejności w kolejce układa je od nowa; ręczne przesunięcie/zmiana rozmiaru dowolnego z nich ją rozwiązuje. |
| **tryb fullscreen / skupienia** (`maximizedID`, „focus”) | Okno powiększone skrótem fullscreen staje się pierwsze na swoim workspace, pozostałe okna tego workspace'u są **przykryte**: przyciemnione na niebiesko albo zwinięte w **kafelkę stosu**, i pomijane przy cyklu. Ponowny skrót przywraca rozmiar i kolejność. To nie jest systemowy pełny ekran. |
| **kafelka stosu** (hidden stack) | Jeden element stripu zastępujący okno w trybie fullscreen i wszystkie okna, które ono przykrywa: kaskada ikon z licznikiem „+N”. |
| **toast / popup nazwy** | Mały dymek obok ikony na stripie z tytułem okna i nazwą aplikacji; wariant wyśrodkowany na ekranie dla akcji na wielu oknach. |
| **tryb niewidzialny** (invisible strip) | Strip schowany poza ekranem, pokazywany tylko w trybie celowania (rozkłada się jak strona). |
| **nośnik** (carrier) | Szczegół implementacji macOS: niewidoczne okienko WindowQueue przenoszone na docelowy workspace, by system „poszedł” za nim. Na GNOME niepotrzebne. |

### Zasady nadrzędne

Te reguły obowiązują wszędzie i każda implementacja musi ich przestrzegać:

1. **Kolejność jest stabilna.** Nowe okno trafia *bezpośrednio za* zaznaczone (jak klient w
   kafelkowym WM), a nie na koniec. Cykl nigdy nie zmienia kolejności. Kolejność zmieniają tylko:
   skróty przesuwania, przeciąganie na stripie, sortowanie po workspace'ach (ręczne lub
   automatyczne), przeniesienie okna na inny workspace (okno przechodzi do „bloku” swojego nowego
   workspace'u, gdy włączone jest automatyczne sortowanie) i tryb fullscreen (tymczasowo).
2. **Ręczne ułożenie wygrywa z automatycznym.** Automatyczne sortowanie po workspace'ach wyłącza się
   samo przy pierwszym ręcznym przestawieniu kolejki; skrót/menu „Sortuj po workspace'ach” włącza je
   z powrotem.
3. **Kolejność przetrwa restart.** Zapisywana jest na bieżąco i odtwarzana po ponownym uruchomieniu
   przez dopasowanie okien po aplikacji i tytule.
4. **Tryb celowania nie przenosi fokusu**, dopóki użytkownik nie zatwierdzi. Klawiatura jest
   przechwytywana globalnie (klawisze nie trafiają do aplikacji na froncie), ale żadne okno nie
   traci fokusu. Escape zostawia wszystko jak było.
5. **Numery workspace'ów to numery systemowe.** Numer na stripie, w skrótach super+N i przy
   przenoszeniu okien to zawsze ta sama numeracja co w systemowym przeglądzie pulpitów.
6. **Strip nigdy nie przechwytuje niczego poza swoimi ikonami.** Puste obszary panelu przepuszczają
   kliknięcia do okien pod spodem; panel nie zmienia rozmiaru przy dodawaniu/usuwaniu okien —
   zawartość animuje się wewnątrz.
7. **Nic nie „kradnie” użytkownika.** Automatyczne mechanizmy (ponawianie przełączenia, trzymanie
   opróżnionego workspace'u, focus follows mouse) ustępują, gdy użytkownik zrobił coś innego w
   międzyczasie.
8. **Akcja na wielu oknach mówi, co zrobiła** — popupem na środku ekranu, bo nie ma jednej ikony, przy
   której można by go pokazać.

### Architektura aplikacji macOS (dla orientacji)

Komponenty i przepływ danych — port nie musi ich odwzorowywać 1:1, ale podział jest sensowny:

- **Model** (`WindowQueueModel`) — cała logika kolejki, zaznaczenia, celowania, grup, trybu
  fullscreen i pustego slotu. Czysty stan + operacje, bez wywołań systemowych; publikuje zmiany
  (obserwowalny obiekt), na które reagują widoki. Jest w pełni testowalny jednostkowo.
- **Enumerator** (`WindowEnumerator`) — odkrywa okna i ich workspace'y, reaguje na zdarzenia
  systemowe (nowe okno, zamknięcie, zmiana fokusu, zmiana tytułu, minimalizacja, zmiana workspace'u)
  i co kilka sekund robi pełne uzgodnienie (`reconcile`). Odczyt bieżącego workspace'u jest też
  sprawdzany co 0,4 s.
- **Kontroler** (`AppDelegate`) — mapuje skróty i kliknięcia na operacje modelu i wywołania
  systemowe; prowadzi tryb celowania, kafelkowanie, zamykanie, przenoszenie, przełączanie
  workspace'ów, fullscreen, nagrywanie.
- **Warstwa systemowa** — fokusowanie okien (`WindowFocuser`), zamykanie (`WindowCloser`),
  workspace'y (`SpacesBridge`, `SpaceSwitcher`, `WindowSpaceMover`), globalne skróty
  (`HotkeyManager`), wykrywanie stuknięcia supera (`ModifierTapMonitor`), przechwytywanie
  klawiatury w trybie celowania (`AimingKeyCapture`/`KeyboardGrabber`), focus follows mouse,
  rezerwacja miejsca na strip (`DockReservation`, `ScreenEdgeGuard`), układanie okien
  (`WindowTiler`), nagrywanie i zdjęcia (`ScreenCapture`).
- **Interfejs** — strip na każdym monitorze (`StripController`/`StripView`/`StripLayout`), panel
  grupy, popup nazwy (`ToastController`), przyciemnienie ekranów, obrysy okien, menu kafelkowania,
  kafelki akcji, wyszukiwarka, okno ustawień, ikona w pasku menu.
- **Ustawienia** (`Preferences`) — jedna struktura, zapisywana w całości przy każdej zmianie;
  wszystkie komponenty reagują na zmiany na żywo.

Przepływ typowej akcji: skrót → kontroler → operacja na modelu (np. `cycle(by: 1)` zwraca nowe
zaznaczone okno) → wywołanie systemowe (sfokusuj to okno, w razie potrzeby najpierw przejdź na jego
workspace) → model publikuje zmianę → strip przerysowuje zaznaczenie, popup pokazuje nazwę.
Zdarzenia z systemu płyną odwrotnie: system zgłasza zmianę fokusu → enumerator przyjmuje ją jako
zaznaczenie (chyba że właśnie trwa fokusowanie innego okna na żądanie WindowQueue) → strip.

### Jak czytać dalsze rozdziały

- **Model kolejki** — reguły logiczne; najważniejszy rozdział dla poprawności portu, niezależny od
  platformy.
- **Interfejs** — wygląd i zachowanie stripu, paneli i nakładek, z liczbami.
- **Akcje, skróty i tryb celowania** — co robi każda akcja w każdym kontekście.
- **Warstwa systemowa** — co musi zapewnić integracja z systemem, jak robi to macOS i jak zrobić to
  w GNOME.
- **Ustawienia** — pełna lista opcji z domyślnymi wartościami.
- **Plan portu na GNOME** — proponowana architektura rozszerzenia GNOME Shell i kolejność prac.

Wartości liczbowe (czasy, rozmiary) pochodzą z kodu i są punktem wyjścia; tam, gdzie wynikały z
ograniczeń macOS (np. opóźnienia na animację Mission Control), rozdziały to zaznaczają.

---

## Model kolejki

Ten rozdział opisuje czysty model danych aplikacji (`WindowQueueModel` i powiązane typy): co przechowuje, jakie ma operacje i jakie reguły nimi rządzą. Model nie rozmawia z systemem: dostaje od warstwy systemowej listę okien, mapę okno→obszar roboczy, identyfikator bieżącego obszaru i kolejność obszarów, a zwraca stan, który rysuje pasek (strip) i który czytają skróty klawiszowe. Wszystko poniżej musi dać się zaimplementować i przetestować bez żadnego menedżera okien.

Konwencje w przykładach:
- okna oznaczamy liczbami (`1`, `2`, …); kolejka `[1,2,3]` to kolejność od początku (góra/lewa strona paska) do końca;
- obszary robocze (workspace, „pulpit”) mają identyfikatory `10`, `20`, `30`, a `spaceOrder = [10,20,30]` znaczy, że są to obszary nr 1, 2, 3; zapis `1(10)` = okno 1 na obszarze 10;
- „bieżący obszar” to `currentSpaceID`;
- o ile nie powiedziano inaczej, `autoSortByWorkspace = true`, `scope = global`, a model zasilono przez `reconcile` z podaną listą.

Każda mutacja stanu opisana niżej musi powiadomić obserwatorów (UI przerysowuje pasek po każdej zmianie opublikowanej właściwości). Tam, gdzie reguła mówi „nic się nie dzieje”, nie należy też wysyłać powiadomienia.

---

### 1. Wpis okna (`ManagedWindow`)

Jeden wpis = jedno „standardowe” okno innej aplikacji (nie panele, nie dialogi pomocnicze — to filtruje warstwa enumeracji).

| Pole | Typ | Znaczenie |
|---|---|---|
| `id` | liczba całkowita (u32) | identyfikator okna nadany przez serwer okien; **jedyna tożsamość** wpisu w trakcie sesji. Niezmienny. |
| `element` | uchwyt opcjonalny | uchwyt dostępności (AX) do sterowania oknem; może być pusty (okno widziane tylko „z daleka”, np. na innym obszarze). Na GNOME odpowiednikiem jest referencja do obiektu okna. |
| `pid` | int | proces właściciela. Niezmienny. |
| `appName` | tekst | wyświetlana nazwa aplikacji. |
| `bundleID` | tekst? | stały identyfikator aplikacji (na GNOME: app id / plik `.desktop`); może być pusty. |
| `title` | tekst | tytuł okna; może być pusty. |
| `isMinimized` | bool | okno zminimalizowane. |
| `spaceID` | u64? | obszar roboczy, na którym okno leży; pusty = nieznany (np. okno zminimalizowane albo jeszcze nieustalone). |

Wartości pochodne:
- `displayTitle` = `title`, a gdy `title` jest pusty — `appName`.
- `orderKey` = `(bundleID ?? appName)` + znak U+0001 + `title`. Tożsamość „przeżywająca restart” (identyfikatory okien są ważne tylko w sesji). Przykład: okno aplikacji bez `bundleID`, `appName = "App1"`, `title = "w3"` → `"App1\u{1}w3"`.
- `icon` — ikona aplikacji po `pid`, z pamięci podręcznej (ta sama instancja obrazka dla danego `pid`, żeby animacje nie migały); wpisy dla nieżyjących procesów są usuwane z pamięci podręcznej przy dodaniu nowego.

**Równość wpisów** (używana do wykrywania „czy coś się zmieniło”): dwa wpisy są równe, gdy mają równe `id`, `title`, `isMinimized` i `spaceID`. Pola `element`, `pid`, `appName`, `bundleID` **nie** biorą udziału w porównaniu. Skutek (świadomie zachować): jeśli przy scalaniu zmieniła się wyłącznie np. nazwa aplikacji albo pojawił się `element`, a nic innego się nie zmieniło, `reconcile` uzna listę za niezmienioną i nowych wartości nie zapisze (patrz §6, krok 7).

---

### 2. Stan modelu

| Pole | Opis |
|---|---|
| `windows` | uporządkowana lista wpisów — **kolejka**. Jedyna prawda o kolejności. |
| `selectedID` | okno zaznaczone (to, na którym „jest” użytkownik); może być puste. |
| `scope` | `global` („All windows (global)”) albo `currentSpace` („Current workspace only”). Domyślnie `global`. Lustro preferencji. |
| `autoSortByWorkspace` | utrzymywanie kolejki pogrupowanej według obszarów. Domyślnie `true`. Lustro preferencji. |
| `currentSpaceID` | id bieżącego obszaru; puste przed pierwszym odczytem. |
| `currentSpaceIndex` | numer bieżącego obszaru do wyświetlenia (ustawiany z zewnątrz, model go nie interpretuje). |
| `currentSpaceIsFullscreen` | czy wyświetlacz z paskiem pokazuje obszar pełnoekranowy (tylko informacja dla UI). |
| `spaceOrder` | lista id „zwykłych” obszarów w kolejności systemowej; pozycja+1 = numer obszaru. |
| `emptySlot` | znacznik „pustego miejsca”: `{spaceID, beforeID?}` albo brak (§8). |
| `slotFilledID` | okno, które przed chwilą zajęło pusty slot (wskazówka animacji, §8). |
| `maximizedID` | okno w trybie skupienia („fullscreen” aplikacji, §10). |
| `placeBeforeMaximize` | (prywatne) sąsiedzi okna sprzed skupienia: `{after: id?, before: id?}`. |
| `groups` | lista grup okien `WindowGroup {id: Int, ids: [id]}` (§11). |
| `openGroupID` | grupa aktualnie „otwarta” (pokazana obok paska). |
| `tiledGroups` | lista grup kafelkowych `TiledGroup {id: Int, ids: [id], layout: String}` (§13). |
| `aimingID` | okno, na które wskazuje celownik; puste = tryb celowania wyłączony (§12). |
| `aimAnchorID` | kotwica zakresu celowania. |
| `aimPinnedIDs` | zbiór okien dobranych pojedynczo (Shift‑klik / „wszystkie”). |
| `aimInsideGroupID` | grupa, do której celownik „wszedł”. |
| `lastAimStep` | kierunek ostatniego kroku celownika (liczba ≠ 0; początkowo `1`). |
| `announcement` | strumień zdarzeń „ogłoś to okno” (§14). |
| `onManualReorder` | callback wywoływany, gdy użytkownik ręcznie zmienił kolejność (§7.4). |

Obserwatory reagujące na zmiany właściwości:
- zmiana `currentSpaceID` (na inną wartość) → `updateEmptySlot(clearingSelection: true)`;
- zmiana `spaceOrder` (na inną wartość) → jeśli `autoSortByWorkspace`, `sortByWorkspace()`; potem `updateEmptySlot()` (bez czyszczenia zaznaczenia).

Warstwa systemowa ustawia najpierw `spaceOrder`, a dopiero potem `currentSpaceID`, żeby slot przy przyjeździe na obszar liczył się już według nowej kolejności.

---

### 3. Kolejka i reguły stabilności

Kolejka to jedna lista wszystkich znanych okien, ze wszystkich obszarów, także zminimalizowanych. Zasady:

1. **Przełączanie (cycling) nigdy nie zmienia kolejności.** Zaznaczenie wędruje po liście, lista stoi.
2. **Zakres jest widokiem**, nie kopią: filtrowanie do bieżącego obszaru nie zmienia `windows`, więc ręczna kolejność przeżywa przełączanie obszarów.
3. Kolejność zmieniają wyłącznie:
   - jawne operacje przestawiania (§9) — to „ręczne” zmiany, wyłączają auto‑sortowanie;
   - `sortByWorkspace()` (auto lub na żądanie) — sortowanie stabilne;
   - wstawianie nowych okien i usuwanie zniknięć w `reconcile` (§6);
   - `relocate` (okna przeniesione na inny obszar, §7.3);
   - wejście/wyjście z trybu skupienia (§10);
   - `applyOrder` (przywrócenie zapisanej kolejności, §15).
4. **Nowe okno ląduje bezpośrednio za oknem zaznaczonym** (jak w kafelkowych WM, które wstawiają obok aktywnego klienta), a nie na końcu. Gdy nic nie jest zaznaczone (lub zaznaczone właśnie znika) — na końcu. Wyjątek: okno otwierające się na pustym bieżącym obszarze zajmuje pusty slot (§8).
5. Przy auto‑sortowaniu sortowanie jest **stabilne**, więc ręczny układ wewnątrz jednego obszaru zostaje zachowany.
6. Pierwsze zasilenie (pusta kolejka): okna przychodzą z enumeracji posortowane po `(spaceID ?? +∞, id)` — pogrupowane po obszarze, w obrębie obszaru rosnąco po id (≈ kolejność utworzenia). Wszystkie są „nowe”, więc trafiają do kolejki w tej kolejności.

---

### 4. Zakres i widoczny wycinek

`visibleIndices` — indeksy w `windows` widoczne w bieżącym zakresie; `visibleWindows` — odpowiadające im wpisy, **w kolejności kolejki**.

Algorytm:
1. Jeśli `scope == global` albo `currentSpaceID` jest puste → wszystkie indeksy.
2. W przeciwnym razie `filtered` = indeksy okien z `spaceID == currentSpaceID` (zminimalizowane z pustym `spaceID` automatycznie odpadają; zminimalizowane ze znanym `spaceID` bieżącego obszaru zostają).
3. Jeśli `filtered` jest puste **i** `currentSpaceID` **nie** należy do `spaceOrder` (obszar pełnoekranowy albo jeszcze nieodczytany) → **fallback: wszystkie indeksy** (pasek nie może zrobić się pusty z powodu nierozpoznanego obszaru).
4. Jeśli `filtered` jest puste, a obszar jest znanym zwykłym obszarem → wycinek pusty (pasek pokazuje wtedy tylko pusty slot).
5. W przeciwnym razie `filtered`.

Uwagi:
- Zmiana `scope` sama z siebie nie rusza zaznaczenia; zaznaczone okno może znaleźć się poza wycinkiem (wtedy operacje „od zaznaczenia” zachowują się jak przy braku zaznaczenia — patrz niżej).
- Wyszukiwarka okien celowo ignoruje zakres i zawsze przeszukuje całe `windows`.

Numeracja obszarów:
- `workspaceNumber(ofSpace s)` = pozycja `s` w `spaceOrder` + 1, lub brak, gdy `s` nie występuje.
- `workspaceNumber(of window)` = numer jego `spaceID`; brak dla okna bez `spaceID` lub na nieznanym obszarze.
- `groupBounds(of id)` (pomocnicza): w `visibleWindows` znajdź pozycję `id`, rozszerzaj w lewo i w prawo, dopóki sąsiad ma ten sam numer obszaru (brak == brak też się liczy); zwraca zakres pozycji `[lower…upper]` lub brak, gdy okna nie ma w wycinku.

---

### 5. Zaznaczenie

#### 5.1 `select(id, announce)`
1. Jeśli okna o `id` nie ma w `windows` → nic.
2. `openGroupID` = id grupy, do której należy okno, albo brak — **zaznaczenie okna w grupie „wchodzi” do niej, zaznaczenie czegokolwiek innego z niej „wychodzi”**.
3. `selectedID = id`.
4. `emptySlot = brak` (każde jawne zaznaczenie zdejmuje znacznik pustego slotu).
5. Jeśli `announce` → wyślij `announcement(window)`.

Okno nie musi być w widocznym wycinku, żeby dało się je zaznaczyć.

`selectedWindow` = wpis o `selectedID` (szukany w całym `windows`).

#### 5.2 Okna osiągalne przy przełączaniu
`cyclableWindows(backwards)`:
1. `reachable` = `visibleWindows` bez okien **zakrytych** (`isCovered`, §10).
2. Z `reachable` usuń okna, dla których `isSkippedInsideGroup(w, backwards, among: reachable)`:
   - okno nie w grupie → nie pomijane;
   - grupa okna jest otwarta (`openGroupID`) → nie pomijane (po otwartej grupie chodzi się okno po oknie);
   - w przeciwnym razie: `members` = okna tej grupy obecne w `reachable`, w kolejności kolejki; okno jest pomijane, chyba że jest **pierwszym** z `members` (przy ruchu do przodu) albo **ostatnim** (przy ruchu wstecz).

Czyli zamknięta grupa to **jeden przystanek**, a grupa jest „wchodzona” od strony, z której się przychodzi. Liczone wśród osiągalnych: jeśli pierwszy/ostatni członek jest poza wycinkiem albo zakryty, przystankiem jest pierwszy/ostatni członek, który jest osiągalny — grupa nigdy nie wypada z obiegu.

#### 5.3 `cycle(by delta)` — przełączanie z zawijaniem
1. `stops = cyclableWindows(backwards: delta < 0)`. Pusta → zwróć brak, nic nie zmieniaj.
2. `current` = pozycja `selectedID` w `stops`; jeśli jej nie ma (brak zaznaczenia, okno zakryte, poza wycinkiem, pominięty członek zamkniętej grupy): `-1` dla `delta > 0`, `0` dla `delta ≤ 0`. Efekt: do przodu zaczyna od pierwszego przystanku, wstecz od ostatniego.
3. `next = ((current + delta) mod n + n) mod n` (zawijanie w obie strony; `delta` może być > 1, np. przy przewijaniu kółkiem kilka kroków naraz).
4. `select(stops[next], announce: true)` i zwróć to okno.

Przykłady:
- `[1(10), 2(20), 3(10)]`, `scope = currentSpace`, bieżący 10, zaznaczone 1: `cycle(+1)` → 3, `cycle(+1)` → 1 (okno 2 nie istnieje w wycinku).
- `[1,2,3,4]` na jednym obszarze, grupa `{2,3}`, zaznaczone 1: `+1` → 2 (grupa się otwiera), `+1` → 3, `+1` → 4 (grupa się zamyka).
- To samo, zaznaczone 4: `-1` → **3** (ostatni członek; `openGroupID = 1`), `-1` → 2, `-1` → 1 (`openGroupID = brak`).
- `[1(10), 2(10), 3(20), 4(10)]`, `scope = currentSpace`, bieżący 10, grupa `{2,3}`, zaznaczone 4: `-1` → **2** (3 jest poza wycinkiem, więc przystankiem jest 2), grupa otwarta.
- Pusty wycinek (pusty obszar w zakresie `currentSpace`) → `cycle` zwraca brak.
- Skupienie na 3 w `[3,1,2 (10), 4(20)]`: zakryte 1,2; `+1` z 3 → 4, `+1` → 3.

Przypadek brzegowy do zachowania: jeśli zaznaczone okno jest członkiem grupy, która nie jest otwarta (np. grupę utworzono, gdy już było zaznaczone, a nie wywołano `select`), i nie jest przystankiem, to `current` = brak → start od końca listy jak w kroku 2.

#### 5.4 `clampSelection()` (wywoływane na końcu `reconcile`)
1. Jeśli `selectedID` wskazuje okno obecne w `windows` → nic.
2. Jeśli `emptySlot` istnieje → `selectedID = brak` (na pustym obszarze nic nie ma być zaznaczone).
3. W przeciwnym razie `selectedID` = pierwsze okno `visibleWindows` (lub brak). Bez ogłoszenia i bez zmiany `openGroupID`.

#### 5.5 `neighbour(after id)` — następca po zamknięciu (okno nie z bieżącego obszaru)
W `visibleWindows`: jeśli okna nie ma albo wycinek ma ≤ 1 okno → brak. W przeciwnym razie następne okno, a jeśli `id` jest ostatnie — poprzednie.

#### 5.6 `nearestWindow(on space, to id, in order, excluding)` — najbliższe okno na obszarze
1. `origin` = pozycja `id` w liście `order` (lista id); brak → wynik brak.
2. Kandydaci: `visibleWindows` (uwaga: w bieżącym zakresie) z `id ≠ id`, `spaceID == space`, niezminimalizowane, spoza `excluding`.
3. Odległość kandydata = `|pozycja w order − origin|`; kandydat nieobecny w `order` ma odległość +∞.
4. Wynik: kandydat o najmniejszej odległości; przy remisie **pierwszy w bieżącej kolejności kolejki** (czyli zwykle sąsiad poprzedzający). Okna zakryte nie są wykluczane.

Przykład: `[1(10), 2(20), 3(20), 4(20)]`, bieżący 20, zaznaczone 3 zostaje zamknięte → 2 i 4 mają odległość 1, wygrywa 2.

Zachowanie aplikacji przy zamykaniu okna (kontekst wywołania): zanim okno zniknie, wybierany jest następca — jeśli okno jest na bieżącym obszarze: `nearestWindow(on: jego obszar, to: id, in: cała bieżąca kolejka)`; w przeciwnym razie `neighbour(after:)`. Następca jest zaznaczany (`announce: false`). Gdy następcy brak, a okno było na bieżącym obszarze, po zniknięciu okna `reconcile` pokaże pusty slot.

---

### 6. `reconcile(with discovered)` — scalanie świeżej enumeracji

Wejście: pełna, aktualna lista okien od warstwy systemowej (id unikalne), w kolejności `(spaceID ?? +∞, id)`. Algorytm krok po kroku:

1. `byID` = słownik `id → wpis` z `discovered`.
2. `previousOrder` = lista id obecnej kolejki (przed zmianą). `vanishedSelection` = obecny wpis zaznaczonego okna, jeśli jego id **nie** ma w `discovered` (inaczej brak).
3. **Scalanie istniejących** — dla każdego wpisu `existing` z `windows`, w kolejności kolejki:
   - jeśli nie ma go w `byID` → pomiń (okno znikło);
   - weź świeży wpis `u = byID[id]`, ale:
     - `u.spaceID = u.spaceID ?? existing.spaceID` (nieznany obszar nie kasuje znanego),
     - `u.element = u.element ?? existing.element` (uchwyt zdobyty wcześniej zostaje; system widzi szczegóły tylko okien bieżącego obszaru),
     - jeśli `u.title` pusty → `u.title = existing.title`;
   - pozostałe pola (`isMinimized`, `appName`, `bundleID`, `pid`) z `u`;
   - dopisz `u` do `next`.
   Kolejność istniejących okien zostaje dokładnie zachowana.
4. `fresh` = wpisy z `discovered`, których id nie ma w `next`, w kolejności `discovered`.
5. **Wypełnienie pustego slotu**: jeśli `emptySlot` istnieje i w `fresh` jest okno, dla którego `(spaceID ?? currentSpaceID) == emptySlot.spaceID` (bierzemy **pierwsze** takie):
   - usuń je z `fresh`;
   - wstaw do `next` na pozycję okna `emptySlot.beforeID` (jeśli to okno jest w `next`), inaczej na koniec;
   - `emptySlot = brak`; `selectedID = to okno` (przypisanie bezpośrednie: bez ogłoszenia, bez zmiany `openGroupID`);
   - `slotFilledID = to okno`; po 0,8 s wyczyść `slotFilledID`, ale tylko jeśli nadal wskazuje to samo okno.
6. **Wstawienie pozostałych nowych**: jeśli `fresh` niepuste — wstaw je (jako blok, w kolejności `fresh`) bezpośrednio za oknem `selectedID` w `next`; jeśli zaznaczonego nie ma w `next` (brak zaznaczenia albo właśnie znikło) → na koniec. (Jeśli krok 5 zadziałał, „zaznaczone” to już okno z krok 5, więc reszta nowych trafia tuż za nie.)
7. Jeśli `next` jest równe `windows` (równość wpisów wg §1, element po elemencie) → **koniec, nic więcej się nie dzieje** (żadnych sprzątań, sortowania ani korekty zaznaczenia).
8. `windows = next`.
9. **Sprzątanie grup** (jeśli są jakiekolwiek): z każdej grupy usuń id nieobecne w kolejce; usuń grupy mające < 2 okna; jeśli `openGroupID` wskazuje grupę, której już nie ma → `openGroupID = brak`. (Uwaga: `aimInsideGroupID` nie jest tu czyszczone — model traktuje wskazanie na nieistniejącą grupę jak jego brak.)
10. **Sprzątanie grup kafelkowych**: analogicznie — usuń nieobecne id; grupy < 2 znikają.
11. **Zniknięcie okna w skupieniu**: jeśli `maximizedID` wskazuje okno, którego już nie ma → `maximizedID = brak`, `placeBeforeMaximize = brak` (koniec zakrywania; nic nie jest przestawiane).
12. `keepAimOnQueue(previousOrder)` (§12.9).
13. Jeśli `autoSortByWorkspace` → `sortByWorkspace()`.
14. Jeśli `vanishedSelection` istnieje → `followVanishedSelection` (poniżej).
15. `updateEmptySlot()` (bez czyszczenia zaznaczenia).
16. `clampSelection()`.

`followVanishedSelection(vanished, previousOrder)`:
- Działa tylko, gdy `vanished.spaceID` jest znane i równe `currentSpaceID` (zamknięto zaznaczone okno na obszarze, na który patrzy użytkownik).
- `nearest = nearestWindow(on: ten obszar, to: vanished.id, in: previousOrder)`; jeśli jest → `selectedID = nearest` (bez ogłoszenia, bez zmiany `openGroupID`); jeśli nie ma → `showEmptySlot(for: ten obszar)`.
- **Nigdy nie przerzuca zaznaczenia na okno z innego obszaru.** Gdy znikło zaznaczone okno z innego obszaru (lub bez obszaru), ten krok nic nie robi, a `clampSelection` wybierze pierwsze widoczne okno.

Przykłady:
- `[1(10), 2(10), 3(20)]`, zaznaczone 1, pojawia się `5(10)` → `[1,5,2,3]`.
- `[1(10), 2(20), 3(30)]`, bieżący 20, zaznaczone 2; 2 znika → `[1,3]`, `emptySlot = {20, before: 3}`, `selectedID = brak`. Potem pojawia się `4(20)` → `[1,4,3]`, `selectedID = 4`, `emptySlot = brak`, `slotFilledID = 4` przez 0,8 s.
- `[1(10), 2(20)]`, bieżący 10, zaznaczone 1; 2 znika → zaznaczenie zostaje na 1, brak slotu.
- `[1,2,3]` na 10, zaznaczone 2, trwa celowanie na 2; 2 znika → celownik przechodzi na 1 lub 3 (§12.9; przy remisie na 1).

---

### 7. Obszary robocze

#### 7.1 `updateSpaces(mapping: id → spaceID)`
1. Dla każdego okna w kolejce: jeśli mapa ma dla niego wartość i różni się ona od obecnej → ustaw. Okna nieobecne w mapie **zachowują** dotychczasowy `spaceID` (mapa nigdy nie kasuje obszaru).
2. Jeśli nic się nie zmieniło → koniec.
3. Jeśli `autoSortByWorkspace` → `sortByWorkspace()`.
4. `updateEmptySlot()`.

#### 7.2 `sortByWorkspace()`
- `rank(w)` = pozycja `w.spaceID` w `spaceOrder`; okno bez obszaru lub na obszarze spoza `spaceOrder` (np. pełnoekranowym) ma rangę +∞.
- Sortowanie **stabilne** rosnąco po randze (remisy wg dotychczasowej pozycji). Okna nieznanych obszarów lądują na końcu, w dotychczasowej kolejności.
- Jeśli wynik ma tę samą kolejność id → nic nie publikuj.

Przykład: `[1(10), 2(20), 3(30)]`, zmiana `spaceOrder` na `[30,10,20]` → `[3,1,2]`.

Kiedy sortowanie odpala się automatycznie (tylko gdy `autoSortByWorkspace == true`): zmiana `spaceOrder`, `reconcile` (krok 13), `updateSpaces` (gdy coś się zmieniło), `applyOrder`, `endFocus` (po odłożeniu okna na miejsce). **Nie** odpala się po `relocate`, `beginFocus` ani po ręcznych przestawieniach.

#### 7.3 `relocate(ids, toSpace space)` — okna przeniesione na inny obszar
1. Jeśli `ids` puste albo `space` nie należy do `spaceOrder` → nic. `targetRank` = pozycja `space` w `spaceOrder`.
2. `moved` = okna z `ids` w kolejności kolejki, każdemu ustaw `spaceID = space`. `rest` = pozostałe okna.
3. Punkt wstawienia w `rest`:
   - za **ostatnim** oknem z `spaceID == space`, jeśli jakieś jest;
   - inaczej przed **pierwszym** oknem, którego obszar ma rangę > `targetRank` (okna bez rangi się nie liczą);
   - inaczej na końcu.
4. Wstaw `moved` blokiem, `windows = rest` z wstawką; `updateEmptySlot()` (bez czyszczenia zaznaczenia).
Nie wywołuje `onManualReorder` i nie sortuje.

Przykłady: `[1(10), 2(10), 3(30)]`: `relocate([1], 20)` → `[2,1,3]`; potem `relocate([3], 10)` → `[2,3,1]`.

`[1(10), 2(20)]`, bieżący 10, zaznaczone 1, `relocate([1], 20)` → obszar 10 jest pusty → `emptySlot.spaceID = 10`. Uwaga: ponieważ `updateEmptySlot()` jest tu wołane bez czyszczenia, `selectedID` zostaje na 1; aplikacja zaraz potem sama woła `showEmptySlot(10)` (patrz niżej), co czyści zaznaczenie.

Kontekst wywołania (przenoszenie okien skrótem „na obszar N”): po `relocate`, jeśli zaznaczone okno odjechało, a bieżący obszar ≠ docelowy → `nearestWindow(on: bieżący, to: dawne zaznaczone, in: widoczna kolejka sprzed przeniesienia, excluding: przeniesione)`; jeśli jest — zaznacz je i nadaj mu fokus; jeśli nie — `showEmptySlot(bieżący)`.

#### 7.4 Auto‑sortowanie a ręczna kolejność (`onManualReorder`)
- Każda ręczna zmiana kolejności (§9) przed wykonaniem woła `noteManualReorder()`: jeśli `autoSortByWorkspace == true`, ustawia je na `false` i wywołuje `onManualReorder` (aplikacja zapisuje to w preferencjach jako trwałe wyłączenie). Jeśli już było `false` — nic.
- Sens: automat ustępuje ręcznemu układowi, zamiast cofnąć go chwilę później.
- Ponowne włączenie: akcja „Sort queue by workspace” (skrót lub menu) ustawia preferencję i `autoSortByWorkspace = true`, po czym woła `sortByWorkspace()`.
- `relocate`, `beginFocus`/`endFocus`, `applyOrder` i wstawianie nowych okien **nie** są ręcznymi zmianami.

---

### 8. Pusty slot

Znaczenie: użytkownik jest na zwykłym obszarze, na którym nie ma żadnego (niezminimalizowanego) okna. Wtedy nic nie jest zaznaczone, a pasek pokazuje znacznik w miejscu kolejki, gdzie stałyby okna tego obszaru.

`EmptySlot = {spaceID, beforeID?}` — `beforeID` to okno, przed którym stoi znacznik, lub brak = koniec kolejki.

`slotAnchor(space)`: jeśli `space` nie ma w `spaceOrder` → brak; inaczej pierwsze okno w kolejce (pełnej, w kolejności kolejki), którego obszar ma rangę **większą** niż `space` (okna bez rangi się nie liczą). To jest miejsce, gdzie `relocate`/auto‑sort postawiłyby nowe okno tego obszaru.

`showEmptySlot(space)`: `selectedID = brak`; `emptySlot = {space, slotAnchor(space)}`. (Publiczne — wołane też przez aplikację.)

`updateEmptySlot(clearingSelection = false)`:
1. Jeśli `currentSpaceID` puste, albo nie należy do `spaceOrder` (obszar pełnoekranowy/nieznany), albo kolejka jest pusta → **nic** (istniejący slot zostaje, jaki był).
2. `occupied` = czy w **całej** kolejce jest okno z `spaceID == current` i `!isMinimized` (okno zminimalizowane nie zajmuje obszaru).
3. Jeśli `occupied`:
   - jeśli slotu nie ma → nic;
   - inaczej `emptySlot = brak`; jeśli `selectedID` jest puste → `selectedID` = pierwsze okno z `visibleWindows` leżące na bieżącym obszarze i niezminimalizowane (przypisanie bezpośrednie, bez ogłoszenia).
4. Jeśli nie `occupied` i (slotu nie ma, albo jest dla innego obszaru, albo jego `beforeID ≠ slotAnchor(current)`):
   - `keep` = `clearingSelection ? brak : selectedID`;
   - `showEmptySlot(current)`;
   - jeśli `keep` istnieje → przywróć `selectedID = keep`.
   (Czyli przy przyjeździe na pusty obszar zaznaczenie znika; przy innych przeliczeniach slot jest odświeżany, ale zaznaczenie, np. okno, do którego trwa podróż, zostaje.)
5. Jeśli nie `occupied`, a slot jest już poprawny → nic.

Kiedy slot jest przeliczany: zmiana `currentSpaceID` (z czyszczeniem zaznaczenia), zmiana `spaceOrder`, `updateSpaces`, `relocate`, koniec `reconcile`. Kiedy znika: `select(...)` (każde), wypełnienie przez nowe okno w `reconcile`, `updateEmptySlot` gdy obszar ma okno. Uwaga: `select` okna z innego obszaru zdejmuje slot, ale kolejne przeliczenie (np. przy następnym `reconcile` ze zmianą) wstawi go z powrotem, zachowując to zaznaczenie.

Umieszczenie na pasku — `slotPlacement`:
- brak slotu → brak;
- `beforeID` puste lub okno `beforeID` nie należy do `visibleWindows` → `end` (na końcu listy);
- inaczej `before(beforeID)`.

`slotFilledID`: ustawiane w `reconcile` (krok 5) na okno, które zajęło slot; UI animuje wiersz tego okna z miejsca znacznika (wspólna geometria „empty-slot”); po 0,8 s zerowane, o ile nadal wskazuje to samo okno.

Przykłady:
- `[1(10), 2(10), 3(30)]`, zaznaczone 2, przejście na 20 → `emptySlot = {20, before: 3}`, `selectedID = brak`. Powrót na 10 → slot znika, `selectedID = 1` (pierwsze okno obszaru 10 w kolejności kolejki; nie „poprzednio zaznaczone 2” — to ewentualnie przywraca później zdarzenie fokusu z systemu).
- `[1(10), 2(20, zminimalizowane)]`, przejście na 20 → slot dla 20 (zminimalizowane się nie liczy).
- `[1(10), 2(30)]`, `scope = currentSpace`, przejście na 20 → `visibleWindows` puste, `slotPlacement = end`, `cycle` zwraca brak.

Kontekst (warstwa systemowa): zewnętrzna zmiana fokusu na okno spoza obszaru slotu nie zaznacza go, dopóki slot istnieje (okno właśnie wysłane z pustego obszaru nie może ściągnąć zaznaczenia).

---

### 9. Przestawianie

Wszystkie operacje działają na **widocznym wycinku**; okna ukryte przez zakres zostają na swoich indeksach w `windows` (przepisuje się tylko sloty widoczne).

#### 9.1 `move(by delta)` — skróty „przesuń w lewo/prawo”
1. Jeśli zaznaczone jest oknem w skupieniu (`selectedID == maximizedID`) i `maximizedGroupIDs` niepuste → `moveGroup(maximizedGroupIDs, delta)` i koniec (okno w skupieniu i okna, które zakrywa, poruszają się jako jeden blok).
2. `position` = pozycja zaznaczonego w wycinku; brak → nic.
3. `target = position + delta`; poza zakresem `0…n-1` → nic (bez zawijania, bez przycinania).
4. `noteManualReorder()`; **zamień miejscami** okna na pozycjach `position` i `target` (to zamiana, nie przesunięcie — dla |delta| > 1 okna pomiędzy zostają na miejscach).
Przykład: `[1,2,3]`, zaznaczone 3, `move(by: -2)` → `[3,2,1]`.

#### 9.2 `moveGroup(ids, delta)` — blok o jeden (lub więcej) slot
1. `visible` = wycinek; `group` = okna z `ids` obecne w `visible`, w kolejności wycinka. Puste → nic.
2. `first` = pozycja pierwszego z nich w `visible`.
3. `destination = clamp(first + delta, 0, n − |group|)`.
4. Jeśli `destination == first` → nic (brak `noteManualReorder`; niesąsiadujące okna nie zostają nawet zebrane).
5. `noteManualReorder()`; `order` = `visible` bez okien grupy; wstaw `group` (zwarcie, zachowując ich wzajemną kolejność) na indeks `destination` w `order`; zapisz `order` z powrotem w widoczne sloty.
Przykłady (`[1,2,3,4]`, blok `{2,3}`): `+1` → `[1,4,2,3]`; potem `+5` → bez zmian; potem `−1` → `[1,2,3,4]`.

#### 9.3 `move(ids, toVisiblePosition target)` — blok na pozycję bezwzględną
1. `group` = okna z `ids` w wycinku (kolejność wycinka). Jeśli puste albo `|group| == n` (przesuwano by wszystko) → nic.
2. `noteManualReorder()` — **zawsze**, nawet gdy pozycja się nie zmieni.
3. `order` = wycinek bez grupy; `destination = clamp(target, 0, |order|)`; wstaw blok; zapisz w widoczne sloty.
Aplikacja używa tego do przeciągania zwiniętego kafla oraz do „na początek/na koniec” dla wielu wycelowanych okien (`target = 0` lub `target = n`, co przycina się do końca).

#### 9.4 `move(id, toVisiblePosition target)` — jedno okno na pozycję
1. Jeśli `id == maximizedID` i `maximizedGroupIDs` niepuste → `move(ids: maximizedGroupIDs, toVisiblePosition: target)`.
2. `position` = pozycja `id` w wycinku; wymagane: jest, `0 ≤ target < n`, `position ≠ target` — inaczej nic.
3. `noteManualReorder()`.
4. Usuń okno z `windows`; przelicz wycinek (`remaining`).
5. Indeks wstawienia w `windows`: `target ≤ 0` → indeks pierwszego widocznego (`remaining[0]`, albo 0); `target ≥ |remaining|` → tuż za ostatnim widocznym; inaczej `remaining[target]` (przed oknem, które teraz jest na tej pozycji). Wstaw.
Efekt: okno ląduje dokładnie na pozycji `target` wycinka, reszta się przesuwa. Przykład: `[a,b,c]`, `a → 2` → `[b,c,a]`.

`moveToStart()` = `move(selectedID, toVisiblePosition: 0)`; `moveToEnd()` = `move(selectedID, toVisiblePosition: n − 1)`. Brak zaznaczenia → nic.

#### 9.5 Blok okna w skupieniu
`maximizedGroupIDs`: jeśli `maximizedID` ustawione → okna z `visibleWindows`, które są oknem w skupieniu lub są zakryte, w kolejności wycinka; zwracane tylko, gdy jest ich ≥ 2, inaczej lista pusta. Pasek rysuje zakryte okna jako jeden zwinięty kafel.

Przykład: `[1(10), 2(10), 3(20), 4(20)]`, zaznaczone 1, `beginFocus(1)` → blok `[1,2]`; `move(by: +1)` → `[3,1,2,4]`; `move(id: 1, toVisiblePosition: 0)` → `[1,2,3,4]`.

---

### 10. Tryb skupienia („fullscreen”/maksymalizacja z zakrywaniem)

Gdy użytkownik skrótem „toggle maximize” wypełnia ekran oknem (i preferencja `focusMaximizedWindow`, domyślnie włączona, jest aktywna), aplikacja woła `beginFocus(on: id)`. Gdy okno wraca do poprzedniej ramki tym samym skrótem — `endFocus()`. Kliknięcie na pasku w okno zakryte najpierw woła `endFocus()`, potem je zaznacza.

#### 10.1 `beginFocus(on id)`
1. Jeśli `maximizedID == id` → nic (ponowne wypełnienie ekranu tym samym oknem nie nadpisuje zapamiętanego miejsca).
2. `endFocus()` (inne okno w skupieniu wraca najpierw na swoje miejsce — dopiero potem wiadomo, gdzie jest to okno).
3. Znajdź okno w `windows`; brak → koniec (skupienie pozostaje wyłączone).
4. `placeBeforeMaximize = {after: id okna tuż przed nim w pełnej kolejce lub brak, before: id okna tuż za nim lub brak}`.
5. `maximizedID = id`.
6. Jeśli okno ma `spaceID`: przenieś je na indeks pierwszego okna kolejki o tym samym `spaceID` (na czoło „swojego obszaru”; przy auto‑sorcie to czoło zwartego bloku obszaru). Okno bez `spaceID` zostaje na miejscu.
Bez `noteManualReorder`, bez sortowania.

#### 10.2 `isCovered(window)`
Prawda, gdy: `maximizedID` jest ustawione, okno ≠ okno w skupieniu, okno w skupieniu istnieje w kolejce, `window.spaceID` jest znane i równe `spaceID` okna w skupieniu. (Okno w skupieniu bez obszaru niczego nie zakrywa.)

Skutki zakrycia: okna zakryte są pomijane przy przełączaniu (§5.2), nie są celowalne (§12), nie da się ich dobrać Shift‑klikiem; poruszają się razem z oknem w skupieniu (§9.5); pasek rysuje je jako zwinięte/wyszarzone.

#### 10.3 `endFocus()`
1. Brak `maximizedID` → nic. Wyzeruj `maximizedID`; `placeBeforeMaximize` zostanie wyzerowane na końcu w każdym przypadku.
2. Brak zapamiętanego miejsca lub okna w kolejce → koniec.
3. `rest` = kolejka bez tego okna. Funkcja `sameSpace(x)` = indeks w `rest` okna `x`, pod warunkiem że ma ono **ten sam `spaceID`** co okno wracające.
4. Reguły, w kolejności:
   - dawny poprzednik (`after`) istnieje i jest na tym samym obszarze → wstaw tuż za nim;
   - inaczej dawny następnik (`before`) istnieje i jest na tym samym obszarze → wstaw tuż przed nim;
   - inaczej, jeśli okno było na samym czele kolejki (`after == brak`) i w `rest` jest jakieś okno tego obszaru → wstaw przed pierwszym takim;
   - inaczej → **zostaw okno tam, gdzie jest** (koniec, bez sortowania).
5. `windows = rest` z wstawką; jeśli `autoSortByWorkspace` → `sortByWorkspace()`.

Przykłady:
- `[1,2,3 (10), 4(20)]`, `beginFocus(3)` → `[3,1,2,4]`; `endFocus()` → `[1,2,3,4]`.
- `[1,2,3]`, `beginFocus(3)` → `[3,1,2]`; `beginFocus(2)` → najpierw 3 wraca (`[1,2,3]`), potem 2 na czoło → `[2,1,3]`; `endFocus()` → `[1,2,3]`.
- `beginFocus(3)` dwa razy, potem `endFocus()` → `[1,2,3]`.
- `[1,2,3 (10), 4,5 (20)]`, `beginFocus(3)` → `[3,1,2,4,5]`; okno 1 znika → `[3,2,4,5]`; `endFocus()` → `[2,3,4,5]` (za poprzednikiem 2).
- Okno w skupieniu zostaje zamknięte → `reconcile` zeruje `maximizedID`, nic nie jest już zakryte.

---

### 11. Grupy okien (`WindowGroup`)

Grupa to zestaw okien pokazywanych na pasku pod jednym wpisem (jednym kaflem). **Grupa nie zmienia kolejki**: każde okno zostaje na swoim miejscu, członkowie mogą być rozrzuceni po kolejce i po obszarach. Grupa zmienia tylko rysowanie i sposób przechodzenia.

- `WindowGroup {id: Int (numer ≥ 1), ids: [id]}`; `group(of id)` — pierwsza grupa zawierająca okno (okno jest w co najwyżej jednej).
- `members(of group)` — okna grupy **w kolejności kolejki** (z pełnego `windows`, niezależnie od zakresu i zakrycia).
- `openGroup` — grupa o `openGroupID`.

`makeGroup(ids)`:
1. Usuń te okna z wszystkich istniejących grup; grupy mające teraz < 2 okna znikają.
2. Jeśli `openGroupID` lub `aimInsideGroupID` wskazuje grupę, która zniknęła → wyzeruj.
3. Jeśli `|ids| ≤ 1` → zwróć brak (efekt uboczny: pojedyncze okno zostało wyjęte ze swojej grupy).
4. Numer = **najmniejsza dodatnia liczba nieużywana** przez istniejące grupy.
5. Dołącz grupę `{numer, ids}` na koniec listy i ją zwróć. Nowa grupa **nie** jest otwierana.

Przykład: `[1,2,3]`, `makeGroup([1,2])` (numer 1), `select(1)` → `openGroupID = 1`; `makeGroup([2,3])` → grupa 1 traci 2, ma 1 okno i znika, `openGroupID = brak`; nowa grupa `{2,3}` dostaje numer **1**, ale nie jest otwarta.

`ungroup(containing id)`: jeśli okno jest w grupie — usuń tę grupę; jeśli była otwarta → `openGroupID = brak`. Okna zostają w kolejce na miejscach. (`aimInsideGroupID` nie jest tu zerowane.)

Otwieranie/zamykanie: `openGroupID` ustawia `select` (zaznaczenie członka otwiera jego grupę, zaznaczenie czegokolwiek innego zamyka) oraz `enterAimedGroup`; zamykają `leaveAimedGroup` (gdy zaznaczenie nie jest w tej grupie), `ungroup`, `makeGroup`/`reconcile` gdy grupa przestaje istnieć. `endAiming` **nie** zamyka grupy.

Przechodzenie przez grupy: §5.2–5.3 (zamknięta grupa = jeden przystanek, wchodzona od strony nadejścia; otwarta = okno po oknie). `isSkippedInsideGroup` opisano w §5.2.

Kontekst aplikacji (toggle group): w trybie celowania z ≥ 2 wycelowanymi oknami → koniec celowania, `makeGroup(wycelowane)`, `select(pierwsze wycelowane)`, komunikat „Grouped N windows as group K”; z < 2 → komunikat „Aim at two or more windows to group them”. Poza celowaniem: jeśli zaznaczone jest w grupie → `ungroup`, komunikat „Ungrouped N windows”; inaczej „Nothing to ungroup”.

Grupy i grupy kafelkowe nie są zapisywane między uruchomieniami.

---

### 12. Tryb celowania (aiming)

Celowanie to tryb wyboru okien na pasku bez zmiany fokusu: celownik (`aimingID`) chodzi po pasku, można zbudować zakres (run), dobierać okna pojedynczo, wchodzić do grup; dopiero zatwierdzenie coś zaznacza i fokusuje. `selectedID` nie jest w trakcie celowania ruszane. Tryb jest włączony ⇔ `aimingID ≠ brak`.

#### 12.1 Okna celowalne (`aimableWindows`)
- Jeśli celownik jest w grupie (`aimInsideGroupID` wskazuje istniejącą grupę) → `members(of: grupa)` (wszyscy członkowie w kolejności kolejki).
- W przeciwnym razie: `reachable` = `visibleWindows` bez zakrytych; z nich zostaw okna spoza grup oraz, dla każdej grupy, **tylko pierwszego osiągalnego członka** (w kolejności kolejki — niezależnie od kierunku ruchu; to różnica względem przełączania). Grupa jest więc jednym przystankiem.

`aimedWindow` = wpis o `aimingID`. `aimedGroup` = jeśli celownik **nie** jest w grupie, grupa okna `aimingID` (czyli celownik stoi na grupie jako całości); inaczej brak.

#### 12.2 Zakres i zbiór wycelowanych (`aimedWindows`, `aimedIDs`)
Funkcja `run(over candidates)`:
1. `aim` = pozycja `aimingID` w `candidates`; brak → pusta lista.
2. `ids` = `aimPinnedIDs` ∪ wszystkie kandydaci między pozycją kotwicy a `aim` włącznie (kotwica = pozycja `aimAnchorID` w `candidates`, a gdy jej nie ma — sama pozycja `aim`).
3. Wynik: `candidates` odfiltrowani do `ids` (kolejność kandydatów). Dobrane okna spoza kandydatów są pomijane.

`aimedWindows`:
- w grupie → `run(over: members(grupy))` (zakres liczony wzdłuż członków grupy, nie kolejki — okna leżące w kolejce między członkami nie wchodzą);
- poza grupą → `run(over: visibleWindows)` (uwaga: po całym wycinku, więc zakres obejmuje też okna zakryte i niepierwszych członków grup leżących pomiędzy), następnie **rozwinięcie grup**: dla każdego okna w wyniku dodaj wszystkich członków jego grupy; wynik = `visibleWindows` odfiltrowane do tego zbioru (członkowie spoza wycinka odpadają).
`aimedIDs` = zbiór id z `aimedWindows`.

#### 12.3 `beginAiming()`
1. `aimAnchorID = brak`, `aimPinnedIDs = ∅`, `lastAimStep = 1`.
2. `aimInsideGroupID` = grupa zaznaczonego okna, jeśli zaznaczone należy do grupy (celowanie rozpoczęte w grupie zaczyna się w niej).
3. `aimingID` = zaznaczone okno, jeśli jest celowalne; inaczej pierwsze okno celowalne; inaczej brak (tryb się nie włącza).
4. Zwraca `aimedWindow`.
(Aplikacja nie włącza trybu, gdy `visibleWindows` jest puste.)

#### 12.4 `moveAim(by delta)` — ruch celownika z zawijaniem
1. Jeśli `delta ≠ 0` → `lastAimStep = delta`.
2. Kotwica = brak, dobrane = ∅ (ruch zwija zakres do jednego okna).
3. `list = aimableWindows`; pusta → brak.
4. `current` = pozycja celownika w `list`, lub `-1` dla `delta > 0` / `0` dla `delta ≤ 0`.
5. `aimingID = list[((current + delta) mod n + n) mod n]`.

#### 12.5 `extendAim(by delta)` — rozszerzanie/zwężanie zakresu (Shift+strzałka)
1. Jeśli `delta ≠ 0` → `lastAimStep = delta`.
2. `list = aimableWindows`; celownika w niej nie ma → brak, nic nie zmieniaj.
3. Jeśli kotwica pusta → kotwica = obecny celownik.
4. `aimingID = list[clamp(current + delta, 0, n − 1)]` — **bez zawijania**, zatrzymuje się na końcach. Dobrane okna zostają.

Przykład: `[1,2,3,4]`, zaznaczone 2, `beginAiming`, `extendAim(+1)` → wycelowane `[2,3]`; `moveAimedGroup(+1)` → kolejka `[1,4,2,3]`, wycelowane nadal `[2,3]`; `moveAimedGroup(+5)` → bez zmian; `moveAimedGroup(−1)` → `[1,2,3,4]`; `extendAim(−3)` → celownik na 1, kotwica 2 → `[1,2]`.

#### 12.6 `moveAimedGroup(by delta)`
= `moveGroup(aimedIDs w kolejności aimedWindows, delta)` (§9.2) — przenosi cały wycelowany zestaw o slot, zbiera go w zwarty blok i zostawia wycelowanym (to ręczna zmiana → wyłącza auto‑sort).

#### 12.7 `toggleAim(id)` — Shift‑klik
1. Wymagane: tryb aktywny, okno jest w `visibleWindows` i nie jest zakryte — inaczej nic.
2. `picked` = obecne `aimedIDs` (wszystko, co wycelowane: zakres + dobrane + rozwinięte grupy).
3. Kotwica = brak.
4. Jeśli `id ∈ picked`:
   - jeśli `|picked| == 1` → koniec (ostatniego wycelowanego nie da się odznaczyć);
   - usuń `id`; jeśli celownik stał na `id`, przenieś go na najbliższe (wg pozycji w `visibleWindows`) okno pozostałe w `picked`, przy remisie wcześniejsze.
5. Jeśli `id ∉ picked`: dodaj, `aimingID = id`.
6. `aimPinnedIDs = picked`.

Przykład: `[1,2,3,4]`, celownik na 1: `toggleAim(3)` → `[1,3]`; `extendAim(+1)` → `[1,3,4]` (kotwica 3, celownik 4, dobrane {1,3}); `toggleAim(1)` → `[3,4]`; `moveAim(+1)` → jedno okno.

Przypadki brzegowe (zachować dosłownie):
- Poza grupą, odznaczenie pojedynczego członka grupy wycelowanej w całości nie działa trwale — rozwinięcie grup (§12.2) przywraca go, bo pozostali członkowie zostają w zbiorze.
- Celownik wewnątrz grupy + Shift‑klik okna spoza grupy: okno trafia do dobranych i staje się celownikiem, ale ponieważ zakres liczy się tylko po członkach grupy, a celownika wśród nich nie ma, `aimedWindows` staje się puste (okno spoza grupy nie jest nigdy wycelowane). Zatwierdzenie w tym stanie sfokusuje jednak okno pod celownikiem.

#### 12.8 `aimAll()` — „wszystko w zasięgu” (klawisz A) i powrót
1. Tryb nieaktywny → `false`. `reachable` = id okien celowalnych; puste → `false`.
2. Kotwica = brak.
3. Jeśli `reachable ⊆ aimedIDs` (liczone już po wyzerowaniu kotwicy) → `aimPinnedIDs = ∅`, zwróć `false` — drugie naciśnięcie wraca do samego okna pod celownikiem.
4. Inaczej `aimPinnedIDs = reachable`, zwróć `true`.
Poza grupą: wycelowany jest cały wycinek (grupy rozwinięte, zakryte nie). W grupie: tylko członkowie grupy.

Przykłady: `[1,2,3,4]`, grupa `{2,3}`, zaznaczone 1: `aimAll()` → `true`, `{1,2,3,4}`; ponownie → `false`, `{1}`. Zaznaczone 2 (w grupie), `beginAiming`, `aimAll()` → `{2,3}`. Grupa `{1,3}` w `[1,2,3,4]`, zaznaczone 3 → `aimAll()` → `{1,3}`.

#### 12.9 Wchodzenie do grupy i wychodzenie
`enterAimedGroup()` (strzałka „w głąb ekranu” lub Return, gdy celownik stoi na grupie):
1. Wymaga `aimedGroup` — inaczej `false`.
2. `aimInsideGroupID = grupa`, `openGroupID = grupa`, kotwica = brak, dobrane = ∅.
3. Celownik na **ostatniego** członka, jeśli `lastAimStep < 0` (przyszło się od dołu/wstecz), inaczej na **pierwszego** (w kolejności kolejki). Zwraca `true`.

`leaveAimedGroup()` (strzałka „w stronę paska”):
1. Wymaga celownika w istniejącej grupie — inaczej `false`.
2. `aimInsideGroupID = brak`; jeśli zaznaczone okno nie należy do tej grupy → `openGroupID = brak` (inaczej grupa zostaje otwarta).
3. Kotwica = brak, dobrane = ∅; celownik na pierwszego członka grupy (kolejność kolejki). Zwraca `true`.

Przykłady (grupa `{1,3}` w `[1,2,3,4]`; pasek pokazuje `[grupa(1,3)] [2] [4]`):
- zaznaczone 4, `beginAiming`: poza grupą; `moveAim(−1)` → 2; `moveAim(−1)` → 1, `aimedGroup = 1`, wycelowane `{1,3}` (2 nie);
- `enterAimedGroup()` → w grupie, celownik 3 (przyszedł wstecz), wycelowane `{3}`; `leaveAimedGroup()` → poza, wycelowane `{1,3}`;
- zaznaczone 1, `beginAiming` → od razu w grupie 1, wycelowane `{1}`; `extendAim(+1)` → celownik 3, wycelowane `{1,3}` (okno 2 nie wchodzi); `moveAim(+1)` → zawija do 1.
- Grupa `{2,3}` w `[1,2,3,4]`: z 1 `moveAim(+1)` → grupa, wejście → celownik 2; z 4 `moveAim(−1)` → grupa, wejście → celownik 3.

#### 12.10 `keepAimOnQueue(previousOrder)` — znikanie okien w trakcie celowania
Wołane w `reconcile` (krok 12):
1. Kotwica, której okna już nie ma → brak.
2. `aimPinnedIDs` ∩ obecne okna.
3. Jeśli okna pod celownikiem nie ma, a było w `previousOrder`: nowy celownik = okno z `previousOrder` obecne w bieżącym `visibleWindows`, najbliższe pozycji starego celownika w `previousOrder` (remis → wcześniejsze); gdy żadnego → pierwsze okno wycinka (lub brak — tryb się wtedy wyłącza). Jeśli nowy celownik równa się kotwicy → kotwica = brak.
(Używa `visibleWindows`, nie celowalnych — celownik może trafić na okno zakryte lub niepierwszego członka grupy.)

#### 12.11 `endAiming()` i zatwierdzenie
`endAiming()` zeruje `aimingID`, kotwicę, dobrane i `aimInsideGroupID`. Nie rusza `selectedID` ani `openGroupID`.

Zatwierdzenie (Return/Spacja, gdy nie wchodzi się do grupy ani nie otwiera menu układów): aplikacja bierze `aimedWindow` (**jedno okno pod celownikiem**, nie cały zakres), woła `endAiming()`, `select(to okno, announce: false)` i nadaje mu fokus. Anulowanie (Esc, klik poza panelami): `endAiming()` bez zaznaczania. Zwykły klik w okno na pasku: anuluje celowanie, zaznacza klikane okno i je fokusuje. Akcje wielookienkowe (maksymalizuj, minimalizuj, zamknij, na początek/koniec, przenieś na obszar, grupuj, zrzut) używają `aimedWindows`; przy jednym wycelowanym oknie aplikacja najpierw kończy celowanie i zaznacza to okno, po czym wykonuje zwykłą akcję. Menu układów kafelkowych dostępne, gdy `|aimedWindows| ≥ 2` i celownik nie stoi na grupie jako całości.

---

### 13. Grupy kafelkowe (`TiledGroup`)

Zapis faktu, że zestaw okien trzyma wspólny układ (tiling). Układ podąża za kolejką: przestawienie okien w kolejce powoduje ponowne rozłożenie w nowej kolejności. Niezależne od `WindowGroup`.

- `TiledGroup {id: Int (numer ≥ 1), ids: [id], layout: String}` — `layout` to nazwa układu (np. „Main and stack”, „Side by side”, „Stacked”).
- `setTiled(ids, layout)`:
  1. usuń te okna z innych grup kafelkowych (okno jest w co najwyżej jednym układzie); grupy z < 2 oknami znikają;
  2. `|ids| < 2` → zwróć brak (ale powiadom o zmianie);
  3. numer = najmniejsza dodatnia liczba nieużywana; dołącz na koniec listy; zwróć.
- `clearTiled(containing id)` — usuń grupę zawierającą okno (okna zachowują ramki, po prostu przestają być trzymane); brak takiej → nic.
- `clearTiled()` — usuń wszystkie (gdy już puste → nic).
- `isTiled(window)`, `tiledGroup(of id)`, `tiledIDs` (spłaszczone id wszystkich grup w kolejności listy).
- `tiledWindowsInQueueOrder(group)` — okna grupy w **bieżącej kolejności kolejki**; to jest kolejność rozmieszczania w układzie.
- Sprzątanie w `reconcile` (§6 krok 10): zamknięte okna wypadają, grupa < 2 znika.

Przykłady:
- `[1,2,3]`, `setTiled([1,2,3], "Main and stack")` → numer 1; zaznaczone 3, `move(by: −2)` → kolejność w układzie `[3,2,1]`; znika 2 → `ids = [1,3]`; znika 1 → grupy brak.
- `[1,2 (10), 3,4 (20)]`: `setTiled([1,2])` → 1, `setTiled([3,4])` → 2; `clearTiled(containing: 3)` → zostaje `[1]`; `setTiled([3,4])` → znów 2; `setTiled([2,3])` → obie stare grupy spadają do 1 okna i znikają, nowa dostaje numer 1, jedyna grupa `ids = [2,3]`.

Kontekst aplikacji: po każdej zmianie `windows` aplikacja porównuje `tiledWindowsInQueueOrder` każdej grupy z ostatnio rozłożoną kolejnością i przy różnicy rozkłada ponownie (pomijając grupę zawierającą okno w skupieniu — wtedy tylko zapamiętuje nową kolejność). Ręczne przesunięcie/zmiana rozmiaru okna z układu przez użytkownika → `clearTiled(containing:)`.

---

### 14. Ogłoszenia (`announcement`)

- Zdarzenie niesie wpis okna; konsument pokazuje dymek (toast) z tytułem okna przy jego ikonie.
- Jedynym źródłem jest `select(id, announce: true)`. Z `announce: true` wołają: `cycle(by:)` (skróty „poprzednie/następne” oraz przewijanie kółkiem po pasku) i polecenie diagnostyczne „focus”.
- **Nie** ogłaszają: kliknięcie na pasku, wybór w wyszukiwarce, zatwierdzenie celowania, przejęcie zewnętrznej zmiany fokusu, najechanie myszą (focus‑follows‑mouse), skoki na obszar, a także wszystkie bezpośrednie zmiany `selectedID` w modelu (wypełnienie slotu, `followVanishedSelection`, `clampSelection`, `updateEmptySlot`).

---

### 15. Trwałość kolejności (`QueueOrderStore`)

- Magazyn: preferencje użytkownika (UserDefaults; na GNOME np. GSettings lub plik w `~/.config`), klucz **`queueOrder.v1`**, wartość: lista tekstów = `orderKey` kolejnych okien całej kolejki (niezależnie od zakresu).
- **Zapis**: po starcie obserwacji każda zmiana `windows` jest brana pod uwagę, ale:
  - listy puste są ignorowane (pusta kolejka to stan przejściowy — start, zamykanie ostatniego okna — i nie może nadpisać dobrego zapisu);
  - debounce 2 s: zapis następuje dopiero po 2 s bez kolejnych zmian, z ostatnią wartością.
- **Odtworzenie**: dokładnie raz na uruchomienie, gdy kolejka pierwszy raz stanie się niepusta (w następnym obrocie pętli zdarzeń, żeby lista była już w modelu). Jeśli zapis istnieje i jest niepusty → `applyOrder(keys)`. Dopiero potem zaczyna się zapisywanie. Okna odkryte później nie są już dopasowywane.
- `applyOrder(keys)` — dopasowanie zachłanne i wyrozumiałe:
  1. `remaining` = bieżąca kolejka, `ordered` = [].
  2. Dla każdego klucza po kolei: pierwsze okno w `remaining` o tym `orderKey` przenieś na koniec `ordered`; brak → pomiń klucz.
  3. Doklej `remaining` (w dotychczasowej kolejności) na koniec.
  4. Jeśli kolejność id się nie zmieniła → nic. Inaczej `windows = ordered`; jeśli `autoSortByWorkspace` → `sortByWorkspace()` (czyli przy auto‑sorcie zapis decyduje tylko o kolejności wewnątrz obszarów).
  Duplikaty (dwa okna o tym samym `orderKey`) są obsłużone naturalnie: każdy wpis klucza zajmuje kolejne pasujące okno. Okno ze zmienionym tytułem po prostu nie pasuje. Nie jest to „ręczna zmiana” (nie wyłącza auto‑sortu).
  Przykład: `[1,2,3]` (tytuły `w1,w2,w3`, app `App1`), klucze `["App1\u{1}w3", "App1\u{1}w1"]` → `[3,1,2]`.
- Nie są zapisywane: zaznaczenie, grupy, grupy kafelkowe, skupienie, slot.

---

### 16. Dopasowanie rozmyte (wyszukiwarka okien)

Wyszukiwarka (niezależna od zakresu) dla każdego okna buduje tekst `appName + " " + title` i liczy `score(query, in: tekst)`. Pusty `query` → wszystkie okna w kolejności kolejki (bez liczenia). W przeciwnym razie: okna z wynikiem ≠ brak, posortowane malejąco po wyniku (remisy w kolejności kolejki). Podświetlenie wraca na pozycję 0 przy każdej zmianie zapytania; ruch podświetlenia zawija się.

`score(query, candidate)`:
1. `terms` = `query` podzielone po spacji, **bez pustych kawałków** (wiele spacji = jedna). Brak słów → wynik `0` (pasuje wszystko).
2. `haystack` = `candidate` zamieniony na małe litery, jako tablica znaków (grafemów). Każde słowo również małymi literami. Brak zdejmowania znaków diakrytycznych (`ł` ≠ `l`).
3. Każde słowo musi pasować samodzielnie: jeśli którekolwiek zwróci brak → cały wynik brak. Inaczej `total` = suma wyników słów.
4. Wynik = `total − (długość haystack div 20)` (dzielenie całkowite; kara za długie tytuły, żeby przy remisie wygrywał krótszy).

Separatory słów (znak poprzedzający czyni pozycję „początkiem słowa”): spacja, `-`, `_`, `.`, `/`, `:`, `—` (em dash), `–` (en dash), `(`, `[`, `|`, `,`, `'`. Pozycja `i` jest początkiem słowa, gdy `i == 0` albo `haystack[i−1]` jest separatorem.

Wynik słowa (`scoreTerm`):
1. Puste słowo → 0.
2. **Podciąg ciągły** (substring): znajdź **pierwsze** (najbardziej lewe) wystąpienie na pozycji `i`. Wynik = `100 − min(i, 40)`, plus `25`, jeśli `i` jest początkiem słowa. (Premia liczona tylko dla pierwszego wystąpienia, nawet jeśli dalsze zaczyna słowo.)
3. Jeśli brak podciągu → **dopasowanie z przerwami** (tylko ciasne):
   - przejdź haystack od lewej zachłannie: każdy znak równy kolejnemu nieodnalezionemu znakowi słowa jest dopasowaniem (bez cofania się);
   - przy pierwszym dopasowaniu zapamiętaj `first`; `+25`, jeśli to początek słowa;
   - przy każdym kolejnym dopasowaniu `+4`, jeśli leży tuż za poprzednim dopasowaniem;
   - jeśli nie dopasowano wszystkich znaków → brak;
   - `span = last − first + 1`; jeśli `span > długość słowa + 3` → brak (dopuszczalne co najwyżej 3 pominięte znaki łącznie);
   - wynik = premie `− min(first, 20)`.
   Uwaga: ponieważ dopasowanie jest zachłanne od lewej, wczesne przypadkowe trafienie pierwszej litery może dać zbyt szeroki `span` i odrzucenie, mimo że dalej istnieje ciasne dopasowanie — to zamierzone/zachowywane zachowanie.

Przykłady:
- `"saf"` w `"Safari Start"` → podciąg na 0, początek słowa: `100 + 25 = 125`; długość 12 → kara 0 → **125**.
- `"start"` w `"Safari Start"` → podciąg na 7 (po spacji): `100 − 7 + 25 = 118` → **118**.
- `"sfri"` w `"safari"` → brak podciągu; zachłannie: s@0 (start, +25), f@2, r@4, i@5 (+4, bo 5 = 4+1) → premie 29, `span = 6 ≤ 4+3` → `29 − 0 = 29`, kara `6 div 20 = 0` → **29**.
- `"gle"` w `"go to the example"` → brak podciągu `gle`; zachłannie g@0, l@15, e@16 → `span = 17 > 6` → brak → okno odpada.
- Zapytanie `"term code"` pasuje tylko do okien, w których pasuje i `term`, i `code`; wynik to suma minus kara za długość.

---

### 17. Zestaw scenariuszy kontrolnych (z testów jednostkowych)

Model z obszarami `[10,20,30]`, bieżący 10 (chyba że podano), auto‑sort włączony:

1. `[1(10),2(10),3(30)]`, zaznacz 2; bieżący → 20: slot `{20, before 3}`, zaznaczenie puste. Bieżący → 10: brak slotu, zaznaczone okno z obszaru 10.
2. `[1(10),2(20),3(30)]`, bieżący 20, zaznacz 2; znika 2 → slot `{20, before 3}`, brak zaznaczenia; pojawia się `4(20)` → `[1,4,3]`, zaznaczone 4, brak slotu.
3. `[1(10),2(20),3(20),4(20)]`, bieżący 20, zaznacz 3; znika 3 → zaznaczone 2 (lub 4 — test dopuszcza oba; implementacja referencyjna daje 2).
4. `[1(10),2(20)]`, zaznacz 1; znika 2 → zaznaczone 1, brak slotu.
5. `[1(10),2(20),3(30)]`; `spaceOrder = [30,10,20]` → `[3,1,2]`.
6. `[1(10),2(10),3(20)]`, zaznacz 1; dochodzi `5(10)` → `[1,5,2,3]`.
7. `relocate`: `[1(10),2(10),3(30)]` → `[1]→20` → `[2,1,3]` → `[3]→10` → `[2,3,1]`.
8. `[1(10),2(20)]`, zaznacz 1, `relocate([1],20)` → slot dla 10.
9. Zakres `currentSpace`, `[1(10),2(20),3(10)]`, zaznacz 1: cycle +1 → 3, +1 → 1.
10. Minimalizowane okno nie zajmuje obszaru (slot się pojawia).
11. `applyOrder(["App1\u{1}w3","App1\u{1}w1"])` na `[1,2,3]` → `[3,1,2]`.
12. Zamknięcie okna pod celownikiem → celownik na sąsiada.
13. Zakres `currentSpace` na pustym obszarze 20 (`[1(10),2(30)]`): wycinek pusty, slot na końcu, cycle → brak.
14–26. Scenariusze celowania, skupienia, grup i grup kafelkowych — podane jako przykłady w §5, §9–§13.

---

## Interfejs: strip, panele i nakładki

Ta sekcja opisuje wszystko, co WindowQueue rysuje na ekranie: strip (po jednym na monitor), panel
grupy („drugi strip”), popup nazwy (toast), przyciemnienie ekranów w trybie celowania, obrysy
okien na ekranie, podgląd komórki kafelkowania przy przeciąganiu oraz wszystkie interakcje myszą
na stripie. Liczby są w punktach logicznych (na GNOME: piksele logiczne, przed skalowaniem HiDPI),
czasy w sekundach. Teksty widoczne dla użytkownika są po angielsku i trzeba je odtworzyć dosłownie.

Panel akcji dla celowania myszą (`ActionPanel`), menu układów kafelkowania (`TilingMenu`) i okno
wyszukiwarki są opisane w sekcjach o trybie celowania, kafelkowaniu i wyszukiwarce; tutaj
wspominam o nich tylko tam, gdzie dotykają stripu.

### 1. Wspólne właściwości wszystkich nakładek

Każdy element rysowany przez WindowQueue (strip, panel grupy, popup, obrysy, podgląd komórki,
przyciemnienie) to osobne bezramkowe okno-nakładka o następujących cechach:

- **Nigdy nie przejmuje fokusu klawiatury** i nie aktywuje aplikacji WindowQueue po kliknięciu
  (panel „non-activating”, `canBecomeKey = false`). Klik w strip nie zabiera fokusu oknu, w którym
  użytkownik pisze.
- **Obecne na wszystkich workspace'ach** (sticky), niezależnie od przełączania; nie biorą udziału w
  animacji przesuwania pulpitów (patrz 1.1), nie pojawiają się w przełącznikach okien ani na pasku
  zadań, nie są ruchome, nie mają animacji pojawiania się od systemu (`animationBehavior = .none`).
- **Mogą pojawiać się nad oknami pełnoekranowymi** (`fullScreenAuxiliary`).
- Tło przezroczyste; widać tylko to, co narysowane.
- Warstwy (od dołu): zwykłe okna → przyciemnienie (poziom „status”, 25) → obrysy okien i podgląd
  komórki (ten sam poziom, ale zamawiane później, więc nad przyciemnieniem) → strip, panel grupy,
  popup, panel akcji (poziom „status + 1”, 26). Przyciemnienie przykrywa także górny pasek menu.
- Strip, panel grupy i popup mają systemowy cień okna (`hasShadow = true`) — delikatny cień wokół
  nieprzezroczystych pikseli. Przyciemnienie, obrysy i podgląd komórki są bez cienia.
- Przyciemnienie, obrysy i podgląd komórki **ignorują mysz** (przepuszczają kliknięcia).

#### 1.1. Warstwa ponad pulpitami (`OverlaySpace`)

Na macOS okna „na wszystkich workspace'ach” i tak należą do aktualnie pokazywanego pulpitu, więc
przy przełączaniu workspace'u odjeżdżają razem z nim i są rysowane od nowa po animacji (strip
„mrugałby”). Dlatego WindowQueue tworzy prywatną przestrzeń WindowServera na absolutnym poziomie
100 (ponad wszystkimi pulpitami i pełnoekranowymi przestrzeniami) i przenosi do niej: każdy strip,
panel grupy, popupy, obrysy celowania/fokusu i podgląd komórki (przyciemnienie — nie). Efekt
wymagany funkcjonalnie: **te nakładki stoją nieruchomo, gdy pulpity przesuwają się pod nimi**, i są
widoczne także na pełnoekranowych przestrzeniach. Przeniesienie wykonuje się za każdym razem, gdy
okno nakładki jest pokazywane na nowo. Gdy prywatne API nie jest dostępne, zachowanie spada do
zwykłego „sticky + nad fullscreenem”.

Na GNOME odpowiednikiem jest aktor w warstwie ponad `global.window_group` (np. `Main.layoutManager`
/ `uiGroup` w rozszerzeniu Shella), który nie należy do żadnego workspace'u i nie bierze udziału w
animacji przełączania.

### 2. Metryki (`StripMetrics`)

Wszystkie rozmiary wynikają z ustawienia `iconSize` (domyślnie 34). Kolumna „domyślnie” pokazuje
wartość dla `iconSize = 34`.

| Nazwa | Wzór | Domyślnie |
|---|---|---|
| `spacing` — odstęp między elementami stripu | stała | 6 |
| `padding` — wewnętrzny margines stripu (ze wszystkich stron) | stała | 6 |
| wewnętrzny margines wiersza (ikona → krawędź podświetlenia) | stała | 4 |
| `rowHeight` — wysokość wiersza (wzdłuż stripu) | `iconSize + 8` | 42 |
| `thickness` — grubość stripu (w poprzek) | `rowHeight + 2·padding` | 54 |
| `corner` — promień zaokrąglenia stripu i panelu grupy | `thickness · 0.28` | 15.12 |
| `rowCorner` — promień podświetlenia wiersza | `rowHeight · 0.24` | 10.08 |
| `badgeCorner` — promień tła odznaki workspace'u | `iconSize · 0.27` | 9.18 |
| `iconCorner` — promień przycięcia ikon w kaskadzie, zastępczej ikony, pustego slotu | `iconSize · 0.23` | 7.82 |
| `slotThickness` | `iconSize` | 34 |
| `slotLength` — długość pustego slotu w układzie | `iconSize + 8` | 42 |
| `stackStep` — przesunięcie kolejnej karty kaskady | stała | 5 |
| `stackPeek` — maks. liczba ikon w kaskadzie | stała | 3 |
| `stackLength` — długość kafelki stosu i kafelki grupy w układzie | `rowHeight + 5·(3−1)` | 52 |
| `labelSize` — rozmiar czcionki etykiety pod ikoną | stała | 10 |
| `layoutDuration` / `foldDuration` | stała | 0.32 s |

Wszystkie zaokrąglenia są „ciągłe” (styl squircle, `.continuous`); na GNOME wystarczy zwykły
zaokrąglony prostokąt o tym promieniu.

**Animacje sprężynowe.** Kod używa sprężyn SwiftUI opisanych parą (`response`, `dampingFraction`).
Przeliczenie na klasyczny oscylator (masa 1): sztywność `k = (2π / response)²`, tłumienie
`c = 4π · dampingFraction / response`. Używane sprężyny:

- `layoutAnimation`: response 0.32, damping 0.82 — zmiany układu stripu (dodanie/usunięcie/
  przestawienie elementu, zwijanie/rozwijanie kafelki stosu).
- rozkładanie/składanie strony w trybie niewidzialnym: response 0.32, damping 0.78.
- powiększenie stripu w trybie celowania (i panelu grupy): response 0.25, damping 0.8.
- podświetlenie serii celowania: response 0.22, damping 0.85.
- „osiadanie” upuszczonej ikony: response 0.22, damping 0.9.

**Kolory systemowe** (odtworzyć z motywu GNOME lub stałymi):

- `accent` — systemowy kolor akcentu (domyślnie niebieski macOS ≈ `#007AFF`; na GNOME: kolor
  akcentu z ustawień, np. `accent-color` libadwaita).
- `orange` — systemowy pomarańczowy ≈ `#FF9500` (jasny motyw) / `#FF9F0A` (ciemny).
- `primary` — kolor tekstu motywu: czarny w jasnym, biały w ciemnym. „primary 12%” = ten kolor
  z kryciem 0.12.
- `secondary` — szary tekst drugorzędny (≈ primary z kryciem ~0.5).
- `ultraThinMaterial` — półprzezroczyste, mocno rozmyte tło zależne od motywu (jasny: biel ~40–50%
  z rozmyciem tła; ciemny: grafit ~40–50% z rozmyciem). Bez rozmycia akceptowalne jest tło w kolorze
  okna motywu z kryciem ~0.75.

### 3. Strip: gdzie i kiedy jest na ekranie

#### 3.1. Tryby wyświetlania (`stripDisplay`)

- `activeScreenOnly` („Selected monitor only”): strip tylko na **aktywnym monitorze** — tym, na
  którym jest okno z fokusem klawiatury (`NSScreen.main`). Na pozostałych nic.
- `highlightActiveScreen` („All monitors, highlight selected”, **domyślnie**): strip na każdym
  monitorze. Strip na monitorze nieaktywnym jest **odbarwiony** (nasycenie 0 — skala szarości) i ma
  krycie `inactiveStripOpacity` (domyślnie 0.55). Zmiana aktywności animowana easeOut 0.2 s.
  W trybie celowania wszystkie stripy rysowane są jak aktywne (celowanie wybiera spośród wszystkich
  okien, gdziekolwiek są).
- `hidden`: żadnego stripu; panele stripów są niszczone.

W trybie `activeScreenOnly` jedyny strip zawsze rysowany jest jako aktywny.

Każdy strip pokazuje **tę samą kolejkę** (ten sam widoczny wycinek), różni się tylko numerem
workspace'u w odznace i jej kolorami (zależnymi od tła pod nią) oraz ewentualnym wyszarzeniem.

Stripy są przeliczane (pokazywane/chowane/przesuwane) przy: każdej zmianie modelu kolejki, każdej
zmianie ustawień, zmianie konfiguracji monitorów, aktywacji innej aplikacji i zmianie aktywnego
workspace'u. Panel stripu dla danego monitora (klucz: identyfikator wyświetlacza) raz utworzony
jest trzymany także w stanie ukrytym, by powrót był natychmiastowy; usuwany dopiero, gdy monitor
zniknie albo tryb zmieni się na `hidden`.

#### 3.2. Ukrywanie na pełnym ekranie

Gdy `hideInFullscreen` (domyślnie włączone) i na danym monitorze aktualnie pokazywany workspace
jest **systemową pełnoekranową przestrzenią** aplikacji, strip na tym monitorze jest chowany od razu
(bez animacji). Dotyczy to tylko systemowego pełnego ekranu, nie „trybu fullscreen” WindowQueue
(ten tylko maksymalizuje okno i zwija przykryte okna w kafelkę stosu). Gdy workspace nie ma
osobnej przestrzeni na monitor (jeden wspólny zestaw), bierze się jedyną dostępną informację.

#### 3.3. Numer workspace'u dla monitora

Numer w odznace to indeks workspace'u (numeracja jak w reszcie specyfikacji: od 1, kolejno przez
monitory) aktualnie pokazywanego **na tym monitorze**. Gdy go nie znamy: dla monitora aktywnego —
numer bieżącego workspace'u z modelu; dla innych — brak, i odznaka pokazuje „–” (półpauza U+2013).
Pełnoekranowe przestrzenie nie mają numeru → „–”.

#### 3.4. Strona, wyrównanie, margines

- `stripSide` ∈ {`left` (domyślnie), `right`, `top`, `bottom`}. Lewy/prawy strip jest **pionowy**
  (elementy jeden pod drugim, od góry), górny/dolny **poziomy** (od lewej do prawej). Dalej „wzdłuż”
  = kierunek układania elementów, „w poprzek” = grubość.
- `stripAlignment` ∈ {`start`, `center` (domyślnie), `end`} — położenie treści wzdłuż krawędzi, jak
  `justify-content`: start = góra/lewo, end = dół/prawo. Ułamek: 0 / 0.5 / 1.
- `stripMargin` (domyślnie 4) — odstęp od krawędzi ekranu:
  - w poprzek: strip jest odsunięty od swojej krawędzi ekranu o `stripMargin`;
  - wzdłuż: margines jest odstępem od **końców** krawędzi, ale **tylko od tego końca, do którego
    strip nie jest wyrównany**. Wyrównany do `start` strip dotyka początku obszaru roboczego (np.
    zaczyna się tuż pod paskiem menu, bez marginesu), a `stripMargin` trzyma tylko drugi koniec z
    dala od krawędzi; dla `end` odwrotnie; dla `center` margines jest z obu stron. Dzięki temu
    wyrównany strip jest w linii z oknami obok niego.

Obszar odniesienia to **obszar roboczy monitora bez własnej rezerwacji WindowQueue** (patrz 3.7):
czyli to, co zostaje po odjęciu paska menu i ewentualnego Docka, ale z oddanym z powrotem pasem,
który WindowQueue zarezerwował dla samego siebie. Inaczej strip odsuwałby się od krawędzi o własną
szerokość.

#### 3.5. Okno stripu: stały rozmiar, treść w środku

Okno (panel) stripu **zajmuje całą długość krawędzi** obszaru odniesienia i **nigdy nie zmienia
rozmiaru** przy zmianach kolejki. Jego grubość to `thickness · max(1, aimingScale)` (domyślnie
54 · 1.2 = 64.8), czyli zawsze tyle, ile strip może osiągnąć w trybie celowania — powiększanie
okna w trakcie animacji przycinałoby strip. Położenie okna (dla obszaru odniesienia `V`, grubości
`T`, marginesu `m`):

- left: `x = V.minX + m`, `y = V.minY`, szerokość `T`, wysokość `V.height`;
- right: `x = V.maxX − T − m`, reszta jak wyżej;
- top: `x = V.minX`, `y = V.maxY − T − m` (współrzędne z osią y w górę), szerokość `V.width`,
  wysokość `T`;
- bottom: `x = V.minX`, `y = V.minY + m`.

Okno jest ustawiane natychmiast (bez animacji), tylko gdy docelowa ramka się zmieniła (zmiana
ustawień lub monitorów).

Wewnątrz okna właściwy strip (pasek o grubości `thickness`) jest:

- w poprzek **przyklejony do krawędzi ekranu** (dla left: do lewego brzegu okna; nadmiar grubości
  okna zostaje po stronie ekranu, pusty);
- wzdłuż umieszczony według wyrównania w przestrzeni `długość okna − marginesy z 3.4`;
- przy wyrównaniu `center` i otwartym panelu grupy przesunięty dodatkowo o `companionLength / 2`
  w stronę początku (w górę / w lewo), aby strip i panel grupy były wyśrodkowane jako całość
  (patrz 7.2). To przesunięcie animowane jest easeOut 0.32 s. Przy `start`/`end` nic się nie
  przesuwa — para rośnie „do środka”.

Zmiany kolejki są więc czystą animacją treści wewnątrz nieruchomego okna. **Puste, przezroczyste
obszary okna nie przyjmują kliknięć** — trafiają do aplikacji pod spodem. Na GNOME trzeba ustawić
obszar wejścia (input region) dokładnie na widoczny kształt stripu (z uwzględnieniem powiększenia w
trybie celowania i pływającej ikony przy przeciąganiu); ruch wskaźnika dla podpowiedzi jest jednak
śledzony w całym oknie (wskaźnik nad pustą częścią = „nad niczym”).

Offset wzdłuż treści dla punktu w oknie: `along − contentStart`, gdzie `along` liczone od góry
(pionowy) lub od lewej (poziomy), a
`contentStart = leading + free · fraction − shift`,
`leading = (alignment == start ? 0 : stripMargin)`,
`trailing = (alignment == end ? 0 : stripMargin)`,
`free = max(0, długośćOkna − leading − trailing − totalHeight)`,
`shift = (alignment == center ? companionLength / 2 : 0)`.
`totalHeight` z `StripLayout` (sekcja 5). Tego offsetu używa hit-testing najechania i środkowego
kliknięcia, zakotwiczenie popupu i próbkowanie tła odznaki.

#### 3.6. Zawsze na wierzchu, na każdym workspace

Strip jest widoczny na wszystkich workspace'ach i nad oknami pełnoekranowymi (1, 1.1), z wyjątkiem
3.2. Przełączanie workspace'u nie rusza stripu.

#### 3.7. Rezerwacja miejsca na ekranie (`reserveScreenSpace`)

Cel: zmaksymalizowane/kafelkowane okna nie wchodzą pod strip. Szerokość rezerwowanego pasa:
`reservedWidth = ceil(thickness + 2·stripMargin)` (domyślnie `ceil(54 + 8) = 62`), a w trybie
niewidzialnym 0 (strip, który jest tylko w trybie celowania, nie zabiera miejsca oknom).

Na macOS realizowane dwutorowo:

1. **Rezerwacja „jak Dock”** (`DockReservation`): tylko gdy `reserveScreenSpace`, strip nie jest
   `hidden`, nie jest niewidzialny i systemowy Dock jest w trybie auto-ukrywania. Obejmuje tylko
   monitor główny (z paskiem menu): pas szerokości `reservedWidth` przy krawędzi stripu, dla
   left/right od dolnej krawędzi paska menu do dołu ekranu, dla top — pas tuż pod paskiem menu, dla
   bottom — na dole ekranu. Sprawdzane co 2 s i przy zmianie monitorów; przy wyjściu przywracane.
2. **Przycinanie po fakcie** (`ScreenEdgeGuard`, gdy także `trimWindowsOutsideReservation`, domyślnie
   włączone): okno standardowe, które **zmieniło rozmiar** (nie tylko się przesunęło) i po 0.3 s
   spokoju, przy niewciśniętym przycisku myszy, leży przy krawędzi stripu (tolerancja 2 pt od
   krawędzi obszaru odniesienia) i sięga dalej niż pas, jest przycinane tak, by zaczynało się
   `reservedWidth` od krawędzi (dla left: `x = krawędź + gap`, prawa krawędź bez zmian). Okna
   w prawdziwym pełnym ekranie (cały ekran z paskiem menu) i okna ułożone przez samo WindowQueue są
   pomijane. Ponowne „zoom” okna przyciętego wraca do ramki sprzed pierwszego zoomu. Ramka jest
   sprawdzana ponownie po 0.15/0.35/0.7/1.2 s i ustawiana jeszcze raz, jeśli aplikacja ją zmieniła.

Na GNOME wystarczy strut / wyłączna strefa (`_NET_WM_STRUT_PARTIAL` albo w Shellu
`Main.layoutManager.addChrome(actor, { affectsStruts: true })`) o szerokości `reservedWidth` na
każdym monitorze, na którym jest strip, oraz liczenie obszaru odniesienia z pominięciem własnego
struta. Przycinanie po fakcie jest wtedy zbędne.

### 4. Tryb niewidzialny (`invisibleStrip`) i animacja „strony”

Gdy `invisibleStrip` jest włączone, strip jest na ekranie **tylko w trybie celowania**. Poza nim
kolejka istnieje, a zmiany ogłasza sam popup (toast). Panel grupy też jest wtedy ukryty (7.4).
Przełączany skrótem „Hide or show the strip (invisible mode)”.

Animacja otwierania i zamykania: strip to **strona zawieszona na zawiasie przy krawędzi ekranu**.

- Oś obrotu: dla stripu pionowego — oś pionowa (Y), dla poziomego — pozioma (X). Zawias (punkt
  zaczepienia) = ten sam punkt, co przy powiększaniu w celowaniu: krawędź stripu przy ekranie, w
  miejscu wyrównania wzdłuż (left: `(x=0, y=fraction)`, right: `(x=1, y=fraction)`, top:
  `(x=fraction, y=0)`, bottom: `(x=fraction, y=1)` we współrzędnych jednostkowych stripu).
- Kąt złożenia: **+100°** dla left i top, **−100°** dla right i bottom (strona leży „twarzą w dół”
  nad ekranem, ponad 90°), z perspektywą (parametr SwiftUI `perspective: 0.9`, czyli wyraźna
  perspektywa — odległość kamery rzędu wielkości stripu).
- Złożona strona ma krycie 0; rozłożona — 1. Kąt i krycie animowane razem sprężyną response 0.32,
  damping 0.78. Otwarcie wygląda jak odwracanie kartki z ekranu na krawędź.

Sekwencja otwarcia (start celowania): okno stripu, które nie było widoczne, zostaje pokazane w stanie
złożonym (kąt ±100°, krycie 0), a w następnym obiegu pętli zdarzeń stan zmienia się na rozłożony,
co uruchamia animację. Sekwencja zamknięcia (koniec celowania): stan „złożony” (animacja), a po
0.32 s okno jest chowane — pod warunkiem, że strip nadal ma być złożony, tryb niewidzialny nadal
jest włączony i nie trwa celowanie. Składanie dotyczy tylko monitorów, na których strip w ogóle
powinien być; gdzie strip znika z innego powodu (tryb monitora, pełny ekran), chowa się od razu.
Gdy tryb niewidzialny jest wyłączony, strip pokazuje się od razu rozłożony, bez animacji.

Rezerwacja miejsca (3.7) jest w trybie niewidzialnym wyłączona.

### 5. Układ elementów (`StripLayout`)

Strip to lista elementów w kolejności:

1. **odznaka workspace'u** (`badge`) — pierwsza, jeśli `showSpaceBadge` (domyślnie tak);
2. elementy okien w kolejności widocznego wycinka kolejki, gdzie:
   - okno należące do **grupy** jest pokazywane w **kafelce grupy** — jedna kafelka na grupę,
     wstawiana w miejscu **pierwszego** członka grupy (w kolejności kolejki); kolejni członkowie
     wskazują na tę samą kafelkę. Grupa ma pierwszeństwo przed zwijaniem w stos: okno w grupie jest
     w grupie, nawet jeśli jest przykryte;
   - okno należące do zbioru **zwiniętego** (tryb fullscreen, patrz niżej) — w jednej **kafelce
     stosu**, wstawianej w miejscu pierwszego zwiniętego okna; kolejne wskazują na nią;
   - każde inne okno — własny **wiersz**;
3. **pusty slot** (`emptySlot`), jeśli model go ma: wstawiany **przed** elementem okna o wskazanym
   identyfikatorze (jeśli to okno jest widoczne jako wiersz; gdy go nie ma — na koniec) albo na
   końcu listy.

Długość (wzdłuż) każdego elementu w układzie: odznaka i wiersz — `rowHeight`; pusty slot —
`slotLength`; kafelka stosu i kafelka grupy — `stackLength`. Elementy układane od `padding` (6),
kolejne co `wysokość + spacing`. `totalHeight = ostatni_koniec + padding` (bez odstępu po ostatnim);
pusty strip ma `2·padding`.

**Zbiór zwinięty** (kafelka stosu) istnieje tylko gdy: `focusMaximizedWindow` (domyślnie tak) i
`collapseCoveredWindows` (domyślnie tak) i jest okno w trybie fullscreen (`maximizedID`) i co
najmniej jedno okno widocznego wycinka jest przez nie przykryte. Zbiór = przykryte okna + samo okno
fullscreen (jest „kartą na wierzchu” kafelki). Podczas przeciągania **pojedynczej ikony**, która
już się ruszyła (≥ 4 pt), zbiór jest pusty — kafelka rozwija się w wiersze, by ikonę można było
upuścić gdziekolwiek między nimi. Przeciąganie samej kafelki stosu zostawia ją zwiniętą. Samo
wciśnięcie bez ruchu niczego nie rozwija.

**Hit-testing** (offset `o` liczony od początku treści stripu):

- okno pod punktem: pierwsza pozycja w kolejce, której element spełnia
  `top ≤ o < top + wysokość + spacing` (pasmo obejmuje odstęp pod elementem, więc szczeliny między
  ikonami są „żywe”). Punkt na kafelce stosu/grupy zwraca **pierwsze okno** tej kafelki w kolejności
  kolejki. Odznaka i pusty slot nie są oknami — punkt na nich daje „nic”;
- odznaka / kafelka stosu / kafelka grupy (numer grupy): to samo pasmo dla danego elementu;
- „najbliższe okno” (dla przeciągania): jak wyżej, a gdy punkt nie trafia w żadne pasmo (powyżej,
  poniżej, poza stripem) — okno, którego środek elementu jest najbliżej.

Uwaga o zgodności: rysowana kafelka grupy ma w rzeczywistości długość `rowHeight` (ikona +
2·4), a rysowana kafelka stosu `rowHeight + 5·(liczba kart − 1)`; układ (hit-testing, kotwice)
zakłada `stackLength` = 52. Rysowanie idzie zwykłym stosem z odstępami 6, więc przy mniej niż 3
kartach lub przy grupie elementy za kafelką są na ekranie trochę wyżej, niż zakłada hit-testing.
Nowa implementacja powinna rysować i liczyć z tych samych długości (zalecane: kafelka stosu i
kafelka grupy o długości `stackLength`, z treścią wyśrodkowaną).

Strip **nie ma nagłówków** (np. sekcji workspace'ów) ani numerów workspace'ów przy poszczególnych
ikonach — jedyny numer jest w odznace.

### 6. Wygląd stripu i jego elementów

#### 6.1. Tło i ramka stripu

- Pasek: grubość `thickness` w poprzek, długość `totalHeight` wzdłuż, wewnętrzny margines 6.
- Tło: zaokrąglony prostokąt (`corner`) wypełniony materiałem `ultraThinMaterial`, z kryciem
  `stripOpacity` (domyślnie 1.0; dotyczy tylko tła, nie ikon).
- Ramka: 1 pt, `primary` 12%, wewnątrz krawędzi, ten sam promień.
- Pod ikonami, nad tłem: podświetlenie serii celowania (6.8).
- Cały strip (tło + ikony): nasycenie 0 i krycie `inactiveStripOpacity` na nieaktywnym monitorze;
  na aktywnym krycie **0.55, gdy otwarta jest jakaś grupa** (`openGroupID`, pracuje się „w grupie”),
  inaczej 1. Zmiana otwartej grupy animowana easeOut 0.18 s.

Animacje treści: zmiana zestawu/kolejności elementów i zbioru zwiniętego — `layoutAnimation`;
zmiana zaznaczenia — easeOut 0.16 s; zmiana okna fullscreen — easeOut 0.2 s.

Przejścia (pojawianie/znikanie elementów):

- wiersz okna: pojawienie — skala od 0.4 + zanikanie krycia od 0; zniknięcie — skala do 0.6 +
  krycie do 0;
- kafelka grupy: skala 0.6 + krycie (w obie strony);
- kafelka stosu: samo krycie (ikony „przelatują” z wierszy — patrz 6.6);
- pusty slot: skala 0.5 + krycie.

#### 6.2. Odznaka workspace'u

Element o wymiarach `iconSize × iconSize` z marginesem 4 dookoła (razem `rowHeight`, jak wiersz).

- Tekst: numer workspace'u monitora albo „–”, czcionka systemowa zaokrąglona (SF Rounded;
  na GNOME np. Cantarell/Inter bold albo font zaokrąglony), rozmiar `iconSize · 0.55`, grubość
  semibold, wyśrodkowany.
- Tło: zaokrąglony kwadrat `badgeCorner`.
- Kolory zależne od jasności tła ekranu pod odznaką (6.2.1):
  - tło jasne: tekst czarny 85%, wypełnienie białe 55%;
  - tło ciemne: tekst biały 100%, wypełnienie czarne 35%;
  - nieznane (przed pierwszym pomiarem): tekst w kolorze akcentu, wypełnienie akcent 16%.
  - Zmiana kolorów animowana easeOut 0.25 s.
- Podpowiedź (tooltip): „Current workspace”.
- **Wskaźnik nagrywania**: gdy trwa nagrywanie ekranu, zamiast numeru odznaka pokazuje ikonę
  „wypełnione kółko w pierścieniu” (`record.circle.fill`) w kolorze czerwonym, rozmiar
  `iconSize · 0.6`, semibold, **pulsującą** (cykliczne przygasanie/rozjaśnianie krycia), na tle
  zaokrąglonego kwadratu `badgeCorner` wypełnionego czerwienią 16%. Podpowiedź „Recording the
  screen”. Kolory tła ekranu nie mają wtedy wpływu.
- **Klik w odznakę** (bez przeciągnięcia ≥ 4 pt) otwiera tryb celowania „z myszy” (6.2.2), jeśli
  celowanie nie trwa.

##### 6.2.1. Próbkowanie jasności tła (luminancja z histerezą i regułą dwóch próbek)

- Pomiar co **1.5 s** (plus raz przy starcie), dla każdego widocznego stripu osobno, tylko gdy
  `showSpaceBadge`.
- **Okres ciszy**: po każdej aktywacji aplikacji lub zmianie aktywnego workspace'u przez **1.2 s**
  nie mierzy się, a wyniki, które przyjdą w tym czasie, są odrzucane (animacja przełączania
  przesuwa okna pod stripem).
- Mierzony prostokąt: miejsce ikony odznaki na ekranie, `iconSize × iconSize`: wzdłuż od
  `contentStart + padding + 4`, w poprzek wyśrodkowany w pasie `thickness` przy krawędzi ekranu
  (odsunięcie `(thickness − iconSize)/2` od brzegu okna stripu po stronie krawędzi). Nie uwzględnia
  powiększenia w celowaniu.
- Źródło: gdy jest uprawnienie do nagrywania ekranu — zrzut tego prostokąta **z pominięciem
  własnych okien WindowQueue** (czyli tego, co jest pod stripem), zmniejszony do 8×8, uśredniony
  do jednego piksela. Bez uprawnienia lub przy błędzie — **tapeta** tego monitora: miniatura
  (maks. 1024 px dłuższego boku, trzymana w pamięci podręcznej dla ostatniego URL), dopasowana jak
  tapeta „wypełnij” (skala `max(obraz.w/ekran.w, obraz.h/ekran.h)`, wyśrodkowane przycięcie),
  wycięty odpowiadający fragment, uśredniony.
- Luminancja: `0.2126·R + 0.7152·G + 0.0722·B` na składowych 0–1 (wartości zakodowane gamma, bez
  linearyzacji).
- **Histereza**: jeśli bieżący werdykt to „jasne”, nowy werdykt „jasne” ⇔ `L > 0.45`; w przeciwnym
  razie (ciemne lub nieznane) „jasne” ⇔ `L > 0.55`.
- **Reguła dwóch próbek**: pierwszy werdykt (gdy stan nieznany) stosuje się od razu. Później zmiana
  koloru następuje tylko, gdy nowy werdykt różni się od bieżącego **i** jest równy werdyktowi z
  poprzedniej próbki. Werdykt każdej udanej próbki zapamiętuje się jako „poprzedni”. Próbka, która
  nic nie zwróciła, jest ignorowana (nie zmienia też „poprzedniego”).

##### 6.2.2. Celowanie z myszy

Klik w odznakę uruchamia tryb celowania „ze wskaźnika”: bez opóźnienia na ewentualne podwójne
stuknięcie supera — od razu pojawia się przyciemnienie, popup nazwy wycelowanego okna na wszystkich
stripach, obrysy okien oraz **panel akcji** (kafelki z akcjami trybu, przy stripie od strony ekranu,
10 pt od niego, wyśrodkowany na stripie; szczegóły w sekcji o trybie celowania).

#### 6.3. Wiersz okna

Struktura: ikona `iconSize × iconSize` + margines 4 = kwadrat `rowHeight`; w poprzek wyśrodkowany w
stripie (6 pt od brzegów stripu).

- **Ikona**: ikona aplikacji właściciela okna, skalowana z wysoką jakością, **nieprzycinana** (ikony
  macOS mają własny kształt). Gdy aplikacja nie ma ikony: zaokrąglony kwadrat `iconCorner`
  wypełniony `secondary` 30%. Wszystkie okna tej samej aplikacji mają tę samą ikonę (obiekt ikony
  jest cache'owany per proces, by animacje nie „mrugały”).
- **Etykieta tytułu** (`showWindowLabels`, domyślnie włączona): na dole ikony, **na niej**, nie pod
  nią (wiersz nie rośnie). Tekst: 10 pt semibold, biały, jedna linia, obcięcie końca wielokropkiem
  („…”), margines poziomy 2, maks. szerokość = `iconSize`, tło: zaokrąglony prostokąt promień 3,
  czarny 62%, przylegający do tekstu, wyśrodkowany poziomo, dosunięty do dolnej krawędzi ikony.
  Treść etykiety: tytuł okna po obcięciu białych znaków z obu końców; jeśli pusty — nazwa
  aplikacji; w przeciwnym razie tytuł z **usuniętymi wszystkimi znakami z początku, które nie są
  literą ani cyfrą** (znaczniki, kropki, emoji, „•”, „*” itp. rysowane przez aplikacje). Jeśli
  tytuł składa się wyłącznie z takich znaków, etykieta jest pusta.
- **Stany**:
  - zminimalizowane okno: ikona (z etykietą) z kryciem 0.45;
  - okno **przykryte** przez okno fullscreen, gdy przykryte okna nie są zwijane (warunek:
    `focusMaximizedWindow` i zbiór zwinięty pusty — np. `collapseCoveredWindows` wyłączone): ikona z
    kryciem 0.5 i nasyceniem 0.2, tło wiersza **niebieskie 22%** (systemowy niebieski). Minimalizacja
    ma pierwszeństwo przy kryciu (0.45);
  - **zaznaczone** (i nie trwa seria celowania): tło akcent 28%, obramowanie akcent 1.5 pt, promień
    `rowCorner`;
  - **celownik** (okno z celownikiem, gdy wycelowane jest tylko jedno okno): tło pomarańczowe 28%,
    obramowanie pomarańczowe **2.5 pt** — ma pierwszeństwo przed zaznaczeniem, więc nigdy nie myli
    się z oknem z fokusem. Zaznaczony wiersz poza celownikiem nadal ma swoje niebieskie podświetlenie;
  - w trakcie **serii** (wycelowane ≥ 2 okna) wiersze nie mają własnych podświetleń — ani zaznaczenia,
    ani celownika; rysowane jest wspólne podświetlenie serii (6.8).
- **Znak grupy kafelkowej** (okno trzymane w układzie kafelkowania): w lewym górnym rogu wiersza,
  przesunięty o (−1, −1): kapsuła czarna 55% z marginesem 2 poziomo / 1 pionowo, w środku ikona
  „siatka 2×2 wypełnionych kwadratów” (`square.grid.2x2.fill`) i — tylko gdy istnieje więcej niż
  jedna grupa kafelkowa — numer grupy, odstęp 1; czcionka bold rozmiar `max(7, iconSize · 0.3)`,
  kolor akcentu. Podpowiedź „Tiled group N — moving or resizing a window frees it”.
- Podpowiedź wiersza: tytuł okna (albo nazwa aplikacji, gdy tytuł pusty).

Na stripie **nie ma** osobnego wyróżnienia okna w trybie fullscreen poza kafelką stosu (albo
niebieskimi wierszami przykrytych okien).

#### 6.4. Pusty slot

Znacznik miejsca, w którym pojawiłyby się okna pustego workspace'u, na którym jest użytkownik
(nic nie jest wtedy zaznaczone).

- Kwadrat `iconSize × iconSize` (w obu kierunkach), margines 4.
- Wypełnienie: **ukośne kreskowanie** — równoległe linie pod 45°, biegnące od lewego dołu do prawego
  góry, rozstaw 5 pt (w poziomie), grubość 1.2 pt, kolor akcent 45%, przycięte do zaokrąglonego
  kwadratu `iconCorner`.
- Obramowanie: przerywane, akcent 85%, 1.5 pt, kreska 3 / przerwa 3, promień `iconCorner`.
- Podpowiedź „Empty workspace”.
- Gdy na tym workspace pojawi się okno, zajmuje miejsce slotu, a jego wiersz przez 0.8 s jest
  powiązany geometrycznie ze slotem (efekt „matched geometry”) — nowa ikona **wyrasta z miejsca i
  rozmiaru slotu**, a nie pojawia się znikąd.

#### 6.5. Kafelka grupy

Grupa okien to jeden wpis na stripie.

- Kaskada: do 3 pierwszych członków grupy (w kolejności kolejki), rysowanych od tyłu do przodu
  (pierwszy członek na wierzchu). Dla karty o głębokości `d` (0 = przód, `n = min(liczba, 3)`):
  przesunięcie wzdłuż stripu `(d − (n−1)/2) · 5` (kaskada rozchodzi się symetrycznie od środka,
  karty dalsze niżej/prawiej), nasycenie `1 − 0.25·d`, krycie `1 − 0.2·d`, skala `1 − 0.08·d`.
  Każda ikona przycięta do zaokrąglonego kwadratu `iconCorner`. Ramka kaskady ma `iconSize ×
  iconSize` (karty wystają poza nią o przesunięcie).
- **Licznik** w prawym dolnym rogu, przesunięty o (+3, +3): liczba okien grupy, czcionka zaokrąglona
  bold `max(8, iconSize · 0.3)`, biała, margines poziomy 3, na kapsule akcent 95%.
- Margines 4, tło zaokrąglone `rowCorner`: gdy zaznaczone okno jest w tej grupie — akcent 28%;
  inaczej `primary` 8%.
- Obramowanie 1.5 pt: gdy grupa zawiera zaznaczenie — akcent, inaczej `primary` 25%; **przerywane
  (4/3), gdy grupa nie jest otwarta; ciągłe, gdy jest otwarta** (jej okna są w panelu grupy).
- Podpowiedź „Group of N windows”.
- Podczas przeciągania tej kafelki jej miejsce w stripie jest niewidoczne (krycie 0), a rysowana jest
  kopia pływająca (6.9).
- Gdy celownik jest na grupie (grupa wycelowana w całości, ≥ 2 okna), kafelkę przykrywa pomarańczowe
  podświetlenie serii (6.8).

#### 6.6. Kafelka stosu (tryb fullscreen z zwijaniem)

Jeden element zastępujący okno fullscreen i wszystkie okna, które ono przykrywa.

- Kolejność kart: okno fullscreen **zawsze pierwsze** (na wierzchu), potem przykryte w kolejności
  kolejki. Pokazuje się pierwsze 3 („peek”).
- Karta o głębokości `d`, `mid = (liczba_kart − 1)/2`: przesunięcie wzdłuż `(d − mid) · 5`,
  nasycenie `1 − 0.35·d`, krycie `1 − 0.28·d`, skala `1 − 0.1·d` (od środka), przycięcie do
  `iconCorner`. Ramka kaskady wzdłuż ma `iconSize + 5·(liczba_kart − 1)`, w poprzek `iconSize`.
- Każda karta jest geometrycznie powiązana z wierszem swojego okna: przy zwijaniu ikony **przelatują
  z wierszy do kaskady**, przy rozwijaniu z powrotem na swoje miejsca (animacja `layoutAnimation`).
- Licznik „+N” w prawym dolnym rogu, przesunięty (+3, +3): N = liczba okien przykrytych (bez okna
  fullscreen), czcionka zaokrąglona bold `iconSize · 0.34`, biała, margines 3 poziomo / 1 pionowo,
  kapsuła akcent 95%.
- Margines 4; gdy zaznaczone okno jest w tym stosie — tło akcent 28% i obramowanie akcent 1.5 pt
  (promień `rowCorner`), inaczej przezroczyste. Zmiana animowana easeOut 0.16 s.
- Podpowiedź „N window(s) behind the maximized one” („window” bez „s” dla 1).

#### 6.7. Kolejność rysowania warstw jednego stripu

Od dołu: tło z materiałem → podświetlenie serii celowania → elementy (odznaka, wiersze, kafelki) →
ramka stripu → kopia pływająca przeciąganego elementu. Całość (z kopią pływającą) podlega kolejno:
wyszarzeniu/kryciu (6.1), obrotowi strony (4), powiększeniu celowania (8.1).

#### 6.8. Podświetlenie serii celowania

Gdy wycelowane są ≥ 2 okna (seria, przypięte, cała grupa): wycelowane okna grupuje się w „biegi”
sąsiednich pozycji w widocznym wycinku kolejki. Dla każdego biegu jeden zaokrąglony prostokąt
(`rowCorner`): wypełnienie pomarańczowe 28%, obramowanie pomarańczowe 2.5 pt; w poprzek szerokość
`rowHeight`, wyśrodkowany; wzdłuż od początku elementu pierwszego okna biegu do końca elementu
(`+ rowHeight`) ostatniego. Pozycje z zatwierdzonego układu (nie z podglądu przeciągania). Okna w
jednej kafelce (grupa) dają ten sam element, więc bieg grupy przykrywa kafelkę na długości
`rowHeight`. Zmiana zbioru wycelowanych animowana sprężyną 0.22/0.85.

#### 6.9. Kopia pływająca (przeciąganie)

Przeciągany element (wiersz, kafelka stosu lub kafelka grupy) jest rysowany nad stripem, **w
kursorze**: skala 1.12, cień czarny 30% promień 6, wyśrodkowany w poprzek stripu, wzdłuż w
pozycji `początekElementu + przesunięcieKursora`. Jego miejsce w liście zostaje zachowane (krycie
0), a pozostałe elementy rozsuwają się, pokazując, gdzie wyląduje (6.10.3).

### 7. Panel grupy („drugi strip”)

#### 7.1. Kiedy jest widoczny

Przeliczany przy każdej zmianie modelu. Pokazuje okna grupy `G`, gdzie `G` to (w tej kolejności):

1. **grupa otwarta** — grupa zaznaczonego okna (wybranie okna w grupie „wchodzi” do niej; wybranie
   okna spoza — wychodzi), albo
2. w trybie celowania: grupa, na której jest celownik (wycelowana w całości, „podgląd” — żeby było
   widać, co da wejście do niej), albo grupa, w którą celownik wszedł.

Panel jest ukryty, gdy nie ma takiej grupy, gdy grupa ma ≤ 1 okno, oraz w trybie niewidzialnym
poza celowaniem. Najechanie na kafelkę grupy **nie otwiera** panelu (tylko ją nazywa, 10.4);
otwiera go klik.

Stan „podgląd” (`peek`) = brak grupy otwartej (panel pokazany tylko dlatego, że celownik jest na
grupie).

#### 7.2. Położenie i rozmiar

- Wymiary treści wzdłuż: `L(n) = 2·padding + n·rowHeight + (n−1)·spacing`, gdzie `n` = liczba
  wierszy panelu (okna przykryte + okno fullscreen w tej grupie liczą się jako jeden wiersz — ich
  kaskada).
- `scale` = `aimingScale`, gdy celownik jest **wewnątrz** tej grupy, inaczej 1.
- Okno panelu: w poprzek `thickness · max(1, aimingScale)` (zapas na powiększenie), wzdłuż
  `L(n) · scale`.
- Panel **kontynuuje strip w tej samej linii** (ten sam pas przy krawędzi ekranu), oddzielony
  przerwą **8 pt**: dla stripu pionowego pod nim (w dół — „za” stripem, jak kolejka), dla poziomego
  za nim (w prawo). **Przy wyrównaniu `end` — przed stripem** (nad nim / na lewo od niego).
  Jeśli nie mieści się w obszarze roboczym monitora, na którym jest strip, idzie na drugą stronę;
  na koniec jest docinany do obszaru roboczego. W poprzek: dla left `x` = lewy brzeg stripu, dla
  right prawy brzeg okna panelu = prawy brzeg stripu, dla top górny brzeg = górny brzeg stripu,
  dla bottom dolny = dolny.
- Odniesieniem jest prostokąt **treści** stripu (nie jego okna), na monitorze stripu-kotwicy (10.6),
  z uwzględnieniem przesunięcia centrowania. Gdy stripu nie ma, panel jest na środku obszaru
  roboczego monitora głównego.
- **Miejsce dla pary**: główny strip dostaje `companionLength = L(n) · (scale celowania w grupie
  ? aimingScale : 1) + 8`, a przy wyrównaniu `center` przesuwa się o połowę tej wartości w stronę
  początku (animacja easeOut 0.32 s), więc strip + przerwa + panel są wyśrodkowane jako całość.
  Ta wartość dotyczy wszystkich stripów (na wszystkich monitorach), choć panel jest tylko przy
  jednym. Gdy panel znika, `companionLength = 0`.
- Wewnątrz okna panelu treść jest przyklejona do krawędzi ekranu (left → do lewej itd.) i
  powiększana od tej krawędzi (punkt zaczepienia: środek krawędzi po stronie ekranu).

#### 7.3. Wygląd

Ten sam materiał i rozmiar co strip — czyta się jako przedłużenie stripu, a nie menu:

- tło: `ultraThinMaterial` z kryciem `stripOpacity`, promień `corner`, margines 6, grubość
  `thickness`;
- ramka: w podglądzie `primary` 12%, 1 pt; gdy grupa otwarta (lub celownik wszedł) — akcent 55%,
  1.5 pt;
- brak odznaki workspace'u, brak etykiet tytułów, brak przyciemnienia zminimalizowanych okien;
- wiersze w kolejności grupy (kolejność kolejki), każdy jak wiersz stripu: ikona `iconSize`,
  margines 4, podświetlenie (`rowCorner`): celownik (gdy nie seria) — pomarańczowe 28% +
  obramowanie pomarańczowe; zaznaczone (gdy nie celownik i nie seria) — akcent 28% + obramowanie
  akcent; grubość obramowania 2.5 pt dla okna z celownikiem, 1.5 pt dla pozostałych; znak grupy
  kafelkowej jak na stripie (numer, gdy istnieje > 1 grupa kafelkowa); podpowiedź = tytuł;
- okna przykryte przez okno fullscreen z tej grupy (przy `focusMaximizedWindow` i
  `collapseCoveredWindows`) razem z tym oknem fullscreen tworzą **jedną kaskadę na końcu listy**
  (nie w miejscu kolejki): jak kafelka stosu (6.6: okno fullscreen na wierzchu, do 3 kart, te same
  współczynniki 0.35/0.28/0.1 i krok 5), ale ramka kaskady ma `iconSize × iconSize`; licznik „+N”
  czcionką `max(8, iconSize · 0.3)`; podświetlenie akcent, gdy zawiera zaznaczenie; podpowiedź
  „N window(s) behind the fullscreen one”;
- seria celowania wewnątrz grupy: pomarańczowe prostokąty biegów jak w 6.8, pozycje liczone
  jednolicie: początek `6 + indeks · (rowHeight + 6)`, długość `k·rowHeight + (k−1)·6`;
- powiększenie `scale` animowane sprężyną 0.25/0.8.

#### 7.4. Animacje pokazania, zmiany i schowania

- **Otwarcie**: okno pojawia się z kryciem 0 w ramce „złożonej” — 25% docelowej długości, po
  stronie przylegającej do głównego stripu (panel pod stripem: górne 25%; nad stripem: dolne 25%;
  za stripem poziomym: lewe 25%; przed nim: prawe 25%) — i przez 0.32 s (easeOut) animuje krycie do 1
  i ramkę do docelowej. Wygląda to jak rozwijanie się stripu z końca głównego.
- **Zmiana** (inna grupa, inna liczba okien, inny `scale`) przy widocznym panelu: animacja ramki
  do nowej (0.32 s easeOut), bez ponownego wygaszania; jeśli panel był w trakcie znikania — wraca
  (krycie → 1). Animacja nie jest restartowana, gdy cel się nie zmienił.
- **Schowanie**: 0.192 s (0.32 · 0.6) easeIn: krycie → 0 i ramka → złożona (25% po stronie
  stripu), potem okno jest chowane. Pokazanie w trakcie chowania przechwytuje panel i przywraca go.
- Równocześnie główny strip przesuwa się (przy `center`) z tym samym czasem 0.32 s.

#### 7.5. Interakcje w panelu grupy

- **Klik** (wciśnięcie i puszczenie w wierszu, bez progu ruchu) wybiera okno i daje mu fokus (bez
  przenoszenia kursora). Kaskada nie reaguje na klik.
- **Najechanie**: wiersz pod wskaźnikiem → przypięty popup nazwy tego okna, przy tym wierszu w
  panelu (z miniaturą, 11); zejście → koniec przytrzymania popupu. Wiersz pod wskaźnikiem liczony
  jednolicie: `indeks = floor((along − 6) / (rowHeight + 6))` po wierszach bez kaskady (bez
  uwzględnienia powiększenia).
- **Środkowy klik** na wierszu zamyka to okno.
- Kółko myszy nie jest obsługiwane w panelu grupy.

### 8. Tryb celowania — elementy wizualne

#### 8.1. Powiększenie stripu (`aimingScale`)

W trybie celowania strip, **na którym jest celownik**, jest powiększony o `aimingScale` (domyślnie
1.2) — całość (tło, ramka, ikony) jednolicie, od punktu zaczepienia przy krawędzi ekranu w miejscu
wyrównania (4), czyli rośnie do wnętrza ekranu i od końca, do którego jest wyrównany. Animacja
sprężyną 0.25/0.8. Gdy celownik wszedł do grupy, główny strip wraca do skali 1, a powiększa się panel
grupy (7.2). Powiększenie dotyczy wszystkich stripów (na wszystkich monitorach) jednocześnie.
Hit-testing najechania nie zna skali, dlatego najechanie jest w celowaniu wyłączone (10.4); kliknięcia
i przeciąganie działają we współrzędnych nieskalowanych (tak jak SwiftUI przelicza gest przed
transformacją) — nowa implementacja powinna przeliczać punkt odwrotną transformacją skali.

#### 8.2. Przyciemnienie ekranów (`DimOverlay`)

- Na **każdym** monitorze okno na całą ramkę monitora (także pod paskiem menu), jednolicie czarne,
  ignorujące mysz, poziom tuż pod stripem.
- Pojawienie: krycie 0 → `aimingDimOpacity` (domyślnie 0.45) w 0.18 s; zniknięcie: → 0 w 0.18 s,
  potem schowanie. Przy `aimingDimOpacity = 0` nic się nie pokazuje. Każde pokazanie najpierw
  usuwa poprzednie bez animacji.
- Pokazywane, gdy tryb celowania się „ujawnia”: natychmiast przy starcie z myszy lub gdy do
  podwójnego stuknięcia supera nie jest przypisana akcja; w przeciwnym razie po 0.4 s (okno na
  podwójne stuknięcie), albo od razu przy pierwszym ruchu celownika. Chowane przy wyjściu z trybu.
  (Ta sama nakładka służy wyszukiwarce.)

#### 8.3. Obrysy wycelowanych okien na ekranie (`AimHighlightOverlay`)

- Dla każdego wycelowanego okna, które jest **na bieżącym workspace** i ma ramkę większą niż 20×20:
  osobne przezroczyste okno ignorujące mysz dokładnie w ramce tego okna, a w nim zaokrąglony
  prostokąt (promień 10) obrysowany linią **3 pt**, wpisany do środka ramki (odsunięty o 1.5 pt, więc
  okno przy krawędzi ekranu ma obrys w całości na ekranie). **Tylko obrys, bez wypełnienia.**
- Kolor: pomarańczowy; krycie 1 dla okna z celownikiem („najjaśniejszy”), 0.65 dla pozostałych okien
  serii.
- Nowy obrys pojawia się z krycia 0 do 1 w 0.12 s; obrysy okien, które przestały być wycelowane,
  znikają natychmiast; przy wyjściu z trybu wszystkie znikają natychmiast.
- Aktualizowane przy każdej zmianie celu (ruch, rozszerzenie, wejście do grupy). Ramki nie są
  śledzone na żywo, jeśli okno się rusza bez zmiany celu.
- Nad przyciemnieniem, więc wycelowane okna wyglądają na „wyjęte” z przyciemnionego ekranu.

#### 8.4. Błysk fokusu (`flashFocusedWindow`)

Po każdym nadaniu fokusu oknu przez WindowQueue (klik, zatwierdzenie celowania, cykl, przełączenie
workspace'u itd.; **nie** przy focus-follows-mouse, które nadaje fokus inną drogą), jeśli `flashFocusedWindow` (domyślnie tak) i `flashFocusedWindowDuration > 0`
(domyślnie **0.15 s**):

- obrys jak w 8.3 (3 pt, promień 10, wewnątrz ramki okna), ale w kolorze **akcentu**, krycie 1;
  jedno współdzielone okno obrysu (nowy błysk przenosi poprzedni);
- pojawia się **od razu** z kryciem 1, trzyma się `flashFocusedWindowDuration`, potem gaśnie do 0
  przez **0.5 s** (easeIn) i znika;
- jeśli okno jest na innym workspace, błysk czeka, aż ten workspace będzie widoczny i okno będzie
  miało ramkę: sprawdzanie co 0.1 s, maks. 20 prób (2 s), potem rezygnacja;
- nie w trybie celowania; okno musi mieć ramkę > 20×20.

#### 8.5. Popup w trybie celowania

Patrz 11.3: przy jednym wycelowanym oknie popup z jego nazwą (i miniaturą) jest przypięty przy
ikonie **na każdym stripie**; przy serii ≥ 2 lub celowaniu w grupę popup znika (seria ma menu
układów przy stripie).

### 9. Podgląd komórki kafelkowania (`TilePreviewOverlay`)

Gdy przeciąga się (≥ 4 pt) ikonę **pojedynczego okna należącego do grupy kafelkowej**, na ekranie
pokazywana jest komórka, którą to okno dostanie, gdy zostanie upuszczone w bieżącym miejscu
(grupa układa się w kolejności kolejki, więc upuszczenie decyduje o miejscu):

- kolejka po hipotetycznym upuszczeniu → pozycja okna wśród członków grupy → prostokąt tej pozycji
  w układzie grupy (układ o nazwie zapisanej w grupie, albo pierwszy dostępny dla tej liczby okien)
  → przeliczony na obszar kafelkowania (pomniejszony o `tileOuterGap`) i pomniejszony o połowę
  `tileInnerGap` z każdej strony (szczegóły układów — sekcja o kafelkowaniu);
- okno nakładki w tej ramce, ignorujące mysz: zaokrąglony prostokąt wpisany z odstępem 2 pt,
  promień 10, wypełnienie akcent 18%, obrys akcent 85% o grubości 3 pt;
- pierwsze pojawienie: krycie 0 → 1 w 0.1 s; kolejne zmiany miejsca — natychmiastowe przestawienie;
  schowanie — natychmiast (upuszczenie, powrót poniżej progu, okno nie w grupie kafelkowej, pozycja
  poza układem).

### 10. Interakcje myszą na stripie

Cały strip ma **jeden** rozpoznawacz gestu przeciągania z minimalnym dystansem 0 (wciśnięcie lewego
przycisku zaczyna „gest”; klik = gest bez ruchu). Pozycje mierzone są wzdłuż stripu w jego
nieprzesuniętym układzie współrzędnych (od początku treści, wraz z marginesem 6). Próg ruchu:
**4 pt** wzdłuż stripu.

#### 10.1. Klik (lewy)

Wciśnięcie na elemencie okna (wiersz, kafelka) i puszczenie, jeśli `|przesunięcie| < 4` i docelowa
pozycja jest ta sama co wyjściowa:

- **wiersz**: wybór okna — jeśli trwa celowanie **i wciśnięty jest Shift**: przełączenie okna w
  celu (dodanie do wycelowanych / usunięcie), bez wychodzenia z trybu. W pozostałych przypadkach:
  zakończenie celowania bez zatwierdzania (jeśli trwało), jeśli okno jest przykryte przez okno
  fullscreen — najpierw wyjście z trybu fullscreen (kolejka wraca do normy), potem zaznaczenie okna
  (bez popupu-ogłoszenia) i fokus **bez przenoszenia kursora** (+ błysk fokusu);
- **kafelka stosu**: jak klik w wiersz okna **fullscreen** (karta na wierzchu), nie pierwszego okna
  stosu;
- **kafelka grupy**: jak klik w wiersz jej pierwszego członka (w kolejności kolejki) — wybór okna w
  grupie otwiera grupę (panel grupy pokazuje się, strip przygasa do 0.55);
- **odznaka**: celowanie z myszy (6.2.2), o ile celowanie nie trwa;
- pusty slot, puste miejsce: nic.

Kliknięcie gdziekolwiek **poza** oknami WindowQueue (lewy, prawy lub inny przycisk) w trakcie
celowania kończy celowanie bez zatwierdzania.

#### 10.2. Przytrzymanie → popup

W chwili wciśnięcia na wierszu (nie kafelce) pokazuje się **przypięty** popup nazwy tego okna (z
miniaturą, jeśli włączona) — trzymany, dopóki przycisk jest wciśnięty, i podąża za ikoną. Gdy tylko
przesunięcie osiągnie 4 pt, popup znika **natychmiast** (użytkownik patrzy, gdzie ikona wyląduje, a
nie na nazwę). Po puszczeniu (klik) — koniec przytrzymania: popup znika po `min(toastDuration, 0.6)`
(domyślnie 0.6 s), z wygaszeniem 0.18 s.

#### 10.3. Przeciąganie i upuszczanie (zmiana kolejności)

- Start: przy pierwszym zdarzeniu gestu pozycja startowa musi trafić w okno (10 — hit-testing z 5,
  na zatwierdzonym układzie); inaczej gest nic nie przeciąga (wciśnięcie na odznace/slocie daje
  najwyżej klik z 10.1). Trafienie w kafelkę stosu → przeciąga się **cały stos** (okno fullscreen
  i wszystkie przykryte, jako blok); w kafelkę grupy → **całą grupę** jako blok; w wiersz → jedno
  okno.
- Po przekroczeniu 4 pt gest uznaje się za przeciąganie (zostaje tak do końca, nawet jeśli kursor
  wróci).
- Cel: `najbliższe okno` (5) dla pozycji `start + przesunięcie`, liczone zawsze na **zatwierdzonym**
  układzie (nie na podglądzie — inaczej cel oscylowałby, gdy podgląd przestawia się pod kursorem).
  Kursor może wyjechać poza strip — cel to wtedy pierwsze/ostatnie okno.
- Podgląd: strip rysuje kolejkę z przeciąganym oknem przeniesionym na pozycję celu
  (`layoutAnimation`), jego wiersz (niewidoczny) zajmuje to miejsce, a kopia pływająca jest pod
  kursorem (6.9). Dla bloku (stos/grupa): blok wyjęty z kolejki i wstawiony w miejscu
  `cel − (liczba członków bloku przed celem) + (1, jeśli cel > pozycji startowej)`, min. 0 — czyli
  przed oknem, na które się go upuszcza, gdy niesie się w górę/w lewo, a za nim, gdy w dół/w prawo.
- Pojedyncze okno z grupy kafelkowej: podgląd komórki (9).
- Upuszczenie pojedynczego okna (ruch ≥ 4 lub zmiana celu): okno przenoszone w kolejce na pozycję
  celu (w widocznym wycinku); następnie kopia pływająca **„osiada”** — animuje się sprężyną
  0.22/0.9 od kursora do miejsca nowego wiersza, a po **0.22 s** gest się kończy i wiersz pod spodem
  (który cały czas trzymał to miejsce) staje się widoczny. Popup: znika natychmiast (10.2).
- Upuszczenie bloku: blok przenoszony na wyliczone miejsce; bez animacji osiadania (kafelka pojawia
  się w nowym miejscu z animacją układu).
- Koniec gestu zawsze: ukrycie podglądu komórki, wyzerowanie stanu, koniec przytrzymania popupu.
- W trakcie przeciągania najechanie jest wyłączone (popup należy do przeciągania).

#### 10.4. Najechanie (hover)

Wskaźnik jest śledzony zawsze (także gdy panel nie jest oknem aktywnym), na całym oknie stripu.
Wyłączone w trakcie przeciągania i w trybie celowania. Reguły, przy każdym ruchu wskaźnika:

- **kafelka stosu** pod wskaźnikiem (tylko raz przy wejściu): przypięty popup przy **pierwszym oknie
  stosu w kolejności kolejki**: tytuł „+N window(s) hidden” — uwaga: tu N = liczba **wszystkich**
  okien w stosie, łącznie z oknem fullscreen (inaczej niż licznik „+N” na kafelce) — i podtytuł
  „‹skrót fullscreen› restores the maximized window and brings them back”, gdzie ‹skrót› to aktualny
  skrót akcji „Fullscreen window (again to restore)” w zapisie skrótu (np. „⌥F”);
- **kafelka grupy** (tylko przy zmianie okna pod wskaźnikiem): przypięty popup „Group N — K windows”
  / „Click to open it in a strip of its own”, przy wierszu jej pierwszego członka (gdy ten członek
  jest akurat widoczny w panelu grupy — przy jego wierszu w panelu);
- **wiersz okna** (tylko przy zmianie okna pod wskaźnikiem): przypięty popup z nazwą okna **od
  razu**, bez opóźnienia (z miniaturą, 11.1);
- wskaźnik nad niczym (odznaka, slot, pusta część okna, wyjście z okna): koniec przytrzymania —
  popup gaśnie po `min(toastDuration, 0.6)`.

Uwaga o zachowaniu oryginału: każdy ruch wskaźnika poza kafelką grupy wywołuje „koniec przytrzymania
nazwy grupy”, co w praktyce planuje zgaszenie popupu po ≤ 0.6 s także wtedy, gdy wskaźnik porusza
się w obrębie tego samego wiersza (popup zostaje, dopóki wskaźnik stoi). Zalecane zachowanie w nowej
implementacji: popup trzyma się, dopóki wskaźnik jest nad tym samym elementem.

Najechanie **nie** zmienia zaznaczenia ani fokusu. Wyjście wskaźnika z okna stripu zeruje „strip pod
wskaźnikiem” (chyba że trwa przeciąganie).

#### 10.5. Kółko myszy

- Kierunek: z dwóch osi bierze się tę o większej wartości bezwzględnej (poziome przewijanie też
  działa); przewinięcie „w dół/w prawo” (tak, jak przewija się dokument dalej) = krok do przodu w
  kolejce (następne okno), „w górę/w lewo” = wstecz. Ustawienie naturalnego przewijania systemu jest
  respektowane (bierze się delty już po jego zastosowaniu).
- **Przewijanie precyzyjne** (touchpad, gładkie kółko, delty w punktach): delty się **sumują**;
  liczba kroków = część całkowita `suma / rowHeight` (w stronę zera), odejmowana od sumy —
  jeden krok na każde przesunięcie o wysokość wiersza, więc zaznaczenie „nadąża” za wyglądem stripu.
- **Przewijanie liniowe** (klasyczne kółko z ząbkami): każde zdarzenie o niezerowej delcie = dokładnie
  jeden krok; akumulator zerowany.
- W trybie celowania kroki przesuwają celownik (jak klawisze cyklu), niczego nie fokusując.
- Poza celowaniem: każdy krok to cykl zaznaczenia o tyle pozycji (z pominięciem okien przykrytych,
  z zawijaniem) — zaznaczenie zmienia się od razu i pokazuje się **zwykły** (nieprzypięty) popup
  nazwy przy ikonie; **fokus** dostaje zaznaczone okno dopiero, gdy przewijanie ustanie na
  `scrollFocusDelay` (domyślnie **0.5 s**; każdy krok restartuje odliczanie), bez przenoszenia
  kursora.

#### 10.6. Środkowy przycisk

Środkowy klik nad elementem okna zamyka to okno (dla kafelki stosu/grupy — pierwsze okno tej kafelki
w kolejności kolejki). Nad odznaką/slotem/pustym miejscem — nic. To samo w panelu grupy (7.5).

#### 10.7. Strip-kotwica

„Strip pod wskaźnikiem” to ostatni strip, nad którym poruszał się wskaźnik (lub na którym zaczęto
przeciąganie). Kotwica popupu i panelu grupy: strip pod wskaźnikiem, jeśli widoczny; inaczej widoczny,
aktywny strip na monitorze aktywnym; inaczej dowolny aktywny; inaczej dowolny widoczny.

### 11. Popup nazwy (toast)

#### 11.1. Wygląd

- Kolumna, wyrównanie do lewej, odstęp 6:
  - tytuł: 13 pt semibold, jedna linia; podtytuł: 11 pt, kolor `secondary`, jedna linia (odstęp
    między nimi 2). Obcinanie końca wielokropkiem przy braku miejsca;
  - opcjonalnie **miniatura okna** pod tekstem: obraz okna dopasowany proporcjonalnie w
    maks. **420 × 315** (dłuższy bok miniatury ≤ 420), zaokrąglenie 8, obramowanie 1 pt `primary` 15%.
- Margines 12 poziomo / 8 pionowo; tło `ultraThinMaterial` z zaokrągleniem 10; ramka 1 pt
  `primary` 12%; cień okna.
- Szerokość okna popupu: szerokość naturalna ograniczona do **[140, 480]**; wysokość naturalna.
- Dla okna: tytuł = tytuł okna (albo nazwa aplikacji, gdy tytuł pusty), podtytuł = nazwa aplikacji.
- Miniatura tylko gdy `showWindowPreview` (domyślnie tak) **i popup jest przypięty** (najechanie,
  przytrzymanie, celowanie) — przy cyklu z klawiatury okno i tak wychodzi na wierzch. Wymaga
  uprawnienia do nagrywania ekranu i okna na bieżącym workspace, większego niż 40×40; obraz
  zmniejszany tak, by dłuższy bok ≤ 420, trzymany w cache 2 s, maks. 8 obrazów. Brak obrazu → sam tekst.
- `toastEnabled = false` wyłącza **wszystkie** popupy (także najechania i celowania).

#### 11.2. Położenie przy ikonie

Kotwica = prostokąt wiersza okna na ekranie: w poprzek całe okno stripu (łącznie z zapasem na
powiększenie), wzdłuż `rowHeight` wyśrodkowane na środku elementu okna (dla okna w kafelce — środek
kafelki), z przesunięciem o bieżące przeciągnięcie, jeśli to okno jest przeciągane. W trybie
celowania (celownik na głównym stripie) pozycja wzdłuż i długość przeliczane skalą:
`along' = a + (along − a) · aimingScale`, `a = contentStart + totalHeight · fraction`. Gdy okno
jest widoczne jako wiersz w **panelu grupy**, kotwicą jest ten wiersz panelu (z jego skalą), a nie
kafelka grupy w stripie.

Odstęp 8 pt; popup po **stronie ekranu** od kotwicy:

- left: `x = kotwica.maxX + 8`, pionowo wyśrodkowany na kotwicy;
- right: `x = kotwica.minX − 8 − szerokość`, pionowo wyśrodkowany;
- top: `y` pod kotwicą (odstęp 8), poziomo wyśrodkowany;
- bottom: nad kotwicą (odstęp 8), poziomo wyśrodkowany.

Współrzędna wzdłuż jest docinana do obszaru roboczego monitora, na którym jest kotwica, z marginesem
8 (popup przy końcu stripu nie wychodzi za ekran). Bez kotwicy: przy lewej krawędzi obszaru roboczego
monitora aktywnego (x = minX + 8), wyśrodkowany pionowo.

#### 11.3. Na każdym stripie (celowanie)

Przy celowaniu w jedno okno popup jest pokazywany **przy ikonie tego okna na każdym widocznym
stripie**: najpierw strip-kotwica, potem pozostałe posortowane po lewej krawędzi ich monitora. Każdy
strip ma swój dymek (dymki są tworzone według potrzeby i używane ponownie; zbędne są chowane). Wyjątek:
okno pokazane w panelu grupy ma popup tylko przy swoim wierszu w panelu.

#### 11.4. Wariant wyśrodkowany

Dla komunikatów niedotyczących jednego okna (np. „Grouped 3 windows as group 2”, „Aim at two or more
windows to group them” / „Shift-click or Shift with the arrows”, „Nothing to ungroup” / …): ten sam
wygląd bez miniatury, szerokość [140, 480], **na środku obszaru roboczego monitora aktywnego**, tylko
jeden dymek (pozostałe chowane), znika po `max(toastDuration, 1.2)` s.

#### 11.5. Czas życia

- Pojawienie nowego: krycie 0 → 1 w **0.12 s**. Jeśli dymek jest już widoczny (np. przeciąganie,
  kolejne kroki cyklu) — tylko przestawienie ramki i powrót krycia do 1 w **0.08 s** (także gdy był
  w trakcie gaśnięcia).
- **Zwykły** (ogłoszenie przy cyklu z klawiatury, kółku, akcjach): gaśnie po `toastDuration`
  (domyślnie **1.0 s**).
- **Przypięty** (najechanie, przytrzymanie, celowanie): bez limitu czasu; „koniec przytrzymania”
  planuje zgaszenie po `min(toastDuration, 0.6)`.
- **Natychmiastowe schowanie** (bez animacji): gdy przeciąganie przekroczy próg; gdy celowanie
  przechodzi w serię ≥ 2 lub na grupę; po podwójnym stuknięciu supera przed wykonaniem jego akcji.
- Gaśnięcie: krycie → 0 w **0.18 s**, potem schowanie — chyba że w międzyczasie pokazano nowy
  popup (licznik pokoleń), wtedy zostaje.
- Wyjście z celowania: koniec przytrzymania (≤ 0.6 s).

### 12. Wiele monitorów — podsumowanie

- **Strip**: po jednym na monitor wg trybu (3.1); każdy liczy własny obszar roboczy, numer
  workspace'u, kolory odznaki (osobne próbkowanie tła) i ukrywanie na pełnym ekranie; wszystkie
  pokazują tę samą kolejkę. Monitor aktywny = z oknem z fokusem; pozostałe w trybie
  `highlightActiveScreen` szare i przygaszone (poza celowaniem). Zmiana konfiguracji monitorów
  przelicza wszystko; stripy monitorów, które zniknęły, są usuwane.
- **Rezerwacja miejsca**: na macOS tylko monitor główny + przycinanie po fakcie na pozostałych; na
  GNOME strut na każdym monitorze ze stripem.
- **Powiększenie celowania**: wszystkie stripy naraz (jeśli celownik nie jest w grupie).
- **Przyciemnienie**: wszystkie monitory.
- **Obrysy celowania**: okna na bieżącym workspace (na macOS workspace aktywnego monitora).
- **Błysk fokusu**: na oknie, gdziekolwiek jest, po dojechaniu do jego workspace'u.
- **Popup**: przy stripie-kotwicy (10.7), a w celowaniu przy każdym stripie; docinany do monitora
  kotwicy. Wariant wyśrodkowany — monitor aktywny.
- **Panel grupy**: jeden, przy stripie-kotwicy, docinany do monitora tego stripu; przesunięcie
  centrowania dotyczy jednak wszystkich stripów.
- **Panel akcji** (celowanie z myszy): przy stripie-kotwicy.
- **Podgląd komórki**: na obszarze kafelkowania (sekcja o kafelkowaniu).

### 13. Ustawienia czytane przez interfejs (wartości domyślne)

| Ustawienie | Domyślnie | Wpływ |
|---|---|---|
| `stripDisplay` | `highlightActiveScreen` | 3.1 |
| `inactiveStripOpacity` | 0.55 | krycie stripu na nieaktywnym monitorze |
| `stripSide` | `left` | 3.4 |
| `stripAlignment` | `center` | 3.4, 7.2 |
| `stripMargin` | 4 | 3.4, 3.5, 3.7 |
| `iconSize` | 34 | wszystkie metryki (2) |
| `showSpaceBadge` | true | odznaka i próbkowanie tła |
| `stripOpacity` | 1.0 | krycie tła stripu i panelu grupy |
| `hideInFullscreen` | true | 3.2 |
| `invisibleStrip` | false | 4 |
| `aimingScale` | 1.2 | 8.1, grubość okna stripu, 7.2 |
| `aimingDimOpacity` | 0.45 | 8.2 (0 = brak) |
| `scrollFocusDelay` | 0.5 s | 10.5 |
| `toastEnabled` | true | 11 |
| `toastDuration` | 1.0 s | 11.5 |
| `showWindowPreview` | true | miniatura w popupie |
| `showWindowLabels` | true | etykieta tytułu na ikonie |
| `focusMaximizedWindow` | true | przykryte okna / kafelka stosu |
| `collapseCoveredWindows` | true | kafelka stosu zamiast niebieskich wierszy |
| `flashFocusedWindow` | true | 8.4 |
| `flashFocusedWindowDuration` | 0.15 s | 8.4 |
| `reserveScreenSpace` | true | 3.7 |
| `trimWindowsOutsideReservation` | true | 3.7 |
| `tileOuterGap` / `tileInnerGap` | 0 / 4 | 9 |
| `stripWidth` | 36 | nieużywane (stary zapis), grubość wynika z `iconSize` |

---

## Akcje, skróty i tryb celowania

Ten rozdział opisuje wszystko, co użytkownik może *zrobić*: każdą akcję (`HotkeyAction`), stuknięcie
klawisza super, tryb celowania z jego klawiszami, kafelkami akcji i menu układów, kafelkowanie okien,
fullscreen/maksymalizację/minimalizację/zamykanie, przenoszenie na workspace, wyszukiwarkę okien,
launcher, przegląd workspace'ów, niewidzialny strip, nagrywanie ekranu, zdjęcia okien, mignięcie
fokusu, menu w pasku stanu oraz *dosłowne* teksty wszystkich popupów. Całością steruje jeden
kontroler aplikacji (w kodzie `AppDelegate`); opisane tu reguły to jego logika.

Konwencje zapisu skrótów: `⌥` = super (domyślnie Option; na GNOME odpowiednik to np. Super/Alt —
patrz rozdział o GNOME), `⇧` Shift, `⌃` Control, `⌘` Command. Nazwa klawisza w skrócie to litera
według bieżącego układu klawiatury (wielka), a klawisze specjalne: `Space`, `↩` Return, `⎋` Escape,
`⇥` Tab, `⌫` Backspace, `↖` Home, `↘` End, strzałki `←→↑↓`, `F1…F12`. Kolejność symboli
modyfikatorów w wyświetlanym skrócie jest zawsze `⌃⌥⇧⌘` + klawisz (np. `⌥⇧W`). Tak właśnie skróty są
wstawiane w teksty popupów (`displayString`).

Klawisze w skrótach identyfikowane są **fizycznym kodem klawisza** (pozycją), nie znakiem. „`[`”
oznacza klawisz leżący na pozycji `[` układu US, niezależnie od układu.

---

### 1. Drogi, którymi użytkownik wywołuje akcje

1. **Globalne skróty** — każda `HotkeyAction` ma jedną kombinację (modyfikatory + klawisz),
   rejestrowaną systemowo tak, by działała w każdej aplikacji i była przez nią *konsumowana* (nie
   dociera do aplikacji na wierzchu). Kombinacja musi zawierać co najmniej jeden modyfikator.
   Rejestracja odbywa się ponownie tylko wtedy, gdy któryś skrót faktycznie się zmienił (każda
   inna zmiana ustawień nie może powodować wyrejestrowania nawet na chwilę — inaczej wciśnięty w tej
   chwili `⌥S` wpisałby „ś” w aplikacji). Skrót, którego nie udało się zarejestrować (zajęty),
   trafia na listę błędów pokazywaną w ustawieniach.
2. **Stuknięcie klawisza super** (sam modyfikator, bez innego klawisza) — otwiera/zatwierdza tryb
   celowania; podwójne stuknięcie może wywołać wybraną akcję (§4).
3. **Klawisze w trybie celowania** — tryb przejmuje całą klawiaturę; tam działają klawisze
   nawigacji oraz każdy skrót również *bez* klawisza super (§5.6).
4. **Mysz na stripie** — klik ikony, Shift+klik w trybie celowania, klik środkowym przyciskiem
   (zamyka okno), kółko (§16), klik w odznakę workspace'u (otwiera tryb celowania), przeciąganie.
5. **Kafelki akcji** obok stripu, gdy tryb celowania otwarto myszą (§5.8), i **menu układów** (§5.9).
6. **Menu w pasku stanu** (§18).
7. (Tylko do testów) polecenia debugowe — patrz §21.

Każde wykonanie akcji (niezależnie od źródła: skrót, klawisz w trybie celowania, kafelek, podwójne
stuknięcie) zaczyna się od **anulowania trwającego stuknięcia supera** (`modifierTaps.cancel()`),
bo klawisz skrótu zostaje skonsumowany i detektor stuknięć by go nie zobaczył.

---

### 2. Tabela wszystkich akcji (`HotkeyAction`)

Domyślne skróty podane dla super = `⌥`. Przy innym superze `⌥` zastępuje się wybraną kombinacją
(np. `⌃⌥`). Zmiana supera w ustawieniach **nadpisuje wszystkie skróty wartościami domyślnymi** dla
nowego supera. Domyślne skróty celowo nie używają liter A, C, E, L, N, O, S, X, Z (Option+te litery
dają ą ć ę ł ń ó ś ź ż w układzie „Polski Pro”).

Kolumna „W celowaniu” opisuje wywołanie akcji, gdy tryb celowania jest otwarty (z klawiatury — pełną
kombinacją lub gołym klawiszem, patrz §5.6 — albo kafelkiem). „Kilka” = co się dzieje, gdy
wycelowane są ≥2 okna.

| Akcja (`id`) | Tytuł w ustawieniach | Domyślnie | Poza celowaniem | W celowaniu (1 okno) | Kilka wycelowanych | Popup |
|---|---|---|---|---|---|---|
| `cyclePrevious` | Select previous window | `⌥[` | Zaznacza poprzednie okno w cyklu (z zawijaniem) i je fokusuje (z przeniesieniem kursora, jeśli włączone). | Przesuwa celownik o 1 wstecz (jak `[`), nic nie fokusuje, tryb zostaje. **Uwaga:** przy domyślnym `⌥[` kod klawisza `[` jest przechwytywany jako klawisz nawigacji z modyfikatorem, więc `⌥[` w celowaniu *przesuwa wycelowane okna w kolejce* (§5.5). Wariant „przesuń celownik” działa tylko, gdy akcja ma skrót na innym klawiszu. | jw. (celownik i seria jak przy `[`) | Popup nazwy okna przy zwykłym cyklu (poza celowaniem, zwykły, znikający). |
| `cycleNext` | Select next window | `⌥]` | Jak wyżej, do przodu. | Jak wyżej, do przodu. | jw. | jw. |
| `moveLeft` | Move window earlier in queue | `⌥⇧[` | Zamienia zaznaczone okno z sąsiadem wcześniej w widocznym wycinku (okno fullscreen przesuwa się razem z przykrytymi jako blok). Wyłącza auto-sortowanie. | Przesuwa wycelowane okna (całą serię jako blok) o 1 miejsce wcześniej; tryb zostaje. | jw. — cały blok. | — |
| `moveRight` | Move window later in queue | `⌥⇧]` | Jak wyżej, później. | Jak wyżej, później. | jw. | — |
| `moveToStart` | Move window to start of queue | `⌥⇧↖` (Home) | Przenosi zaznaczone okno na początek widocznego wycinka. Wyłącza auto-sortowanie. | Wycelowane okno staje się zaznaczeniem, tryb się kończy (bez fokusowania), potem jak poza celowaniem. | Wszystkie wycelowane przenoszone blokiem (w swojej kolejności) na początek; tryb się kończy. | Kilka: „Moved N windows to the start of the queue”. |
| `moveToEnd` | Move window to end of queue | `⌥⇧↘` (End) | Na koniec widocznego wycinka. | jw., na koniec. | Blok na koniec. | Kilka: „Moved N windows to the end of the queue”. |
| `sortByWorkspace` | Sort queue by workspace | `⌥⇧W` | Włącza z powrotem auto-sortowanie (zapisane w ustawieniach) i sortuje kolejkę stabilnie po workspace'ach (§9). | Kończy tryb (bez zatwierdzenia), potem jak poza. | jw. | — |
| `closeWindow` | Close selected window | `⌥Q` | Zamyka zaznaczone okno (§7.4). | Wycelowane okno staje się zaznaczeniem, tryb się kończy, zamyka je. | Tryb się kończy, zamyka każde wycelowane (w kolejności kolejki). | Kilka: „Closed N windows”. |
| `toggleMaximize` | Fullscreen window (again to restore) | `⌥F` | Przełącza „fullscreen” zaznaczonego okna (§7.2). | Kończy tryb **bez** zaznaczania wycelowanego okna, potem działa na *zaznaczone* okno (patrz uwaga w §22). | **Nic się nie dzieje**, tryb zostaje otwarty, popup. | Kilka: „Fullscreen takes one window” / „Aim at a single window, or tile the group with Return”. |
| `maximizeWindow` | Maximize window | `⌥M` | Wypełnia obszar ekranu (bez miejsca stripu) zaznaczonym oknem (§7.1). | Wycelowane → zaznaczenie, koniec trybu, maksymalizacja. | Koniec trybu, maksymalizuje każde po kolei. | Kilka: „Maximized N windows”. |
| `minimizeWindow` | Minimize window | `⌥H` | Minimalizuje zaznaczone okno (§7.3). | Wycelowane → zaznaczenie, koniec trybu, minimalizacja. | Koniec trybu, minimalizuje każde. | Kilka: „Minimized N windows”. |
| `toggleGroup` | Group or ungroup windows | `⌥G` | Rozwiązuje grupę, w której jest zaznaczone okno (§17). | 1 okno: **tryb zostaje otwarty**, popup ostrzegawczy. | Koniec trybu, tworzy grupę z wycelowanych, zaznacza pierwsze z nich. | Patrz §17. |
| `search` | Search windows | `⌥Space` | Otwiera/zamyka wyszukiwarkę okien (§10). | Kończy tryb, otwiera wyszukiwarkę. **Uwaga:** klawisz Space w celowaniu jest klawiszem nawigacji („zatwierdź”) niezależnie od modyfikatorów, więc `⌥Space` wciśnięte w trybie celowania *zatwierdza celownik*, a nie otwiera wyszukiwarki. Wyszukiwarkę da się otworzyć z celowania tylko podwójnym stuknięciem (domyślnie) lub skrótem na innym klawiszu. | jw. | — |
| `openLauncher` | Open the launcher | `⌥R` | Otwiera launcher: Spotlight/Raycast/Alfred (§11). | Kończy tryb (zwalnia klawiaturę), potem otwiera launcher. | jw. | — |
| `showOverview` | Show Mission Control | `⌥W` | Otwiera przegląd workspace'ów (Mission Control; na GNOME: Activities overview) (§11). | Kończy tryb, potem otwiera przegląd. | jw. | — |
| `toggleInvisibleStrip` | Hide or show the strip (invisible mode) | `⌥I` | Przełącza tryb niewidzialnego stripu (§12). | Przełącza; **tryb celowania zostaje otwarty** (strip pojawia się/składa pod celownikiem). | jw. | „Strip hidden”/„Strip shown” (§19). |
| `toggleRecording` | Start or stop recording the screen | `⌥V` | Start/stop nagrywania całego ekranu (§13). | Start/stop; **tryb zostaje otwarty** (ten sam klawisz zatrzyma). | jw. | „Recording the screen”/„Recording saved”. |
| `screenshotWindow` | Take a picture of the window | `⌥P` | Zdjęcie zaznaczonego okna (§14). | Kończy tryb, zdjęcie wycelowanego okna. | Kończy tryb, jedno zdjęcie na każde wycelowane okno. | „Screenshot saved”/„N screenshots saved” itp. |
| `space1`…`space9` | Switch to workspace N | `⌥1`…`⌥9` | Przełącza na workspace N (§8.2). | Kończy tryb (bez zatwierdzenia), przełącza. | jw. | — |
| `moveToSpace1`…`moveToSpace9` | Move window to workspace N | `⌥⇧1`…`⌥⇧9` | Przenosi zaznaczone okno na workspace N i przenosi tam użytkownika razem z nim (fokus na przeniesionym oknie) (§8.1). | Przenosi wycelowane okno; tryb się kończy. | Przenosi wszystkie wycelowane. | „<tytuł> / Moved to workspace N” lub „<App> stayed where it was / It could not be moved to workspace N”. |

Grupy akcji w ustawieniach: „Queue” (`cyclePrevious, cycleNext, moveLeft, moveRight, moveToStart,
moveToEnd, sortByWorkspace, toggleMaximize, maximizeWindow, minimizeWindow, toggleGroup, closeWindow,
search, openLauncher, showOverview, toggleInvisibleStrip, toggleRecording, screenshotWindow` — w tej
kolejności), „Workspaces” (`space1…9`), „Move to workspace” (`moveToSpace1…9`).

Migracja jednorazowa (flaga `bindings.polishLettersFree.v1`): przy pierwszym uruchomieniu nowej
wersji skróty, które nadal mają *dawne* wartości domyślne, przechodzą na nowe:
`sortByWorkspace` super+⇧S → super+⇧W, `openLauncher` super+S → super+R, `showOverview` super+O →
super+W, `toggleRecording` super+C → super+V, `screenshotWindow` super+X → super+P. Skrót ustawiony
ręcznie na co innego zostaje. Migracja nigdy się nie powtarza.

---

### 3. Wspólne zachowanie akcji na „zaznaczonym oknie”

Poza trybem celowania akcje okienne (`closeWindow`, `toggleMaximize`, `maximizeWindow`,
`minimizeWindow`, `screenshotWindow`, `moveToSpaceN`, `moveToStart/End`, `moveLeft/Right`) działają
na **zaznaczonym** oknie kolejki (`selectedID`), nie na „oknie z fokusem wg systemu” (zwykle to samo).
Brak zaznaczenia (np. pusty workspace) → akcja nic nie robi, bez popupu (wyjątek: `toggleGroup`,
który mówi „Nothing to ungroup”; `screenshotWindow` bez okna nic nie robi).

Jeśli okno nie ma jeszcze uchwytu dostępności (np. leży na workspace, którego nie odwiedzono), przed
operacją na geometrii kontroler próbuje go pobrać na nowo z listy okien aplikacji.

---

### 4. Klawisz super: stuknięcie i podwójne stuknięcie

#### 4.1 Czym jest stuknięcie

Detektor obserwuje wyłącznie zmiany stanu modyfikatorów (zdarzenia „flags changed”), globalnie i we
własnych panelach. Stan = zbiór wszystkich wciśniętych modyfikatorów niezależnych od urządzenia
(Shift, Control, Option, Command, a także Caps Lock, Fn, klawiatura numeryczna — więc **przy
włączonym Caps Lock stuknięcie nigdy nie zadziała**).

Stan wewnętrzny: `armed` (super wciśnięty sam, „od zera”), `invalidated` (coś wykluczyło stuknięcie),
`pressedAt`.

Algorytm dla każdej zmiany modyfikatorów:

1. **Wszystko puszczone** (zbiór pusty): stuknięcie zachodzi, gdy `armed && !invalidated &&
   czas_od_pressedAt ≤ 0,4 s`. Potem reset (`armed=false, invalidated=false, pressedAt=nil`); jeśli
   było stuknięcie → `onTap` (przełącz tryb celowania).
2. **Zbiór == dokładnie kombinacja supera** i nie `armed` → `armed=true`, `invalidated=false`,
   `pressedAt=teraz`. Uzbrajanie zachodzi *tylko przy przejściu w górę*: powrót do samego supera
   (np. puszczenie Shift przy trzymanym Option po `⌥⇧]`) **nie** uzbraja ponownie.
3. **Zbiór niepusty i różny od supera** → `invalidated=true` (to kombinacja, nie stuknięcie).

Przerwania (każde ustawia `invalidated=true`): dowolne wciśnięcie klawisza (key down), wciśnięcie
lewego/prawego/innego przycisku myszy, przewinięcie kółkiem — globalnie i we własnych oknach — oraz
wykonanie dowolnej akcji WindowQueue (skrót skonsumowany przez system nie dociera do detektora, więc
dyspozytor anuluje ręcznie).

Stała: **maksymalny czas trzymania 0,4 s**.

Konsekwencja dla superów dwuklawiszowych (`⌃⌥`, `⌘⌥`): puszczenie jednego klawisza wcześniej niż
drugiego daje stan „jeden modyfikator” ≠ super → unieważnienie. Stuknięcie zadziała tylko, jeśli oba
klawisze zostaną puszczone w tym samym zdarzeniu. (Wciśnięcie po kolei jest OK: stan pośredni
unieważnia, ale późniejsze osiągnięcie pełnej kombinacji uzbraja od nowa z `invalidated=false`.)

#### 4.2 Co robi stuknięcie (`toggleAiming`)

Warunki wstępne: ustawienie `aimingEnabled` (domyślnie włączone) i **wyszukiwarka nie jest
otwarta** (inaczej nic).

- Tryb celowania zamknięty → **otwórz** (§5.1, „z klawiatury”).
- Tryb otwarty:
  - jeśli skonfigurowano akcję podwójnego stuknięcia (`superDoubleTapAction ≠ nil`) **i** od chwili
    otwarcia trybu (`aimingOpenedAt`) minęło < **0,4 s** → to podwójne stuknięcie: zamknij tryb
    bez zatwierdzenia, natychmiast schowaj popup nazwy (bez wygaszania), wykonaj skonfigurowaną akcję
    (już poza trybem celowania, więc działa na zaznaczone okno);
  - w przeciwnym razie → **zatwierdź** (zamknij tryb z fokusowaniem wycelowanego okna, §5.10).

Ponieważ stuknięcie rozpoznawane jest przy puszczeniu, podwójne stuknięcie = drugie puszczenie
nastąpiło w ciągu 0,4 s od pierwszego puszczenia (oba spełniają warunki stuknięcia).

`aimingOpenedAt` ustawiane jest przy *każdej* próbie otwarcia, także z odznaki i także gdy nie było
czego celować (tryb się wtedy nie otwiera, więc drugie stuknięcie po prostu znów próbuje otworzyć).
Otwarcie myszą i stuknięcie supera w ciągu 0,4 s też liczy się jako podwójne stuknięcie.

#### 4.3 Konfiguracja podwójnego stuknięcia

Ustawienie „Double tap of the super key”. Wartości: „Confirm the aim” (`nil` — drugie stuknięcie
zwyczajnie zatwierdza) albo jedna z akcji, w tej kolejności w liście: `openLauncher, showOverview,
search, toggleInvisibleStrip, toggleRecording, screenshotWindow, toggleMaximize, maximizeWindow,
minimizeWindow, toggleGroup, closeWindow, sortByWorkspace, moveToStart, moveToEnd`.
**Domyślnie: `search`** (wyszukiwarka okien). Kontrolka wyłączona, gdy tryb celowania wyłączony.
Opis w UI: „Two taps of the super key in quick succession. Confirming focuses the aimed window,
which is what the second tap does on its own; any other choice leaves aiming mode and runs that
action instead.”

---

### 5. Tryb celowania

Tryb, w którym klawiatura (i mysz) przesuwa **celownik** po stripie bez zmiany fokusu; dopiero
zatwierdzenie fokusuje okno, albo akcja działa na wycelowane okna. Model celownika (`aimingID`,
kotwica, przypięte, wejście do grupy) opisany jest w rozdziale o modelu; tu — orkiestracja.

#### 5.1 Otwarcie

Dwie drogi:

- **Z klawiatury**: stuknięcie supera (§4.2).
- **Myszą**: klik w **odznakę workspace'u** na stripie (klik = przycisk puszczony bez przeciągnięcia
  poza próg przeciągania). Działa tylko, gdy tryb nie jest już otwarty. Otwarty tak tryb jest
  „myszowy” (`aimStartedWithPointer = true`) i pokazuje kafelki akcji (§5.8).

Procedura `beginAiming(fromPointer)`:

1. `aimingOpenedAt = teraz`, zapamiętaj, czy myszą.
2. Jeśli widoczny wycinek kolejki jest pusty → nic (tryb się nie otwiera; brak popupu).
3. Model rozpoczyna celowanie: czyści kotwicę i przypięte, kierunek ostatniego kroku = +1; jeśli
   zaznaczone okno należy do grupy, celowanie startuje **wewnątrz tej grupy**; celownik ląduje na
   zaznaczonym oknie, jeśli jest ono osiągalne, inaczej na pierwszym osiągalnym (osiągalne = te,
   które osiąga cykl: bez przykrytych przez fullscreen; grupa reprezentowana przez swoje pierwsze
   osiągalne okno; wewnątrz grupy — okna grupy).
4. **Przechwyć klawiaturę** (§5.3) — od razu, także w czasie opóźnionego odsłonięcia.
5. Zacznij obserwować kliknięcia poza własnymi panelami (§5.7).
6. **Odsłonięcie** (funkcja `show`): pokaż kafelki akcji (tylko tryb myszowy), obrysy wycelowanych
   okien, przyciemnienie ekranów i — jeśli wycelowane jest dokładnie jedno okno — **przypięty popup
   nazwy** tego okna obok *każdego* stripu na ekranie (z podglądem okna, jeśli włączony). Popup
   dotyczy okna, na którym celownik jest *w chwili odsłonięcia*, nie w chwili otwarcia.
   - Jeśli skonfigurowano akcję podwójnego stuknięcia **i** tryb otwarto z klawiatury → odsłonięcie
     jest **opóźnione o 0,4 s** (by nie mignąć trybem, jeśli to pierwsza połowa podwójnego stuknięcia).
   - W przeciwnym razie (brak akcji podwójnego stuknięcia albo otwarcie myszą) → natychmiast.
   - Każda zmiana celownika w czasie opóźnienia (klawisz, kółko, Shift+klik, kafelek) anuluje
     opóźnienie i od razu pokazuje przyciemnienie; resztę pokazuje zwykła synchronizacja po zmianie
     celownika (§5.11).
   - Uwaga: strip reaguje na tryb celowania natychmiast (powiększa się o `aimingScale`, domyślnie
     1,2×; w trybie niewidzialnym rozkłada się), bo śledzi sam fakt celowania — opóźniane są tylko
     przyciemnienie, obrysy, popup nazwy i kafelki.

#### 5.2 Co widać w trybie celowania

- **Strip** powiększony (skala `aimingScale`), aktywny wygląd na wszystkich monitorach; celownik
  oznaczony na pomarańczowo, seria/przypięte wyróżnione (szczegóły wyglądu — rozdział o stripie).
  W trybie niewidzialnym strip jest widoczny tylko w trakcie celowania.
- **Panel grupy** obok stripu: jeśli celownik stoi na grupie jako całości albo wszedł do grupy,
  pokazywany jest panel tej grupy (by było widać, co oferuje wejście). W trybie niewidzialnym panel
  grupy poza celowaniem jest zawsze ukryty.
- **Przyciemnienie**: czarna, nieklikalna warstwa na każdym ekranie o nieprzezroczystości
  `aimingDimOpacity` (domyślnie 0,45; 0 = wyłączone; suwak 0–0,85), pod stripem i popupami,
  nad zwykłymi oknami; pojawia się i znika z animacją 0,18 s.
- **Obrysy okien**: wokół każdego wycelowanego okna leżącego na *bieżącym* workspace (i mającego
  odczytywalną ramkę > 20×20) rysowany jest pomarańczowy kontur (linia 3 pt, narożnik 10 pt,
  rysowany *wewnątrz* ramki okna, bez wypełnienia), nad przyciemnieniem. Okno pod celownikiem —
  pełne krycie, pozostałe wycelowane — 65 %. Pojawianie się: 0,12 s. Okna z innych workspace'ów nie
  są obrysowywane.
- **Popup nazwy**: przy jednym wycelowanym oknie — przypięty (nie znika sam) obok wiersza tego okna
  na każdym stripie (okno pokazane w panelu grupy — tylko tam); przy ≥2 oknach albo celowaniu grupy
  jako całości — schowany (zamiast niego menu układów lub panel grupy).
- **Menu układów** (§5.9) przy ≥2 wycelowanych oknach (nie będących grupą jako całością).
- **Kafelki akcji** (§5.8) w trybie myszowym.

#### 5.3 Przechwycenie klawiatury

Tryb celowania musi dostawać klawisze **bez przenoszenia fokusu** i **bez przepuszczania ich** do
aplikacji na wierzchu. Implementacja macOS: filtr zdarzeń na poziomie sesji, który *połyka* każde
wciśnięcie klawisza (key down). Puszczenia klawiszy i zmiany modyfikatorów przechodzą dalej (dlatego
stuknięcie supera nadal działa w trybie). Na GNOME: modalny grab klawiatury powłoki (np.
`Main.pushModal`/grab sceny) bez aktywowania żadnego okna.

- Każdy klawisz jest połykany, także nieznany.
- Klawisz nawigacji → obsługa w §5.5 (asynchronicznie, poza wywołaniem filtra).
- Każdy inny klawisz → próba dopasowania skrótu (§5.6).
- **Limit bezczynności: 15 s** od ostatniego wciśnięcia klawisza (licznik restartowany tylko przez
  klawisze — kliknięcia i kółko go nie odnawiają) → tryb zamyka się bez zatwierdzenia. Zabezpieczenie
  przed zablokowaniem klawiatury przez zapomniany tryb. Dotyczy też trybu myszowego.
- Nie udało się założyć grabu → tryb natychmiast się zamyka bez zatwierdzenia.
- Jeśli system wyłączy filtr (timeout/wejście użytkownika), zostaje on natychmiast włączony z powrotem.

Mapowanie klawiszy nawigacji (kody fizyczne macOS → znaczenie):

| Klawisz | Znaczenie (`Key`) |
|---|---|
| Return, Enter (numeryczny) | `enter` |
| Space | `space` |
| Escape | `cancel` |
| ↑ ↓ ← → | `up`, `down`, `left`, `right` |
| `[` | `back` |
| `]` | `forward` |
| `A` | `all` |

Do każdego klawisza nawigacji dołączane są dwie flagi z bieżących modyfikatorów:
`extends` = trzymany Shift; `moves` = trzymany Option **lub** Command **lub** Control (dowolny).
Klawisz nawigacji jest rozpoznawany niezależnie od modyfikatorów (np. `⌥A` = `all`, `⌥Space` =
`space`).

#### 5.4 Kierunki: „wzdłuż” i „w poprzek” stripu

- Strip pionowy (lewy/prawy): **wzdłuż** = ↑ (−1, poprzedni) / ↓ (+1, następny); **w poprzek** = ← →.
- Strip poziomy (górny/dolny): wzdłuż = ← (−1) / → (+1); w poprzek = ↑ ↓.
- Strzałka **„w głąb ekranu”** (od stripu do środka): strip lewy → `→`, prawy → `←`, górny → `↓`,
  dolny → `↑`. Strzałka **„ku stripowi”**: odwrotna (lewy → `←`, prawy → `→`, górny → `↑`, dolny → `↓`).
- `[` = −1, `]` = +1 zawsze.

#### 5.5 Obsługa klawiszy nawigacji — dokładny algorytm (`handleAimingPress`)

Zmienne pomocnicze w chwili naciśnięcia:
- `aimedGroup` = grupa, na której stoi celownik *jako na całości* (tzn. celownik nie wszedł do grupy,
  a okno pod celownikiem należy do grupy);
- `canTile` = wycelowane są ≥2 okna **i** `aimedGroup == nil` (seria zbudowana przez użytkownika).

Kroki:

0. Jeśli **menu układów ma fokus klawiatury** → obsługa menu (§5.9) i koniec.
1. Oblicz krok:
   - `back` → −1, `forward` → +1;
   - strzałka wzdłuż stripu → −1/+1 jak w §5.4;
   - strzałka w poprzek stripu: jeśli `canTile` → **brak kroku**; w przeciwnym razie ← i ↑ → −1,
     → i ↓ → +1 (czyli bez menu układów strzałki w poprzek też przesuwają celownik);
   - pozostałe klawisze → brak kroku.
2. Jeśli jest krok:
   - `moves` (Option/Command/Control) → **przesuń wycelowane okna w kolejce** o krok (cała seria
     jako blok, §5.12); ma pierwszeństwo przed Shift;
   - w przeciwnym razie `extends` (Shift) → **rozciągnij serię** o krok;
   - w przeciwnym razie → **przesuń celownik** o krok (z zawijaniem; kasuje serię i przypięte);
   - potem synchronizacja po zmianie (§5.11). Koniec.
3. Bez kroku, pierwsze pasujące:
   1. strzałka w głąb ekranu i `aimedGroup ≠ nil` → wejdź do grupy;
   2. strzałka ku stripowi i celownik jest wewnątrz grupy → wyjdź z grupy (celownik na grupie jako
      całości, na jej pierwszym oknie);
   3. `enter` i `aimedGroup ≠ nil` → wejdź do grupy;
   4. `enter` i `canTile` → daj fokus menu układów;
   5. strzałka w głąb ekranu i `canTile` → daj fokus menu układów;
   6. `all` → „zaznacz wszystko” (`aimAll`: celuje we wszystkie osiągalne; jeśli już wszystkie były
      wycelowane — wraca do samego okna pod celownikiem);
   7. `enter` lub `space` → **zatwierdź** (§5.10);
   8. `cancel` → zamknij bez zatwierdzenia;
   9. inne → nic.

Uwaga o faktycznym działaniu (odtworzyć wiernie albo świadomie poprawić): ponieważ krok z punktu 1
jest liczony przed punktem 3, strzałki w poprzek stripu przy `canTile == false` *zawsze* dają krok.
Skutki: (a) gdy celownik stoi na grupie jako całości, strzałka „w głąb ekranu” przesuwa celownik o +1
(zamiast wejść do grupy) — do grupy wchodzi się **Returnem** (albo klikiem); (b) wewnątrz grupy z
jednym wycelowanym oknem strzałka „ku stripowi” przesuwa celownik o −1; wyjście z grupy tą strzałką
działa tylko przy serii ≥2 okien wewnątrz grupy. Space przy grupie wycelowanej jako całość zatwierdza
(fokusuje okno pod celownikiem). Wejście do grupy odbywa się od strony, z której celownik nadszedł:
ostatni krok ujemny → celownik na ostatnim oknie grupy, dodatni → na pierwszym; wejście kasuje serię
i przypięte, a panel grupy staje się „otwarty”. Wyjście: jeśli zaznaczenie nie leży w tej grupie,
panel grupy się zamyka.

Tabela skrótowa (strip lewy, domyślne modyfikatory):

| Klawisz | 1 okno / brak serii | Seria ≥2 (`canTile`) | Celownik na grupie (całość) | Wewnątrz grupy |
|---|---|---|---|---|
| `[` / `]`, ↑ / ↓ | przesuń celownik ∓1 (zawija) | przesuń celownik (seria znika) | przesuń celownik | przesuń po oknach grupy |
| ⇧ + powyższe | rozciągnij serię (bez zawijania, stop na końcach) | rozciągnij/skróć | rozciągnij (grupa zawsze cała) | rozciągnij w grupie |
| ⌥/⌘/⌃ + powyższe | przesuń wycelowane okna w kolejce | przesuń blok | przesuń całą grupę | przesuń wycelowane |
| → (w głąb) | przesuń celownik +1 | fokus do menu układów | przesuń celownik +1 | przesuń +1 (1 okno) / menu układów (seria) |
| ← (ku stripowi) | przesuń celownik −1 | nic | przesuń −1 | −1 (1 okno) / wyjdź z grupy (seria) |
| Return | zatwierdź | fokus do menu układów | wejdź do grupy | zatwierdź / menu (seria) |
| Space | zatwierdź | zatwierdź (fokus okna pod celownikiem) | zatwierdź | zatwierdź |
| A | wszystko / z powrotem | jw. | jw. | wszystkie okna grupy |
| Esc | zamknij bez zmian | jw. | jw. | jw. |
| stuknięcie supera | zatwierdź (lub akcja podwójnego stuknięcia < 0,4 s od otwarcia) | jw. | jw. | jw. |

Znany efekt uboczny: klawisze nawigacji w filtrze trybu nie anulują jawnie detektora stuknięć, a
połknięte zdarzenie może nie dotrzeć do globalnego obserwatora. Szybkie `⌥]` (Option wciśnięty i
puszczony w ≤0,4 s) w trybie celowania może więc zostać odczytane *również* jako stuknięcie supera i
zatwierdzić tryb. Zalecenie dla reimplementacji: każdy klawisz w trakcie trzymania supera ma
unieważniać stuknięcie (zgodnie z definicją „nic pomiędzy”).

#### 5.6 Skróty w trybie celowania; gołe klawisze

Globalne skróty nie działają w trybie (grab połyka klawisze), więc każdy klawisz niebędący klawiszem
nawigacji jest dopasowywany do akcji ręcznie. `bare` = nie trzymano żadnego z ⌘ ⌥ ⌃ ⇧ (Caps Lock
itp. się nie liczą). Kolejność (pierwsze trafienie wygrywa):

1. Jeśli `bare` — **klawisz przypisany tylko do trybu celowania** (`aimBindings`: słownik fizyczny
   kod klawisza → akcja, ustawiany przez użytkownika).
2. Akcja, której **pełna kombinacja** dokładnie pasuje (ten sam klawisz, identyczny zbiór
   modyfikatorów ⌘⌥⌃⇧) — w kolejności deklaracji akcji (tabela w §2).
3. Jeśli `bare` — akcja, której kombinacja to **ten sam klawisz + dokładnie sam super** (np. goły
   `G` → `⌥G`). Kombinacje z dodatkowym Shiftem nie są osiągalne gołym klawiszem (goły `W` to
   `showOverview`, nie `sortByWorkspace`; `⇧W` nie pasuje do niczego — sortowanie w trybie wymaga
   pełnego `⌥⇧W`).
4. Brak trafienia → nic (klawisz i tak połknięty).

Znalezioną akcję wykonuje się tak jak w tabeli §2 (kolumna „W celowaniu”).

Skutki przy domyślnych skrótach (super ⌥): w trybie działają gołe `Q` (zamknij), `F` (fullscreen),
`M` (maksymalizuj), `H` (minimalizuj), `G` (grupuj), `R` (launcher), `W` (przegląd), `I` (strip),
`V` (nagrywanie), `P` (zdjęcie), `1`…`9` (przełącz workspace — kończy tryb). Pełnymi kombinacjami:
`⌥⇧1…9` (przenieś wycelowane), `⌥⇧↖`/`⌥⇧↘` (na początek/koniec), `⌥⇧W` (sortuj). Gołe Space, Return,
Esc, strzałki, `[`, `]`, `A` są zawsze klawiszami nawigacji — skróty ani `aimBindings` na tych
klawiszach w trybie nigdy nie zadziałają.

Ustawienia „Aiming mode only” (lista pod skrótami): wiersze „klawisz → akcja” z listy akcji „Queue”,
przycisk usuwania każdego wiersza, rejestrator „Add a key” przyjmujący goły klawisz (liczy się tylko
kod klawisza) i wybór akcji dla nowego klawisza. Opis w UI: „While aiming, every shortcut above works
without its super key. These keys work there and nowhere else, and come first when both would
answer.”

#### 5.7 Mysz w trybie celowania

- **Klik w ikonę na stripie** (bez Shift): kończy tryb **bez zatwierdzenia**, potem zwykłe
  zaznaczenie i fokus klikniętego okna (bez przenoszenia kursora). Jeśli kliknięto okno przykryte
  przez fullscreen, najpierw kończy się tryb fullscreen (kolejka wraca do normy). Klik w kafelkę
  stosu = klik w okno fullscreen; klik w grupę = wejście do grupy na jej pierwszym oknie.
- **Shift+klik w ikonę**: dodaje okno do celu lub je z niego usuwa (`toggleAim`): wszystko dotąd
  wycelowane zostaje jako „przypięte”, kotwica znika; dodane okno dostaje celownik; usunięcie
  ostatniego okna jest niemożliwe; usunięcie okna spod celownika przenosi celownik na najbliższe
  (w widocznym wycinku) wciąż wycelowane. Okna przykrytego nie da się dodać. Tryb zostaje.
- **Kółko nad stripem**: każdy krok przesuwa celownik o 1 (jak `[`/`]`, bez Shift/modyfikatorów),
  niczego nie fokusując.
- **Klik środkowym przyciskiem** w ikonę: zamyka okno (§7.4) — tryb pozostaje otwarty.
- **Klik w okno w panelu grupy**: zaznacza i fokusuje to okno (bez przenoszenia kursora), **nie**
  zamyka trybu celowania (zachowanie kodu; prawdopodobnie przeoczenie).
- **Klik gdziekolwiek poza własnymi panelami WindowQueue** (dowolnym przyciskiem: lewy, prawy,
  inny) → tryb zamyka się bez zatwierdzenia. Kliknięcia w strip, panel grupy, kafelki akcji, menu
  układów, popupy nie zamykają trybu (dostarczane są do aplikacji, a obserwator widzi tylko
  kliknięcia trafiające do innych aplikacji). Kliknięcie nadal dociera do klikniętej aplikacji.
- Wszystkie własne panele są „nieaktywujące”: nigdy nie biorą fokusu klawiatury; kliknięcie w nie
  rejestruje się przy puszczeniu przycisku (gest „przeciągnięcie o zerowym dystansie”).

#### 5.8 Kafelki akcji (tryb otwarty myszą)

Pokazywane **tylko**, gdy tryb otwarto klikiem w odznakę; odświeżane przy każdej zmianie celownika.
Kafelek robi dokładnie to, co jego klawisz. Lista budowana od nowa (kolejność ścisła):

Gdy wycelowane są **≥2 okna**:
1. „Group” (ikona stosu warstw) → `toggleGroup`;
2. „Tile” (siatka 2×2) → *confirm*; tylko gdy celownik **nie** stoi na grupie jako całości.

Gdy wycelowane jest **1 okno**:
1. „Focus” (celownik/scope) → *confirm*;
2. „Fullscreen” (strzałki na zewnątrz) → `toggleMaximize`.

Dalej zawsze:
3. „Maximize” (prostokąt rozciągnięty pionowo) → `maximizeWindow`;
4. „Minimize” (prostokąt z minusem) → `minimizeWindow`;
5. „Close” (×) → `closeWindow`;
6. „Select all” (lista z ptaszkami) → *select all* (jak `A`);
7. nazwa launchera: „Spotlight” / „Raycast” / „Alfred” (lupa) → `openLauncher`;
8. „Overview” (siatka 3×3) → `showOverview`;
9. „Screenshot” (aparat) → `screenshotWindow`;
10. „Record” (kółko nagrywania) albo „Stop” (kółko stop), gdy nagrywanie trwa → `toggleRecording`;
11. „Hide strip” (przekreślone oko) albo „Show strip” (oko), gdy tryb niewidzialny włączony →
    `toggleInvisibleStrip`;
12. „Cancel” (escape) → zamknij bez zatwierdzenia.

Działanie specjalnych rodzajów:
- *confirm*: jeśli wycelowane ≥2 okna i nie grupa jako całość → daj fokus menu układów (i odśwież
  kafelki); w przeciwnym razie → zatwierdź (fokus okna pod celownikiem).
- *select all*: jak klawisz `A`, potem synchronizacja.
- skrót: dokładnie jak wykonanie akcji w trybie (§2).

Wygląd i położenie: kafelek 58×42 pt (ikona 15 pt, podpis 9 pt w jednej linii, może się zmniejszyć
do 70 %), odstęp 4 pt, marginesy panelu 6 pt, tło panelu półprzezroczyste z krawędzią, narożnik
12 pt, nieprzezroczystość tła jak stripu. Kafelki układają się **w poprzek kierunku stripu**: przy
stripie bocznym jeden pod drugim (kolumna), przy górnym/dolnym — w rzędzie. Najechany kafelek
podświetlony kolorem akcentu (30 %). Panel stoi obok treści stripu, po stronie środka ekranu, 10 pt
od niego, wyśrodkowany względem środka stripu, przycięty do widocznego obszaru ekranu stripu z
marginesem 10 pt. Pojawia się z animacją 0,14 s; rozmiar liczony od nowa przy każdej zmianie listy.
Bez stripu — na środku ekranu.

#### 5.9 Menu układów (kafelkowanie wycelowanych okien)

Pokazywane, gdy wycelowane są ≥2 okna i celownik nie stoi na grupie jako całości; aktualizowane
przy każdej zmianie celownika; chowane przy <2 oknach, przy grupie jako całości i przy zamknięciu
trybu (schowanie zawsze odbiera mu fokus klawiatury).

Zawartość (szerokość 220 pt, tło materiałowe, narożnik 12 pt):
- nagłówek „N windows” (N = liczba wycelowanych);
- wiersze układów dostępnych dla N (§6.1), każdy z miniaturą układu (34×22 pt, prostokąty komórek)
  i nazwą;
- podpowiedź na dole:
  - menu bez fokusu: „<strzałka>, Return or click to choose a layout”, gdzie strzałka = `→` (strip
    lewy), `←` (prawy), `↓` (górny), `↑` (dolny);
  - menu z fokusem: „Return or click to tile · Esc to go back”.
- menu z fokusem ma pomarańczową ramkę 2 pt (inaczej subtelną 1 pt); podświetlony wiersz:
  pomarańcz 35 % (z fokusem) albo szary 8 % (bez).

Podświetlenie: startowo pierwszy (najbardziej użyteczny) układ; zeruje się, gdy zmienia się zestaw
nazw układów (np. przejście z 2 na 3 okna), a zostaje przy zmianie liczby okien, która nie zmienia
nazw (np. 4 → 5: Grid/Main and stack/Columns/Rows).

Położenie: obok ikon wycelowanych okien (prostokąt obejmujący wiersz pierwszego i ostatniego
wycelowanego okna — w panelu grupy, jeśli tam są pokazane, inaczej na stripie), po stronie ekranu,
10 pt odstępu, wyśrodkowane względem tego prostokąta i przycięte do widocznego obszaru.

Jak wybrać układ:
- **Myszą**: klik w wiersz → podświetla go i od razu kafelkuje (działa także bez fokusu menu).
- **Klawiaturą**: najpierw fokus menu (Return albo strzałka w głąb ekranu przy serii ≥2, albo kafelek
  „Tile”), potem w menu:
  - ↑ lub `[` → poprzedni układ; ↓ lub `]` → następny (z zawijaniem);
  - przy stripie górnym/dolnym dodatkowo ← → poprzedni, → → następny;
  - Return lub Space → kafelkuj podświetlonym układem;
  - **każdy inny klawisz nawigacji** (Esc, `A`, strzałki w poprzek przy stripie bocznym — w tym
    strzałka „ku stripowi”, ale też „w głąb”) → oddaj fokus z powrotem stripowi (tryb celowania trwa).
  - Modyfikatory (Shift/⌥) w menu są ignorowane. Skróty (klawisze nie-nawigacyjne) działają jak
    zwykle w trybie celowania.

#### 5.10 Zamknięcie trybu

`endAiming(commit)` (bez efektu, gdy tryb nie jest otwarty):
1. zapamiętaj okno pod celownikiem;
2. model kończy celowanie (czyści celownik, kotwicę, przypięte, wejście do grupy);
3. schowaj menu układów, zwolnij klawiaturę, przestań obserwować kliknięcia, anuluj opóźnione
   odsłonięcie, schowaj kafelki, obrysy i przyciemnienie; przypięty popup nazwy znika po
   min(`toastDuration`, 0,6) s;
4. jeśli `commit` → zaznacz okno spod celownika (bez ogłaszania) i **sfokusuj je** (§15, z
   przeniesieniem kursora, jeśli włączone). Przy serii zatwierdzenie fokusuje tylko okno pod
   celownikiem.

Drogi zamknięcia **z zatwierdzeniem**: Return/Space (poza przypadkami menu/grupy), ponowne stuknięcie
supera (bez podwójnego), kafelek „Focus”, *confirm* przy jednym oknie.

Drogi **bez zatwierdzenia**: Esc, kafelek „Cancel”, klik poza panelami, klik w ikonę na stripie (po
czym fokusuje klikane okno), 15 s bezczynności klawiatury, błąd grabu, podwójne stuknięcie (po czym
akcja), każda akcja kończąca tryb (tabela §2), kafelkowanie.

Akcje, po których tryb **zostaje**: przesuwanie celownika/serii/bloku, wejście/wyjście z grupy,
`A`, Shift+klik, kółko, `toggleInvisibleStrip`, `toggleRecording`, `toggleGroup` przy jednym
wycelowanym oknie, `toggleMaximize` przy kilku, fokus/wyjście z menu układów, klik środkowym
przyciskiem, klik w panelu grupy.

#### 5.11 Synchronizacja po każdej zmianie celownika (`aimChanged`)

1. Jeśli odsłonięcie wciąż czeka → anuluj je i pokaż przyciemnienie.
2. Odśwież panel grupy, kafelki akcji (tryb myszowy), obrysy.
3. Jeśli celownik stoi na grupie jako całości → schowaj popup nazwy natychmiast, schowaj menu układów.
4. Inaczej, gdy wycelowane ≥2 → schowaj popup natychmiast, pokaż/odśwież menu układów.
5. Inaczej → schowaj menu układów; przypięty popup nazwy okna spod celownika obok każdego stripu.

#### 5.12 Semantyka operacji na celowniku (skrót — pełny opis w rozdziale o modelu)

- **Przesunięcie celownika** o ±1: po oknach osiągalnych, z zawijaniem; kasuje kotwicę i przypięte;
  zapamiętuje kierunek.
- **Rozciągnięcie** o ±1: przy braku kotwicy kotwica = bieżący celownik; celownik przesuwa się bez
  zawijania (zatrzymuje się na końcach). Seria = okna od kotwicy do celownika + przypięte, w
  kolejności kolejki. Poza grupą, jeśli seria dotyka okna grupy, wycelowana jest cała grupa.
- **Przesunięcie wycelowanych w kolejce** o ±1: wycelowane okna (widoczne) wyjmowane i wstawiane
  razem, w swojej kolejności, od pozycji (pierwsze z nich + krok), przyciętej do [0, liczba widocznych
  − liczba przesuwanych]; zmiana kolejności wyłącza auto-sortowanie i (dla grup kafelkowych) może
  wywołać ponowne ułożenie (§6.6).
- **Wszystko** (`A`): patrz §5.5.

---

### 6. Kafelkowanie

#### 6.1 Układy i ich geometria

Układ = lista prostokątów jednostkowych (0…1, początek w lewym górnym rogu), po jednym na okno, w
kolejności okien. Okna przypisuje się do komórek w **kolejności kolejki** (pierwsze wycelowane w
kolejce = pierwsza komórka = „główne”).

Oferowane układy dla N okien, w tej kolejności (pierwszy jest domyślnie podświetlony):
- N < 2: brak;
- N = 2: „Side by side”, „Stacked”;
- N = 3: „Main and stack”, „Columns”, „Rows”;
- N ≥ 4: „Grid”, „Main and stack”, „Columns”, „Rows”.

Geometria:
- **Side by side / Columns** (N): kolumny równej szerokości 1/N, pełna wysokość, od lewej.
- **Stacked / Rows** (N): wiersze równej wysokości 1/N, pełna szerokość, od góry.
- **Main and stack** (N ≥ 3): okno 1 = lewa połowa, pełna wysokość (x 0, szer. 0,5); pozostałe N−1
  w prawej połowie (x 0,5, szer. 0,5) jedno pod drugim, każde wysokości 1/(N−1).
- **Grid** (N ≥ 4): kolumny `c = ⌈√N⌉`, wiersze `r = ⌈N/c⌉`, wysokość wiersza 1/r; wypełnianie
  wierszami od lewej do prawej, od góry; wiersz i ma `min(c, N − i·c)` okien i dzieli **całą
  szerokość** równo między nie (krótki ostatni wiersz ma szersze okna). Np. N=5: c=3, r=2 → 3 + 2;
  N=7: 3+3+1 (ostatnie okno na całą szerokość).

„Rodzaj” układu (używany, gdy liczba okien się zmienia przy finalizacji): „Side by side” ≡
„Columns”, „Stacked” ≡ „Rows”, pozostałe — same sobą.

Maksymalizacja/fullscreen to wewnętrznie układ „Maximize” z jedną komórką (0,0,1,1).

#### 6.2 Obszar kafelkowania (`tilingArea`)

1. Ekran: ten z fokusem klawiatury („main”; na GNOME — monitor z aktywnym oknem), a w razie braku —
   pierwszy.
2. Jego obszar roboczy (bez paska menu i Docka; na GNOME — work area monitora), ale **bez**
   rezerwacji miejsca, którą WindowQueue sama nałożyła dla stripu (jeśli rezerwacja jest zainstalowana
   na tym ekranie i obszar ją faktycznie zawiera, jest dodawana z powrotem — by nie odjąć jej dwa razy).
3. Jeśli strip nie jest ukryty (`stripDisplay ≠ hidden`) **i** włączone `reserveScreenSpace` → od
   strony stripu odejmij szerokość rezerwy: `ceil(grubość_stripu + 2·stripMargin)`, gdzie grubość =
   `iconSize + 8 + 2·6` (domyślnie 34 + 8 + 12 = 54, rezerwa = 54 + 8 = **62 pt**). **W trybie
   niewidzialnym rezerwa = 0.**

Kafelkowanie zawsze odbywa się w obszarze *tego* ekranu, niezależnie od tego, na którym monitorze
leżą okna.

#### 6.3 Ustawianie ramek (`WindowTiler.tile`) i odstępy

Parametry: `tileOuterGap` (domyślnie 0) — odstęp od krawędzi obszaru; `tileInnerGap` (domyślnie 4)
— odstęp między sąsiednimi oknami.

1. `inset = outer − inner/2`; obszar pomniejszony o `inset` z każdej strony (przy domyślnych:
   −2, czyli *powiększony* o 2).
2. Komórka = prostokąt jednostkowy przeskalowany do obszaru, każda współrzędna zaokrąglona.
3. Ramka okna = komórka pomniejszona o `inner/2` z każdej strony. Wynik: dokładnie `outer` przy
   krawędziach, dokładnie `inner` między oknami.
4. Okno zminimalizowane jest najpierw przywracane.
5. Ustaw pozycję, potem rozmiar. Jeśli odczytana ramka różni się od żądanej o > 2 pt na którejkolwiek
   współrzędnej → ustaw rozmiar, pozycję i znowu rozmiar (dla aplikacji przycinających rozmiar).
6. Na czas zmiany wyłącza się animowanie ramki przez aplikację (atrybut „enhanced UI”), potem
   przywraca.
7. **Korekty**: sprawdzenie po 0,15, 0,4, 0,8 i 1,5 s od ustawienia. Jeśli ramka zgodna (±2 pt) →
   dalej. Jeśli inna, ale różna też od stanu z poprzedniego sprawdzenia → okno wciąż się przesuwa,
   sprawdź później. Jeśli inna i stabilna → ustaw ponownie (i kontynuuj sprawdzenia). Nowsze żądanie
   ramki dla tego samego okna unieważnia sprawdzenia starszego.
8. Zapamiętywana jest „ostatnia ramka nadana przez WindowQueue” każdemu oknu (do rozpoznania, czy
   użytkownik je potem ruszył).
9. Okna bez uchwytu (np. na nieodwiedzonym workspace) są pomijane; wynik = lista faktycznie
   ustawionych.

Po ułożeniu grupa jest **wynoszona na wierzch** razem: okna podnoszone w odwrotnej kolejności, więc
pierwsze okno układu kończy na samej górze.

#### 6.4 Wybór workspace'u dla układu (`tileAimedWindows`)

Wejście: wycelowane okna (kolejność kolejki, ≥2), podświetlony układ. Najpierw tryb celowania się
zamyka (bez zatwierdzenia).

- `home` = workspace **ostatniego** wycelowanego okna.
- „Obcy na miejscu” = czy na `home` jest jakiekolwiek niezminimalizowane okno kolejki (cała kolejka,
  bez względu na zakres) spoza układu.
- Jeśli są obcy → szukaj najlepszego workspace'u (`workspaceForLayout`):
  - tylko workspace'y **tego samego monitora** co `home`, w kolejności numeracji (Mission Control);
  - z wyłączeniem samego `home`;
  - kwalifikuje się workspace, na którym **wszystkie** niezminimalizowane okna należą do układu
    (pusty też się kwalifikuje);
  - najlepszy = najwięcej okien układu już tam („holds”); remis → najbliższy odległością w liście od
    `home`; dalszy remis → wcześniejszy w kolejności;
  - znaleziony → cel = ten workspace;
  - nie znaleziony → cel = `home` i popup wyśrodkowany: **„Tiled where they are”** / **„No workspace
    on this monitor is free for the layout, and macOS would not add one”** (nowych workspace'ów się
    nie tworzy).
- Brak obcych → cel = `home` (rozciągnięcie na kilka workspace'ów samo nie jest powodem do przenosin:
  brakujące okna zostaną przeniesione na `home`).

#### 6.5 Przenoszenie i finalizacja

1. `home` nieznany → ułóż od razu na miejscu (§6.5 krok 6).
2. Wszystkie okna już na celu **i** cel jest widoczny (na którymkolwiek monitorze) → ułóż od razu.
3. W przeciwnym razie okna spoza celu przenieś na cel (jak §8.1; okno, którego nie da się przenieść,
   zostaje) i przesuń je w kolejce do bloku celu.
4. Przejdź na cel: jeśli ostatnie okno (po przeniesieniu) jest na celu albo cel jest widoczny →
   sfokusuj je (bez przenoszenia kursora; to też przenosi na jego workspace); inaczej przełącz
   workspace (nośnik, awaryjnie systemowy skrót ⌃N).
5. Po **0,9 s**: jeśli cel jest teraz widoczny, każde okno wciąż nie na celu próbuje się „przyciągnąć”
   na bieżący workspace (na macOS: sztuczka z aktywacją aplikacji; na GNOME: zwykłe przeniesienie
   okna). Następnie „zebrane” = okna na celu **lub** o nieodczytywalnym workspace; przesuń je w kolejce
   do bloku celu.
   - Zebranych < 2 → układaj **wszystkie** żądane okna tam, gdzie są.
   - Zebranych mniej niż żądanych → popup wyśrodkowany **„Tiled N windows”** / **„K would not leave
     its workspace”** i układaj tylko zebrane.
   Odśwież uchwyty okien i listę okien.
6. **Finalizacja** (`finishTiling`): odrzuć okna bez uchwytu. Jeśli liczba okien ≠ liczba komórek
   układu → weź układ tego samego *rodzaju* dla nowej liczby, a gdy go nie ma — pierwszy dostępny;
   przy < 2 oknach nic się nie dzieje. Ułóż (§6.3) w obszarze (§6.2), wynieś grupę na wierzch, zapisz
   grupę kafelkową (§6.6), zaznacz pierwsze okno (bez ogłaszania) i je sfokusuj (bez przenoszenia
   kursora).

#### 6.6 Cykl życia grupy kafelkowej

**Utworzenie** (`noteTiled`):
- przez 2 s od teraz zmiany ramek są uznawane za własne (globalny znacznik `tilingSettledAt`,
  wspólny dla wszystkich grup);
- oknom układu kasuje się zapamiętane ramki sprzed maksymalizacji (układ zastępuje maksymalizację);
- okna odchodzą z dotychczasowych grup kafelkowych; grupa, której zostało < 2 okien, znika;
- nowa grupa dostaje **najmniejszy wolny numer** (od 1), nazwę układu i listę okien; numer jest
  pokazywany na stripie (gdy grup jest > 1);
- grupy, które straciły okna, ale mają ich ≥ 2, są **układane ponownie po 0,4 s** dla nowej liczby
  okien: układ o tej samej *nazwie*, jeśli dostępny dla tej liczby, inaczej pierwszy dostępny (tu nie
  używa się „rodzaju”: np. „Rows” z 3 okien przy 2 oknach staje się „Side by side”, „Grid” z 4 przy 3
  — „Main and stack”);
- zapamiętuje się kolejność okien grupy; po 2 s zapisuje się faktyczne ramki okien (po korektach).

**Ponowne ułożenie po zmianie kolejności**: po każdej zmianie kolejki, dla każdej grupy kafelkowej
kolejność jej okien w kolejce jest porównywana z zapamiętaną. Różna (i ≥ 2 okna) →
- jeśli któreś okno grupy jest w trybie fullscreen → tylko zapamiętaj nową kolejność (bez układania);
- inaczej ułóż grupę od nowa w nowej kolejności (układ po nazwie lub pierwszy) i zapisz ją jako nową
  grupę (znów najmniejszy wolny numer — numer może się zmienić).
To najszybszy sposób zmiany „głównego” okna: przesunąć je w kolejce na początek grupy.

**Zwolnienie ręcznym ruchem**: przy powiadomieniu o przesunięciu lub zmianie rozmiaru okna (nie przy
zmianie fokusu):
- ignorowane, jeśli nie minęły 2 s od ostatniego układania (`tilingSettledAt`), jeśli okno nie jest
  w grupie kafelkowej albo jeśli jego ramka różni się od zapisanej o ≤ 4 pt na każdej współrzędnej;
- inaczej cała grupa przestaje istnieć; okna zostają dokładnie tam, gdzie są.
Uwaga: `maximizeWindow` na oknie z grupy powoduje zmianę ramki po czasie ochronnym → zwalnia grupę.
Ponowne układanie przez „grupy, które straciły okna” nie odświeża zapisanych ramek — reimplementacja
powinna je odświeżać po 2 s, by przypadkowe powiadomienie nie zwolniło grupy.

**Fullscreen nie zwalnia grupy**: przełączenie fullscreen ustawia czas ochronny 2 s, a powrót
przywraca okno na jego komórkę (§7.2).

**Znikanie okien**: okno zamknięte/zniknięte wypada z grupy; grupa < 2 okien znika (ostatnie okno
zostaje, jak stoi). Grupa, której zostały ≥ 2 okna, ma teraz inną listę okien niż zapamiętana, więc
detektor zmiany kolejności (wyżej) **układa ją od nowa** dla mniejszej liczby okien (układ po nazwie
lub pierwszy dostępny). Minimalizacja nie usuwa okna z kolejki, więc nie zmienia grupy.

**Dopasowanie do nowego miejsca** (tylko po przełączeniu trybu niewidzialnego skrótem/kafelkiem, 0,25 s
później — `refitPlacedWindows`): w nowym obszarze
1. każda grupa kafelkowa (≥ 2 okna, bez okna w fullscreen) jest układana od nowa i zapisywana;
2. okno w trybie fullscreen jest wypełniane na nowo;
3. każde inne okno, które było maksymalizowane (ma zapamiętaną ramkę sprzed maksymalizacji), nie
   należy do grupy kafelkowej i wciąż stoi dokładnie (±2 pt) tam, gdzie WindowQueue je ostatnio
   postawiła → wypełniane na nowo. Okna ruszone przez użytkownika zostają.
(Zmiana widoczności stripu w samych ustawieniach nie wywołuje dopasowania.)

**Raise całego układu**: patrz §15.

#### 6.7 Podgląd komórki przy przeciąganiu

Gdy na stripie przeciąga się ikonę okna należącego do grupy kafelkowej, na ekranie pokazywany jest
prostokąt komórki, którą okno zajęłoby po upuszczeniu w bieżącym miejscu: symuluje się kolejkę po
upuszczeniu, bierze członków grupy w tej kolejności, indeks przeciąganego okna, układ po nazwie (lub
pierwszy dla tej liczby), komórkę tego indeksu w obszarze (§6.2) pomniejszonym o `outer`, a potem
o `inner/2`. Okno spoza grupy kafelkowej / koniec przeciągania → podgląd znika.

---

### 7. Operacje na oknie

#### 7.1 Maksymalizacja (`maximizeWindow`, `⌥M`)

- Jeśli okno nie ma jeszcze zapamiętanej „ramki sprzed maksymalizacji” → zapamiętaj bieżącą.
- Wypełnij obszar kafelkowania (§6.2) z odstępem `outer` od krawędzi (§6.3).
- Nic więcej: nie ma trybu skupienia, nie zmienia się kolejka, pozostałe okna zostają. Ponowne `⌥M`
  nie przywraca (ale `⌥F` na tak zmaksymalizowanym oknie przywróci ramkę sprzed `⌥M` — §7.2).
- Przy kilku wycelowanych: po kolei każde okno (wszystkie dostają tę samą ramkę, nakładając się).

#### 7.2 Fullscreen (`toggleMaximize`, `⌥F`)

To **nie** systemowy pełny ekran — okno wypełnia obszar ekranu pomniejszony o miejsce stripu
(z odstępem `outer`).

1. Weź zaznaczone okno (brak → nic). Ustaw czas ochronny grup kafelkowych na 2 s.
2. **Przywrócenie**: jeśli okno ma zapamiętaną ramkę sprzed maksymalizacji **i** jego bieżąca ramka
   „wypełnia” obszar — |Δx| ≤ 12, |Δy| ≤ 12, |Δszer.| ≤ 24, |Δwys.| ≤ 24 (tolerancja na zaokrąglenia
   aplikacji) → skasuj zapamiętaną ramkę, przywróć okno do niej, zakończ tryb skupienia (kolejka
   wraca do dawnego porządku).
3. **Wejście**: w przeciwnym razie zapamiętaj bieżącą ramkę (nadpisując starą), wypełnij obszar i,
   jeśli włączone `focusMaximizedWindow` (domyślnie tak), rozpocznij **tryb skupienia** na oknie:
   okno przechodzi na początek bloku swojego workspace'u w kolejce (zapamiętując sąsiadów, by potem
   wrócić na miejsce), a pozostałe okna tego workspace'u stają się „przykryte” (na stripie zwinięte w
   kafelkę stosu lub przyciemnione, pomijane przez cykl i celowanie). Wcześniejsze skupienie na innym
   oknie kończy się najpierw.
4. Okno z grupy kafelkowej pozostaje w grupie; ponowne `⌥F` przywraca je do jego komórki.

Przywracanie działa niezależnie od tego, czy okno jest „oknem skupienia” — decyduje tylko zapamiętana
ramka i dopasowanie do obszaru. Okno, które po fullscreenie zostało ruszone (nie wypełnia już
obszaru), przy `⌥F` znowu wchodzi w fullscreen (z nową zapamiętaną ramką).

Wyjście ze skupienia następuje też przez klik w przykryte okno na stripie (skupienie kończy się, okno
się nie zmienia) oraz gdy okno fullscreen zniknie.

Popup przytrzymania kafelki stosu (wskaźnik spoczywa na niej): **„+N window(s) hidden”** (liczba
pojedyncza „window” dla N=1) / **„<skrót toggleMaximize> restores the maximized window and brings them
back”**, przypięty obok pierwszego ukrytego okna.

#### 7.3 Minimalizacja (`minimizeWindow`, `⌥H`)

Ustawia oknu stan „zminimalizowane” (przez API dostępności). Nic więcej — bez popupu (poza wariantem
dla kilku okien), bez zmiany zaznaczenia przez kontroler.

#### 7.4 Zamykanie (`closeWindow`, `⌥Q`, środkowy przycisk, × na stripie/panelu grupy)

1. **Następca** wybierany *przed* zamknięciem (by zaznaczenie nie spadło na początek kolejki):
   - okno na **bieżącym** workspace → najbliższe w kolejności kolejki niezminimalizowane okno z
     widocznego wycinka leżące na tym samym workspace (bez samego okna); może nie być żadnego;
   - okno na innym workspace (albo bez workspace'u) → sąsiad w widocznym wycinku: następny, a dla
     ostatniego — poprzedni; brak, gdy okno jest jedyne.
2. Zamknięcie: naciśnięcie przycisku zamknięcia okna przez API dostępności. Gdy okno nie ma uchwytu
   (inny workspace) albo przycisku → sfokusuj okno i ponawiaj co 0,12 s do 12 razy szukanie przycisku;
   przy ostatniej próbie, jeśli aplikacja okna jest na wierzchu i jej okno z fokusem to właśnie to
   (albo nie da się tego ustalić, a aplikacja ma ≤ 1 okno) → wyślij aplikacji `⌘W` (na GNOME: poproś
   okno o zamknięcie — `Meta.Window.delete`, co usuwa cały ten obejściowy mechanizm).
3. Jeśli jest następca → **zaznacz** go (bez ogłaszania i bez jawnego fokusowania).
4. Jeśli okno było na bieżącym workspace i nie ma następcy (zamknięto ostatnie okno workspace'u) →
   **przytrzymaj workspace** na 2 s: jeśli w tym czasie system sam przeniesie użytkownika na inny
   workspace (np. aktywując inną aplikację), a użytkownik nie prosił o zmianę workspace'u w ciągu
   ostatnich 0,5 s i nie trwa własny skok WindowQueue → wróć na opróżniony workspace (jednorazowo).
   Prośba użytkownika o zmianę workspace'u kasuje przytrzymanie. Strip pokazuje wtedy pusty slot.
5. Odśwież listę okien po 0,4 s i po 1,2 s (system mógł przenieść tu inne okno).

Przy kilku wycelowanych: po kolei `close` dla każdego (każde wylicza swojego następcę), potem popup
„Closed N windows”.

---

### 8. Workspace'y

#### 8.1 Przeniesienie okien na workspace (`moveToSpaceN`, `⌥⇧N`)

1. Okna: w trybie celowania — wszystkie wycelowane (tryb się kończy bez zatwierdzenia); inaczej —
   zaznaczone okno.
2. Workspace N = N-ty (od 1) workspace użytkownika w kolejności numeracji **przez wszystkie monitory**.
   Brak okien, brak takiego workspace'u albo niedostępny mechanizm przenoszenia → nic (bez popupu).
3. Przenieś — **użytkownik przechodzi razem z oknami** na docelowy workspace:
   - macOS: najpierw próba przeniesienia pojedynczych okien przez WindowServer; co nie przeszło —
     przez przypisanie całej aplikacji do workspace'u, ale **tylko** jeśli aplikacja nie ma innych
     niezminimalizowanych okien poza przenoszonym zestawem i poza celem. Wynik odczytywany z
     powrotem: „przybyłe” (łącznie z tymi, które już tam były) i „pozostawione”.
   - macOS, zapas dla pozostawionych („przeciągnięcie”): okno jest wysuwane na wierzch, a punkt chwytu
     (środek szerokości, 5 px pod górną krawędzią) musi trafiać właśnie w nie — inaczej rezygnacja.
     Symulowane: wciśnięcie lewego przycisku, przesunięcie o 1 px, przełączenie na cel oknem-nośnikiem
     (nie ⌃N — użytkownik może jeszcze trzymać ⌥⇧ ze skrótu, a ⌃⌥⇧N nie jest skrótem Mission
     Control), oczekiwanie na cel (≤ 2 s + 0,2 s), puszczenie, przywrócenie kursora, sprawdzenie.
     Okno z innego desktopu jest najpierw odwiedzane. Gdy żadne okno nie dotarło, użytkownik wraca na
     desktop wyjściowy. W trakcie kolejne przeniesienie jest ignorowane, a focus follows mouse
     wstrzymany. (Minimalizacja nie działa: macOS 26 przywraca okno na jego dawny desktop.)
   - GNOME: każde okno można przenieść osobno (`change_workspace_by_index`), zapas jest zbędny;
     „pozostawione” = tylko faktyczne niepowodzenia.
4. Przybyłe okna przechodzą w kolejce do bloku docelowego workspace'u (za jego ostatnie okno, albo —
   gdy nie ma tam okien — przed pierwsze okno późniejszego workspace'u, albo na koniec), zachowując
   wzajemną kolejność.
5. Pierwsze (w kolejności przenoszonych) okno, które dotarło, zostaje zaznaczone i sfokusowane —
   to przenosi użytkownika na docelowy workspace, jeśli jeszcze go tam nie ma.
6. Popup (zwykły, znika po `toastDuration`, obok ikony):
   - są pozostawione → **„<nazwa aplikacji pierwszego pozostawionego> stayed where it was”** + gdy
     pozostawionych > 1: **„ and K more”** (K = liczba − 1); podtytuł **„It could not be moved to
     workspace N”**; obok pozostawionego okna;
   - inaczej → tytuł = tytuł okna (lub nazwa aplikacji, gdy tytuł pusty) przy jednym oknie, albo
     **„N windows”**; podtytuł **„Moved to workspace N”**; obok pierwszego okna.
7. Odśwież listę okien po 0,3 s.
8. Okno przeniesione z grupy kafelkowej wypada z niej (grupa pamięta swój workspace), a pozostałe
   okna grupy są układane od nowa; jedno pozostałe okno wypełnia obszar roboczy.

#### 8.2 Przełączenie workspace'u (`spaceN`, `⌥N`) — skrót

Szczegóły mechaniki są w rozdziale o workspace'ach; kontroler robi:
- notuje czas prośby użytkownika (dla §7.4) i numer prośby (nowsza unieważnia ponawianie starszej);
- strategia z ustawień: „Focus a window on that workspace” — zaznacz i sfokusuj (z przeniesieniem
  kursora) zaznaczone okno, jeśli leży na celu, inaczej pierwsze niezminimalizowane okno celu w
  kolejności kolejki; gdy pusto — skok nośnikiem; awaryjnie systemowy skrót; „Send ⌃1…⌃9” — tylko
  skrót; „Carry an invisible window there” (domyślna) — skok nośnikiem, awaryjnie skrót;
- po 0,8 s sprawdza, czy cel jest widoczny; jeśli nie, a użytkownik nadal jest na wyjściowym
  workspace → ponawia (1. ponowienie: skok, awaryjnie skrót; 2.: skrót), maksymalnie 2 ponowienia;
  jeśli użytkownik jest już gdzie indziej — odpuszcza.
Na GNOME wystarczy `workspace.activate_with_focus(okno, czas)` / `activate(czas)`.

---

### 9. Sortowanie kolejki (`sortByWorkspace`, `⌥⇧W`, menu)

Włącza trwale ustawienie `autoSortByWorkspace` i natychmiast sortuje: stabilnie według pozycji
workspace'u okna w kolejności numeracji; okna o nieznanym workspace (np. zminimalizowane) na końcu;
kolejność wewnątrz workspace'u zostaje. Każda ręczna zmiana kolejności (przesunięcie, przeciągnięcie,
przesunięcie bloku w celowaniu, `moveToStart/End`) wyłącza auto-sortowanie i zapisuje to w
ustawieniach. Bez popupu.

---

### 10. Wyszukiwarka okien (`search`, `⌥Space`, domyślnie też podwójne stuknięcie)

Przełącznik: otwarta → zamknij; zamknięta → otwórz (tylko jeśli kolejka nie jest pusta).

**Wygląd**: panel nieaktywujący (nie bierze fokusu), szerokość 560 pt; pole zapytania wysokości 52 pt
z ikoną lupy i tekstem 19 pt — przy pustym zapytaniu szary placeholder **„Search windows”**; pod
spodem (gdy są wyniki) separator 1 pt i lista wierszy po 44 pt, maks. **8 widocznych** (reszta
przewijana; podświetlony wiersz przewijany na środek). Wiersz: ikona aplikacji 22×22, tytuł okna
(lub nazwa aplikacji przy pustym tytule), pod nim nazwa aplikacji (mniejsza, szara), po prawej numer
workspace'u w szarej pastylce (jeśli znany). Podświetlony wiersz: kolor akcentu 25 %. Narożnik panelu
14 pt, tło półprzezroczyste. Wysokość panelu = 52 + (wyniki > 0 ? 1 + min(wyniki, 8)·44 : 0) —
liczona z liczby wyników, nie z pomiaru widoku, i przeliczana po każdej zmianie zapytania. Położenie:
wyśrodkowany poziomo na ekranie z fokusem, górna krawędź 22 % wysokości obszaru roboczego poniżej jego
górnej krawędzi. Przy otwartej wyszukiwarce ekrany są przyciemnione (to samo przyciemnienie co w
celowaniu).

**Wyniki**: wszystkie okna kolejki (**ignoruje zakres „tylko bieżący workspace”**; zawiera
zminimalizowane, jeśli są w kolejce). Puste zapytanie → kolejność kolejki. Inaczej: dopasowanie
rozmyte do tekstu „<nazwa aplikacji> <tytuł>”, tylko dopasowane, malejąco po wyniku (remisy w
kolejności kolejki):
- zapytanie dzielone na słowa po spacjach; **każde** słowo musi pasować (wyniki się sumują);
- porównanie bez rozróżniania wielkości liter;
- słowo jako podciąg ciągły: wynik 100 − min(indeks, 40), +25 jeśli zaczyna się na początku słowa
  (indeks 0 albo poprzedni znak to jeden z: spacja `-` `_` `.` `/` `:` `—` `–` `(` `[` `|` `,` `'`);
- jeśli nie ma podciągu — dopasowanie „z przerwami”: znaki słowa po kolei, każdy przy pierwszym
  wystąpieniu po poprzednim; +25 jeśli pierwszy trafiony znak zaczyna słowo; +4 za każdy znak trafiony
  tuż po poprzednim; rozpiętość (od pierwszego do ostatniego trafienia) może przekroczyć długość słowa
  najwyżej o 3, inaczej brak dopasowania; minus min(pozycja pierwszego trafienia, 20);
- na koniec od sumy odejmuje się `długość_tekstu / 20` (całkowicie) — krótsze tytuły wygrywają remisy.

**Klawiatura** (grab jak w celowaniu: nic nie dociera do aplikacji, fokus się nie zmienia; limit
bezczynności **30 s** → zamknięcie):
- Esc → zamknij;
- Return / Enter → wybierz podświetlony wynik (brak wyników → nic);
- ↑ / ↓ → poprzedni / następny wynik (z zawijaniem); Tab → następny;
- Backspace → usuń ostatni znak zapytania;
- każdy inny klawisz → znaki, które by wpisał (z uwzględnieniem Shift/Option, np. „ą”), dopisane do
  zapytania, jeśli niepuste i bez znaków sterujących; inaczej ignorowany;
- każda zmiana zapytania ustawia podświetlenie na pierwszy wynik;
- wszystkie klawisze są połykane — globalne skróty (także `⌥Space`) nie działają, póki wyszukiwarka
  jest otwarta; zamyka się ją Esc, wyborem albo limitem czasu.
- Klik w wiersz → wybór.

**Wybór**: zamknij wyszukiwarkę, zaznacz okno (bez ogłaszania) i sfokusuj je (§15, z przeniesieniem
kursora).

Podczas otwartej wyszukiwarki: stuknięcie supera nic nie robi, focus-follows-mouse jest wstrzymany.

---

### 11. Launcher i przegląd workspace'ów

**Launcher** (`openLauncher`, `⌥R`; ustawienie `launcher`, domyślnie Spotlight):
- Spotlight → symulowane wciśnięcie i puszczenie `⌘Space` (jego systemowego skrótu);
- Raycast / Alfred → uruchomienie/aktywacja aplikacji (identyfikator pakietu `com.raycast.macos` /
  `com.runningwithcrayons.Alfred`), co pokazuje ich pasek; jeśli nie jest zainstalowana → Spotlight.
- Ustawienia pokazują Raycast/Alfred jako dostępne tylko, gdy są zainstalowane.
- W trybie celowania tryb najpierw się zamyka (zwalnia klawiaturę), dopiero potem otwiera się launcher.
- GNOME: odpowiednik Spotlight = wyszukiwanie w przeglądzie Activities (`Main.overview.show()` z
  fokusem pola wyszukiwania) lub skonfigurowany zewnętrzny launcher (polecenie).

**Przegląd** (`showOverview`, `⌥W`): otwiera Mission Control (uruchamia aplikację systemową). GNOME:
`Main.overview.show()` / przełączenie widoku Activities. W trybie celowania — najpierw zamknięcie trybu.

---

### 12. Niewidzialny strip (`toggleInvisibleStrip`, `⌥I`)

1. Odwróć ustawienie `invisibleStrip` (zapisywane trwale).
2. Popup wyśrodkowany:
   - włączone: **„Strip hidden”** / **„<skrót> brings it back; aiming mode shows it meanwhile”**;
   - wyłączone: **„Strip shown”** / **„<skrót> hides it again”**.
3. Zaktualizuj rezerwację miejsca na ekranie (w trybie niewidzialnym rezerwa = 0) i integrację z
   zewnętrznym menedżerem układów (Rectangle — na GNOME brak).
4. Po 0,25 s — dopasowanie umieszczonych okien do nowego obszaru (§6.6 „Dopasowanie”).
W trybie celowania tryb zostaje (strip rozkłada się/składa pod celownikiem); kafelek zmienia napis
„Hide strip” ↔ „Show strip”.

---

### 13. Nagrywanie ekranu (`toggleRecording`, `⌥V`)

- **Start** (gdy nic nie nagrywa): uruchom nagrywanie **całego ekranu** do pliku
  `„Recording <data>.mov”` w katalogu zrzutów ekranu użytkownika (§14 „Katalog”), gdzie `<data>` =
  `yyyy-MM-dd 'at' HH.mm.ss` (np. `Recording 2026-09-24 at 14.03.22.mov`); przy kolizji nazw:
  `… (2).mov`, `… (3).mov`… Na macOS: `screencapture -v <ścieżka>` jako proces działający do
  przerwania. GNOME: np. D-Bus `org.gnome.Shell.Screencast.Screencast` (plik .webm/.mp4 w
  `~/Videos/Screencasts` lub tym samym katalogu co zrzuty).
  Popup wyśrodkowany: **„Recording the screen”** / **„<skrót> stops it and saves the file”**.
- **Stop** (gdy nagrywa): wyślij procesowi SIGINT (tak narzędzie domyka plik). Popup:
  **„Recording saved”** / nazwa pliku bez rozszerzenia (np. `Recording 2026-09-24 at 14.03.22`).
- Gdy proces nagrywania zakończy się sam, stan „nagrywa” gaśnie.
- Nieudany start: kod zwraca „nie rozpoczęto, brak pliku”, więc pokazuje się **„Recording saved”** /
  **„The recording has been written”** (mylący komunikat — zalecane w reimplementacji: osobny popup
  błędu).
- **Wskaźnik**: dopóki trwa nagrywanie, odznaka workspace'u na stripie jest zastąpiona czerwonym,
  pulsującym symbolem nagrywania (60 % rozmiaru ikony) na czerwonawym tle (16 %), z podpowiedzią
  „Recording the screen”. Kafelek akcji: „Record” ↔ „Stop”.
- W trybie celowania tryb zostaje otwarty.

---

### 14. Zdjęcia okien (`screenshotWindow`, `⌥P`)

1. Okna: w trybie celowania — **wszystkie wycelowane** (kolejność kolejki; tryb najpierw się zamyka);
   inaczej — zaznaczone okno. Brak okien → nic.
2. Brak uprawnienia do nagrywania ekranu → popup wyśrodkowany **„Screen Recording access needed”** /
   **„System Settings › Privacy & Security › Screen Recording”** i koniec. (GNOME: uprawnienia nie ma;
   zrzut okna przez rozszerzenie powłoki / `Shell.Screenshot`.)
3. Każde okno po kolei jest wynoszone na wierzch (ostatnie kończy na górze), bo okno zasłonięte
   sfotografowałoby się z tym, co je zasłania; po **0,15 s** zdjęcia.
4. **Jeden plik PNG na okno**, samo okno bez cienia, bez dźwięku migawki. Nazwa:
   `„<nazwa> <data>.png”`, gdzie `<nazwa>` = tytuł okna (lub nazwa aplikacji przy pustym tytule) z
   `/` i `:` zamienionymi na `-`, obciętymi białymi znakami; pusty wynik → nazwa aplikacji; maks.
   60 znaków; `<data>` jak przy nagrywaniu; kolizje → ` (2)`, ` (3)`…
5. **Katalog**: miejsce zapisu zrzutów ustawione przez użytkownika w systemie (na macOS preferencja
   `location` w domenie `com.apple.screencapture`, z rozwinięciem `~`), domyślnie `~/Desktop`
   (GNOME: katalog zrzutów ekranu, zwykle `~/Pictures/Screenshots`).
6. Popup wyśrodkowany:
   - nic nie zapisano → **„Nothing captured”** / **„The window could not be photographed”**;
   - 1 plik → **„Screenshot saved”**, >1 → **„N screenshots saved”**; podtytuł = nazwa katalogu
     (ostatni człon ścieżki, np. „Desktop”).

---

### 15. Fokusowanie okna i to, co mu towarzyszy (`focus`)

Każde fokusowanie przez kontroler:
1. Fokus okna (mechanika w rozdziale o fokusie): podróż na jego workspace, wyniesienie, aktywacja,
   ponawianie. **Przeniesienie kursora** na środek okna — tylko gdy fokus pochodzi z klawiatury
   **i** włączone `warpCursorToWindow` (domyślnie tak). Z przeniesieniem: cykl, zatwierdzenie
   celowania, wybór w wyszukiwarce, przełączenie workspace'u przez fokus okna, następca po przeniesieniu
   okna na workspace. Bez przeniesienia: klik na stripie i w panelu grupy, fokus po przewinięciu
   kółkiem, finalizacja kafelkowania.
2. **Wyniesienie całego układu**: jeśli okno należy do grupy kafelkowej, pozostałe jej okna leżące na
   *tym samym workspace* są wynoszone na wierzch (odwrotna kolejność kolejki), a na końcu samo
   fokusowane okno — żeby wybór jednego okna układu nie zostawił reszty pod inną aplikacją. Okna
   grupy z innych workspace'ów nie są ruszane.
3. **Mignięcie fokusu** (jeśli `flashFocusedWindow`, domyślnie tak, i czas > 0): kontur jak w
   celowaniu, ale w **kolorze akcentu/zaznaczenia**, pełne krycie, wokół ramki okna; pojawia się od
   razu, trzyma przez `flashFocusedWindowDuration` (domyślnie **0,15 s**), potem wygasa przez 0,5 s
   (ease-in). Okno na innym workspace jest obrysowywane dopiero po dotarciu: sprawdzanie co 0,1 s,
   do 20 prób (2 s), potem rezygnacja. Nie miga, gdy w międzyczasie otwarto tryb celowania, ani gdy
   ramka okna jest nieczytelna / < 20×20. Jeden wspólny kontur (nowe mignięcie zastępuje poprzednie).

---

### 16. Kółko nad stripem

- Przeliczanie na kroki: kółko zapadkowe — każde zdarzenie = 1 krok (znak wg kierunku); gładkie
  przewijanie (touchpad) — sumowanie przesunięcia i 1 krok na każdą wysokość wiersza stripu
  (`iconSize + 8`), reszta przechodzi dalej. Używana oś o większej wartości (poziome przewijanie
  działa tak samo). Przewijanie „w dół” (treść w górę) = następne okno.
- **Poza celowaniem**: zaznaczenie przesuwa się od razu o tyle kroków w cyklu (z popupem nazwy), a
  **fokus jest odroczony**: każde przewinięcie anuluje poprzednie odroczenie; po `scrollFocusDelay`
  (domyślnie **0,5 s**) bez przewijania zaznaczone okno jest fokusowane (bez przenoszenia kursora).
- **W celowaniu**: każdy krok przesuwa celownik (jak `[`/`]`), nic nie jest fokusowane.

---

### 17. Grupy (`toggleGroup`, `⌥G`)

- **W celowaniu, ≥ 2 wycelowane**: zamknij tryb, utwórz grupę z wycelowanych okien (w kolejności
  kolejki; okna opuszczają poprzednie grupy, grupy < 2 znikają; numer = najmniejszy wolny od 1),
  zaznacz pierwsze wycelowane okno (bez fokusowania; grupa staje się otwarta — panel grupy obok
  stripu). Popup wyśrodkowany **„Grouped N windows as group G”** / **„WindowQueue”**. Celowanie w
  grupę jako całość i ponowne `G` tworzy grupę na nowo (może zmienić numer).
- **W celowaniu, 1 wycelowane**: popup **„Aim at two or more windows to group them”** / **„Shift-click
  or Shift with the arrows”**; tryb zostaje otwarty.
- **Poza celowaniem**: zaznaczone okno w grupie → rozwiąż tę grupę (okna zostają w kolejce na swoich
  miejscach), popup **„Ungrouped N windows”** / **„WindowQueue”**. Inaczej popup **„Nothing to
  ungroup”** / **„Select a window in a group, or aim at several to make one”**.
- Najechanie wskaźnikiem na wpis grupy na stripie: przypięty popup **„Group G — N windows”** /
  **„Click to open it in a strip of its own”** (znika po zjechaniu).

---

### 18. Menu w pasku stanu

Ikona: symbol „stos prostokątów” (na GNOME: wskaźnik w panelu górnym). Pozycje menu, w kolejności:

| Pozycja | Skrót w menu | Działanie |
|---|---|---|
| „Settings…” | `⌘,` | Otwiera okno ustawień (tworzone raz, potem przywoływane); po 0,3 s odświeża listę okien. Na czas otwartego okna ustawień aplikacja staje się zwykłą aplikacją; po zamknięciu wraca do trybu „bez ikony w Docku” i odświeża listę okien. |
| „Sort queue by workspace” | `⌘S` | Jak akcja `sortByWorkspace` (§9). |
| „Refresh windows” | `⌘R` | Natychmiastowe ponowne wyliczenie okien. |
| (separator) | | |
| „Quit WindowQueue” | `⌘Q` | Zamyka aplikację (z przywróceniem rezerwacji miejsca na ekranie). |

Skróty w menu działają tylko przy otwartym menu. Ponowne „uruchomienie” już działającej aplikacji
(z launchera/menedżera plików) otwiera ustawienia.

---

### 19. Wszystkie popupy — dosłowne teksty

Wszystkie popupy są wyłączane jednym ustawieniem `toastEnabled` (wtedy nie pojawia się żaden, także
wyśrodkowany). Rodzaje:
- **obok ikony** (tytuł 13 pt pogrubiony, podtytuł 11 pt szary, każdy w jednej linii; szerokość
  140–480 pt; 8 pt od ikony po stronie ekranu, przycięty do ekranu; gdy wiersza nie ma —
  przy lewej krawędzi obszaru roboczego w pionowym środku): zwykły znika po `toastDuration` (domyślnie
  1,0 s), przypięty trwa do zdjęcia przytrzymania i wtedy znika po min(`toastDuration`, 0,6) s;
- **wyśrodkowany** (na środku obszaru roboczego ekranu z fokusem): znika po max(`toastDuration`, 1,2) s.
Pojawianie 0,12 s (0,08 s, gdy już widoczny i tylko się zmienia), znikanie 0,18 s. Nowy popup zastępuje
poprzedni.

| Kiedy | Rodzaj | Tytuł | Podtytuł |
|---|---|---|---|
| Zmiana zaznaczenia ogłaszana (cykl, kółko) | obok ikony, zwykły | tytuł okna (lub nazwa aplikacji) | nazwa aplikacji |
| Celowanie w jedno okno | obok ikony na **każdym** stripie, przypięty, z podglądem okna (jeśli `showWindowPreview` i jest dostęp) | tytuł okna | nazwa aplikacji |
| Przytrzymanie/najechanie ikony | obok ikony, przypięty, z podglądem | tytuł okna | nazwa aplikacji |
| Najechanie na kafelkę stosu | obok ikony, przypięty | „+N window hidden” / „+N windows hidden” | „<skrót fullscreen> restores the maximized window and brings them back” |
| Najechanie na wpis grupy | obok ikony, przypięty | „Group G — N windows” | „Click to open it in a strip of its own” |
| Kafelkowanie bez wolnego workspace'u | wyśrodkowany | „Tiled where they are” | „No workspace on this monitor is free for the layout, and macOS would not add one” |
| Kafelkowanie, część okien nie dojechała | wyśrodkowany | „Tiled N windows” | „K would not leave its workspace” |
| Fullscreen przy kilku wycelowanych | wyśrodkowany | „Fullscreen takes one window” | „Aim at a single window, or tile the group with Return” |
| Grupowanie przy 1 wycelowanym | wyśrodkowany | „Aim at two or more windows to group them” | „Shift-click or Shift with the arrows” |
| Utworzenie grupy | wyśrodkowany | „Grouped N windows as group G” | „WindowQueue” |
| Rozwiązanie grupy | wyśrodkowany | „Ungrouped N windows” | „WindowQueue” |
| Nie ma czego rozgrupować | wyśrodkowany | „Nothing to ungroup” | „Select a window in a group, or aim at several to make one” |
| Maksymalizacja kilku | wyśrodkowany | „Maximized N windows” | „WindowQueue” |
| Minimalizacja kilku | wyśrodkowany | „Minimized N windows” | „WindowQueue” |
| Zamknięcie kilku | wyśrodkowany | „Closed N windows” | „WindowQueue” |
| Kilka na początek kolejki | wyśrodkowany | „Moved N windows to the start of the queue” | „WindowQueue” |
| Kilka na koniec kolejki | wyśrodkowany | „Moved N windows to the end of the queue” | „WindowQueue” |
| Przeniesienie na workspace — OK | obok ikony pierwszego okna, zwykły | tytuł okna albo „N windows” | „Moved to workspace N” |
| Przeniesienie — okno zostało | obok ikony tego okna, zwykły | „<App> stayed where it was” [+ „ and K more”] | „It could not be moved to workspace N” |
| Start nagrywania | wyśrodkowany | „Recording the screen” | „<skrót> stops it and saves the file” |
| Stop nagrywania | wyśrodkowany | „Recording saved” | nazwa pliku bez rozszerzenia (lub „The recording has been written”) |
| Zdjęcie bez uprawnień | wyśrodkowany | „Screen Recording access needed” | „System Settings › Privacy & Security › Screen Recording” |
| Zdjęcie nieudane | wyśrodkowany | „Nothing captured” | „The window could not be photographed” |
| Zdjęcie udane | wyśrodkowany | „Screenshot saved” / „N screenshots saved” | nazwa katalogu |
| Strip ukryty | wyśrodkowany | „Strip hidden” | „<skrót> brings it back; aiming mode shows it meanwhile” |
| Strip pokazany | wyśrodkowany | „Strip shown” | „<skrót> hides it again” |

`<skrót>` to bieżąca kombinacja danej akcji w zapisie z §„Konwencje” (np. `⌥V`, `⌥I`, `⌥F`).

Inne stałe teksty UI z tego rozdziału: tytuły kafelków akcji (§5.8), „N windows” i podpowiedzi menu
układów (§5.9), placeholder „Search windows” (§10), pozycje menu paska stanu (§18), podpowiedź
wskaźnika nagrywania „Recording the screen” (§13).

---

### 20. Stałe czasowe i progi

| Stała | Wartość |
|---|---|
| Maks. czas trzymania supera przy stuknięciu | 0,4 s |
| Okno podwójnego stuknięcia (od otwarcia trybu) | 0,4 s |
| Opóźnienie odsłonięcia trybu (gdy jest akcja podwójnego stuknięcia) | 0,4 s |
| Limit bezczynności klawiatury: celowanie / wyszukiwarka | 15 s / 30 s |
| Oczekiwanie na zebranie okien przed kafelkowaniem | 0,9 s |
| Ponowne ułożenie grup, które straciły okna | +0,4 s |
| Czas ochronny po układaniu/fullscreenie (zmiany ramek „własne”) | 2 s |
| Odczyt ramek grupy kafelkowej po ułożeniu | +2 s |
| Tolerancja „okno nie ruszone” (grupa kafelkowa) | ±4 pt |
| Sprawdzenia korekt ramek | 0,15 / 0,4 / 0,8 / 1,5 s; tolerancja ±2 pt |
| Tolerancja „okno wypełnia obszar” (fullscreen) | pozycja ±12 pt, rozmiar ±24 pt |
| Zamykanie: ponowienia szukania przycisku | 12 × co 0,12 s |
| Zamykanie: odświeżenia listy | 0,4 s i 1,2 s |
| Przytrzymanie opróżnionego workspace'u | 2 s; prośba użytkownika w ostatnich 0,5 s wygrywa |
| Odświeżenie po przeniesieniu na workspace | 0,3 s |
| Sprawdzenie dotarcia na workspace | 0,8 s, maks. 2 ponowienia |
| Zdjęcie okna po wyniesieniu | 0,15 s |
| Dopasowanie po przełączeniu niewidzialnego stripu | 0,25 s |
| Mignięcie fokusu: trzymanie / wygaszanie / ponawianie | 0,15 s (ustawialne) / 0,5 s / co 0,1 s × 20 |
| Fokus po przewinięciu kółkiem | 0,5 s (ustawialne) |
| Popup: zwykły / wyśrodkowany / po przytrzymaniu | `toastDuration` (1,0 s) / max(·, 1,2 s) / min(·, 0,6 s) |
| Animacje: przyciemnienie / kafelki / obrysy | 0,18 s / 0,14 s / 0,12 s |
| Odświeżenie po otwarciu ustawień | 0,3 s |

---

### 21. Polecenia debugowe (tylko do testów)

Włączane preferencją `debugCommands`; polecenia przychodzą jako rozgłaszane powiadomienie
`com.mpochec.windowqueue.command` z linią tekstu: `action <id akcji>` (wykonaj akcję), `aim` (jak
stuknięcie supera), `aimkey <up|down|left|right|back|forward|enter|space|cancel> [shift] [move]`
(klawisz w trybie celowania, tylko gdy otwarty), `focus <id okna>` (zaznacz z ogłoszeniem i
sfokusuj), `refresh`, `dump` (zapis stanu do pliku logu). Na GNOME odpowiednik: metoda D-Bus.

---

### 22. Zachowania nieoczywiste (zachować albo świadomie poprawić)

1. `toggleMaximize` z trybu celowania przy **jednym** wycelowanym oknie kończy tryb **bez**
   zaznaczenia wycelowanego okna, więc fullscreen dotyczy okna *zaznaczonego* — różnego od
   wycelowanego, jeśli użytkownik przesunął celownik. Dotyczy też kafelka „Fullscreen”. (Inne akcje
   okienne — `maximize/minimize/close/moveToStart/End` — najpierw zaznaczają wycelowane okno.)
   Zalecenie: zaznaczyć wycelowane okno przed fullscreenem.
2. `⌥[`/`⌥]` (domyślne skróty cyklu) w trybie celowania przesuwają wycelowane okna w kolejce (bo
   Option = „moves”), a nie celownik; `⌥Space` zatwierdza zamiast otwierać wyszukiwarkę.
3. Strzałka „w głąb ekranu” nie wchodzi do grupy wycelowanej jako całość (przesuwa celownik); do
   grupy wchodzi się Returnem lub klikiem (§5.5).
4. Klik w okno w panelu grupy w trakcie celowania fokusuje je, nie zamykając trybu.
5. Nieudany start nagrywania pokazuje „Recording saved”.
6. Limit 15 s bezczynności zamyka także tryb otwarty myszą, mimo że kliknięcia go nie odnawiają.
7. Wszystkie wycelowane okna przeniesione `⌥⇧↖`/`⌥⇧↘`, gdy obejmują cały widoczny wycinek: kolejka
   się nie zmienia, a popup i tak mówi „Moved N windows…”.
8. Szybkie `⌥` + klawisz nawigacji w trybie może zostać odczytane jako stuknięcie supera (§5.5).
9. Kafelkowanie zawsze używa obszaru ekranu z fokusem, nawet gdy docelowy workspace jest na innym
   monitorze.

---

## Warstwa systemowa

Ta część opisuje wszystko, co łączy WindowQueue z systemem okien: skąd bierze się lista okien,
jak aplikacja wie, który obszar roboczy (workspace) jest widoczny, jak przełącza obszary, jak
fokusuje i zamyka okna, jak rejestruje globalne skróty, jak rezerwuje miejsce na pasek (strip)
i jak się uruchamia. Dla każdej funkcji podano najpierw **kontrakt** (co ma być osiągnięte i jak
to wygląda dla użytkownika, z czasami, ponowieniami i przypadkami brzegowymi), potem krótko
**jak robi to macOS**, żeby implementator GNOME mógł znaleźć odpowiednik. Ostatnia podsekcja
zbiera odpowiedniki w GNOME/Mutter.

Terminologia: „obszar” = workspace / Space z Mission Control; „pasek” = strip WindowQueue;
„kolejka” = uporządkowana lista okien, którą pokazuje pasek; „zaznaczenie” = `selectedID`
w modelu; „pusty slot” = znacznik w kolejce pokazywany, gdy użytkownik stoi na obszarze bez okien
(`emptySlot`, opisany w części o modelu).

### 0. Zasady ogólne warstwy

- **Nic nie może zamrozić paska.** Zapytania do innych aplikacji (macOS Accessibility, „AX”)
  potrafią blokować do timeoutu. Każde zapytanie AX ma limit **0,25 s**
  (`AXUIElementSetMessagingTimeout`), a pełne wyliczanie okien działa na osobnej kolejce
  w tle; wynik trafia do modelu na wątku głównym. Jedno odświeżanie naraz (`isRefreshing`) —
  kolejne żądanie w trakcie trwania jest po prostu pomijane (następne przyjdzie z timera).
- **Każda operacja asynchroniczna ma token generacji.** Fokus, skok na obszar, weryfikacja
  przełączenia obszaru – każde nowe żądanie zwiększa licznik, a stare pętle/ponowienia po
  zobaczeniu nieaktualnego tokenu przerywają się bez efektów ubocznych. Zasada: *wygrywa
  najnowsze żądanie użytkownika*, nigdy spóźnione ponowienie starego.
- **Prywatne API są opcjonalne.** Wszystkie prywatne symbole macOS są wiązane dynamicznie; brak
  symbolu wyłącza funkcję (albo przełącza na wariant zastępczy), a nie wywraca aplikacji.
- **Identyfikator okna** to numer okna serwera okien (`CGWindowID`, liczba 32-bit), stabilny przez
  całe życie okna, unikalny w sesji. Uchwyt AX (`element`) jest dodatkowy i może być nieobecny.
- **Własne okna WindowQueue** (pasek, dymek z tytułem, podświetlenie, panele) nigdy nie trafiają
  do kolejki: leżą powyżej zwykłego poziomu okien, a wyliczanie bierze tylko warstwę 0. Okno
  ustawień WindowQueue *jest* zwykłym oknem i trafia do kolejki jak każde inne.
- **Dziennik zdarzeń**: praktycznie każda decyzja opisana niżej zapisuje linijkę do
  `events.log` (sekcja 12); w spec podano te komunikaty tylko tam, gdzie pomagają zrozumieć
  zachowanie.

### 1. Odkrywanie okien (`WindowEnumerator`)

#### 1.1 Które aplikacje się liczą

- Aplikacje zwykłe (z ikoną w Docku) **oraz** „akcesoryjne” (menu-bar, bez ikony w Docku) –
  okno ustawień aplikacji z paska menu jest prawdziwym oknem, do którego użytkownik chce dojść.
- Nie liczą się procesy tła/agenty bez UI.
- Nazwa aplikacji (`localizedName`, domyślnie „Unknown”) i identyfikator pakietu (`bundleID`)
  są zapamiętywane dla każdego okna.

#### 1.2 Które okna się liczą (źródło: serwer okien)

Lista okien jest budowana w dwóch krokach, bo macOS ma dwa źródła o różnych brakach: serwer okien
widzi okna na **wszystkich** obszarach, ale bez tytułów (tytuły tylko z uprawnieniem Screen
Recording); AX ma tytuły i pozwala działać na oknie, ale pokazuje okna aplikacji **tylko z
bieżącego obszaru**.

Krok 1 – „nasiono” z serwera okien. Okno jest kandydatem, gdy **wszystkie** warunki:
1. warstwa (layer) = 0 (zwykłe okna; menu, Dock, pasek, panele systemowe odpadają);
2. rozmiar co najmniej **120 × 80** px (odrzuca paski narzędzi, cienie, okna pomocnicze);
3. właściciel jest aplikacją z 1.1;
4. okno jest przypisane do jakiegoś obszaru (serwer zna jego space);
5. okno jest „ordered-in”, tj. naprawdę na liście wyświetlania serwera (nie jest zamkniętym,
   ale nie zwolnionym oknem ani okienkiem roboczym poza ekranem). Jeśli tego nie da się
   sprawdzić, warunek jest pomijany.
Pomijane są elementy pulpitu (`excludeDesktopElements`).

Krok 2 – wzbogacenie przez AX, dla każdej aplikacji:
- Przy pierwszym zobaczeniu aplikacji WindowQueue włącza jej drzewo dostępności
  (`AXManualAccessibility = true` – Chromium/Electron domyślnie go nie budują). Ponawiane po każdej
  aktywacji aplikacji (niektóre akceptują to tylko, gdy są na przodzie).
- Jeśli aplikacja zwraca **pustą** listę okien AX, raz na jej życie WindowQueue ustawia
  `AXEnhancedUserInterface = true` (to co robi VoiceOver; Chrome dopiero wtedy wystawia okna) i
  czyta listę ponownie. Tylko dla aplikacji z tym objawem, bo tryb ten zmienia animacje okien.
- Okno sfokusowane aplikacji (`AXFocusedWindow`) jest odczytywane zawsze – dla aplikacji, które
  nie wypełniają listy okien, to jedyny uchwyt. Jego element i tytuł (jeśli niepusty) są
  dopisywane do okna z kroku 1.
- Dla każdego okna z listy AX, które jest *standardowe* (subrola brak lub `AXStandardWindow`,
  rola brak lub `AXWindow`): dopisuje element, tytuł, stan zminimalizowania. Okno
  **zminimalizowane** jest dodawane nawet, gdy serwer okien go nie wymienił (zminimalizowane
  okna nie są ordered-in) – tak zminimalizowane okna trafiają do kolejki. Okno niezminimalizowane
  nieznane serwerowi jest pomijane.

Krok 3 – filtr popupów (tylko dla aplikacji „ślepych” w AX). Serwer okien nie odróżnia
dymków kart, menu, bąbelków pobierania czy podpowiedzi od prawdziwych okien. Okno jest
**podejrzanym popupem**, gdy: jego aplikacja ma ≥ 2 okna; okno nie ma tytułu (bez Screen Recording
żadne nie ma); istnieje inne okno tej samej aplikacji na **tym samym obszarze**, co najmniej
dwukrotnie większe powierzchniowo, a część wspólna obejmuje ≥ **85 %** powierzchni podejrzanego.
Podejrzany jest usuwany tylko jeśli AX go nie „poręczył” jako standardowe okno **i** jego
aplikacja ani teraz, ani nigdy wcześniej (`everListedPIDs`) nie wymieniła żadnego okna przez AX.
(Aplikacja, która wymienia okna – np. terminal – po prostu pomija te z innych obszarów; zgadywanie
geometrią wyrzucałoby mały terminal leżący na dużym.)

Krok 4 – filtr „duchów” zastępczy: tylko gdy sprawdzanie ordered-in jest niedostępne. Wtedy
na bieżącym obszarze AX jest autorytatywne: okno bez elementu AX, na bieżącym obszarze, z
aplikacji, która odpowiada na AX, jest usuwane.

Kolejność pierwszego wypełnienia: grupowanie po identyfikatorze obszaru, potem po id okna
(≈ kolejność utworzenia); okna bez obszaru na końcu. Diagnostycznie logowane są aplikacje, które
mają okno na bieżącym obszarze, a AX nadal go nie widzi („AX blind on active space”).

#### 1.3 Dane każdego okna (`ManagedWindow`)

| Pole | Znaczenie |
|---|---|
| `id` | numer okna serwera, klucz |
| `element` | uchwyt AX lub brak (okno z nieodwiedzonego obszaru nie ma go, dopóki obszar nie zostanie odwiedzony) |
| `pid` | proces właściciela |
| `appName`, `bundleID` | nazwa i identyfikator aplikacji |
| `title` | tytuł (może być pusty; wtedy wyświetlana jest nazwa aplikacji) |
| `isMinimized` | czy zminimalizowane |
| `spaceID` | obszar okna (pierwszy z listy obszarów, na których serwer je widzi) |

Klucz trwałości kolejki między uruchomieniami to `bundleID (albo appName) + tytuł` (części o
modelu). Równość okien dla celów odświeżania UI: id, tytuł, zminimalizowanie, obszar.

#### 1.4 Scalanie z kolejką (`reconcile`)

- Kolejność istniejących okien jest zachowana. Okna, których już nie ma, znikają.
- Dla okna, które nadal istnieje: jeśli nowe odczytanie nie ma obszaru/elementu/tytułu, zostają
  poprzednie wartości (AX widzi tylko bieżący obszar, więc to, czego się nauczyliśmy, gdy okno
  było widoczne, jest zachowywane).
- **Nowe okna** wstawiane są tuż **za zaznaczonym** oknem (jak w kafelkowym WM obok
  sfokusowanego klienta), a gdy nic nie jest zaznaczone – na końcu.
- Wyjątek: gdy pokazany jest pusty slot, pierwsze nowe okno leżące na obszarze slotu (albo bez
  obszaru – traktowane jak bieżący) zajmuje miejsce slotu, staje się zaznaczone, slot znika, a
  okno przez 0,8 s jest oznaczone jako „właśnie wypełniło slot” (dla animacji paska).
- Dalsze skutki (grupy, kafelki, maksymalizacja, auto-sortowanie, zaznaczenie po zniknięciu okna)
  opisane są w części o modelu.

#### 1.5 Wyzwalacze odświeżania

| Wyzwalacz | Reakcja |
|---|---|
| Start enumeratora | odczyt stanu obszarów + pełne odświeżenie |
| Timer co **3,0 s** | pełne odświeżenie (łapie to, czego nie zgłosiły powiadomienia) |
| Timer co **0,4 s** | odczyt stanu obszarów (1.8); gdy coś się zmieniło → odświeżenie z opóźnieniem |
| Powiadomienia AX okna: utworzenie, zniszczenie elementu, zmiana fokusu okna, zmiana tytułu, minimalizacja, deminimalizacja | odświeżenie z opóźnieniem |
| Uruchomienie aplikacji | rejestracja obserwatora + odświeżenie z opóźnieniem; po **2 s** ponowna rejestracja (świeżo uruchomiona aplikacja przyjmuje rejestrację, ale nic nie dostarcza, dopóki jej AX nie wstanie) i odczyt jej sfokusowanego okna |
| Zakończenie aplikacji | wyrejestrowanie, zapomnienie flag AX, odświeżenie z opóźnieniem |
| Aktywacja aplikacji | rejestracja obserwatora (jeśli brak), ponowne włączenie AX przy następnym odświeżeniu, adopcja jej sfokusowanego okna (1.6), odświeżenie z opóźnieniem |
| Zmiana aktywnego obszaru (powiadomienie systemowe) | natychmiastowy odczyt stanu obszarów + odświeżenie z opóźnieniem |
| Otwarcie ustawień | odświeżenie po 0,3 s (własne okno ustawień ma się pojawić szybko) |
| Zamknięcie okna ustawień | przejście z powrotem w tryb akcesoryjny + natychmiastowe odświeżenie |
| Zamknięcie okna przez WindowQueue | odświeżenia po 0,4 s i 1,2 s |
| Przeniesienie okien na obszar | odświeżenie po 0,3 s |
| Pozycja menu „Refresh windows”, polecenie debugowe `refresh` | natychmiastowe odświeżenie |

„Odświeżenie z opóźnieniem” = **debounce 0,15 s**: każde kolejne żądanie anuluje poprzednie
zaplanowane. Obserwatory AX są rejestrowane dla każdej aplikacji z 1.1 przy starcie (oprócz
własnego procesu).

Powiadomienia **przesunięcia** i **zmiany rozmiaru** okna nie odświeżają kolejki – są
przekazywane dalej jako zdarzenia geometrii:
- zmiana rozmiaru → `onWindowResized` (strażnik krawędzi, sekcja 8) i `onWindowFrameChanged`
  (ponowne kafelkowanie, część o kafelkach);
- przesunięcie → `onWindowSettled` (strażnik zapamiętuje położenie) i `onWindowFrameChanged`;
- zmiana fokusu okna → także `onWindowSettled` (ale *nie* `onWindowFrameChanged` – fokus to nie
  ruch).

#### 1.6 Przejmowanie zewnętrznej zmiany fokusu do zaznaczenia

Gdy użytkownik sam (klik, Cmd-Tab, inny program) zmieni fokus, zaznaczenie w kolejce ma pójść
za nim, **bez** pokazywania dymka z tytułem (`announce: false`). Zasady:
1. Jeśli WindowQueue właśnie prowadzi okno do fokusu (`WindowFocuser.pendingTargetID` ustawione)
   i zgłoszone okno jest **inne** – ignoruj (aplikacja w trakcie przejścia chwilowo zgłasza stare
   okno i ściągnęłaby zaznaczenie z powrotem).
2. Jeśli okna jeszcze nie ma w kolejce (nowe okno bierze fokus zanim enumeracja je zobaczy) –
   zapamiętaj jego id jako oczekujące; po następnym scaleniu, gdy okno już jest, zaznacz je (o ile
   w międzyczasie nie zaczęło się fokusowanie innego okna). Pamiętane jest tylko ostatnie.
3. Jeśli pokazany jest pusty slot, a zgłoszone okno leży na **innym** obszarze niż slot –
   ignoruj (okno właśnie wysłane z pustego obszaru może nadal trzymać fokus aplikacji; nie może
   zabrać zaznaczenia ze slotu, na który patrzy użytkownik).
4. W przeciwnym razie – zaznacz.

#### 1.7 Nowe okna – podsumowanie zachowania

Nowe okno pojawia się w kolejce najpóźniej po ~0,15 s od powiadomienia AX (lub do 3 s, jeśli
aplikacja nie powiadamia), tuż za zaznaczonym oknem albo w miejscu pustego slotu; jeśli wzięło
fokus, zostaje zaznaczone. Okna aplikacji właśnie uruchomionej mogą przyjść dopiero przy
ponownej rejestracji po 2 s albo przy timerze 3 s.

#### 1.8 Stan obszarów w modelu (`refreshSpaceState`)

Czytane: bieżący obszar ekranu z paskiem, jego numer, czy jest pełnoekranowy, kolejność
wszystkich obszarów. Model dostaje **tylko zmienione** wartości (każde przypisanie przerysowuje
pasek). Najpierw kolejność (z niej liczony jest pusty slot), potem bieżący obszar. Gdy zmienił się
bieżący obszar → callback `onActiveSpaceChanged` (używany do „trzymania” obszaru, 2.8).

Poller 0,4 s dodatkowo porównuje „co pokazuje każdy ekran” (numer obszaru / pełny ekran per
wyświetlacz); jeśli zmieniło się tylko to (np. drugi monitor przeszedł na inny obszar), wymusza
przerysowanie pasków bez pełnego odświeżenia. Po co poller: przełączenie obszaru samym serwerem
okien oraz dodanie/usunięcie/przestawienie obszarów w Mission Control nie generują żadnego
powiadomienia.

Numery obszarów okien są też aktualizowane osobno (`updateSpaces`): tylko rozpoznane obszary
nadpisują zapamiętane; przy zmianie – auto-sortowanie (jeśli włączone) i przeliczenie slotu.

### 2. Obszary robocze

#### 2.1 Topologia i numeracja

- Uwzględniane są tylko **obszary użytkownika** (typ „desktop”); obszary pełnoekranowe (okno
  w trybie pełnoekranowym macOS dostaje własny obszar) nie mają numeru.
- Numeracja 1-based, **w kolejności Mission Control, łącznie przez wszystkie wyświetlacze**:
  najpierw obszary wyświetlacza 1 w kolejności, potem wyświetlacza 2 itd. (tak jak liczy
  Mission Control). Dzięki temu okno na drugim monitorze też ma numer. Ta sama numeracja służy
  skrótom „przełącz na obszar N” i „przenieś na obszar N”, etykietom na pasku i sortowaniu.
- Każdy wyświetlacz ma własny zestaw obszarów i własny obszar bieżący. „Bieżący obszar” modelu to
  obszar wyświetlacza z paskiem = ekran główny (z paskiem menu), a gdy nie da się go dopasować –
  pierwszy.
- „Obszar jest pokazywany” (`isShowing`) = jest bieżący na **którymkolwiek** wyświetlaczu (okno na
  widocznym obszarze drugiego monitora nie wymaga podróży).
- Bieżący obszar jest **pełnoekranowy**, gdy nie należy do listy obszarów użytkownika. Gdy
  topologii nie da się odczytać, przyjmuje się „nie pełnoekranowy” (nieznany stan nigdy nie
  chowa paska). Numer bieżący = brak, gdy pełnoekranowy.
- Dla każdego ekranu dostępna jest para (numer obszaru | brak, czy pełnoekranowy); gdy monitory
  nie mają osobnych obszarów, jest jeden wpis dla wszystkich.
- Obszary tego samego wyświetlacza (`spacesSharingDisplay`) – używane przy wyborze obszaru pod
  układ kafelków (okna mogą iść tylko na obszar tego samego monitora).
- WindowQueue **nigdy nie tworzy ani nie usuwa obszarów** (utworzony z boku obszar nie byłby
  widoczny w Mission Control i rozjechałby numerację).

*macOS:* prywatne SkyLight/CGS: `CGSCopyManagedDisplaySpaces` (wyświetlacze → obszary z typem,
`id64`, `uuid`, „Current Space”), `CGSCopySpacesForWindows` (obszary okna, maska 7 = bieżący +
inne + użytkownika), `SLSWindowIsOrderedIn`. Brak symboli → `isAvailable = false`, funkcje
obszarów wyłączone (w ustawieniach pokazywane jako niedostępne).

#### 2.2 Metody przełączania obszaru

Ustawienie `spaceSwitchMethod` (domyślnie `privateAPI`):

| Metoda | Opis dla użytkownika | Działanie |
|---|---|---|
| `focusWindow` | „Focus a window on that workspace (recommended)” | sfokusuj okno z docelowego obszaru; gdy go brak – skok nośnikiem; gdy niedostępny – skrót systemowy |
| `systemShortcut` | „Send macOS ⌃1…⌃9 shortcut” (wymaga włączenia skrótów „Switch to Desktop N”) | tylko skrót ⌃N (N ≤ 9) |
| `privateAPI` | „Carry an invisible window there” (działa dla pustych obszarów i powyżej 9) | skok nośnikiem; gdy niedostępny – skrót ⌃N |

„Okno do sfokusowania” dla `focusWindow`: spośród okien kolejki na docelowym obszarze, niezminimalizowanych
– zaznaczone, jeśli tam leży, w przeciwnym razie pierwsze w kolejności kolejki. Zostaje zaznaczone i
sfokusowane pełną ścieżką fokusu (3.1, z przeniesieniem kursora zgodnie z preferencją).

Numer spoza zakresu (większy niż liczba obszarów): nie ma identyfikatora docelowego, więc nie ma
weryfikacji; zostaje tylko wysłanie skrótu ⌃N (gdy N ≤ 9).

#### 2.3 Weryfikacja i łańcuch ponowień (`ensureArrived`)

Każda metoda może „po cichu nic nie zrobić”, więc po żądaniu:
1. Zapamiętaj obszar wyjściowy, czas żądania (`lastSpaceRequest`) i zwiększ licznik żądań (nowe
   żądanie – nawet na obszar już widoczny – unieważnia ponowienia starego).
2. Po **0,8 s** (przejście animowane trwa ok. 0,5 s; wcześniejsze sprawdzenie pomyliłoby „w
   trakcie” z „odmową”): jeśli licznik się zmienił – koniec. Odczytaj stan obszarów. Jeśli
   docelowy jest pokazywany – sukces.
3. Jeśli bieżący obszar ≠ wyjściowy (użytkownik lub system poszedł gdzie indziej) – zostaw, nie
   ciągnij go z powrotem.
4. Ponowienie nr 1: skok nośnikiem (a gdy niedostępny – ⌃N). Ponowienie nr 2: ⌃N. Po dwóch
   ponowieniach – log „could not switch” i koniec. Każde ponowienie znów czeka 0,8 s.
Łącznie najwyżej ~2,4 s prób.

#### 2.4 Skok „oknem-nośnikiem” (`SpaceSwitcher.jump`)

Cel: przejść na **dowolny** obszar (także pusty i o numerze > 9) z animacją systemową, bez
skrótów klawiszowych. Idea: proces może umieścić *własne* okno na dowolnym obszarze, a aktywacja
aplikacji sprawia, że macOS animuje przejście do obszaru z jej oknem.

- Nośnik to jedno, stale istniejące okno 1×1 px, przezroczyste (alfa 0,01), bez cienia, bez
  animacji, zwykły poziom, bez żadnego „collection behaviour” (np. `stationary` sprawiłoby, że
  system nie traktuje go jako powodu do zmiany obszaru).
- Sekwencja:
  1. Pokaż nośnik (musi mieć numer okna; jeśli nie – skok niemożliwy, zwróć false).
  2. Zwiększ generację skoku; ustaw „kierunek” = (obszar docelowy, ważny **1,2 s**).
  3. Dodaj nośnik do obszaru docelowego; usuń go ze **wszystkich** innych obszarów, na których
     jest (nośnik zostaje na każdym obszarze, na który go kiedykolwiek wstawiono), oraz
     z obszarów aktualnie pokazywanych (świeży może jeszcze nie być na nich wymieniony). Gdyby
     został na bieżącym, system nie miałby powodu nigdzie iść.
  4. Po **0,1 s** (serwer musi mieć okno na obszarze przed aktywacją), jeśli generacja aktualna:
     aktywuj WindowQueue, zrób nośnik kluczowym i dodatkowo „wypchnij na przód” jego proces
     prywatnym wywołaniem (samo żądanie aktywacji nic nie robi, gdy WindowQueue już jest na
     przodzie – np. gdy skok przejął poprzedni).
  5a. Gdy skok ma kontynuację (fokus okna na tamtym obszarze): po kolejnych **0,15 s** wywołaj
     kontynuację i schowaj nośnik (dalej przejmuje okno fokusowane).
  5b. Bez kontynuacji: po **0,45 s** schowaj nośnik i dezaktywuj WindowQueue – obszar zostaje w
     stanie takim, jak po ręcznym przejściu (bez aktywnej aplikacji na przodzie).
- Liczy się tylko najnowszy skok: starszy nie aktywuje i nie woła kontynuacji (jeden nośnik na
  dwóch obszarach dałby systemowi wybór).
- `SpaceSwitcher.destination` – obszar, do którego skok *może jeszcze jechać*: zwraca cel, gdy
  kierunek nie wygasł (1,2 s) i cel nie jest jeszcze pokazywany; gdy cel już widać – czyści
  kierunek. Używane: (a) fokus okna na obszarze pokazywanym też idzie przez skok, jeśli inny skok
  jest w drodze (żeby nie wylądować później gdzie indziej); (b) wstrzymanie focus-follows-mouse;
  (c) wyłączenie „trzymania” obszaru.

*macOS:* `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces`, `NSApp.activate`,
`_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo`. Bezpośrednie przełączenie obszaru w
serwerze okien istnieje, ale **celowo nie jest używane**: Dock się o nim nie dowiaduje (serwer
raportuje nowy obszar, ekran zostaje na starym).

#### 2.5 Skrót systemowy ⌃N

Syntetyczne naciśnięcie i puszczenie Control + cyfra N (1–9) na poziomie HID. Działa tylko, gdy
użytkownik włączył w systemie „Switch to Desktop N”. Dla N > 9 – nic.

#### 2.6 Fokus okna leżącego na innym obszarze („najpierw podróż, potem podniesienie”)

Aktywacja aplikacji przenosi na jej obszar tylko przy włączonym systemowym „przełącz na obszar z
oknami aplikacji”, a wielu to wyłącza (i WindowQueue potrzebuje tego wyłączonego do sztuczki z
2.10). Dlatego `WindowFocuser.focus`:
- jeśli okno ma znany obszar, który jest obszarem użytkownika (nie pełnoekranowym), **i**
  (obszar nie jest pokazywany **lub** inny skok jest w drodze), wykonuje skok nośnikiem z
  kontynuacją „podnieś okno” (kontynuacja sprawdza token fokusu – nowszy fokus ją unieważnia);
- w przeciwnym razie od razu podnosi okno (3.3).
Dodatkowo pętla weryfikacji (3.4) w próbie nr 3 wysyła ⌃N, jeśli okno nadal jest na
niepokazywanym obszarze. Okno w obszarze pełnoekranowym jest fokusowane bez podróży (aktywacja
aplikacji sama przenosi do jej pełnego ekranu).

#### 2.7 Trzymanie opróżnionego obszaru po zamknięciu ostatniego okna

Kontrakt: użytkownik zamknął okno – nie prosił o podróż. Gdy zamknięte okno było **ostatnim** na
bieżącym obszarze (nie było następcy na tym obszarze), macOS lubi aktywować inną aplikację i –
przy wyłączonym przełączaniu przy aktywacji – potrafi przenieść użytkownika gdzie indziej.
- Po takim zamknięciu ustaw „trzymanie” = (bieżący obszar, ważne **2 s**).
- Przy każdej zmianie bieżącego obszaru (`onActiveSpaceChanged`):
  - trzymanie wygasło → wyczyść;
  - użytkownik prosił o zmianę obszaru w ostatnich **0,5 s** albo w drodze jest skok WindowQueue
    → wyczyść (żądanie użytkownika wygrywa);
  - bieżący ≠ trzymany i trzymany nie jest pokazywany → wyczyść trzymanie i wróć: skok nośnikiem
    na trzymany obszar, a gdy niemożliwy – ⌃N.
Strip po powrocie pokazuje pusty slot tego obszaru.

#### 2.8 Przenoszenie okien między obszarami (`moveWindows(toWorkspace:)`)

Kontrakt: skrót „przenieś na obszar N” wysyła zaznaczone okno – albo wszystkie namierzone okna w
trybie celowania (aiming; tryb się kończy) – na obszar N; **użytkownik przechodzi tam razem z
oknami**.
1. Brak okien, numer poza zakresem, brak mechanizmu lub trwa poprzednie przenoszenie przeciągnięciem
   → nic.
2. Próba **per okno**: prośba do serwera okien o przeniesienie listy okien (kilka równoważnych
   wywołań, bo nie wiadomo, które zwykłej aplikacji wolno użyć). Serwer przenosi asynchronicznie,
   więc do **6 odczytów co 40 ms**; okna nadal nie na miejscu przechodzą dalej. Na macOS 26 dla
   cudzych okien żadne z tych wywołań nie działa (także `SLSSpaceSetCompatID` +
   `SLSSetWindowListWorkspace` — błąd 1006).
3. Zapas **per aplikacja**: przypisanie całej aplikacji do obszaru („Assign To” z Docka) przenosi
   *wszystkie* jej okna, po czym przypisanie jest od razu kasowane (okna zostają, nowe otwierają się
   tam gdzie użytkownik). Stosowane **tylko**, gdy aplikacja nie ma w kolejce innych,
   niezaznaczonych, niezminimalizowanych okien poza obszarem docelowym („bystanders”) – inaczej
   przeciągnęłoby niezwiązane okna. Takie okna przechodzą do kroku 5.
4. Odczyt obszarów wszystkich przenoszonych okien: na docelowym → „przybyłe”, reszta →
   „pozostawione”. Model: przybyłe przenoszone są w kolejce na koniec okien docelowego obszaru
   (albo przed pierwsze okno późniejszego obszaru), z zachowaniem ich wzajemnej kolejności.
5. Zapas **przeciągnięcia** dla pozostawionych (`WindowDragMover`): okno trzymane symulowaną myszą
   za pasek tytułu podczas przełączenia obszaru jedzie razem z nim — tak macOS natywnie przenosi
   pojedyncze okno. Szczegóły kroków i czasów: rozdział „Akcje”, §8.1. Nie działają na macOS 26:
   `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` (błąd 1006) ani minimalizacja (okno wraca na
   swój dawny obszar).
6. Pierwsze okno, które dotarło, zostaje zaznaczone i sfokusowane, co przenosi użytkownika na obszar
   docelowy (jeśli krok 5 go tam jeszcze nie przeniósł).
7. Dymek: przy pozostawionych „<Aplikacja> stayed where it was[ and K more]” / „It could not be
   moved to workspace N”; w przeciwnym razie tytuł okna (lub „N windows”) + „Moved to workspace N”.
8. Odświeżenie po 0,3 s.

#### 2.9 Ściągnięcie jednego okna na bieżący obszar (`pullToCurrentSpace`)

Używane przy zbieraniu okien pod układ kafelków (0,9 s po przejściu na obszar docelowy, dla
okien, które nie przyjechały). Działa tylko przy **wyłączonym** systemowym „przy przełączaniu na
aplikację przejdź na obszar z jej oknami” (`com.apple.dock workspaces-auto-swoosh`, domyślnie
włączone): wtedy aktywacja aplikacji ściąga jej *sfokusowane* okno do użytkownika. Sekwencja:
okno już tu → sukces; ustaw okno jako główne/sfokusowane w aplikacji przez AX, aktywuj aplikację,
potem do **10 odczytów co 60 ms**, czy okno jest na bieżącym obszarze. Wynik jest zwracany
(pozostałe okna aplikacji zostają na miejscu).

#### 2.10 Obszar nakładkowy (`OverlaySpace`)

Kontrakt: pasek i wszystkie panele WindowQueue (dymek, podświetlenie celowania, panel akcji,
panel grupy, menu kafelków, podgląd kafelka) **nie biorą udziału w animacji przejścia między
obszarami** – obszary przesuwają się pod nimi, a one stoją w miejscu, także nad obszarami
pełnoekranowymi. *macOS:* prywatny obszar tworzony przez serwer okien (`CGSSpaceCreate` z flagą 1,
poziom absolutny 100, `CGSShowSpaces`), do którego każdy panel jest dodawany po pierwszym
pokazaniu. Brak symboli → panele zostają przy zwykłym „na wszystkich obszarach” (miganie przy
przejściu).

### 3. Fokusowanie okna

#### 3.1 Wejście: fokus z WindowQueue (`AppDelegate.focus`)

Wołane przy wyborze okna z paska, cyklowaniu skrótami, wyszukiwarce, przełączaniu obszaru metodą
`focusWindow`, poleceniu debugowym `focus`. Kroki:
1. `WindowFocuser.focus(window, numer obszaru okna, liczba okien tej aplikacji w kolejce,
   warpCursor)` – `warpCursor` = parametr (domyślnie tak; **nie** dla kliknięcia na pasku, panelu
   grupy ani przewijania kółkiem) **i** preferencja `warpCursorToWindow` (domyślnie włączona).
2. **Podniesienie układu**: jeśli okno należy do grupy skafelkowanej, podnieś pozostałe okna
   tej grupy leżące na **tym samym** obszarze, a na końcu jeszcze raz samo okno (ma zostać na
   wierzchu). Okna z innych obszarów się nie rusza.
3. **Błysk fokusu** (preferencja `flashFocusedWindow`, domyślnie tak, czas domyślnie **0,15 s**):
   obrys okna w kolorze zaznaczenia. Rysowany, dopiero gdy okno jest na bieżącym obszarze i ma
   odczytywalną ramkę; sprawdzane co 0,1 s, najwyżej 20 razy (2 s), przerwane, gdy włączy się
   celowanie lub okno zniknie.

Przewijanie kółkiem nad paskiem przesuwa zaznaczenie od razu, a fokus odkłada o
`scrollFocusDelay` (domyślnie **0,5 s**; każde kolejne przewinięcie przesuwa termin) – żeby
kręcenie nie odpaliło serii aktywacji i przejść między obszarami.

#### 3.2 `WindowFocuser.focus` – kontrakt

- Nowe żądanie unieważnia poprzednie (token). Ustawiane jest `pendingTargetID` = okno docelowe
  (patrz 1.6) i budżet naciśnięć „cyklu okien aplikacji” = **2 × (liczba okien aplikacji − 1)**.
- Jeśli `warpCursor`: kursor od razu na środek okna (ramka znana z serwera okien także dla okien
  z innych obszarów), razem z naciśnięciem, a nie po potwierdzeniu.
- Potem podróż (2.6) albo od razu `bringForward`: jeśli jest element AX i przyjął podniesienie
  (3.3) – koniec tego kroku; w przeciwnym razie aktywacja aplikacji. Następnie pętla weryfikacji.

#### 3.3 Podniesienie przez element

Kolejno: gdy było zminimalizowane → odminimalizuj; ustaw jako główne (`AXMain`); ustaw
sfokusowane (`AXFocused`); akcja `AXRaise`; ustaw jako sfokusowane okno aplikacji; ustaw
aplikację na przodzie (`AXFrontmost`). Wynik = czy akcja raise się powiodła (zapamiętany element
potrafi się „zestarzeć”, gdy aplikacja odtworzy okno – wtedy wszystkie wywołania cicho zawodzą).
Aktywacja zastępcza: `NSRunningApplication.activate()` + `AXFrontmost = true` (sama publiczna
aktywacja bywa ignorowana dla procesu akcesoryjnego).

#### 3.4 Pętla weryfikacji

Maksymalnie **20 prób co 0,1 s** (~2 s). W każdej próbie (jeśli token aktualny):
1. Sukces wstępny, gdy **aplikacja okna jest na przodzie** i jej sfokusowane okno == docelowe
   (samo „sfokusowane okno aplikacji” nie wystarcza: spóźniona aktywacja z wcześniejszego
   naciśnięcia może wynieść inną aplikację). → potwierdzenie (3.5).
2. Aplikacja bez listy okien **i** bez sfokusowanego okna (Spotify, niektóre Chromium), będąca na
   przodzie, od próby nr **3** → uznaj za zakończone (nie ma jak potwierdzić; dalsze próby tylko
   walczyłyby z użytkownikiem).
3. W próbie nr **3**: jeśli okno jest na obszarze użytkownika, który nadal nie jest pokazywany, a
   numer obszaru jest znany → wyślij ⌃N.
4. Jeśli okno jest na liście okien AX aplikacji → podnieś je (3.3), a gdy odmówi – aktywuj
   aplikację. Jeśli go nie ma i próba ≥ 3 → aktywuj aplikację i wykonaj jedno naciśnięcie cyklu
   okien (3.6).
5. Następna próba.
Po 20 próbach – `finish` bez przeniesienia kursora.

#### 3.5 Potwierdzenie

**0,25 s** po wstępnym sukcesie sprawdź ponownie (spóźniona aktywacja z poprzedniego żądania
potrafi zabrać fokus). Nadal OK → `finish`. Inaczej: log „focus of X was taken back; retrying”,
ponowne podniesienie (lub aktywacja) i wznowienie pętli od próby nr 4.

`finish`: czyści `pendingTargetID` i budżet cyklu. Jeśli fokus miał przenosić kursor: po
**0,15 s**, jeśli kursor nie jest wewnątrz aktualnej ramki okna (okno mogło się przesunąć, np. przy
odminimalizowaniu), przenieś go ponownie na środek; kursor już na oknie zostaje.

#### 3.6 Cykl okien aplikacji jako zapas

Dla aplikacji, które nie wystawiają listy okien AX (Chrome bez trybu rozszerzonego), jedyną drogą
do konkretnego okna jest ich własny skrót „następne okno aplikacji” (**Cmd + `**). Wysyłany
tylko, gdy aplikacja jest na przodzie i budżet > 0; każde naciśnięcie zmniejsza budżet.
Weryfikacja kończy się w chwili, gdy sfokusowane okno to docelowe.

#### 3.7 Przeniesienie kursora

Kursor na środek ramki okna w globalnych współrzędnych ekranu; po przeniesieniu ponownie
związać ruch myszy z kursorem (macOS po warpie chwilowo „odwiązuje”).

#### 3.8 Fokus bez podnoszenia (`focusWithoutRaising`)

Kontrakt: okno dostaje klawiaturę tam, gdzie leży, **bez zmiany kolejności stosu** (dla
focus-follows-mouse). *macOS:* brak publicznego API; sekwencja jak w yabai/AutoRaise:
1. Jeśli aplikacja okna już jest na przodzie i ma sfokusowane *inne* swoje okno: wyślij temu
   oknu rekord „resign key”, a docelowemu „become key”.
2. Wypchnij proces na przód w trybie „user generated” (`kCPSUserGenerated`, bez żądania
   wysunięcia okien; tryb „no windows” zostawia aplikację półaktywną).
3. Wyślij parę rekordów „make key window” dla okna.
4. Dodatkowo przez AX: `AXFocused = true` na oknie i ustaw je jako sfokusowane okno aplikacji
   (niektóre aplikacje, np. Ghostty, ignorują syntetyczne rekordy). Bez `AXRaise`.
Zwraca false, gdy brakuje prywatnych symboli → wywołujący robi zwykły fokus. Diagnostycznie po
0,3 s logowany wynik („hover result: ok/MISSED”).

Pokrewne: `bringToFront(pid, windowID)` – kroki 2+3 (używane przy skoku nośnikiem);
`isFocused(window)` – aplikacja na przodzie i jej sfokusowane okno == to okno.

### 4. Focus follows mouse (`FocusFollowsMouse`)

Preferencje: `focusFollowsMouse` (domyślnie **włączone**), `focusFollowsMouseDelay` (domyślnie
**0,05 s**), `focusFollowsMouseRaises` (domyślnie **wyłączone** – fokus bez podnoszenia).

Kontrakt:
1. Każdy ruch myszy (globalny monitor ruchu) anuluje oczekujące sprawdzenie i planuje nowe po
   czasie `focusFollowsMouseDelay` – czyli fokus następuje dopiero, gdy kursor **się zatrzyma**
   (przejazd przez stos okien nie fokusuje każdego po drodze).
2. W chwili sprawdzenia nic nie robić, jeśli: funkcja wyłączona; tryb „zawieszony” – trwa
   celowanie (aiming), otwarta wyszukiwarka, albo skok na obszar jest w drodze (to, co przesuwa się
   pod kursorem podczas animacji, nie jest celem użytkownika); wciśnięty jakikolwiek przycisk
   myszy; wciśnięty jakikolwiek modyfikator.
3. Okno pod kursorem: przeglądaj okna na ekranie od przodu do tyłu, pomijając elementy pulpitu
   i okna o alfie 0; pierwsze zawierające punkt musi mieć warstwę 0 – jeśli jest to cokolwiek
   innego (pasek WindowQueue, pasek menu, Dock, popup) → brak okna. Jeśli **gdziekolwiek** na
   ekranie jest otwarte menu (okno na poziomie menu kontekstowych/rozwijanych) → brak okna.
4. Okno musi być w kolejce, nie należeć do WindowQueue i nie być zminimalizowane. Jeśli to już
   zaznaczone okno, a jego aplikacja jest na przodzie → nic.
5. Zaznacz okno (bez dymka) i sfokusuj je **bez przenoszenia kursora**:
   - jeśli `focusFollowsMouseRaises` wyłączone i fokus bez podnoszenia się powiódł: po **0,3 s**,
     jeśli funkcja nadal włączona, okno *nie* ma klawiatury, a kursor nadal jest nad tym oknem →
     log „hover focus did not land…; raising it” i pełny fokus z podniesieniem (pisanie tam, gdzie
     jest kursor, jest ważniejsze niż nienaruszony stos);
   - w przeciwnym razie – pełny `WindowFocuser.focus` (bez numeru obszaru, z liczbą okien
     aplikacji).

### 5. Zamykanie okna (`WindowCloser` + `AppDelegate.close`)

Wywoływane skrótem „zamknij zaznaczone okno”, przyciskiem zamknięcia na pasku/panelu grupy, dla
namierzonych okien w trybie celowania.

Przed zamknięciem (AppDelegate):
- Wyznacz następcę: jeśli okno jest na bieżącym obszarze – najbliższe w kolejce okno **tego
  samego obszaru**; w przeciwnym razie – sąsiad w kolejce. Po zleceniu zamknięcia zaznacz
  następcę (bez fokusowania go; selekcja nie ma wracać na początek kolejki).
- Brak następcy na bieżącym obszarze → trzymanie obszaru (2.7).
- Odświeżenia po 0,4 s i 1,2 s (system może przenieść inne okno na opróżniony obszar).

`WindowCloser.close`:
1. Jeśli okno ma element AX z przyciskiem zamknięcia i jego „press” się powiódł → koniec (okno nie
   musi być sfokusowane ani widoczne).
2. W przeciwnym razie: sfokusuj okno (pełna ścieżka 3.2, z numerem obszaru i liczbą okien
   aplikacji) i ponawiaj co **0,12 s**, maks. **12 prób** (~1,4 s): znajdź okno na liście AX
   aplikacji i naciśnij jego przycisk zamknięcia.
3. W ostatniej próbie, jeśli aplikacja okna jest na przodzie: wyślij **Cmd+W** tylko gdy jej
   sfokusowane okno to docelowe **albo** (nie da się ustalić sfokusowanego okna **i** aplikacja ma
   ≤ 1 okno w kolejce). Inaczej nie wysyłaj (log „has another window focused; not sending ⌘W”) –
   Cmd+W zamknąłby niewłaściwe okno.

### 6. Globalne skróty (`HotkeyManager`)

Kontrakt:
- Każda akcja (`HotkeyAction`) ma jedną kombinację (klawisz + modyfikatory), konfigurowalną.
  Domyślne kombinacje używają modyfikatora „super” (domyślnie **Option/Alt**) – tabela akcji i
  domyślnych kombinacji jest w części o ustawieniach; tu tylko zasady: przełącz na obszar N =
  super+N (1–9), przenieś na obszar N = super+Shift+N.
- Skrót jest **przechwytywany** (nie trafia do aplikacji na przodzie) i działa globalnie, bez
  względu na to, która aplikacja ma fokus.
- Akcja jest wykonywana na wątku głównym, asynchronicznie. Każde wywołanie akcji najpierw
  anuluje wykrywanie „stuknięcia” samego modyfikatora super (przechwycenie klawisza sprawia, że
  detektor nie widzi, co przerwało stuknięcie).
- **Błędy rejestracji** (kombinacja zajęta przez inną aplikację/system) są zbierane per akcja i
  pokazywane w ustawieniach na czerwono: „Could not register: <tytuły akcji>. Another app probably
  owns those shortcuts.”
- **Ponowna rejestracja tylko przy zmianie kombinacji.** Każda zmiana preferencji (także
  niezwiązana ze skrótami, np. suwak) przechodzi przez `apply`, a wyrejestrowanie+rejestracja
  zostawia chwilę bez skrótów – klawisz wciśnięty wtedy wpisałby znak w aplikacji na przodzie (np.
  „ś” dla Option+S). Dlatego porównuje się słownik akcja→kombinacja z ostatnio zastosowanym;
  identyczny → nic nie ruszać. Przy zmianie: wyrejestruj wszystko, wyczyść błędy, zarejestruj
  wszystkie akcje od nowa.
- W trybie celowania (aiming) i w wyszukiwarce klawiatura jest przechwytywana osobnym
  mechanizmem (część o celowaniu); te same kombinacje działają tam także bez modyfikatora.

*macOS:* Carbon `RegisterEventHotKey` + jeden handler zdarzeń `kEventHotKeyPressed` (sygnatura
`'WQKE'`, id per rejestracja); nie wymaga uprawnień poza Accessibility.

### 7. Rezerwacja miejsca na pasek (`DockReservation`)

Kontrakt: gdy włączone `reserveScreenSpace` (domyślnie tak), okna maksymalizowane/„wypełniające”/
kafelkowane systemowo mają zostawiać wolny pas przy krawędzi paska, jak przy Docku.

Szerokość rezerwacji (`reservedWidth`) = zaokrąglona w górę grubość paska + 2 × margines paska
(`stripMargin`, domyślnie 4); **0**, gdy pasek jest w trybie niewidzialnym (pojawia się tylko przy
celowaniu).

Warunki instalacji (wszystkie): `reserveScreenSpace`; pasek nie ukryty (`stripDisplay != hidden`);
nie tryb niewidzialny; **Dock systemowy ma włączone autoukrywanie** (widoczny Dock potrzebuje swojej
rezerwacji bardziej). Dotyczy tylko ekranu z paskiem menu (jeden prostokąt na system). Dla
pozostałych ekranów i przypadków działa strażnik krawędzi (sekcja 8).

Geometria prostokąta (współrzędne z początkiem w lewym górnym rogu ekranu menu, wysokość paska
menu = różnica między ramką ekranu a obszarem widocznym u góry): lewa – (0, menu, szer., wys.−menu);
prawa – (W−szer., menu, szer., wys.−menu); góra – (0, menu, W, szer.); dół – (0, H−szer., W, szer.);
orientacja zgodna z krawędzią; „powód” = pokazany.

Cykl życia:
- **Start:** jeśli na dysku jest zapisany oryginał z poprzedniego uruchomienia (crash) i bieżący
  prostokąt „wygląda na nasz” → przywróć oryginał. Wymuś, by WindowQueue sam odczytał obszar
  widoczny ekranu *przed* instalacją (inaczej pasek liczyłby swoją rezerwę podwójnie). Potem
  `update`, timer co **2 s** i reakcja na zmianę parametrów ekranów.
- **`update`:** gdy aktywne wstrzymanie – nic. Jeśli bieżący prostokąt ≠ nasz zainstalowany, to
  jest najnowszym słowem Docka → zapisz go jako oryginał (chyba że wygląda na nasz i nic nie było
  zainstalowane). Gdy rezerwacja niepożądana → przywróć. Gdy pożądana i różna od bieżącej →
  zapisz oryginał (jeśli brak), zapisz nasz prostokąt, zapamiętaj jako zainstalowany. Wywoływane
  też po każdej zmianie preferencji (w następnym obiegu pętli).
- **„Wygląda na nasz”:** powód = pokazany, a Dock ma autoukrywanie (Dock ukryty nigdy nie
  raportuje „pokazany”).
- **Przywrócenie:** przy normalnym zakończeniu, przy sygnałach **SIGTERM, SIGINT, SIGHUP**
  (przechwycone; po przywróceniu `exit(0)`), i gdy rezerwacja przestaje być pożądana. Przywraca
  tylko, jeśli bieżący jest nasz. Oryginał jest trwale zapisany w preferencjach
  (`dockReservation.originalRect.v1`), zanim nasz zostanie wpisany.
- **Wstrzymanie (`suspend(d)`):** przywraca prostokąt Docka na d sekund (i +0,1 s później
  `update`), żeby aplikacja uruchamiana w tym czasie przeczytała prawdziwy ekran (Rectangle).
- **Ograniczenia:** aplikacje czytają wartość przy starcie i przy ogłoszeniu zmiany przez Dock;
  aplikacje już uruchomione jej nie widzą, a każda zmiana geometrii Docka ją nadpisuje (stąd
  timer 2 s).
- **`unreservedFrame(screen)`:** obszar widoczny ekranu z *oddaną* naszą rezerwą – do układania
  paska i liczenia miejsca na kafelki. Oddawane tylko na ekranie menu, gdy rezerwacja jest
  zainstalowana **i** obszar widoczny faktycznie ją zawiera (odległość od krawędzi ≥ szer. −
  0,5 px; dla góry: ≥ pasek menu + szer.). Bez tego sprawdzenia pasek skakałby przy
  podłączaniu/odłączaniu monitorów.

*macOS:* prywatne `SLSGetDockRectWithOrientation` / `SLSSetDockRectWithOrientation`,
`CoreDockGetAutoHideEnabled`.

### 8. Strażnik krawędzi (`ScreenEdgeGuard`)

Kontrakt: gdy okno zostanie **zmienione rozmiarem** przez system tak, że przylega do krawędzi
paska (zoom podwójnym kliknięciem tytułu, „Fill”, wbudowane kafelkowanie), przytnij je, by
zaczynało się obok paska – ten sam efekt co rezerwacja, jedną klatkę później. Włączony gdy
`reserveScreenSpace` **i** `trimWindowsOutsideReservation` (domyślnie tak) **i** pasek nie ukryty.

1. Każde zdarzenie zmiany rozmiaru okna (nie w czasie naszego ustawiania – patrz 6.) planuje
   korektę po **0,3 s** (debounce per okno; animacja zoomu raportuje kilka rozmiarów).
2. Korekta: jeśli wciśnięty przycisk myszy (użytkownik ciągnie krawędź) → zaplanuj ponownie.
   Pomiń, gdy okno nie jest standardowe, gdy jego ramka równa się ramce całego ekranu (prawdziwy
   pełny ekran; zoom kończy się pod paskiem menu), gdy okno ustawił sam WindowQueue (kafelki,
   maksymalizacja – ramka zgodna z zapamiętaną ±2 px).
3. Ekran okna = zawierający środek okna, inaczej ten o największej części wspólnej. Krawędź
   paska liczona od `unreservedFrame` przesuniętego o szerokość rezerwy. Przycinanie tylko, gdy
   brzeg okna leży w odległości ≤ **2 px** od krawędzi obszaru widocznego po stronie paska **i**
   okno sięga dalej niż krawędź + szerokość (jest wystarczająco duże). Lewa/góra: przesuń początek
   na krawędź i zmniejsz; prawa/dół: zmniejsz.
4. **Odwrócenie zoomu:** aplikacja nie wie, że jej zoom przycięto, więc ponowny zoom (by wyjść)
   znów robi zoom. Jeśli okno było przycięte, jego ostatnia znana ramka to ta przycięta, a
   przyszedł kolejny zoom → przywróć ramkę sprzed pierwszego zoomu.
5. **Ustawianie ramki:** tymczasowo wyłącz tryb rozszerzonego AX aplikacji (inaczej AppKit
   animuje); ustaw pozycję, potem rozmiar; jeśli wynik się nie zgadza – rozmiar, pozycja, rozmiar
   (kolejność Rectangle, dla aplikacji przycinających rozmiar do starej pozycji). Następnie
   sprawdzenia po **0,15 / 0,35 / 0,7 / 1,2 s** od startu: jeśli ramka odjechała (aplikacje
   animujące zoom, terminale przyciągające do siatki znaków) – ustaw ponownie; jeśli użytkownik
   trzyma przycisk myszy – odpuść. Przez 1,2 + 0,5 s zdarzenia ruchu/rozmiaru tego okna są
   ignorowane jako nasze.
6. **Zapamiętywanie ramki** (`windowSettled`, po ruchu lub zmianie fokusu): po **0,4 s**
   bezruchu zapisz ramkę jako „znaną” (do odwrócenia zoomu); klatki pośrednie animacji się nie
   liczą. Ramka różna od przyciętej kasuje rekord przycięcia.
Zwykłe przesunięcia nigdy nie są korygowane.

### 9. Integracja z Rectangle (`RectangleIntegration`)

Kontrakt: jeśli zainstalowany jest menedżer okien Rectangle (`com.knollsoft.Rectangle`), jego
kafelkowanie ma zostawiać miejsce na pasek.
- Zapis do preferencji Rectangle: `screenEdgeGap<Strona>` (Left/Right/Top/Bottom) = szerokość
  rezerwy po stronie paska (0 gdy rezerwacja wyłączona), 0 po pozostałych stronach. Zwraca, czy
  cokolwiek się zmieniło.
- Rectangle czyta te wartości przy starcie, więc zmiana przy uruchomionym Rectangle = restart:
  zakończ go, wstrzymaj rezerwację Docka na **6 s** (Rectangle doda swoją przerwę do obszaru
  widocznego; nie może on już zawierać paska), po **1 s** uruchom ponownie – ukryty, bez
  aktywacji, bez dodawania do „ostatnich”.
- Zastosowanie: przy starcie oraz po zmianach preferencji z **debounce 1 s** (nie restartować
  przy każdym kroku suwaka); także przy przełączaniu trybu niewidzialnego paska; w ustawieniach
  jest przycisk ręcznego zastosowania i restartu z komunikatem o wyniku.
- Gdy Rectangle uruchomi się sam (np. przy logowaniu), a rezerwacja Docka jest zainstalowana i to
  nie WindowQueue go restartuje → restart po 1 s (przeczytał ekran z już odjętym paskiem).
- `clear()` zeruje wszystkie cztery wartości.

### 10. Uprawnienia i sekwencja startowa

Uprawnienia macOS:
- **Accessibility (wymagane)** – każde wywołanie AX, syntetyczne klawisze (⌃N, Cmd+`, Cmd+W),
  globalne monitory zdarzeń. Przy starcie jednorazowy systemowy monit, potem sprawdzanie co
  **1 s** do skutku; dopiero po przyznaniu startuje enumeracja i pasek. Przycisk w ustawieniach
  otwiera odpowiedni panel ustawień systemu.
- **Screen Recording (opcjonalne)** – tylko po to, by znać tytuły okien z nieodwiedzonych
  obszarów (i dla funkcji nagrywania/zrzutów). Ustawienia pokazują stan i przycisk proszący
  o dostęp/otwierający panel.

Sekwencja startu:
1. Rezerwacja Docka: start (w tym naprawa po crashu), przechwycenie sygnałów, obserwacja
   uruchomień aplikacji dla Rectangle.
2. Log „launch: trusted=… windowIDs=… spaces=…”.
3. Ikona w pasku menu z menu: „Settings…” (,), „Sort queue by workspace” (s), „Refresh windows”
   (r), separator, „Quit WindowQueue” (q). Ponowne „otwarcie” aplikacji (Spotlight/Finder) otwiera
   ustawienia.
4. Model dostaje zakres i auto-sortowanie; subskrypcja preferencji: przy każdej zmianie –
   zakres, auto-sortowanie, modyfikator super, skróty (6), element logowania (11), rezerwacja Docka
   (7); z debounce 1 s – Rectangle (9).
5. Budowa UI (wyszukiwarka, dymki, pasek, panele), detektor stuknięć modyfikatora super,
   focus-follows-mouse (start od razu), obsługa klawiszy celowania.
6. Handler skrótów, polecenia debugowe (jeśli włączone), rejestracja skrótów, zastosowanie
   Rectangle.
7. Czekanie na Accessibility; po przyznaniu: przywrócenie zapisanej kolejności przy pierwszym
   niepustym stanie kolejki (i od tej pory zapisywanie), utworzenie strażnika krawędzi i
   enumeratora, podpięcie zdarzeń geometrii i `onActiveSpaceChanged`, start enumeratora, start
   paska.
Zakończenie: przywrócenie prostokąta Docka.

### 11. Uruchamianie przy logowaniu (`LoginItem`)

- Preferencja `launchAtLogin`, domyślnie **włączona**, stosowana idempotentnie przy każdej
  zmianie preferencji i przy starcie.
- Tylko dla kopii zainstalowanej w `/Applications/`; kopia z katalogu budowania ma stan
  „notInstalled” (przełącznik wyłączony w ustawieniach) – rejestracja startowałaby przestarzałą
  wersję.
- Stany: włączone, wyłączone, wymaga zatwierdzenia (ustawienia pokazują przycisk „Open Login
  Items”), niezainstalowane. Błędy rejestracji tylko logowane.
*macOS:* `SMAppService.mainApp.register()/unregister()`.

### 12. Diagnostyka i polecenia debugowe

Katalog: `~/Library/Logs/WindowQueue/`.

| Plik | Kiedy | Zawartość |
|---|---|---|
| `events.log` | **zawsze** (dopisywanie) | linie `[data] komunikat`: start, przyznanie uprawnień, zaznaczenia, fokusy, weryfikacje, skoki, przełączenia, trzymanie obszaru, zamknięcia, edge guard, Dock, Rectangle, mover, polecenia debugowe; część komunikatów tylko przy włączonej diagnostyce |
| `diagnostics.txt` | przy włączonej diagnostyce, nadpisywany po każdym odświeżeniu | stan: zaufanie AX, dostępność numerów okien i API obszarów, liczba obszarów, bieżący obszar i numer, zakres, liczba okien w kolejce/widocznych; lista kolejki (nr, id, obszar, pid, zminimalizowane, aplikacja — tytuł); lista okien serwera (warstwa 0, ≥ 200×200: id, rozmiar, obszar, ordered-in, właściciel); per aplikacja: wynik/liczba okien AX kilkoma metodami, liczba okien w serwerze, ukryta, sfokusowane okno, a pod spodem okna AX (id, rola, subrola, tytuł) |
| `state.txt` | polecenie `dump` | czas; bieżący obszar i numer; kolejność obszarów; zaznaczenie; celowanie i kotwica; pusty slot; auto-sort; aplikacja na przodzie i jej sfokusowane okno; pozycja kursora; per okno: id, numer obszaru, obszar w modelu i w serwerze, zminimalizowane, czy ma element, pid, aplikacja, tytuł |

Włączanie: `defaults write com.mpochec.windowqueue diagnostics -bool true`.

Polecenia debugowe (do testów skryptami bez syntetycznych klawiszy): włączane
`defaults write com.mpochec.windowqueue debugCommands -bool true`; przychodzą jako rozproszone
powiadomienie `com.mpochec.windowqueue.command`, którego obiekt to linia tekstu dzielona spacjami:

| Polecenie | Działanie |
|---|---|
| `action <nazwa>` | wykonaj akcję skrótu (surowa nazwa `HotkeyAction`, np. `cycleNext`, `space3`, `moveToSpace2`) |
| `aim` | jak stuknięcie modyfikatora super (otwórz/zatwierdź celowanie) |
| `aimkey <klawisz> [shift] [move]` | klawisz w trybie celowania: `up down left right back forward enter space cancel`; `shift` = rozszerz, `move` = przesuń; tylko gdy celowanie trwa |
| `focus <id okna>` | zaznacz (z dymkiem) i sfokusuj okno |
| `refresh` | pełne odświeżenie |
| `dump` | zapisz `state.txt` |

Każde polecenie jest logowane („debug command: …”).

### Odpowiedniki w GNOME

**Architektura.** Implementacja powinna być **rozszerzeniem GNOME Shell (GJS)**. Rozszerzenie
działa wewnątrz kompozytora (Mutter), więc ma pełny dostęp do `Meta.Display`, `Meta.Window`,
`Meta.WorkspaceManager`, Clutter i St – również pod Waylandem. Zewnętrzny program pod Waylandem
nie mógłby wyliczać cudzych okien, fokusować ich, przesuwać, rejestrować globalnych skrótów ani
czytać pozycji kursora (pod X11 częściowo przez EWMH/libwnck/xdotool, ale to ślepa uliczka).
Ewentualny osobny proces (np. okno ustawień w GTK/libadwaita jako `prefs.js`) komunikuje się
z rozszerzeniem przez GSettings (lub D-Bus). Prawie cała „walka z systemem” z macOS znika: nie ma
AX, nie ma prywatnych API, nie ma pętli weryfikacji wymuszonych asynchronicznością innych
procesów.

| Funkcja (macOS) | GNOME/Mutter |
|---|---|
| Wyliczanie okien (1.2) | `global.display.list_all_windows()` lub `global.get_window_actors().map(a => a.meta_window)`; filtr: `window.get_window_type() === Meta.WindowType.NORMAL` (ewentualnie też `DIALOG` bez rodzica), `!window.is_skip_taskbar()`, `!window.is_override_redirect()`, `window.get_transient_for() === null` dla okien pobocznych. Nie trzeba filtra popupów ani „duchów” – menu, podpowiedzi, dymki mają inne typy (`POPUP_MENU`, `TOOLTIP`, `DROPDOWN_MENU`…). Własne aktory paska nie są `Meta.Window`, więc same odpadają; okno ustawień (`prefs`) jest zwykłym oknem i trafi do kolejki jak na macOS. |
| Id okna | `window.get_id()` (stabilny w sesji, `guint64`); aplikacja: `Shell.WindowTracker.get_default().get_window_app(window)` → `app.get_id()` (np. `org.gnome.Terminal.desktop`) zamiast `bundleID`, `app.get_name()`, ikona `app.create_icon_texture(size)`; `window.get_pid()`. |
| Tytuł | `window.get_title()`, sygnał `notify::title` – dostępny zawsze, dla wszystkich obszarów (Screen Recording nie ma odpowiednika i nie jest potrzebne). |
| Zminimalizowanie | `window.minimized`, sygnał `notify::minimized`; odminimalizowanie `window.unminimize()` (albo samo `activate`). |
| Obszar okna | `window.get_workspace()` (null dla okien „na wszystkich obszarach”: `window.is_on_all_workspaces()` – potraktować jak „bez obszaru”), sygnał `workspace-changed` na oknie. |
| Nowe/usunięte okna (1.5) | `global.display.connect('window-created', …)` (tytuł/typ bywa jeszcze nieustalony – odczekać do `first-frame` aktora lub `GLib.idle_add`), `window.connect('unmanaged', …)`; dodatkowo `workspace.connect('window-added'/'window-removed')`. Timer 3 s i ponowna rejestracja po 2 s nie są potrzebne; można zostawić lekki debounce (np. 150 ms) na scalanie zmian, a okresowe uzgadnianie jako tanią asekurację. |
| Zewnętrzna zmiana fokusu (1.6) | `global.display.connect('notify::focus-window', …)` → `global.display.focus_window`. Reguły ignorowania (cel w trakcie fokusu, pusty slot) zostają, choć „cel w trakcie” trwa zwykle jedną klatkę. |
| Zdarzenia geometrii (1.5) | `window.connect('size-changed')`, `('position-changed')`; `window.get_frame_rect()`. Początek i koniec przeciągania: `global.display` `grab-op-begin`/`grab-op-end` (zamiast sprawdzania przycisku myszy). |
| Topologia obszarów (2.1) | `global.workspace_manager`: `get_n_workspaces()`, `get_workspace_by_index(i)`, `get_active_workspace()`, `workspace.index()`. Numer = `index()+1`. Mutter ma **jeden** zestaw obszarów wspólny dla monitorów (domyślnie `workspaces-only-on-primary = true`: monitory dodatkowe pokazują zawsze to samo, okna na nich są „na wszystkich obszarach”). Jeden „bieżący obszar” zamiast per wyświetlacz; `isShowing(ws)` = `ws === get_active_workspace()` (plus okna na monitorach niegłównych, gdy obszary tylko na głównym, są zawsze widoczne). Numeracja „przez wyświetlacze” upraszcza się do indeksu. Kolejność: sygnały `workspace-added`, `workspace-removed`, `workspaces-reordered`, `notify::n-workspaces`; brak potrzeby pollera 0,4 s. Dynamiczne obszary GNOME (`org.gnome.mutter dynamic-workspaces`) – ostatni obszar jest zawsze pusty; pusty slot i numeracja muszą to uwzględniać. |
| Obszary pełnoekranowe | Nie ma osobnych obszarów: pełnoekranowe okno leży na zwykłym obszarze (`window.is_fullscreen()`, sygnał `notify::fullscreen`; `global.display` `in-fullscreen-changed`, `Main.layoutManager.monitors[i].inFullscreen`). Stan „bieżący obszar jest pełnoekranowy” trzeba wyprowadzić z „na bieżącym monitorze jest pełnoekranowe okno na wierzchu”. |
| Przełączanie obszaru (2.2–2.5) | `workspace.activate(global.get_current_time())` albo `workspace.activate_with_focus(window, time)` (przejście i fokus w jednym kroku, z animacją Shella). Działa zawsze, także dla pustych i > 9 obszarów – **nie trzeba okna-nośnika, skrótu ⌃N ani łańcucha weryfikacji**. Wybór metody (`spaceSwitchMethod`) można pominąć lub zredukować do „fokusuj okno na obszarze” vs „po prostu przejdź”. Ewentualna weryfikacja: sygnał `active-workspace-changed`. „Kierunek w drodze” (`destination`) = obszar od `activate` do końca animacji (`Main.wm` / `global.window_manager` sygnał `switch-workspace` i koniec animacji; wystarczy flaga z timeoutem ~ czasu animacji). |
| Fokus okna na innym obszarze (2.6) | `window.activate(time)` – Mutter sam przełącza na obszar okna (albo `workspace.activate_with_focus(window, time)`), odminimalizowuje i podnosi. Jednorazowe, synchroniczne; pętla 20×0,1 s, potwierdzenie 0,25 s i Cmd+` odpadają. Czas: `global.get_current_time()` (inaczej ochrona przed kradzieżą fokusu może odmówić). Kolejka „najnowszy wygrywa” trywialna. |
| Trzymanie obszaru po zamknięciu (2.7) | Mutter nie przełącza obszaru przy zamknięciu ostatniego okna (fokus przechodzi na inne okno *tego samego* obszaru lub pulpit), więc mechanizm prawdopodobnie zbędny; przy dynamicznych obszarach GNOME **usuwa pusty obszar** (jeśli nie jest ostatni ani aktywny – aktywny pusty obszar jest usuwany po opuszczeniu). Zachować tylko ochronę: przez 2 s po zamknięciu, jeśli `active-workspace-changed` przyszło nie z naszego żądania – wróć. |
| Przenoszenie okien (2.8, 2.9) | `window.change_workspace(ws)` lub `window.change_workspace_by_index(i, false)` – **per okno, bez ograniczenia „cała aplikacja”**; wynik synchroniczny. Zapas przeciągnięcia i komunikat „stayed where it was” stają się zbędne (zostawić ogólny komunikat błędu na wypadek okien, których nie da się przenieść, np. `is_on_all_workspaces()` lub okna modalne związane z rodzicem). `pullToCurrentSpace` = `window.change_workspace(active)`. |
| Obszar nakładkowy (2.10) | Pasek i panele jako aktory St w `Main.layoutManager` (`addChrome`/`addTopChrome`) – leżą w warstwie Shella nad wszystkimi obszarami i nie biorą udziału w animacji przełączania. Nad oknami pełnoekranowymi: `addTopChrome` lub `Main.uiGroup` (pełnoekranowy stan ukrywa zwykły chrome, jeśli `trackFullscreen: true`). |
| Podniesienie + fokus (3.3) | `window.activate(time)` (= raise + focus + przejście). Samo podniesienie: `window.raise()`; podniesienie grupy kafelków: kolejno `raise()` pozostałych, na końcu `activate` wybranego. |
| Fokus bez podnoszenia (3.8) | `window.focus(time)` – daje klawiaturę bez zmiany stosu (to dokładnie to, co w macOS wymaga prywatnych rekordów zdarzeń). Sprawdzenie: `global.display.focus_window === window`. |
| Przeniesienie kursora (3.7) | Pod Waylandem tylko z wnętrza kompozytora: `Clutter.get_default_backend().get_default_seat().warp_pointer(x, y)` (środek `get_frame_rect()`). Pozycja kursora: `global.get_pointer()` → `[x, y, mods]`. |
| Błysk fokusu | Aktor St (obrys) nad `window.get_compositor_private()` / wg `get_frame_rect()`, dodany do `global.window_group` lub chrome'u, usunięty po czasie. |
| Focus follows mouse (4) | Mutter ma wbudowany tryb (`org.gnome.desktop.wm.preferences focus-mode = 'sloppy'/'mouse'`, `auto-raise`, `auto-raise-delay`), ale nie zna reguł WindowQueue (pomijanie paska, wstrzymanie w celowaniu/wyszukiwaniu/przejściu, brak przy wciśniętych przyciskach/modyfikatorach, ponowienie z podniesieniem) – lepiej własna implementacja: śledzenie ruchu przez `global.stage` `captured-event` nie łapie ruchu nad oknami klientów, więc użyć timera odpytującego `global.get_pointer()` (np. co 16–50 ms, tylko gdy się zmienia) albo `Clutter` seat/`PointerWatcher` (`imports.ui.pointerWatcher.getPointerWatcher().addWatch(interval, cb)` – używany przez lupę). Okno pod kursorem: `global.get_window_actors()` od góry (odwrócona kolejność stosu, np. `global.display.sort_windows_by_stacking`) – pierwsze, którego `get_frame_rect()` zawiera punkt i które jest widoczne na aktywnym obszarze; jeśli punkt jest nad aktorem chrome'u (pasek, panel górny, dash) → `global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y)` i sprawdzić, czy to nie nasz aktor/Shell. Otwarte menu: `Main.panel.menuManager.activeMenu`, `global.display.get_grab_op?.()`/`Main.pushModal` (modalność Shella), typy okien `POPUP_MENU`/`DROPDOWN_MENU` na wierzchu. Modyfikatory i przyciski: maska z `global.get_pointer()[2]` (`Clutter.ModifierType.*_MASK`, `BUTTON1_MASK`…). Fokus: `window.focus(time)` lub przy opcji podnoszenia `window.activate(time)`. |
| Zamykanie (5) | `window.delete(global.get_current_time())` – zamyka konkretne okno bez fokusu i bez przejścia na jego obszar; nie trzeba Cmd+W ani warunku bezpieczeństwa. Aplikacja może odmówić/pytać (niezapisany dokument) – wtedy okno zostaje, kolejka się nie zmienia (odświeżenia 0,4/1,2 s zastąpione przez `unmanaged`). `window.kill()` tylko jako świadomie osobna akcja. |
| Globalne skróty (6) | `Main.wm.addKeybinding(name, settings, Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, handler)` z kluczami typu `as` w schemacie GSettings rozszerzenia; zdejmowanie `Main.wm.removeKeybinding(name)`. Konflikt: `addKeybinding` zwraca `Meta.KeyBindingAction.NONE` (0) przy niepowodzeniu → lista błędów w ustawieniach. Ponowna rejestracja tylko skrótu, którego wartość się zmieniła (`settings.connect('changed::key')`) – od razu daje zasadę „nie ruszaj, jeśli bez zmian”. Uwaga na kolizje z domyślnymi skrótami GNOME (Super+1…9 to przełączanie aplikacji w docku, Super+Shift+1…9, Alt+F…); modyfikator „super” domyślnie Alt/Option może kolidować z mnemonikami menu – dobrać domyślne. Stuknięcie samego modyfikatora (otwarcie celowania): Mutter obsługuje skróty „tylko modyfikator” wyłącznie dla `overlay-key` (Super); dla innych modyfikatorów trzeba śledzić stan modyfikatorów samodzielnie – np. odpytywać maskę z `global.get_pointer()[2]` krótkim timerem i uznać za stuknięcie wciśnięcie+puszczenie bez innego klawisza w krótkim czasie (wywołanie dowolnego skrótu anuluje stuknięcie). Przechwycenie klawiatury w celowaniu/wyszukiwarce: `Main.pushModal(actor)` / `Main.popModal(grab)`. |
| Rezerwacja miejsca (7) | `Main.layoutManager.addChrome(stripActor, { affectsStruts: true, trackFullscreen: true, affectsInputRegion: true })` – struty są oficjalnym mechanizmem: obszar roboczy (`workspace.get_work_area_for_monitor(i)`) automatycznie się zmniejsza, maksymalizacja, kafelkowanie połówkowe i inne rozszerzenia go respektują, **na każdym monitorze** i natychmiast dla już działających aplikacji. Nie ma sztuczki z Dockiem, zapisu oryginału, timera 2 s, przywracania przy sygnałach/crashu (strut znika razem z aktorem; `disable()` rozszerzenia go usuwa). Tryb niewidzialnego paska = `affectsStruts: false` (lub usunięcie strutu). `unreservedFrame` = obszar roboczy + szerokość własnego strutu albo `Main.layoutManager.getWorkAreaForMonitor` przed dodaniem – najprościej liczyć od geometrii monitora (`global.display.get_monitor_geometry(i)`) minus panel górny. Uwaga: struty muszą przylegać do krawędzi ekranu (nie „wewnątrz” między monitorami). |
| Strażnik krawędzi (8) | Przy strutach zbędny dla maksymalizacji i kafelków Mutter (one używają work area). Może się przydać dla aplikacji same ustawiających sobie rozmiar na cały monitor lub przy innych rozszerzeniach kafelkujących: `size-changed` + debounce 0,3 s, `grab-op-end` zamiast sprawdzania myszy, `window.move_resize_frame(true, x, y, w, h)` (jedno wywołanie, bez kolejności rozmiar/pozycja/rozmiar), pominięcie `is_fullscreen()` i okien zmaksymalizowanych (`get_maximized()`). Logika odwrócenia zoomu zbędna (Mutter pamięta ramkę sprzed maksymalizacji: `unmaximize`). |
| Rectangle (9) | Nie ma odpowiednika; rozszerzenia kafelkujące GNOME (Tiling Assistant, Forge, Pop Shell, wbudowane kafelkowanie krawędziowe) respektują work area, więc struty wystarczą. Sekcję można pominąć lub zastąpić zapisem „gap” do GSettings konkretnego rozszerzenia, jeśli zajdzie potrzeba. |
| Uprawnienia (10) | Brak: rozszerzenie zainstalowane i włączone (`gnome-extensions enable`) ma wszystkie możliwości. „Czekanie na Accessibility” odpada; start = `enable()`, koniec = `disable()` (musi posprzątać wszystkie sygnały, timery, skróty, aktory – wymóg recenzji extensions.gnome.org). Zrzuty/nagrywanie: `Shell.Screenshot` wewnątrz Shella, bez pytań. |
| Menu w pasku stanu | `PanelMenu.Button` w `Main.panel` z `PopupMenu.PopupMenuItem` (Settings…, Sort queue by workspace, Refresh windows); „Quit” → wyłączenie rozszerzenia nie jest typowe – zamiast tego „Disable” lub brak. Ustawienia: `extension.openPreferences()`. |
| Uruchamianie przy logowaniu (11) | Włączone rozszerzenie startuje z sesją automatycznie (`org.gnome.shell enabled-extensions`). Preferencja `launchAtLogin` staje się zbędna (odpowiednik: włącz/wyłącz rozszerzenie). |
| Diagnostyka (12) | Katalog `GLib.get_user_state_dir()/window-queue/` (np. `~/.local/state/window-queue/`) lub `~/.cache/window-queue/`; zapis przez `Gio.File.append_to`/`replace_contents`. Dodatkowo `console.log`/`log()` → `journalctl --user -f /usr/bin/gnome-shell`. Przełączniki `diagnostics` i `debugCommands` jako klucze GSettings. |
| Polecenia debugowe (12) | Interfejs D-Bus eksportowany przez rozszerzenie (`Gio.DBusExportedObject.wrapJSObject`) z metodą `Command(s line)` na ścieżce np. `/org/windowqueue/Debug`; wywołanie `gdbus call --session --dest org.gnome.Shell --object-path /org/windowqueue/Debug --method org.windowqueue.Debug.Command "action cycleNext"`. Te same polecenia co na macOS. (Alternatywa w trybie deweloperskim: `Looking Glass`/`org.gnome.Shell.Eval`, wyłączone domyślnie.) |

**Co się upraszcza (podsumowanie):** brak okna-nośnika, skrótów ⌃N i łańcucha ponowień
przełączania; fokus i przejście na obszar to jedno `activate`; przenoszenie okien per okno;
zamykanie konkretnego okna bez fokusu; fokus bez podnoszenia to publiczne `focus()`; rezerwacja
miejsca przez struty na wszystkich monitorach; brak filtrów popupów/duchów i trybów rozszerzonej
dostępności; tytuły zawsze dostępne; brak uprawnień i elementu logowania.

**Na co uważać:** (1) wszystko musi żyć w procesie `gnome-shell` – błąd w rozszerzeniu może
zawiesić sesję pod Waylandem, więc długie operacje dzielić przez `GLib.idle_add`/`timeout_add` i
nigdy nie blokować; (2) API Shella zmienia się między wersjami (importy ESM od GNOME 45,
`Meta.WindowType`, `get_maximized` vs `is_maximized` w nowszych) – zadeklarować wspierane wersje w
`metadata.json`; (3) ochrona przed kradzieżą fokusu wymaga poprawnego znacznika czasu
(`global.get_current_time()`); (4) dynamiczne obszary i „obszary tylko na monitorze głównym” to
ustawienia użytkownika – numeracja, pusty slot i przenoszenie muszą działać w obu konfiguracjach;
(5) okna X11 przez Xwayland i natywne Wayland są tak samo widoczne jako `Meta.Window`, ale
`get_pid()` może zwracać 0 dla niektórych klientów Wayland – grupować okna aplikacji przez
`Shell.WindowTracker`, nie przez PID.

---

## Ustawienia

Wszystkie ustawienia WindowQueue żyją w jednej strukturze (`Preferences`) trzymanej przez jeden
obiekt-magazyn (`PreferencesStore`). Nie ma przycisków „OK/Anuluj/Zastosuj”: każda zmiana kontrolki
od razu trafia do magazynu, jest od razu zapisywana na dysk i od razu działa w całej aplikacji
(strip, skróty, rezerwacja miejsca itd. subskrybują zmiany magazynu).

### Okno ustawień

- Tytuł okna: „WindowQueue Settings”. Stały rozmiar 600 × 560 pt, wyśrodkowane przy pierwszym
  otwarciu, z przyciskami zamknij i minimalizuj (bez zmiany rozmiaru).
- Okno jest tworzone raz, przy pierwszym otwarciu, i potem tylko ponownie pokazywane (zamknięcie go
  nie niszczy).
- Aplikacja normalnie nie ma ikony w Docku (tryb „accessory”). Otwarcie ustawień przełącza ją na
  zwykłą aplikację (ikona w Docku, może dostać fokus) i aktywuje; zamknięcie okna przywraca tryb
  bez ikony i zleca ponowne wyliczenie okien (żeby okno ustawień zniknęło z kolejki). Ok. 0,3 s po
  otwarciu też zlecane jest odświeżenie listy okien — samo okno ustawień jest zwykłym oknem i
  trafia do kolejki jak każde inne.
- Otwierane z menu ikony w pasku menu („Settings…”) oraz przy ponownym uruchomieniu już działającej
  aplikacji (np. ze Spotlighta/Findera) — wtedy nie ma nic innego do pokazania niż ustawienia.
- Cztery zakładki, w tej kolejności: **General** (ikona koła zębatego), **Focus** (kursor z
  promieniami), **Shortcuts** (klawiatura), **Strip** (pasek boczny).
- Zakładki General, Focus i Strip to pogrupowane formularze (sekcje z nagłówkiem). Zakładka Shortcuts
  to własny układ z przewijaną listą.

Wspólne elementy formularzy:

- **Suwak** (`sliderRow`): etykieta po lewej, po prawej suwak o stałej szerokości 200 pt i obok
  bieżąca wartość w stałej kolumnie 48 pt (cyfry o stałej szerokości, wyrównane do prawej, kolor
  drugorzędny), żeby suwaki na stronie tworzyły równą kolumnę. Formaty wartości:
  - punkty: `"<liczba całkowita> pt"` (wartość obcięta do całości),
  - procenty: `"<wartość×100 zaokrąglona>%"`,
  - sekundy: `"<wartość z maks. 2 cyframi znaczącymi> s"`, np. `0.05 s`, `0.5 s`, `1 s`, `10 s`.
- **Podpis** (caption): mały, drugorzędny tekst pod kontrolką, zawijany; opisuje działanie.
- „Wyłączona” kontrolka = widoczna, ale wyszarzona i nieaktywna. „Ukryta” = nie ma jej w ogóle.

#### Zakładka General

1. Sekcja **„Queue”**
   - Lista wyboru **„Queue scope”** (`scope`): „All windows (global)” / „Current workspace only”.
     Domyślnie global.
   - Przełącznik **„Keep the queue sorted by workspace”** (`autoSortByWorkspace`), domyślnie wł.
     Podpis: nowe okna same dołączają do grupy swojego workspace'u; ręczne przestawienie kolejki
     wyłącza tę opcję, a skrót sortowania włącza ją z powrotem. (Przełącznik w oknie odzwierciedla
     to na żywo — może się sam przestawić, gdy użytkownik przesunie okno w kolejce.)
2. Sekcja **„Workspaces”**
   - Lista wyboru **„Workspace switching”** (`spaceSwitchMethod`), trzy pozycje:
     - „Focus a window on that workspace (recommended)” (`focusWindow`),
     - „Send macOS ⌃1…⌃9 shortcut” (`systemShortcut`),
     - „Carry an invisible window there” (`privateAPI`) — **domyślna**, mimo że etykieta
       „recommended” stoi przy pierwszej.
   - Pod listą podpis zależny od wybranej metody:
     - focusWindow: aktywuje pierwsze okno z kolejki na docelowym workspace'ie (system sam tam
       przewija); workspace bez okien osiąga przez przeniesienie tam niewidzialnego okna;
     - systemShortcut: wymaga włączonych w ustawieniach systemu skrótów „Switch to Desktop N”;
     - privateAPI: przenosi niewidzialne okno WindowQueue na ten workspace i wysuwa je na wierzch;
       działa dla pustych workspace'ów i powyżej 9.
   - Jeśli obsługa workspace'ów jest niedostępna (nie udało się załadować prywatnego API
     przestrzeni), pod spodem pomarańczowy komunikat: „Workspace support is unavailable on this macOS
     version: … Workspace switching and per-workspace scope are disabled.” Uwaga: kontrolki nie są
     wtedy faktycznie wyłączane — to tylko informacja.
3. Sekcja **„Tiling”**
   - Suwak **„Screen gap”** (`tileOuterGap`): 0–40 pt, krok 1, domyślnie 0.
   - Suwak **„Gap between windows”** (`tileInnerGap`): 0–40 pt, krok 1, domyślnie 4.
   - Podpis: odstęp wokół okien, które układa WindowQueue — kafelkowanych z trybu celowania,
     maksymalizowanych albo wysyłanych na pełny ekran.
4. Sekcja **„Fullscreen windows”**
   - Przełącznik **„Focus on the fullscreen window”** (`focusMaximizedWindow`), domyślnie wł.
     Podpis: wysłanie okna na pełny ekran przenosi je na początek jego workspace'u w kolejce;
     cyklowanie zostaje wtedy na nim, dopóki nie zostanie przywrócone (co przywraca kolejkę);
     zwykła maksymalizacja kolejki nie rusza.
   - Przełącznik **„Collapse the windows it covers”** (`collapseCoveredWindows`), domyślnie wł.
     **Ukryty**, gdy poprzedni jest wyłączony. Podpis: zakryte okna składają się w jeden kafel obok
     okna pełnoekranowego, pokazujący kilka pierwszych ikon i ich liczbę; wyłączone — każde zostaje
     w swoim wierszu, tylko przyciemnione/zabarwione.
5. Sekcja **„Strip labels”**
   - Przełącznik **„Show window titles under the icons”** (`showWindowLabels`), domyślnie wł.
     Podpis: odróżnia kilka okien tej samej aplikacji; ikona oddaje miejsce, strip nie rośnie.
6. Sekcja **„Window titles”** (specyficzna dla macOS — uprawnienie „Screen Recording”)
   - Tylko podpis, zależny od stanu uprawnienia: gdy nadane — „tytuły okien są pokazywane dla
     każdego workspace'u”; gdy nie — okna na innych workspace'ach pokazują tylko nazwę aplikacji,
     system ukrywa tytuły bez tego uprawnienia, reszta działa bez niego.
   - Przycisk **„Grant Screen Recording…”** tylko gdy uprawnienie nie jest nadane: prosi system o
     uprawnienie i otwiera odpowiednią stronę ustawień systemu.
   - Na GNOME odpowiednik zwykle nie istnieje (tytuły są dostępne) — sekcję można pominąć albo
     pokazywać zawsze wariant „nadane”.
7. Sekcja **„Startup”**
   - Przełącznik **„Launch at login”** (`launchAtLogin`), domyślnie wł. **Wyłączony**, gdy
     aplikacja nie jest zainstalowana (nie leży w `/Applications/`).
   - Pod nim, zależnie od stanu elementu logowania:
     - nie zainstalowana: „Available once WindowQueue is in the Applications folder (make install).”
     - czeka na zatwierdzenie w systemie: „Waiting for approval in the system's login item
       settings.” + mały przycisk **„Open Login Items”** otwierający tę stronę ustawień systemu;
     - włączony/wyłączony: brak podpisu.

#### Zakładka Focus

1. Sekcja **„Pointer”**
   - Przełącznik **„Move the pointer to windows focused from the keyboard”** (`warpCursorToWindow`),
     domyślnie wł.
   - Przełącznik **„Focus the window under the pointer”** (`focusFollowsMouse`), domyślnie wł.
   - Suwak **„Hover delay”** (`focusFollowsMouseDelay`): 0–1,0 s, krok 0,05, domyślnie 0,05 s.
     Wyłączony, gdy focus-follows-mouse wyłączone.
   - Przełącznik **„Bring the hovered window to the front”** (`focusFollowsMouseRaises`), domyślnie
     wył. Wyłączony, gdy focus-follows-mouse wyłączone.
2. Sekcja **„Aiming mode”**
   - Przełącznik **„Aiming mode”** (`aimingEnabled`), domyślnie wł. Podpis: tapnięcie samego klawisza
     super pozwala wybrać okno bez fokusowania go; strip rośnie, ekrany się przyciemniają, celowana
     ikona robi się pomarańczowa, `[` / `]` lub strzałki przesuwają cel; ponowne tapnięcie super
     fokusuje okno, tak samo Return i Spacja; Escape zostawia wszystko jak było.
   - Lista wyboru **„Double tap of the super key”** (`superDoubleTapAction`). Pozycje w kolejności:
     „Confirm the aim” (brak akcji, `nil`), potem tytuły akcji: „Open the launcher”, „Show Mission
     Control”, „Search windows”, „Hide or show the strip (invisible mode)”, „Start or stop recording
     the screen”, „Take a picture of the window”, „Fullscreen window (again to restore)”, „Maximize
     window”, „Minimize window”, „Group or ungroup windows”, „Close selected window”, „Sort queue by
     workspace”, „Move window to start of queue”, „Move window to end of queue”. Domyślnie
     **„Search windows”**. Podpis: dwa tapnięcia super szybko po sobie; „Confirm” fokusuje celowane
     okno (to, co drugie tapnięcie robi i tak); każdy inny wybór wychodzi z trybu celowania i
     uruchamia tę akcję. Wyłączona, gdy tryb celowania wyłączony.
   - Suwak **„Dim the screens”** (`aimingDimOpacity`): 0–0,85, krok 0,05, format procentowy, przy 0
     pokazuje „off”. Domyślnie 0,45 (45%). Wyłączony, gdy tryb celowania wyłączony.
3. Sekcja **„Focus”**
   - Przełącznik **„Outline the window focus lands on”** (`flashFocusedWindow`), domyślnie wł.
     Podpis: krótki obrys okna, które właśnie dostało fokus, w kolorze zaznaczenia (ten sam znak, co
     rysuje tryb celowania); pojawia się od razu, trzyma się, potem zanika przez pół sekundy.
   - Suwak **„Outline holds for”** (`flashFocusedWindowDuration`): 0,05–1 s, krok 0,05, domyślnie
     0,15 s. Wyłączony, gdy obrys wyłączony.
4. Sekcja **„Launcher”**
   - Lista wyboru **„Open with”** (`launcher`): „Spotlight”, „Raycast”, „Alfred”. Aplikacja, której
     nie ma w systemie, ma dopisek „ (not installed)” (Spotlight jest zawsze dostępny). Domyślnie
     Spotlight. Podpis: co otwiera skrót launchera, w trybie celowania i poza nim; Spotlight otwiera
     się tylko przez jego własne ⌘Spacja, wysyłane jako naciśnięcie klawisza; pozostałe otwiera się
     jak aplikacje; niezainstalowany launcher → Spotlight.
   - Na GNOME: naturalne odpowiedniki to przegląd/wyszukiwarka GNOME Shell, ewentualnie
     zewnętrzne launchery (Ulauncher, Albert itp.) — zasada ta sama: lista wyboru, fallback na
     wbudowany.
5. Sekcja **„Name popup”**
   - Przełącznik **„Show the window name after a change”** (`toastEnabled`), domyślnie wł.
   - Suwak **„Popup duration”** (`toastDuration`): 0,5–10 s, krok 0,5, domyślnie 1,0 s. Wyłączony,
     gdy popup wyłączony.
   - Przełącznik **„Show a picture of the window”** (`showWindowPreview`), domyślnie wł. Wyłączony,
     gdy popup wyłączony. Podpis: wymaga uprawnienia Screen Recording i da się pokazać tylko okna z
     workspace'u, który jest na ekranie.

#### Zakładka Shortcuts

Układ od góry (z marginesem wewnętrznym, bez formularza):

1. Wiersz nagłówka: lista wyboru **„Super key”** (szer. 300 pt) z pozycjami „⌥ Option”, „⌃ Control”,
   „⌘ Command”, „⌃⌥ Control+Option”, „⌘⌥ Command+Option” (domyślnie Option); po prawej przycisk
   **„Reset all”**.
2. Podpis: „Changing the super key regenerates every shortcut from the defaults.”
3. Jeśli jakichś skrótów nie udało się zarejestrować — czerwony mały tekst:
   „Could not register: <tytuły akcji po przecinku>. Another app probably owns those shortcuts.”
   (Uwaga implementacyjna: w oryginale lista błędów jest pobierana raz, przy tworzeniu okna
   ustawień, więc nie odświeża się przy kolejnych otwarciach — to usterka, nie zamierzone
   zachowanie; reimplementacja powinna pokazywać bieżący stan.)
4. Przewijana lista z czterema grupami, każda z pogrubionym nagłówkiem:
   - **„Queue”** — 18 akcji kolejki,
   - **„Workspaces”** — „Switch to workspace 1” … „Switch to workspace 9”,
   - **„Move to workspace”** — „Move window to workspace 1” … „Move window to workspace 9”,
   - **„Aiming mode only”** — klawisze tylko dla trybu celowania (opis niżej).
   Wiersz akcji: tytuł po lewej, po prawej rejestrator skrótu 130 × 24 pt pokazujący bieżący skrót.

#### Zakładka Strip

1. Sekcja **„Visibility”**
   - Przełącznik **„Invisible mode”** (`invisibleStrip`), domyślnie wył. Podpis: strip jest
     rysowany tylko, gdy otwarty jest tryb celowania; kolejka działa normalnie; poza celowaniem zmianę
     ogłasza wyłącznie popup z nazwą; żadne miejsce na ekranie nie jest rezerwowane.
   - Lista wyboru **„Show strip”** (`stripDisplay`): „Selected monitor only”, „All monitors,
     highlight selected” (domyślna), „Hidden”.
   - Suwak **„Inactive monitors”** (`inactiveStripOpacity`): 10–100%, krok 5%, domyślnie 55%.
     Wyłączony, gdy „Show strip” ≠ „All monitors, highlight selected”.
   - Przełącznik **„Hide over fullscreen windows”** (`hideInFullscreen`), domyślnie wł.
2. Sekcja **„Position”**
   - Przycisk segmentowy **„Side”** (`stripSide`): Left / Right / Top / Bottom, domyślnie Left.
   - Przycisk segmentowy **„Alignment”** (`stripAlignment`): Start / Center / End, domyślnie Center.
   - Suwak **„Margin”** (`stripMargin`): 0–40 pt, krok 1, domyślnie 4.
3. Sekcja **„Appearance”**
   - Suwak **„Icon size”** (`iconSize`): 16–48 pt, krok 2, domyślnie 34.
   - Suwak **„Opacity”** (`stripOpacity`): 20–100%, krok 5%, domyślnie 100%.
   - Przełącznik **„Show workspace number”** (`showSpaceBadge`), domyślnie wł.
4. Sekcja **„Scrolling”**
   - Suwak **„Focus after scrolling”** (`scrollFocusDelay`): 0,1–2,0 s, krok 0,1, domyślnie 0,5 s.
5. Sekcja **„Reserve screen space”**
   - Przełącznik **„Keep windows clear of the strip”** (`reserveScreenSpace`), domyślnie wł.
   - Przełącznik **„Trim windows on other screens and in older apps”**
     (`trimWindowsOutsideReservation`), domyślnie wł. Wyłączony, gdy poprzedni wyłączony.
   - Podpis dynamiczny: gdy Dock się automatycznie ukrywa, WindowQueue „pożycza” stripowi
     zarezerwowany obszar Docka na ekranie z paskiem menu, więc zoom, „Fill” i kafelkowanie zostawiają
     `<N>` pt wolnego (w aplikacjach uruchomionych po WindowQueue); wszędzie indziej okna oparte o
     krawędź stripu są przycinane po fakcie. `<N>` = szerokość rezerwacji (patrz niżej). Jeśli
     zainstalowany jest Rectangle, dopisek: ustawia też odstęp od krawędzi `<side>` w Rectangle,
     który Rectangle czyta przy starcie, więc trzeba go zrestartować.
   - Tylko przy zainstalowanym Rectangle: przycisk **„Restart Rectangle to apply”** i obok tekst
     statusu: „Restarting…” → „Rectangle restarted.” albo „Could not restart Rectangle.”
   - Na GNOME cała sekcja odpowiada rezerwowaniu „strutu” (obszaru roboczego) dla panelu stripu;
     integracje z Dockiem i Rectangle nie mają odpowiednika. Istotny kontrakt funkcjonalny: przy
     włączonej opcji maksymalizacja/kafelkowanie nie zachodzą na strip, przy wyłączonej — mogą.

### Pełna tabela zapisywanych preferencji

Klucze to dokładne nazwy pól w zapisanym JSON-ie. „UI” = czy jest kontrolka w oknie ustawień.

| Klucz | Typ | Domyślnie | Dozwolone wartości | UI | Efekt i miejsce działania |
|---|---|---|---|---|---|
| `scope` | enum str | `global` | `global`, `currentSpace` | General › Queue | Zakres kolejki: `currentSpace` ogranicza widoczną część kolejki (strip, cyklowanie, wyszukiwarkę) do okien bieżącego workspace'u; gdy bieżący workspace jest nieznany, działa jak `global`. Kolejność pełnej kolejki się nie zmienia. |
| `superModifier` | enum str | `option` | `option`, `control`, `command`, `controlOption`, `commandOption` | Shortcuts | Modyfikator „super”: baza domyślnych skrótów i klawisz, którego samo tapnięcie otwiera tryb celowania (patrz model skrótów). |
| `spaceSwitchMethod` | enum str | `privateAPI` | `focusWindow`, `systemShortcut`, `privateAPI` | General › Workspaces | Strategia przełączania na workspace N. `focusWindow`: sfokusuj pierwsze okno z kolejki na N; jeśli brak — przenieś tam własne niewidzialne okno; jeśli się nie da — systemowy skrót ⌃N. `systemShortcut`: tylko ⌃N. `privateAPI`: niewidzialne okno, awaryjnie ⌃N. We wszystkich przypadkach po chwili sprawdzane jest, czy przełączenie nastąpiło, i próbowane są pozostałe sposoby. |
| `reserveScreenSpace` | bool | `true` | — | Strip › Reserve | Rezerwuje miejsce stripu, żeby maksymalizowane/kafelkowane okna go nie zasłaniały. Działa tylko gdy `stripDisplay ≠ hidden` i `invisibleStrip = false`. Wpływa też na obszar, w którym WindowQueue sam kafelkuje/maksymalizuje (odejmuje szerokość rezerwacji od strony stripu). |
| `trimWindowsOutsideReservation` | bool | `true` | — | Strip › Reserve (zależne) | Gdy okno zostanie powiększone/ułożone pod stripem w miejscu, którego rezerwacja nie obejmuje (inne monitory, starsze aplikacje), po ustaniu zmiany rozmiaru jest przycinane, by nie wchodziło pod strip. Aktywne tylko gdy `reserveScreenSpace` i `stripDisplay ≠ hidden`; nie dotyka okien w prawdziwym pełnym ekranie ani przeciąganych myszą. |
| `bindings` | słownik `{nazwaAkcji: KeyCombo}` | pełny zestaw domyślnych dla `option` (przy świeżej instalacji) | klucze = surowe nazwy akcji | Shortcuts | Globalne skróty akcji. Brakujący wpis → domyślny skrót dla bieżącego super. |
| `toastEnabled` | bool | `true` | — | Focus › Name popup | Włącza popup z nazwą okna (i wszystkie inne popupy, także centralne komunikaty). Wyłączony: żadne popupy się nie pokazują. |
| `toastDuration` | double (s) | `1.0` | 0,5–10 (UI) | Focus › Name popup | Czas wyświetlania popupu przy oknie. Centralne komunikaty: `max(toastDuration, 1.2)`. Po zakończeniu „przytrzymania” (hover/celowanie): `min(toastDuration, 0.6)`. |
| `showWindowPreview` | bool | `true` | — | Focus › Name popup | Miniatura okna w popupie — tylko w popupach „przytrzymanych” (najazd na ikonę, tryb celowania), nigdy przy zwykłym cyklowaniu. |
| `stripDisplay` | enum str | `highlightActiveScreen` | `activeScreenOnly`, `highlightActiveScreen`, `hidden` | Strip › Visibility | `activeScreenOnly`: strip tylko na ekranie z fokusowanym oknem. `highlightActiveScreen`: strip na każdym ekranie, na nieaktywnych przygaszony do `inactiveStripOpacity` (w trybie celowania wszystkie rysowane jako aktywne). `hidden`: brak stripu nigdzie, brak rezerwacji i przycinania. |
| `inactiveStripOpacity` | double | `0.55` | 0,1–1,0 | Strip › Visibility | Krycie stripów na nieaktywnych monitorach. |
| `hideInFullscreen` | bool | `true` | — | Strip › Visibility | Chowa strip na ekranie, którego bieżący workspace jest systemowym pełnym ekranem. |
| `invisibleStrip` | bool | `false` | — | Strip › Visibility; skrót `toggleInvisibleStrip` | Tryb niewidzialny: strip (i panel grupy) widoczny tylko w trybie celowania — „rozkłada się” animacją na jego początek i „składa” po jego końcu. Szerokość rezerwacji = 0. Przełączany też skrótem (z centralnym komunikatem „Strip hidden”/„Strip shown” i przeliczeniem układu okien umieszczonych przez WindowQueue). |
| `stripSide` | enum str | `left` | `left`, `right`, `top`, `bottom` | Strip › Position | Krawędź ekranu stripu; left/right = strip pionowy, top/bottom = poziomy. Wpływa na położenie popupów, paneli grupy/akcji, menu kafelkowania, stronę rezerwacji. |
| `stripAlignment` | enum str | `center` | `start`, `center`, `end` | Strip › Position | Położenie stripu wzdłuż krawędzi (jak `justify-content`): 0 / 0,5 / 1 długości krawędzi. Przy `end` panel grupy otwiera się przed stripem zamiast za nim. |
| `stripMargin` | double (pt) | `4` | 0–40 | Strip › Position | Odstęp stripu od krawędzi ekranu (od krawędzi, do której przylega, i od końców — z wyjątkiem końca, do którego jest wyrównany). Wchodzi w szerokość rezerwacji. |
| `stripWidth` | double | `36` | — | brak | **Przestarzałe, nieużywane.** Grubość stripu wynika z rozmiaru ikon. Trzymane tylko dla zgodności odczytu. |
| `iconSize` | double (pt) | `34` | 16–48 | Strip › Appearance | Rozmiar ikon. Wysokość wiersza = `iconSize + 8`; grubość stripu = `iconSize + 20` (wiersz + 2×6 pt wypełnienia); promienie zaokrągleń i rozmiary odznak skalują się z nim. |
| `stripOpacity` | double | `1.0` | 0,2–1,0 | Strip › Appearance | Krycie stripu, panelu grupy i panelu akcji trybu celowania. |
| `showSpaceBadge` | bool | `true` | — | Strip › Appearance | Odznaka z numerem bieżącego workspace'u na początku stripu (klik w nią otwiera tryb celowania). Wyłączona — nie ma odznaki ani próbkowania jasności tła pod nią. |
| `showWindowLabels` | bool | `true` | — | General › Strip labels | Jedna linia tytułu okna (10 pt, biały na półprzezroczystym czarnym) przy dolnej krawędzi ikony; rozmiar wiersza się nie zmienia. |
| `autoSortByWorkspace` | bool | `true` | — | General › Queue | Kolejka trzymana posortowana po workspace'ach przy każdej zmianie. Aplikacja **sama zapisuje** `false`, gdy użytkownik ręcznie przestawi kolejkę (przesunięcie o pozycję, przeciągnięcie, przesunięcie na początek/koniec), i `true` po skrócie sortowania lub pozycji menu „Sort queue by workspace”. |
| `aimingEnabled` | bool | `true` | — | Focus › Aiming | Czy samo tapnięcie super otwiera tryb celowania. Nie blokuje otwarcia trybu kliknięciem w odznakę workspace'u. |
| `aimingScale` | double | `1.2` | ≥ 1 sensowne | brak | Powiększenie w trybie celowania: grubość stripu × `max(1, aimingScale)`, celowana ikona skalowana o ten czynnik. Tylko w zapisie (brak kontrolki). |
| `aimingDimOpacity` | double | `0.45` | 0–0,85 | Focus › Aiming | Krycie czarnej zasłony na wszystkich ekranach za stripem w trybie celowania i w wyszukiwarce; 0 = bez przyciemniania. Zasłona pojawia się/znika w 0,18 s. |
| `superDoubleTapAction` | nazwa akcji lub brak | `search` | `nil` lub jedna z akcji „double tap” | Focus › Aiming | Co robi drugie tapnięcie super w ciągu 0,4 s od otwarcia trybu celowania (szczegóły niżej). |
| `scrollFocusDelay` | double (s) | `0.5` | 0,1–2,0 | Strip › Scrolling | Kółko myszy nad stripem przesuwa zaznaczenie od razu, a fokus dostaje okno dopiero po tylu sekundach bez przewijania (każdy krok zeruje licznik). Kursor nie jest wtedy przenoszony. |
| `warpCursorToWindow` | bool | `true` | — | Focus › Pointer | Po fokusowaniu okna z klawiatury kursor przeskakuje na środek okna. Nigdy przy fokusie z myszy (klik, kółko, hover). |
| `focusFollowsMouse` | bool | `true` | — | Focus › Pointer | Okno pod kursorem dostaje fokus po `focusFollowsMouseDelay` bez ruchu. Nie działa: w trybie celowania, przy otwartej wyszukiwarce, w trakcie przełączania workspace'u, przy wciśniętym przycisku myszy lub jakimkolwiek modyfikatorze, nad oknami samego WindowQueue, nad zminimalizowanymi, gdy nad oknem jest coś innego lub otwarte jest menu; nie powtarza fokusu okna już zaznaczonego i na wierzchu. |
| `focusFollowsMouseDelay` | double (s) | `0.05` | 0–1,0 | Focus › Pointer | Czas spoczynku kursora przed fokusem. |
| `focusFollowsMouseRaises` | bool | `false` | — | Focus › Pointer | Wł.: fokus z hovera też wysuwa okno na wierzch. Wył.: próba nadania fokusu bez podnoszenia; jeśli to się nie da — normalny fokus z podniesieniem; jeśli po 0,3 s okno wciąż nie ma fokusu, a kursor nadal nad nim jest — podnosi je. |
| `flashFocusedWindow` | bool | `true` | — | Focus › Focus | Krótki obrys okna po każdym fokusie nadanym przez WindowQueue (nie w trybie celowania). Dla okna na innym workspace'ie czeka, aż workspace się pokaże (do 20 prób co 0,1 s). |
| `flashFocusedWindowDuration` | double (s) | `0.15` | 0,05–1 | Focus › Focus | Czas trzymania obrysu przed wygaszeniem (wygaszanie ok. 0,5 s dodatkowo). 0 wyłącza obrys. |
| `launcher` | enum str | `spotlight` | `spotlight`, `raycast`, `alfred` | Focus › Launcher | Co otwiera akcja `openLauncher`; także tytuł kafla launchera w panelu akcji trybu celowania. |
| `tileOuterGap` | double (pt) | `0` | 0–40 | General › Tiling | Odstęp od krawędzi obszaru roboczego przy kafelkowaniu, maksymalizacji i „pełnym ekranie” WindowQueue (oraz w podglądzie miejsca przy przeciąganiu). |
| `tileInnerGap` | double (pt) | `4` | 0–40 | General › Tiling | Odstęp między sąsiednimi kafelkami (każda komórka oddaje połowę z każdej strony). |
| `focusMaximizedWindow` | bool | `true` | — | General › Fullscreen | Czy akcja „fullscreen” (`toggleMaximize`) włącza tryb skupienia kolejki na tym oknie. Wyłączone: okno tylko wypełnia ekran, kolejka bez zmian, nic nie jest zakrywane/zwijane. |
| `collapseCoveredWindows` | bool | `true` | — | General › Fullscreen (ukryte, gdy poprzednie wył.) | Przy aktywnym skupieniu: okna zakryte przez pełnoekranowe zwijają się w jeden kafel-kaskadę z liczbą; wyłączone — zostają w swoich wierszach, zabarwione. Działa tylko razem z `focusMaximizedWindow`. |
| `includeMinimized` | bool | `true` | — | brak | **Zapisywane, ale nigdzie nieodczytywane.** Zminimalizowane okna zawsze są członkami kolejki (rysowane przygaszone). |
| `launchAtLogin` | bool | `true` | — | General › Startup | Rejestracja w systemowych elementach logowania (patrz niżej). |
| `aimBindings` | słownik `{"<kod klawisza>": nazwaAkcji}` | `{}` | akcje z grupy Queue | Shortcuts › Aiming mode only | Gołe klawisze działające wyłącznie w trybie celowania. |
| (legacy) `stripEnabled` | bool | — | — | brak | Tylko odczyt z bardzo starych zapisów: `false` → `stripDisplay = hidden` (gdy `stripDisplay` nie jest zapisane). Nigdy nie zapisywane. |

### Model skrótów

#### Akcje

Lista akcji (surowa nazwa → tytuł w UI). Kolejność w tabeli = kolejność w grupie „Queue” zakładki
Shortcuts; kolejność w wewnętrznej liście wszystkich akcji (rozstrzyga remisy) jest podana w
kolumnie „#”.

| # | Akcja | Tytuł w UI | Domyślny skrót |
|---|---|---|---|
| 1 | `cyclePrevious` | Select previous window | super + `[` |
| 2 | `cycleNext` | Select next window | super + `]` |
| 3 | `moveLeft` | Move window earlier in queue | super + ⇧ + `[` |
| 4 | `moveRight` | Move window later in queue | super + ⇧ + `]` |
| 5 | `moveToStart` | Move window to start of queue | super + ⇧ + Home |
| 6 | `moveToEnd` | Move window to end of queue | super + ⇧ + End |
| 7 | `sortByWorkspace` | Sort queue by workspace | super + ⇧ + W |
| 9 | `toggleMaximize` | Fullscreen window (again to restore) | super + F |
| 10 | `maximizeWindow` | Maximize window | super + M |
| 11 | `minimizeWindow` | Minimize window | super + H |
| 12 | `toggleGroup` | Group or ungroup windows | super + G |
| 8 | `closeWindow` | Close selected window | super + Q |
| 13 | `search` | Search windows | super + Space |
| 14 | `openLauncher` | Open the launcher | super + R |
| 15 | `showOverview` | Show Mission Control | super + W |
| 16 | `toggleInvisibleStrip` | Hide or show the strip (invisible mode) | super + I |
| 17 | `toggleRecording` | Start or stop recording the screen | super + V |
| 18 | `screenshotWindow` | Take a picture of the window | super + P |
| 19–27 | `space1` … `space9` | Switch to workspace 1 … 9 | super + `1` … `9` |
| 28–36 | `moveToSpace1` … `moveToSpace9` | Move window to workspace 1 … 9 | super + ⇧ + `1` … `9` |

Przy domyślnym super = Option daje to np. `⌥[`, `⌥⇧]`, `⌥R`, `⌥W`, `⌥⇧W`, `⌥V`, `⌥P`, `⌥1`, `⌥⇧1`.

Zasada doboru domyślnych: **żaden domyślny skrót nie używa liter A, C, E, L, N, O, S, X, Z**, bo
Option + te litery w polskim układzie „Polski – Programisty” daje ą ć ę ł ń ó ś ź ż — z Option jako
super polskie znaki nadal się wpisują. (Dlatego launcher to R, Mission Control to W, sortowanie
⇧W, nagrywanie V, zdjęcie okna P.) Na GNOME polskie znaki są pod AltGr (prawy Alt); ta zasada
dotyczy reimplementacji tylko wtedy, gdy super może wypaść na AltGr/Alt — warto ją zachować jako
niezmiennik testowy („żadna domyślna kombinacja nie zabiera polskiej litery”).

Klawisze są identyfikowane **pozycją fizyczną** (kod wirtualny klawisza w układzie ANSI), a nie
znakiem: `[` to klawisz na prawo od P niezależnie od układu. Nazwa pokazywana w UI jest tłumaczona
przez bieżący układ klawiatury (np. na układzie niemieckim ten sam klawisz pokaże się jako `Ü`).
Na GNOME odpowiednikiem jest wiązanie po kodzie sprzętowym (keycode), a etykieta z keysymu bieżącego
układu.

#### Reprezentacja skrótu (`KeyCombo`)

- `keyCode` (liczba całkowita) + `modifiers` (maska bitowa): Command = 256, Shift = 512,
  Option = 2048, Control = 4096 (maski Carbon). Caps Lock i Fn nie są brane pod uwagę.
- Dopasowanie: kod klawisza równy i zbiór wciśniętych modyfikatorów (z tych czterech) **dokładnie**
  równy masce.
- Tekst do wyświetlenia: symbole modyfikatorów w stałej kolejności ⌃ ⌥ ⇧ ⌘, potem nazwa klawisza.
  Nazwy specjalne: Return „↩”, Tab „⇥”, Spacja „Space”, Backspace „⌫”, Delete „⌦”, Escape „⎋”,
  Home „↖”, End „↘”, PageUp „⇞”, PageDown „⇟”, strzałki „← → ↑ ↓”, F1–F12 „F1”…„F12”. Pozostałe:
  znak z bieżącego układu wielkimi literami; gdy się nie da przetłumaczyć — `#<kod>`.

#### Klawisz super

Pięć wariantów: Option, Control, Command, Control+Option, Command+Option (na GNOME naturalne
odpowiedniki: Alt, Ctrl, Super/Meta i ich pary). Klawisz super pełni dwie role:

1. Jest modyfikatorem bazowym wszystkich domyślnych skrótów (super lub super + ⇧).
2. **Tapnięcie samego super** (bez innych klawiszy) otwiera/zamyka tryb celowania. Tapnięcie liczy
   się, gdy: stan modyfikatorów przeszedł z „nic” dokładnie na zbiór super (dla par — oba naraz),
   potem wszystko zostało puszczone w ciągu 0,4 s, a w międzyczasie nie było żadnego naciśnięcia
   klawisza, kliknięcia ani przewinięcia, ani nie zadziałał żaden globalny skrót. Powrót do „samego
   super” po puszczeniu np. Shift w trakcie kombinacji nie uzbraja tapnięcia.

Zmiana super w ustawieniach **od razu generuje od nowa wszystkie globalne skróty** z domyślnych dla
nowego super — własne przypisania użytkownika przepadają (bez pytania; ostrzega tylko stały
podpis). Nie rusza `aimBindings` ani `superDoubleTapAction`. Detektor tapnięć przełącza się na nowy
modyfikator natychmiast.

#### Rejestracja globalnych skrótów

- Wszystkie 36 akcji jest zawsze rejestrowanych jako globalne skróty (także workspace 1–9), każdy
  skrót osobno. Nie ma opcji „brak skrótu” — każda akcja ma jakąś kombinację.
- Po każdej zmianie ustawień rejestracja jest przeliczana, **ale tylko jeśli zmienił się
  którykolwiek skrót**. Ponowna rejestracja zostawia chwilę bez żadnego skrótu i naciśnięcie
  wtedy trafiłoby do aplikacji na pierwszym planie jako znak (np. „ś” zamiast ⌥S) — dlatego zmiana
  suwaka czy przełącznika nie może powodować przerejestrowania.
- Skrót, którego system nie przyjął, trafia na listę błędów (akcja + kombinacja), pokazywaną w
  zakładce Shortcuts (czerwony tekst, patrz wyżej). Akcja pozostaje wtedy nieosiągalna globalnie
  (w trybie celowania nadal działa, bo tam klawisze są rozpoznawane z surowych zdarzeń).
- Rejestrator **nie wykrywa konfliktów** między akcjami WindowQueue: można przypisać tę samą
  kombinację dwóm akcjom; w trybie celowania wygra akcja wcześniejsza w kolejności „#”, a globalnie
  zależy to od systemu (drugi identyczny skrót może się nie zarejestrować i pojawić na liście
  błędów). Reimplementacja może to poprawić (ostrzeżenie o duplikacie), ale nie jest to wymagane.

#### Rejestrator skrótu (`ShortcutRecorder`)

Pole 130 × 24 pt z zaokrąglonymi rogami (promień 5), tekst wyśrodkowany, 12 pt.

- Spoczynek: tło kontrolki, cienka szara ramka, tekst = bieżący skrót (np. `⌥⇧W`) albo „Unset”,
  gdy brak.
- Klik → pole przejmuje klawiaturę i wchodzi w nagrywanie: tło w kolorze akcentu z 15% kryciem,
  ramka i tekst w kolorze akcentu, tekst „Press keys…”.
- Następne naciśnięcie klawisza w trybie nagrywania:
  - **Escape** (z dowolnymi modyfikatorami) — anuluje, skrót bez zmian. Escape nie może więc być
    przypisany.
  - Klawisz z co najmniej jednym modyfikatorem (⌘ ⌥ ⌃ ⇧ — sam Shift też się liczy) — zapisuje
    kombinację, kończy nagrywanie i oddaje fokus. Zmiana działa od razu.
  - Goły klawisz bez modyfikatora — w zwykłym rejestratorze **systemowy sygnał dźwiękowy** i
    nagrywanie trwa dalej (goły klawisz nie może być globalnym skrótem). W rejestratorze trybu
    celowania goły klawisz jest przyjmowany.
  - Samo wciśnięcie modyfikatorów niczego nie zapisuje (czeka na klawisz niemodyfikujący).
- Utrata fokusu (klik gdzie indziej, Tab) kończy nagrywanie bez zmian.

#### Reset do domyślnych

Przycisk **„Reset all”** zastępuje wszystkie 36 globalnych skrótów domyślnymi dla *aktualnie
wybranego* super. Nie rusza super, `aimBindings`, `superDoubleTapAction` ani żadnych innych
ustawień. Bez potwierdzenia. Nie ma resetu pozostałych ustawień ani przywracania pojedynczego
skrótu.

#### Klawisze „Aiming mode only” (`aimBindings`)

Sekcja na dole listy skrótów. Nagłówek „Aiming mode only”, podpis: w trybie celowania każdy skrót
powyżej działa bez klawisza super; te klawisze działają tylko tam i mają pierwszeństwo, gdy
odpowiadałyby oba.

- Lista istniejących przypisań, posortowana po kluczu jako tekście (czyli leksykograficznie po
  dziesiętnym kodzie klawisza, np. „11” przed „9”). Wiersz: nazwa klawisza (czcionka o stałej
  szerokości, 60 pt), lista wyboru akcji (bez etykiety) — zmiana od razu zapisuje, przycisk
  usuwania (ikona „minus w kółku”, bez ramki) — usuwa od razu.
- Wiersz dodawania: tekst „Add a key”, rejestrator przyjmujący gołe klawisze, lista wyboru akcji
  (domyślnie „Start or stop recording the screen”; wartość tej listy nie jest zapisywana — po
  ponownym otwarciu okna wraca do domyślnej). Nagranie klawisza natychmiast dodaje (albo
  nadpisuje, jeśli klawisz już jest) przypisanie `kod → wybrana akcja`. Liczy się tylko kod
  klawisza — modyfikatory wciśnięte przy nagrywaniu są odrzucane. Po dodaniu pole wraca do „Unset”.
- Wybór akcji w obu listach: tylko 18 akcji grupy Queue (bez przełączania/przenoszenia na
  workspace).

Rozpoznawanie klawiszy w trybie celowania (klawiatura jest wtedy przejęta w całości, każde
naciśnięcie jest połykane):

1. Klawisze zarezerwowane przez sam tryb (po pozycji fizycznej): Return i Enter z klawiatury
   numerycznej (potwierdź), Spacja (potwierdź), Escape (anuluj), strzałki, `[`, `]`, `A` (zaznacz
   wszystko). Z Shiftem „rozszerzają” cel, z ⌥/⌘/⌃ „przesuwają” okna. **Przypisania
   `aimBindings` na te klawisze nigdy nie zadziałają.**
2. Inny klawisz bez żadnego modyfikatora → najpierw `aimBindings[kod]`.
3. Potem akcja, której globalny skrót dokładnie pasuje do naciśniętej kombinacji (pełny skrót z
   super też działa).
4. Potem, dla gołego klawisza: akcja, której skrót to dokładnie super + ten klawisz (więc skróty
   z super + ⇧ nie mają wersji „gołej”).
5. Nic nie pasuje → naciśnięcie jest połykane bez efektu.

#### Podwójne tapnięcie super (`superDoubleTapAction`)

- Dozwolone wartości: `nil` („Confirm the aim”) albo jedna z: `openLauncher`, `showOverview`,
  `search`, `toggleInvisibleStrip`, `toggleRecording`, `screenshotWindow`, `toggleMaximize`,
  `maximizeWindow`, `minimizeWindow`, `toggleGroup`, `closeWindow`, `sortByWorkspace`,
  `moveToStart`, `moveToEnd` (to, co ma sens bez uprzedniego wskazania okna).
- Gdy tryb celowania jest otwarty i drugie tapnięcie przychodzi **w ciągu 0,4 s od jego
  otwarcia**: jeśli ustawiona jest akcja — tryb jest zamykany bez potwierdzania, popup znika od
  razu i wykonywana jest akcja (na zwykłym zaznaczeniu, poza trybem celowania). Jeśli `nil` albo
  tapnięcie przyszło później — zwykłe potwierdzenie (fokus celowanego okna).
- Skutek uboczny ustawionej akcji: po otwarciu trybu celowania tapnięciem, jego widoczne elementy
  (przyciemnienie, popup, obrys, panel akcji) pojawiają się dopiero po 0,4 s, żeby przy podwójnym
  tapnięciu ekran nie mignął trybem. Klawiatura jest przejęta od razu. Przy `nil` oraz przy
  otwarciu trybu kliknięciem w odznakę — wszystko pokazuje się natychmiast.
- Kontrolka jest wyłączona, gdy `aimingEnabled = false`.

### Utrwalanie

- Miejsce: domena preferencji aplikacji (`com.mpochec.windowqueue`), klucz **`preferences.v1`**,
  wartość = **binarny blob z JSON-em** całej struktury (jeden obiekt). Na GNOME odpowiednik: jeden
  plik JSON w `~/.config/<app>/` albo jeden klucz GSettings z JSON-em — ważne, by zachować
  tolerancyjny odczyt opisany niżej.
- Format JSON: nazwy pól jak w tabeli; enumy jako surowe napisy; liczby jako liczby;
  `bindings` = obiekt `{"cycleNext": {"keyCode": 30, "modifiers": 2048}, …}`; `aimBindings` =
  obiekt `{"9": "toggleRecording"}` (klucz = kod klawisza zapisany dziesiętnie jako napis);
  `superDoubleTapAction` = napis albo **brak klucza** (dla `nil` klucz jest pomijany).
  Zapis zawiera wszystkie pola, także nieużywane (`stripWidth`, `includeMinimized`, `aimingScale`).
- Zapis: przy każdej zmianie, synchronicznie, tylko gdy nowa wartość różni się od poprzedniej.
  (Suwak zapisuje przy każdym kroku przeciągania.)
- **Świeża instalacja** (brak klucza albo blob nie daje się zdekodować jako obiekt): wszystkie
  pola domyślne, a `bindings` jest od razu wypełniane pełnym zestawem domyślnych dla Option. Blob
  zapisuje się dopiero przy pierwszej zmianie ustawień.
- **Tolerancyjny odczyt pole po polu**: każde pole jest czytane osobno; brakujące albo
  niepoprawne (zły typ, nieznana wartość enuma) dostaje wartość domyślną, a reszta się wczytuje.
  Dzięki temu dodanie nowego ustawienia nigdy nie unieważnia starego zapisu. Szczegóły:
  - pola-słowniki czytane są w całości: jeden zły wpis w `bindings` lub `aimBindings` (np. nazwa
    akcji, której już nie ma) zeruje cały słownik do domyślnego (`bindings` → `{}`, czyli w praktyce
    wszystkie skróty domyślne dla zapisanego super; `aimBindings` → `{}`);
  - brakujący wpis w `bindings` dla danej akcji → domyślny skrót tej akcji dla bieżącego super
    (tak nowe akcje dostają skróty u istniejących użytkowników);
  - **wyjątek**: `superDoubleTapAction` przy braku/błędzie dostaje `nil` („Confirm the aim”), a
    nie domyślne `search` — konieczne, bo `nil` zapisuje się jako brak klucza; skutek: użytkownik
    z zapisem sprzed tej opcji ma „Confirm the aim”;
  - legacy: jeśli nie ma `stripDisplay`, a jest stare `stripEnabled: false` → `hidden`.
- **Jednorazowa migracja „polskich liter”** (flaga `bindings.polishLettersFree.v1`, bool, w tej
  samej domenie preferencji):
  - uruchamia się przy starcie, gdy istnieje zapisany blob, a flaga nie jest ustawiona; flaga jest
    ustawiana **przed** migracją, więc migracja nigdy się nie powtórzy;
  - dla pięciu akcji sprawdza, czy zapisany skrót jest **dokładnie** dawnym domyślnym (dawny
    klawisz + modyfikatory obecnego domyślnego dla bieżącego super) i jeśli tak — zamienia na nowy
    domyślny:

    | Akcja | Dawny domyślny | Nowy domyślny |
    |---|---|---|
    | `openLauncher` | super + S | super + R |
    | `showOverview` | super + O | super + W |
    | `sortByWorkspace` | super + ⇧ + S | super + ⇧ + W |
    | `toggleRecording` | super + C | super + V |
    | `screenshotWindow` | super + X | super + P |

  - skróty ustawione przez użytkownika na cokolwiek innego zostają; skrót przywrócony na dawny
    klawisz już po migracji też zostaje (to wybór użytkownika);
  - jeśli cokolwiek się zmieniło, blob jest od razu zapisywany ponownie;
  - migracja nie sprawdza kolizji z innymi skrótami użytkownika (np. jeśli ktoś już miał coś na
    super + R);
  - świeża instalacja nie ustawia flagi, więc migracja wykona się (zwykle bez zmian) przy drugim
    uruchomieniu.
- Inne dane w tej samej domenie, **niebędące** ustawieniami z UI: `queueOrder.v1` (zapamiętana
  kolejność kolejki), `dockReservation.originalRect.v1` (kopia oryginalnego obszaru Docka do
  przywrócenia), oraz ukryte flagi diagnostyczne `diagnostics` i `debugCommands` (bool, ustawiane
  ręcznie z linii poleceń, włączają logowanie i polecenia debugowe).
- Brak funkcji „zapisz bieżące ustawienia jako domyślne”, eksportu/importu ustawień i resetu
  ustawień innych niż skróty. Domyślne wartości są stałymi w kodzie.

### Propagacja zmian

Przy każdej zmianie (i raz przy starcie) aplikacja:

- ustawia zakres kolejki i flagę auto-sortowania w modelu kolejki,
- przestawia detektor tapnięć na modyfikatory bieżącego super,
- przelicza rejestrację globalnych skrótów (tylko jeśli skróty się zmieniły),
- uzgadnia element logowania z `launchAtLogin`,
- aktualizuje rezerwację miejsca na ekranie (w następnym obiegu pętli zdarzeń),
- po **1 s bez żadnych zmian** (debounce — żeby przeciąganie suwaka nie restartowało niczego co
  krok) zapisuje odstęp dla Rectangle i restartuje go, jeśli wartość się zmieniła i Rectangle
  działa (specyficzne dla macOS).

Pozostałe ustawienia są czytane „na żywo” przy każdym użyciu (strip przerysowuje się od razu po
zmianie wyglądu).

Szerokość rezerwacji (używana w podpisie, rezerwacji i obszarze kafelkowania):
`ceil(iconSize + 20 + 2 × stripMargin)` pt; 0 w trybie niewidzialnym. Domyślnie
`34 + 20 + 8 = 62` pt.

### Uruchamianie przy logowaniu

- Domyślnie włączone. Działa tylko dla kopii zainstalowanej w `/Applications/`; kopia uruchomiona
  z katalogu budowania nigdy się nie rejestruje (rejestracja uruchamiałaby przy logowaniu starą
  wersję), a przełącznik w UI jest wtedy wyszarzony z podpisem o instalacji.
- Przy starcie i przy każdej zmianie: wł. i niezarejestrowane → rejestruj; wył. i zarejestrowane →
  wyrejestruj; w pozostałych przypadkach nic. Błędy tylko do logu diagnostycznego.
- Stan „wymaga zatwierdzenia” (system czeka na zgodę użytkownika) jest pokazywany w UI z
  przyciskiem otwierającym systemowe ustawienia elementów logowania.
- Użytkownik może też wyłączyć start w ustawieniach systemu — wtedy preferencja nadal mówi „wł.”
  i przy następnym starcie/zmianie aplikacja zarejestruje się ponownie.
- Na GNOME: plik `~/.config/autostart/<app>.desktop` tworzony/usuwany według tej samej logiki
  (tylko dla zainstalowanej kopii).

### Ikona w pasku menu

Aplikacja ma stałą ikonę w pasku menu (symbol „stos prostokątów”, opis dostępności
„WindowQueue”). Kliknięcie otwiera menu:

1. **„Settings…”** (⌘,) — otwiera okno ustawień.
2. **„Sort queue by workspace”** (⌘S) — ustawia `autoSortByWorkspace = true` i sortuje kolejkę po
   workspace'ach (to samo co skrót sortowania).
3. **„Refresh windows”** (⌘R) — wymusza ponowne wyliczenie okien.
4. separator
5. **„Quit WindowQueue”** (⌘Q) — zamyka aplikację (przed wyjściem oddaje zarezerwowany obszar
   Docka).

Skróty w nawiasach działają tylko przy otwartym menu. Na GNOME odpowiednikiem jest ikona w
obszarze powiadomień / wskaźnik rozszerzenia GNOME Shell z tym samym menu.

---

## Plan portu na GNOME

Ten rozdział zbiera decyzje, które trzeba podjąć przy przenoszeniu WindowQueue na GNOME, i proponuje
architekturę. Szczegółowe odpowiedniki poszczególnych mechanizmów systemowych są w rozdziale
„Warstwa systemowa” (sekcja „Odpowiedniki w GNOME”); tu jest obraz całości.

### Forma: rozszerzenie GNOME Shell, nie osobny program

Na Waylandzie zwykły program nie może wyliczać cudzych okien, fokusować ich, przesuwać ani
przechwytywać globalnie klawiatury — to wszystko robi kompozytor (Mutter, wewnątrz procesu
`gnome-shell`). Narzędzia z X11 (`wmctrl`, `xdotool`, `EWMH`) na Waylandzie nie działają. Dlatego
WindowQueue na GNOME powinien być **rozszerzeniem GNOME Shell** (GJS, moduły ESM, GNOME Shell 45+),
które ma bezpośredni dostęp do:

- `global.display` (`Meta.Display`) — okna, fokus, sygnały okien, monitory;
- `global.workspace_manager` (`Meta.WorkspaceManager`) — workspace'y;
- `Main.layoutManager` — warstwy interfejsu powłoki, monitory, rezerwacja miejsca (struts);
- `Main.wm` — globalne skróty (`addKeybinding`);
- `Shell.WindowTracker` / `Shell.AppSystem` — aplikacje i ikony okien;
- `St` / `Clutter` — widżety i animacje;
- `Main.pushModal` — przechwycenie klawiatury dla trybu celowania i wyszukiwarki.

Ustawienia: schemat GSettings rozszerzenia + okno `prefs.js` (GTK4 + libadwaita).

Wynika z tego, że duża część kodu macOS **znika**, bo istniała tylko po to, by obejść ograniczenia
tamtego systemu (patrz niżej), a model kolejki przenosi się niemal 1:1.

### Co znika, a co się upraszcza

| Mechanizm macOS | Na GNOME |
|---|---|
| Wyliczanie okien z dwóch źródeł (WindowServer + Accessibility), „ślepe” aplikacje Chromium, ⌘\` jako obejście, heurystyka popupów po geometrii, sprawdzanie `isOrderedIn` | Niepotrzebne: `Meta.Window` każdego okna na każdym workspace z typem (`Meta.WindowType.NORMAL`, `DIALOG`…), tytułem (`title`, `notify::title`), stanem (`minimized`, `notify::minimized`) i workspace'em (`get_workspace()`, `workspace-changed`). Okna do pominięcia: `skip_taskbar`, typy inne niż `NORMAL` (ewentualnie `DIALOG` z rodzicem — do decyzji). |
| Niewidoczne okienko-nośnik do przechodzenia na workspace; weryfikacja i ponawianie przełączenia; utrzymywanie zgodności z Dockiem | `workspace.activate(time)` / `workspace.activate_with_focus(win, time)` / `Main.activateWindow(win)` — deterministyczne, z animacją powłoki. Weryfikacja dotarcia nie jest potrzebna. |
| Przenoszenie okien na workspace tylko całymi aplikacjami | `win.change_workspace_by_index(i, false)` — pojedyncze okno, zawsze. Komunikat „aplikacja przenosi się tylko w całości” znika. |
| Fokus: pętla weryfikacji, ponowienia, `⌘\``, wyścigi aktywacji | `Main.activateWindow(win, time)` (fokus + raise + przejście na workspace) lub `win.activate(time)`. Fokus bez podnoszenia: `win.focus(time)`. Pętla weryfikacji zbędna. |
| Rezerwacja miejsca na strip: podmiana prostokąta Docka, „strażnik krawędzi” przycinający okna, integracja z Rectangle | `Main.layoutManager.addChrome(actor, { affectsStruts: true, trackFullscreen: true })` — struts rezerwują pas ekranu natywnie; maksymalizacja, kafelkowanie krawędziowe i `get_work_area_for_monitor()` automatycznie go omijają. |
| Prywatna przestrzeń WindowServera nad pulpitami, żeby strip nie migał przy zmianie workspace'u | Aktor chrome'u powłoki leży ponad `window_group` i nie należy do żadnego workspace'u — przy przełączaniu nie znika. Trzeba tylko świadomie zdecydować o widoczności w przeglądzie (overview) — patrz niżej. |
| Uprawnienia TCC (Accessibility, Screen Recording), podpisywanie kodu | Rozszerzenie ma pełny dostęp; brak odpowiednika. |
| Wykrywanie stuknięcia supera przez obserwację `flagsChanged` + wyjątki | Patrz „Klawisz super” — to jedno z nielicznych miejsc, które na GNOME jest *trudniejsze* lub wymaga decyzji. |

### Klawisz super i konflikty klawiatury

To najważniejsza decyzja projektowa portu.

- **Na Linuksie polskie znaki daje prawy Alt (AltGr)** w układzie „Polski (programisty)”; lewy Alt
  jest wolny. Mimo to Alt jako modyfikator globalnych skrótów koliduje z aplikacjami (menu GTK/Qt z
  mnemonikami `Alt+litera`, skróty terminali, edytorów, Emacsa, przeglądarek). **Zalecenie: jako
  super użyć klawisza Super (Windows/Meta).** To naturalny modyfikator menedżera okien na Linuksie i
  nie koliduje z polskimi znakami w ogóle.
- GNOME ma już wiele skrótów na Super, które trzeba **zdjąć lub przemapować** (w GSettings, najlepiej
  przez rozszerzenie przy włączeniu, z przywróceniem przy wyłączeniu — i z pytaniem użytkownika):
  - `org.gnome.shell.keybindings switch-to-application-1..9` (Super+1…9 — uruchamia/przełącza
    aplikacje z docka) → zwolnić dla przełączania workspace'ów;
  - `org.gnome.desktop.wm.keybindings switch-to-workspace-1..N` i `move-to-workspace-1..N` — można
    je po prostu ustawić na Super+N / Super+Shift+N zamiast rejestrować własne (patrz niżej);
  - `org.gnome.shell.keybindings toggle-application-view` (Super+A), `toggle-message-tray`
    (Super+V), `toggle-quick-settings` (Super+S), `focus-active-notification` (Super+N),
    `org.gnome.desktop.wm.keybindings minimize` (Super+H), `toggle-maximized` (Super+Up), lock
    screen (Super+L), `switch-input-source` (Super+Space!) — sprawdzić z tabelą domyślnych skrótów
    WindowQueue i rozstrzygnąć każdy konflikt.
- **Stuknięcie samego klawisza Super** w GNOME otwiera przegląd (overview). Mutter emituje wtedy
  sygnał `overlay-key` na `global.display` (klawisz ustawia `org.gnome.mutter overlay-key`, domyślnie
  `Super_L`). Rozszerzenie może przechwycić ten sygnał (odłączyć domyślny handler powłoki albo
  zastąpić `Main.overview.toggle` na czas działania) i otwierać tryb celowania — dokładnie ten sam
  gest co w WindowQueue. Przegląd (odpowiednik Mission Control) dostaje wtedy własny skrót
  (w macOS ⌥W → na GNOME Super+W). Mutter sam rozstrzyga, czy to było „czyste” stuknięcie (bez
  innego klawisza pomiędzy), więc cała logika `ModifierTapMonitor` z macOS jest niepotrzebna.
  Podwójne stuknięcie: mierzyć czas między dwoma sygnałami `overlay-key` (okno 0,4 s jak w
  oryginale).
- Jeśli użytkownik mimo to wybierze Alt jako super: `overlay-key` przyjmuje dowolny keysym (np.
  `Alt_L`), ale dokładnie sprawdzić interakcję z menu aplikacji. Nie wybierać `Alt_R`/AltGr.

### Globalne skróty

- `Main.wm.addKeybinding(name, settings, Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL, handler)`
  dla każdej akcji z tabeli akcji; nazwy kluczy = nazwy akcji, wartości w schemacie GSettings
  rozszerzenia jako tablice akceleratorów (`['<Super>bracketright']`).
- Przełączanie i przenoszenie na workspace można zrobić własnymi skrótami (żeby zachować zachowanie
  WindowQueue: sfokusowanie *zaznaczonego* albo pierwszego okna kolejki na docelowym workspace,
  pusty slot na pustym workspace, obsługę celowania) — zalecane, bo systemowe `switch-to-workspace-N`
  fokusuje „ostatnio używane” okno workspace'u, nie okno z kolejki.
- Rejestrować ponownie tylko przy zmianie skrótów (lekcja z macOS: ponowna rejestracja przy każdej
  zmianie ustawień gubiła wciśnięcia).
- Skróty trybu celowania nie są globalnymi skrótami — w trybie celowania klawiatura jest
  przechwycona (patrz niżej) i klawisze interpretuje sam tryb.

### Tryb celowania i wyszukiwarka: przechwycenie klawiatury

- `Main.pushModal(actor, { actionMode: Shell.ActionMode.POPUP })` przekazuje wszystkie zdarzenia
  klawiatury do aktora rozszerzenia; `Main.popModal(grab)` oddaje. Obsługa w
  `actor.connect('key-press-event', …)` z `Clutter.KEY_*` i `event.get_state()` dla modyfikatorów.
- Różnica względem macOS: w czasie modalnego przechwycenia aplikacja z fokusem dostaje na Waylandzie
  `wl_keyboard.leave` i może narysować się jako nieaktywna. `global.display.focus_window` się nie
  zmienia, a po `popModal` fokus wraca do tego samego okna — z punktu widzenia zasady „celowanie nie
  przenosi fokusu” to wystarcza. Zatwierdzenie = `popModal`, potem fokus na wycelowane okno.
- Zabezpieczenie z macOS („przechwycenie samo się zamyka po 15 s ciszy”) warto zachować.
- Klik poza panelami WindowQueue kończy tryb: przy `pushModal` zdarzenia myszy też idą do powłoki —
  obsłużyć `button-press-event` na aktorze przechwytującym (albo na `global.stage`) i sprawdzić, czy
  trafia w strip/panel grupy/kafelki akcji.

### Strip i nakładki

- Strip na każdy monitor: `St.BoxLayout` (pionowy dla krawędzi lewej/prawej, poziomy dla
  górnej/dolnej) w kontenerze na całą długość krawędzi. Dodany przez
  `Main.layoutManager.addChrome(container, { affectsStruts: <rezerwuj miejsce>, trackFullscreen: <ukrywaj w fullscreenie> })`.
  Rezerwacja miejsca na pasek o grubości stripu musi wynikać z osobnego, niewidocznego aktora o
  stałym rozmiarze (struts liczone z geometrii aktora), bo panel wizualnie „rośnie” w trybie celowania.
- Monitory: `Main.layoutManager.monitors`, `primaryIndex`, sygnał `monitors-changed`. „Wybrany
  monitor” = monitor okna z fokusem (`global.display.focus_window.get_monitor()`) albo
  `global.display.get_current_monitor()` (pod wskaźnikiem) — do decyzji; macOS używał ekranu z
  kluczowym oknem.
- Ikony: `Shell.WindowTracker.get_default().get_window_app(win).create_icon_texture(size)`; dla okien
  bez aplikacji — ikona zastępcza.
- Popup nazwy, panel grupy, kafelki akcji, menu kafelkowania, wyszukiwarka: aktory `St` w
  `Main.layoutManager.uiGroup` (`addTopChrome` dla tych, które mają być nad wszystkim), animacje
  `actor.ease({ … duration, mode: Clutter.AnimationMode.EASE_OUT_QUAD })`.
- Przyciemnienie ekranów w trybie celowania: półprzezroczysty `St.Widget` na każdym monitorze pod
  stripem, nad oknami.
- Obrysy wycelowanych okien i błysk fokusu: `St.Widget` ze stylem `border` w ramce
  `win.get_frame_rect()`, dodany nad `global.window_group`; śledzić `position-changed`/`size-changed`.
- Kolor numeru workspace'u zależny od jasności tła: w GNOME można pobrać piksele przez
  `Shell.Screenshot` (`screenshot_area`) albo prościej wyliczyć z tapety; to nice-to-have.
- Przegląd (overview): zdecydować, czy strip ma być widoczny w przeglądzie (chrome jest domyślnie
  widoczny ponad przeglądem, jeśli dodany do `uiGroup`). Tryb celowania powinien zamykać przegląd.

### Workspace'y — różnice modelu

- **W GNOME workspace obejmuje domyślnie wszystkie monitory**, a przy
  `org.gnome.mutter workspaces-only-on-primary = true` (domyślnie) okna na monitorach dodatkowych są
  na *wszystkich* workspace'ach. Numeracja „przez monitory” z macOS nie ma odpowiednika: w GNOME jest
  jedna lista workspace'ów i jeden bieżący, wspólny dla wszystkich monitorów. Konsekwencje:
  - numer na stripie jest ten sam na każdym monitorze;
  - okno „na wszystkich workspace'ach” (`win.is_on_all_workspaces()`, np. na monitorze dodatkowym
    albo przypięte) nie ma numeru — w zakresie `currentSpace` należy do każdego workspace'u;
    w sortowaniu po workspace'ach potrzebna reguła (propozycja: na końcu, jak okna bez numeru w
    macOS).
- **Dynamiczne workspace'y** (`org.gnome.mutter dynamic-workspaces = true`, domyślnie): GNOME sam
  dodaje pusty workspace na końcu i usuwa puste w środku. Kłóci się to z „pustym slotem” i z
  przełączaniem na pusty workspace N. Zalecenie: w ustawieniach rozszerzenia opcja „stała liczba
  workspace'ów” (ustawia `dynamic-workspaces=false`, `num-workspaces=9`), albo obsłużyć tryb
  dynamiczny: super+N dla N > liczba workspace'ów przechodzi na ostatni (pusty).
- Zmiana kolejności workspace'ów (przeciąganie w przeglądzie, `workspace_manager.reorder_workspace`)
  → sygnał `workspaces-reordered`; dodanie/usunięcie → `workspace-added`/`workspace-removed`;
  zmiana bieżącego → `active-workspace-changed`. Polling z macOS jest niepotrzebny.
- „Trzymanie opróżnionego workspace'u po zamknięciu ostatniego okna”: w GNOME przy dynamicznych
  workspace'ach pusty workspace w środku *znika*, a powłoka przechodzi gdzie indziej — trzeba albo
  wyłączyć dynamiczne workspace'y, albo pogodzić się z tym (i nie „trzymać”).

### Model kolejki

Rozdział „Model kolejki” przenosi się 1:1 do czystego modułu JS bez importów z `gi://` — dzięki
temu testy jednostkowe (przepisane z `WindowQueueModelTests`) działają pod `gjs` lub Node bez
powłoki. Identyfikator okna: `win.get_id()` (stabilny w sesji). Klucz do zapamiętania kolejności
między sesjami: `app id` (z `Shell.WindowTracker`) lub `wm_class` + tytuł — jak w macOS (bundle id +
tytuł), z tą samą logiką dopasowania.

### Kafelkowanie

- Obszar roboczy: `workspace.get_work_area_for_monitor(monitorIndex)` — już pomniejszony o strip
  (struts), więc wzory z macOS („obszar ekranu minus strip”) upraszczają się do „obszar roboczy”.
- Ustawienie ramki: `if (win.get_maximized()) win.unmaximize(Meta.MaximizeFlags.BOTH)`, potem
  `win.move_resize_frame(true, x, y, w, h)`. Niektóre aplikacje (terminale z siatką znaków)
  zaokrąglają rozmiar — zachować tolerancję przy porównaniach (macOS: 12 px pozycja, 24 px rozmiar).
- Wykrywanie ręcznego przesunięcia/zmiany rozmiaru okna z grupy kafelkowej: sygnały okna
  `position-changed`, `size-changed` + `global.display` `grab-op-begin`/`grab-op-end` (odróżnia
  przeciąganie myszą od zmian programowych). Zmiany wywołane przez WindowQueue przez krótki czas
  ignorować (macOS: 2 s po ułożeniu).
- Własny tryb fullscreen WindowQueue (wypełnienie obszaru roboczego, nie systemowy pełny ekran):
  zapamiętać `get_frame_rect()`, ustawić ramkę na obszar roboczy; przywrócić zapamiętaną. Można też
  użyć `win.maximize()` — ale wtedy trzeba odróżniać maksymalizację użytkownika od trybu skupienia.

### Pozostałe funkcje

| Funkcja | GNOME |
|---|---|
| Fokus/raise | `Main.activateWindow(win)`; bez podnoszenia: `win.focus(global.get_current_time())` |
| Focus follows mouse | Można zdać się na GNOME: `org.gnome.desktop.wm.preferences focus-mode 'sloppy'`, `auto-raise true`, `auto-raise-delay` (ms). Własna implementacja: śledzenie wskaźnika (`global.get_pointer()` w timerze lub zdarzenia `Clutter`), okno pod wskaźnikiem z `global.get_window_actors()` w kolejności stosu, reguły ignorowania jak w macOS. |
| Zamknij okno | `win.delete(global.get_current_time())` |
| Minimalizuj | `win.minimize()`; przywrócenie: `win.unminimize()` + `activate` |
| Przenieś na workspace N | `win.change_workspace_by_index(N-1, false)` |
| Przełącz workspace | `global.workspace_manager.get_workspace_by_index(N-1).activate_with_focus(win, time)` albo `.activate(time)` dla pustego |
| Przegląd (Mission Control) | `Main.overview.toggle()` |
| Launcher | Przegląd z polem wyszukiwania (`Main.overview.show()` + fokus na wyszukiwanie) albo zewnętrzny launcher (`Gio.Subprocess`, np. Ulauncher/Albert) — ustawienie jak Spotlight/Raycast/Alfred w macOS |
| Nagrywanie ekranu | D-Bus `org.gnome.Shell.Screencast` (`Screencast`/`StopScreencast`) dostępny wewnątrz powłoki; albo wbudowany `Main.screenshotUI` w trybie wideo. Wskaźnik nagrywania na stripie zamiast numeru. |
| Zdjęcie okna | `new Shell.Screenshot().screenshot_window(includeFrame, includeCursor, stream)` do pliku w `~/Pictures/Screenshots` (lub katalogu z `org.gnome.gnome-screenshot`/XDG) — nazwa z aplikacją i datą, jak w macOS |
| Zapamiętanie kolejki | plik JSON w `~/.local/share/<uuid-rozszerzenia>/` albo klucz GSettings (tablica stringów) |
| Uruchamianie przy logowaniu | niepotrzebne — rozszerzenie włącza się z sesją |
| Pasek menu (status item) | `PanelMenu.Button` w górnym panelu z tymi samymi pozycjami menu |
| Diagnostyka | `console.log` (journal: `journalctl /usr/bin/gnome-shell -f`) + opcjonalny plik; polecenia debugowe przez D-Bus rozszerzenia zamiast rozproszonych powiadomień |

### Proponowana kolejność prac

1. **Model** — czysty moduł JS + testy przepisane z macOS (wszystkie reguły z rozdziału „Model
   kolejki”). Bez tego reszta nie ma sensu.
2. **Enumeracja + strip tylko do odczytu** — lista okien, ikony w kolejności, zaznaczenie podąża za
   fokusem, numer workspace'u, nowe okna za zaznaczonym, zapamiętywanie kolejności.
3. **Skróty podstawowe** — cykl, przesuwanie w kolejce, zamknij/minimalizuj/maksymalizuj, super+N,
   super+⇧+N, popup nazwy.
4. **Interakcje myszą na stripie** — klik, przeciąganie, kółko, środkowy klik, hover.
5. **Pusty slot, zakres `currentSpace`, sortowanie po workspace'ach, auto-sort.**
6. **Tryb celowania** — przechwycenie klawiatury, serie, przypinanie, zaznacz wszystko,
   przyciemnienie, obrysy, stuknięcie/podwójne stuknięcie supera, kafelki akcji.
7. **Kafelkowanie i grupy kafelkowe**, potem **grupy** z panelem grupy, potem **tryb fullscreen**
   z kafelką stosu.
8. **Wyszukiwarka okien**, launcher, przegląd, tryb niewidzialny, nagrywanie i zdjęcia, błysk
   fokusu, focus follows mouse.
9. **Ustawienia** (`prefs.js`) — na bieżąco przy każdym etapie dodawać klucze do schematu.

### Pułapki specyficzne dla GNOME

- Rozszerzenie musi po `disable()` posprzątać wszystko: odłączyć sygnały, usunąć skróty, aktory,
  przywrócić zmienione ustawienia GNOME (overlay-key, skróty Super, dynamiczne workspace'y). Powłoka
  wyłącza rozszerzenia np. na ekranie blokady.
- Błąd w rozszerzeniu może wyłożyć całą powłokę (na Waylandzie — całą sesję). Ciężką pracę (np.
  dopasowanie kolejki po restarcie) robić w małych krokach; obsługiwać wyjątki w handlerach sygnałów.
- Okna pojawiają się, zanim mają tytuł i aplikację (`window-created` przychodzi wcześnie); czekać na
  pierwszy `notify::title`/`shown` lub odroczyć (`GLib.idle_add`) przed wstawieniem do kolejki —
  odpowiednik macOS-owego „przyjmij fokus okna, którego jeszcze nie znamy, przy następnym
  odświeżeniu”.
- Okna Xwayland i natywne Wayland zachowują się tak samo z punktu widzenia `Meta.Window`, ale ikony
  aplikacji Xwayland bez pliku `.desktop` bywają puste.
- API powłoki zmienia się między wersjami (45: przejście na ESM; 46–48: drobne zmiany w
  `LayoutManager`, `Screencast`). Zadeklarować obsługiwane wersje w `metadata.json`.
