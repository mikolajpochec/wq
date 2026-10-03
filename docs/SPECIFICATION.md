# WindowQueue — functional specification

A complete description of how WindowQueue (macOS) works, for the purpose of reimplementing it on another system, in
particular as a GNOME Shell extension on GNU/Linux. It describes behavior, not code: rules,
algorithms, numbers, message texts and edge cases, so that they can be reproduced without
access to the Swift sources. State as of commit `face354` plus the changes to shortcuts free of
Polish letters (⌥R, ⌥W, ⌥⇧W, ⌥V, ⌥P).

Where the original behaves strangely or inconsistently, the chapters say so explicitly and give a
recommendation for the new implementation — look for paragraphs about "quirks", "discrepancies" and
"inconsistencies".

## Table of contents

1. [What is WindowQueue](#what-is-windowqueue) — concepts, overriding principles, architecture
2. [Queue model](#queue-model) — queue, selection, aiming, groups, fullscreen mode, empty slot, persistence, search
3. [Interface: strip, panels and overlays](#interface-strip-panels-and-overlays) — appearance, metrics, animations, mouse interactions
4. [Actions, shortcuts and aiming mode](#actions-shortcuts-and-aiming-mode) — every action in every context, tiling, messages
5. [System layer](#system-layer) — windows, workspaces, focus, global shortcuts, space reservation, GNOME equivalents
6. [Settings](#settings) — all options, default values, shortcuts, persistence
7. [GNOME port plan](#gnome-port-plan) — extension architecture, model differences, order of work


---

## What is WindowQueue

WindowQueue is a "Linux-WM-style" window manager layered on top of the system's ordinary desktop. It does not
replace the window manager — it works alongside it and provides three things:

1. **A window queue** — a single ordered list of all windows of all applications (or only of the
   current workspace), navigated from the keyboard. The order is *stable*: it is set by the
   user, not the system, and it does not change merely from switching focus.
2. **The strip** — a narrow bar stuck to the edge of the screen, always on top, showing window icons
   in queue order, the selection and the number of the current workspace. When switching workspaces
   the strip neither moves nor flickers: the desktops slide underneath it.
3. **Workspace handling by number** — switching to workspace N and moving windows to it
   with the shortcuts super+N / super+⇧+N, with numbering matching the system's.

Built on top of this are: **aiming mode** (choosing a window or a group of windows without moving focus, then
an action on the chosen ones), **tiling** of chosen windows into layouts, window **groups**, **fullscreen mode**
concentrating the queue on a single window, the **window finder**, **focus follows mouse**, screen
recording and window snapshots.

The program is a menu-bar application (no Dock icon) controlled almost exclusively by keyboard, with
the mouse as a second route to everything (click, drag, scroll wheel, middle button on the strip).

### Glossary

Terms used throughout the specification (code names in parentheses):

| Term | Meaning |
|---|---|
| **window** (`ManagedWindow`) | A standard application window that qualifies for the queue: system identifier, application PID, application name and icon, title, minimized state, workspace. Panels, menus, popups, tooltips, WindowQueue's own overlays — not. |
| **queue** (`windows`) | The ordered list of all known windows. The sole source of order. |
| **scope** (`scope`) | `global` — the strip and cycling cover all windows; `currentSpace` — only the windows of the current workspace. It is a *view* onto the same queue; hidden windows keep their places. |
| **visible slice** (`visibleWindows`) | The queue windows that the scope lets through, in queue order. All positions on the strip and when dragging are computed within this slice. |
| **selection** (`selectedID`) | The window the queue considers current. Usually the window with focus. May be empty (e.g. on an empty workspace). |
| **workspace** (on macOS: Space/desktop) | A virtual desktop. Numbered from 1 in Mission Control order, *across all monitors* (monitor 1: 1–3, monitor 2: 4–5 etc.). Applications' fullscreen spaces have no number. |
| **empty slot** (`emptySlot`) | A marker on the strip when the current workspace has no windows: it shows the place in the queue where its windows would appear. Nothing is selected then. |
| **super** | The modifier key for all shortcuts (⌥ Option by default; may be ⌃, ⌘, ⌃⌥, ⌘⌥). A mere *tap* of super (without another key) opens aiming mode. |
| **aiming mode** (aiming) | A mode in which the keyboard moves the **aim** (`aimingID`) along the strip without focusing anything; confirming focuses the aimed window or opens actions for several windows. |
| **run** (run) | A contiguous range of adjacent windows covered by the aim, from the **anchor** (`aimAnchorID`) to the aim. |
| **pinned** (`aimPinnedIDs`) | Windows added to the target one by one (Shift+click), not necessarily adjacent. |
| **group** (`WindowGroup`) | A set of windows shown on the strip as a single entry; entering the group opens a **group panel** beside it — a second strip with its windows. The queue does not change. |
| **tiled group** (`TiledGroup`) | Windows arranged together into a layout (e.g. side by side). It holds the layout; changing their order in the queue re-lays them out; manually moving/resizing any of them dissolves it. |
| **fullscreen / focus mode** (`maximizedID`, "focus") | A window enlarged with the fullscreen shortcut becomes first on its workspace, the other windows of that workspace are **covered**: dimmed in blue or collapsed into a **stack tile**, and skipped when cycling. Pressing the shortcut again restores size and order. This is not the system's full screen. |
| **stack tile** (hidden stack) | A single strip element replacing the window in fullscreen mode and all the windows it covers: a cascade of icons with a "+N" counter. |
| **toast / name popup** | A small bubble next to an icon on the strip with the window title and application name; a variant centered on the screen for actions on multiple windows. |
| **invisible mode** (invisible strip) | The strip hidden off-screen, shown only in aiming mode (it unfolds like a page). |
| **carrier** (carrier) | A macOS implementation detail: an invisible little WindowQueue window moved to the target workspace so that the system "follows" it. Unnecessary on GNOME. |

### Overriding principles

These rules apply everywhere and every implementation must follow them:

1. **The order is stable.** A new window goes *directly after* the selected one (like a client in a
   tiling WM), not at the end. Cycling never changes the order. The order is changed only by:
   the move shortcuts, dragging on the strip, sorting by workspace (manual or
   automatic), moving a window to another workspace (the window goes into the "block" of its new
   workspace when automatic sorting is enabled) and fullscreen mode (temporarily).
2. **Manual arrangement beats automatic.** Automatic sorting by workspace turns itself off
   on the first manual reordering of the queue; the "Sort by workspace" shortcut/menu turns it
   back on.
3. **The order survives a restart.** It is saved continuously and restored after relaunch
   by matching windows by application and title.
4. **Aiming mode does not move focus** until the user confirms. The keyboard is
   captured globally (keys do not reach the frontmost application), but no window
   loses focus. Escape leaves everything as it was.
5. **Workspace numbers are system numbers.** The number on the strip, in the super+N shortcuts and when
   moving windows is always the same numbering as in the system's desktop overview.
6. **The strip never captures anything other than its icons.** Empty areas of the panel pass
   clicks through to the windows underneath; the panel does not resize when windows are added/removed —
   the content animates inside it.
7. **Nothing "steals" the user.** Automatic mechanisms (retrying a switch, holding on to an
   emptied workspace, focus follows mouse) give way when the user has done something else in the
   meantime.
8. **An action on multiple windows says what it did** — with a popup in the center of the screen, because there is no single icon
   next to which it could be shown.

### macOS application architecture (for orientation)

Components and data flow — the port does not have to reproduce them 1:1, but the division is sensible:

- **Model** (`WindowQueueModel`) — all the logic of the queue, selection, aiming, groups, fullscreen
  mode and the empty slot. Pure state + operations, without system calls; it publishes changes
  (an observable object) to which the views react. It is fully unit-testable.
- **Enumerator** (`WindowEnumerator`) — discovers windows and their workspaces, reacts to system
  events (new window, close, focus change, title change, minimization, workspace change)
  and every few seconds performs a full reconciliation (`reconcile`). The current workspace reading is also
  checked every 0.4 s.
- **Controller** (`AppDelegate`) — maps shortcuts and clicks to model operations and system
  calls; drives aiming mode, tiling, closing, moving, workspace
  switching, fullscreen, recording.
- **System layer** — focusing windows (`WindowFocuser`), closing (`WindowCloser`),
  workspaces (`SpacesBridge`, `SpaceSwitcher`, `WindowSpaceMover`), global shortcuts
  (`HotkeyManager`), detecting a tap of super (`ModifierTapMonitor`), capturing the
  keyboard in aiming mode (`AimingKeyCapture`/`KeyboardGrabber`), focus follows mouse,
  reserving space for the strip (`DockReservation`, `ScreenEdgeGuard`), arranging windows
  (`WindowTiler`), recording and snapshots (`ScreenCapture`).
- **Interface** — a strip on every monitor (`StripController`/`StripView`/`StripLayout`), the group
  panel, the name popup (`ToastController`), screen dimming, window outlines, the tiling menu,
  action tiles, the finder, the settings window, the menu bar icon.
- **Settings** (`Preferences`) — a single structure, saved in full on every change;
  all components react to changes live.

Flow of a typical action: shortcut → controller → model operation (e.g. `cycle(by: 1)` returns the new
selected window) → system call (focus that window, first going to its
workspace if necessary) → the model publishes the change → the strip redraws the selection, the popup shows the name.
Events from the system flow the other way: the system reports a focus change → the enumerator accepts it as the
selection (unless focusing of another window at WindowQueue's request is in progress right now) → strip.

### How to read the following chapters

- **Queue model** — logical rules; the most important chapter for the port's correctness, independent of
  the platform.
- **Interface** — appearance and behavior of the strip, panels and overlays, with numbers.
- **Actions, shortcuts and aiming mode** — what each action does in each context.
- **System layer** — what the system integration must provide, how macOS does it and how to do it
  in GNOME.
- **Settings** — the full list of options with default values.
- **GNOME port plan** — the proposed GNOME Shell extension architecture and order of work.

Numerical values (times, sizes) come from the code and are a starting point; where they resulted from
macOS limitations (e.g. delays for the Mission Control animation), the chapters point this out.

---

## Queue model

This chapter describes the application's pure data model (`WindowQueueModel` and related types): what it stores, what operations it has and what rules govern them. The model does not talk to the system: it receives from the system layer a list of windows, a window→workspace map, the identifier of the current workspace and the order of workspaces, and it returns state that the strip draws and that the keyboard shortcuts read. Everything below must be implementable and testable without any window manager.

Conventions in the examples:
- windows are denoted by numbers (`1`, `2`, …); the queue `[1,2,3]` is the order from the start (top/left side of the strip) to the end;
- workspaces (workspace, "desktop") have identifiers `10`, `20`, `30`, and `spaceOrder = [10,20,30]` means they are workspaces no. 1, 2, 3; the notation `1(10)` = window 1 on workspace 10;
- "the current workspace" is `currentSpaceID`;
- unless stated otherwise, `autoSortByWorkspace = true`, `scope = global`, and the model has been fed via `reconcile` with the given list.

Every state mutation described below must notify observers (the UI redraws the strip after every change of a published property). Where a rule says "nothing happens", no notification should be sent either.

---

### 1. Window entry (`ManagedWindow`)

One entry = one "standard" window of another application (not panels, not auxiliary dialogs — the enumeration layer filters these out).

| Field | Type | Meaning |
|---|---|---|
| `id` | integer (u32) | window identifier assigned by the window server; the **sole identity** of the entry during a session. Immutable. |
| `element` | optional handle | accessibility (AX) handle for controlling the window; may be empty (a window seen only "from afar", e.g. on another workspace). On GNOME the equivalent is a reference to the window object. |
| `pid` | int | owning process. Immutable. |
| `appName` | text | displayed application name. |
| `bundleID` | text? | stable application identifier (on GNOME: app id / `.desktop` file); may be empty. |
| `title` | text | window title; may be empty. |
| `isMinimized` | bool | window is minimized. |
| `spaceID` | u64? | the workspace the window lies on; empty = unknown (e.g. a minimized window or one not yet determined). |

Derived values:
- `displayTitle` = `title`, and when `title` is empty — `appName`.
- `orderKey` = `(bundleID ?? appName)` + the character U+0001 + `title`. An identity that "survives a restart" (window identifiers are valid only within a session). Example: a window of an application without `bundleID`, `appName = "App1"`, `title = "w3"` → `"App1\u{1}w3"`.
- `icon` — the application icon by `pid`, from a cache (the same image instance for a given `pid`, so that animations do not flicker); entries for dead processes are removed from the cache when a new one is added.

**Entry equality** (used to detect "whether anything changed"): two entries are equal when they have equal `id`, `title`, `isMinimized` and `spaceID`. The fields `element`, `pid`, `appName`, `bundleID` do **not** take part in the comparison. Consequence (to be deliberately preserved): if during merging only e.g. the application name changed or an `element` appeared, and nothing else changed, `reconcile` will consider the list unchanged and will not store the new values (see §6, step 7).

---

### 2. Model state

| Field | Description |
|---|---|
| `windows` | ordered list of entries — the **queue**. The sole truth about order. |
| `selectedID` | the selected window (the one the user "is on"); may be empty. |
| `scope` | `global` ("All windows (global)") or `currentSpace` ("Current workspace only"). Default `global`. Mirror of the preference. |
| `autoSortByWorkspace` | keeping the queue grouped by workspace. Default `true`. Mirror of the preference. |
| `currentSpaceID` | id of the current workspace; empty before the first reading. |
| `currentSpaceIndex` | number of the current workspace for display (set from outside, the model does not interpret it). |
| `currentSpaceIsFullscreen` | whether the display with the strip is showing a fullscreen space (information for the UI only). |
| `spaceOrder` | list of ids of "ordinary" workspaces in system order; position+1 = workspace number. |
| `emptySlot` | "empty place" marker: `{spaceID, beforeID?}` or none (§8). |
| `slotFilledID` | the window that has just taken the empty slot (animation hint, §8). |
| `maximizedID` | the window in focus mode (application "fullscreen", §10). |
| `placeBeforeMaximize` | (private) the window's neighbors from before focus: `{after: id?, before: id?}`. |
| `groups` | list of window groups `WindowGroup {id: Int, ids: [id]}` (§11). |
| `openGroupID` | the group currently "open" (shown beside the strip). |
| `tiledGroups` | list of tiled groups `TiledGroup {id: Int, ids: [id], layout: String}` (§13). |
| `aimingID` | the window the aim points at; empty = aiming mode off (§12). |
| `aimAnchorID` | anchor of the aiming range. |
| `aimPinnedIDs` | set of windows picked one by one (Shift‑click / "all"). |
| `aimInsideGroupID` | the group the aim has "entered". |
| `lastAimStep` | direction of the aim's last step (number ≠ 0; initially `1`). |
| `announcement` | stream of "announce this window" events (§14). |
| `onManualReorder` | callback invoked when the user has manually changed the order (§7.4). |

Observers reacting to property changes:
- change of `currentSpaceID` (to a different value) → `updateEmptySlot(clearingSelection: true)`;
- change of `spaceOrder` (to a different value) → if `autoSortByWorkspace`, `sortByWorkspace()`; then `updateEmptySlot()` (without clearing the selection).

The system layer sets `spaceOrder` first and only then `currentSpaceID`, so that the slot on arrival at a workspace is already computed according to the new order.

---

### 3. Queue and stability rules

The queue is a single list of all known windows, from all workspaces, including minimized ones. Rules:

1. **Cycling never changes the order.** The selection travels along the list, the list stays put.
2. **The scope is a view**, not a copy: filtering to the current workspace does not change `windows`, so the manual order survives switching workspaces.
3. The order is changed exclusively by:
   - explicit reordering operations (§9) — these are "manual" changes, they turn off auto‑sorting;
   - `sortByWorkspace()` (automatic or on demand) — a stable sort;
   - inserting new windows and removing vanished ones in `reconcile` (§6);
   - `relocate` (windows moved to another workspace, §7.3);
   - entering/leaving focus mode (§10);
   - `applyOrder` (restoring the saved order, §15).
4. **A new window lands directly after the selected window** (as in tiling WMs, which insert next to the active client), not at the end. When nothing is selected (or the selected one is just vanishing) — at the end. Exception: a window opening on an empty current workspace takes the empty slot (§8).
5. With auto‑sorting, the sort is **stable**, so a manual arrangement within a single workspace is preserved.
6. First feed (empty queue): windows arrive from enumeration sorted by `(spaceID ?? +∞, id)` — grouped by workspace, within a workspace ascending by id (≈ creation order). All of them are "new", so they enter the queue in that order.

---

### 4. Scope and visible slice

`visibleIndices` — indices in `windows` visible in the current scope; `visibleWindows` — the corresponding entries, **in queue order**.

Algorithm:
1. If `scope == global` or `currentSpaceID` is empty → all indices.
2. Otherwise `filtered` = indices of windows with `spaceID == currentSpaceID` (minimized ones with an empty `spaceID` automatically drop out; minimized ones with a known `spaceID` of the current workspace stay).
3. If `filtered` is empty **and** `currentSpaceID` does **not** belong to `spaceOrder` (a fullscreen space or one not yet read) → **fallback: all indices** (the strip must not become empty because of an unrecognized workspace).
4. If `filtered` is empty and the workspace is a known ordinary workspace → the slice is empty (the strip then shows only the empty slot).
5. Otherwise `filtered`.

Notes:
- Changing `scope` does not by itself touch the selection; the selected window may end up outside the slice (then operations "from the selection" behave as if there were no selection — see below).
- The window finder deliberately ignores the scope and always searches the whole of `windows`.

Workspace numbering:
- `workspaceNumber(ofSpace s)` = position of `s` in `spaceOrder` + 1, or none when `s` does not occur.
- `workspaceNumber(of window)` = the number of its `spaceID`; none for a window without `spaceID` or on an unknown workspace.
- `groupBounds(of id)` (helper): in `visibleWindows` find the position of `id`, extend to the left and to the right as long as the neighbor has the same workspace number (none == none also counts); returns the position range `[lower…upper]` or none when the window is not in the slice.

---

### 5. Selection

#### 5.1 `select(id, announce)`
1. If there is no window with `id` in `windows` → nothing.
2. `openGroupID` = id of the group the window belongs to, or none — **selecting a window in a group "enters" it, selecting anything else "leaves" it**.
3. `selectedID = id`.
4. `emptySlot = none` (every explicit selection removes the empty slot marker).
5. If `announce` → send `announcement(window)`.

A window does not have to be in the visible slice to be selectable.

`selectedWindow` = the entry with `selectedID` (searched in the whole of `windows`).

#### 5.2 Windows reachable when cycling
`cyclableWindows(backwards)`:
1. `reachable` = `visibleWindows` without **covered** windows (`isCovered`, §10).
2. From `reachable` remove the windows for which `isSkippedInsideGroup(w, backwards, among: reachable)`:
   - window not in a group → not skipped;
   - the window's group is open (`openGroupID`) → not skipped (an open group is traversed window by window);
   - otherwise: `members` = the windows of that group present in `reachable`, in queue order; the window is skipped unless it is the **first** of `members` (when moving forward) or the **last** (when moving backward).

So a closed group is **a single stop**, and the group is "entered" from the side one is coming from. Computed among the reachable ones: if the first/last member is outside the slice or covered, the stop is the first/last member that is reachable — a group never drops out of the rotation.

#### 5.3 `cycle(by delta)` — cycling with wrap-around
1. `stops = cyclableWindows(backwards: delta < 0)`. Empty → return none, change nothing.
2. `current` = position of `selectedID` in `stops`; if it is not there (no selection, window covered, outside the slice, skipped member of a closed group): `-1` for `delta > 0`, `0` for `delta ≤ 0`. Effect: forward starts from the first stop, backward from the last.
3. `next = ((current + delta) mod n + n) mod n` (wrap-around in both directions; `delta` may be > 1, e.g. when scrolling the wheel several steps at once).
4. `select(stops[next], announce: true)` and return that window.

Examples:
- `[1(10), 2(20), 3(10)]`, `scope = currentSpace`, current 10, selected 1: `cycle(+1)` → 3, `cycle(+1)` → 1 (window 2 does not exist in the slice).
- `[1,2,3,4]` on one workspace, group `{2,3}`, selected 1: `+1` → 2 (the group opens), `+1` → 3, `+1` → 4 (the group closes).
- The same, selected 4: `-1` → **3** (last member; `openGroupID = 1`), `-1` → 2, `-1` → 1 (`openGroupID = none`).
- `[1(10), 2(10), 3(20), 4(10)]`, `scope = currentSpace`, current 10, group `{2,3}`, selected 4: `-1` → **2** (3 is outside the slice, so the stop is 2), group open.
- Empty slice (an empty workspace in the `currentSpace` scope) → `cycle` returns none.
- Focus on 3 in `[3,1,2 (10), 4(20)]`: 1,2 covered; `+1` from 3 → 4, `+1` → 3.

Edge case to preserve: if the selected window is a member of a group that is not open (e.g. the group was created when it was already selected, and `select` was not called), and it is not a stop, then `current` = none → start from the end of the list as in step 2.

#### 5.4 `clampSelection()` (called at the end of `reconcile`)
1. If `selectedID` points to a window present in `windows` → nothing.
2. If `emptySlot` exists → `selectedID = none` (on an empty workspace nothing is to be selected).
3. Otherwise `selectedID` = the first window of `visibleWindows` (or none). Without announcement and without changing `openGroupID`.

#### 5.5 `neighbour(after id)` — successor after closing (window not on the current workspace)
In `visibleWindows`: if the window is not there or the slice has ≤ 1 window → none. Otherwise the next window, and if `id` is the last — the previous one.

#### 5.6 `nearestWindow(on space, to id, in order, excluding)` — nearest window on a workspace
1. `origin` = position of `id` in the list `order` (a list of ids); none → result none.
2. Candidates: `visibleWindows` (note: in the current scope) with `id ≠ id`, `spaceID == space`, not minimized, not in `excluding`.
3. A candidate's distance = `|position in order − origin|`; a candidate absent from `order` has distance +∞.
4. Result: the candidate with the smallest distance; on a tie, **the first in the current queue order** (i.e. usually the preceding neighbor). Covered windows are not excluded.

Example: `[1(10), 2(20), 3(20), 4(20)]`, current 20, selected 3 is closed → 2 and 4 have distance 1, 2 wins.

Application behavior when closing a window (call context): before the window disappears, a successor is chosen — if the window is on the current workspace: `nearestWindow(on: its workspace, to: id, in: the whole current queue)`; otherwise `neighbour(after:)`. The successor is selected (`announce: false`). When there is no successor and the window was on the current workspace, after the window disappears `reconcile` will show the empty slot.

---

### 6. `reconcile(with discovered)` — merging a fresh enumeration

Input: the complete, current list of windows from the system layer (unique ids), in the order `(spaceID ?? +∞, id)`. Algorithm step by step:

1. `byID` = dictionary `id → entry` from `discovered`.
2. `previousOrder` = list of ids of the current queue (before the change). `vanishedSelection` = the current entry of the selected window, if its id is **not** in `discovered` (otherwise none).
3. **Merging existing ones** — for each entry `existing` in `windows`, in queue order:
   - if it is not in `byID` → skip (the window vanished);
   - take the fresh entry `u = byID[id]`, but:
     - `u.spaceID = u.spaceID ?? existing.spaceID` (an unknown workspace does not erase a known one),
     - `u.element = u.element ?? existing.element` (a handle obtained earlier stays; the system sees details only of windows on the current workspace),
     - if `u.title` is empty → `u.title = existing.title`;
   - the remaining fields (`isMinimized`, `appName`, `bundleID`, `pid`) from `u`;
   - append `u` to `next`.
   The order of existing windows is preserved exactly.
4. `fresh` = entries from `discovered` whose id is not in `next`, in `discovered` order.
5. **Filling the empty slot**: if `emptySlot` exists and `fresh` contains a window for which `(spaceID ?? currentSpaceID) == emptySlot.spaceID` (we take the **first** such one):
   - remove it from `fresh`;
   - insert it into `next` at the position of the window `emptySlot.beforeID` (if that window is in `next`), otherwise at the end;
   - `emptySlot = none`; `selectedID = that window` (direct assignment: without announcement, without changing `openGroupID`);
   - `slotFilledID = that window`; after 0.8 s clear `slotFilledID`, but only if it still points to the same window.
6. **Inserting the remaining new ones**: if `fresh` is non-empty — insert them (as a block, in `fresh` order) directly after the `selectedID` window in `next`; if the selected one is not in `next` (no selection or it just vanished) → at the end. (If step 5 took effect, "the selected one" is already the window from step 5, so the rest of the new ones go right after it.)
7. If `next` is equal to `windows` (entry equality per §1, element by element) → **end, nothing more happens** (no cleanups, sorting or selection correction).
8. `windows = next`.
9. **Group cleanup** (if there are any): remove from each group the ids absent from the queue; remove groups with < 2 windows; if `openGroupID` points to a group that no longer exists → `openGroupID = none`. (Note: `aimInsideGroupID` is not cleared here — the model treats a reference to a nonexistent group as its absence.)
10. **Tiled group cleanup**: analogously — remove absent ids; groups < 2 disappear.
11. **Vanishing of the window in focus**: if `maximizedID` points to a window that no longer exists → `maximizedID = none`, `placeBeforeMaximize = none` (covering ends; nothing is reordered).
12. `keepAimOnQueue(previousOrder)` (§12.9).
13. If `autoSortByWorkspace` → `sortByWorkspace()`.
14. If `vanishedSelection` exists → `followVanishedSelection` (below).
15. `updateEmptySlot()` (without clearing the selection).
16. `clampSelection()`.

`followVanishedSelection(vanished, previousOrder)`:
- Takes effect only when `vanished.spaceID` is known and equal to `currentSpaceID` (the selected window was closed on the workspace the user is looking at).
- `nearest = nearestWindow(on: that workspace, to: vanished.id, in: previousOrder)`; if there is one → `selectedID = nearest` (without announcement, without changing `openGroupID`); if there is none → `showEmptySlot(for: that workspace)`.
- **Never moves the selection to a window from another workspace.** When a selected window from another workspace (or without a workspace) vanished, this step does nothing, and `clampSelection` will pick the first visible window.

Examples:
- `[1(10), 2(10), 3(20)]`, selected 1, `5(10)` appears → `[1,5,2,3]`.
- `[1(10), 2(20), 3(30)]`, current 20, selected 2; 2 vanishes → `[1,3]`, `emptySlot = {20, before: 3}`, `selectedID = none`. Then `4(20)` appears → `[1,4,3]`, `selectedID = 4`, `emptySlot = none`, `slotFilledID = 4` for 0.8 s.
- `[1(10), 2(20)]`, current 10, selected 1; 2 vanishes → the selection stays on 1, no slot.
- `[1,2,3]` on 10, selected 2, aiming at 2 is in progress; 2 vanishes → the aim moves to 1 or 3 (§12.9; on a tie to 1).

---

### 7. Workspaces

#### 7.1 `updateSpaces(mapping: id → spaceID)`
1. For each window in the queue: if the map has a value for it and it differs from the current one → set it. Windows absent from the map **keep** their existing `spaceID` (the map never erases a workspace).
2. If nothing changed → end.
3. If `autoSortByWorkspace` → `sortByWorkspace()`.
4. `updateEmptySlot()`.

#### 7.2 `sortByWorkspace()`
- `rank(w)` = position of `w.spaceID` in `spaceOrder`; a window without a workspace or on a workspace outside `spaceOrder` (e.g. a fullscreen one) has rank +∞.
- A **stable** sort ascending by rank (ties by existing position). Windows of unknown workspaces land at the end, in their existing order.
- If the result has the same id order → publish nothing.

Example: `[1(10), 2(20), 3(30)]`, `spaceOrder` changed to `[30,10,20]` → `[3,1,2]`.

When sorting fires automatically (only when `autoSortByWorkspace == true`): change of `spaceOrder`, `reconcile` (step 13), `updateSpaces` (when something changed), `applyOrder`, `endFocus` (after putting the window back in its place). It does **not** fire after `relocate`, `beginFocus` or after manual reorderings.

#### 7.3 `relocate(ids, toSpace space)` — windows moved to another workspace
1. If `ids` is empty or `space` does not belong to `spaceOrder` → nothing. `targetRank` = position of `space` in `spaceOrder`.
2. `moved` = windows from `ids` in queue order, set `spaceID = space` on each. `rest` = the remaining windows.
3. Insertion point in `rest`:
   - after the **last** window with `spaceID == space`, if there is any;
   - otherwise before the **first** window whose workspace has rank > `targetRank` (windows without a rank do not count);
   - otherwise at the end.
4. Insert `moved` as a block, `windows = rest` with the insertion; `updateEmptySlot()` (without clearing the selection).
Does not call `onManualReorder` and does not sort.

Examples: `[1(10), 2(10), 3(30)]`: `relocate([1], 20)` → `[2,1,3]`; then `relocate([3], 10)` → `[2,3,1]`.

`[1(10), 2(20)]`, current 10, selected 1, `relocate([1], 20)` → workspace 10 is empty → `emptySlot.spaceID = 10`. Note: because `updateEmptySlot()` is called here without clearing, `selectedID` stays on 1; the application itself calls `showEmptySlot(10)` right afterwards (see below), which clears the selection.

Call context (moving windows with the "to workspace N" shortcut): after `relocate`, if the selected window left and the current workspace ≠ the target → `nearestWindow(on: current, to: the former selected one, in: the visible queue from before the move, excluding: the moved ones)`; if there is one — select it and give it focus; if not — `showEmptySlot(current)`.

#### 7.4 Auto‑sorting vs. manual order (`onManualReorder`)
- Every manual change of order (§9) calls `noteManualReorder()` before executing: if `autoSortByWorkspace == true`, it sets it to `false` and invokes `onManualReorder` (the application records this in preferences as a persistent turn-off). If it was already `false` — nothing.
- Rationale: the automation gives way to the manual arrangement instead of undoing it a moment later.
- Turning it back on: the "Sort queue by workspace" action (shortcut or menu) sets the preference and `autoSortByWorkspace = true`, then calls `sortByWorkspace()`.
- `relocate`, `beginFocus`/`endFocus`, `applyOrder` and inserting new windows are **not** manual changes.

---

### 8. Empty slot

Meaning: the user is on an ordinary workspace on which there is no (non-minimized) window. Then nothing is selected, and the strip shows a marker at the place in the queue where the windows of that workspace would stand.

`EmptySlot = {spaceID, beforeID?}` — `beforeID` is the window before which the marker stands, or none = the end of the queue.

`slotAnchor(space)`: if `space` is not in `spaceOrder` → none; otherwise the first window in the queue (full, in queue order) whose workspace has a rank **greater** than `space` (windows without a rank do not count). This is the place where `relocate`/auto‑sort would put a new window of that workspace.

`showEmptySlot(space)`: `selectedID = none`; `emptySlot = {space, slotAnchor(space)}`. (Public — also called by the application.)

`updateEmptySlot(clearingSelection = false)`:
1. If `currentSpaceID` is empty, or does not belong to `spaceOrder` (fullscreen/unknown space), or the queue is empty → **nothing** (an existing slot stays as it was).
2. `occupied` = whether the **whole** queue contains a window with `spaceID == current` and `!isMinimized` (a minimized window does not occupy a workspace).
3. If `occupied`:
   - if there is no slot → nothing;
   - otherwise `emptySlot = none`; if `selectedID` is empty → `selectedID` = the first window of `visibleWindows` lying on the current workspace and not minimized (direct assignment, without announcement).
4. If not `occupied` and (there is no slot, or it is for another workspace, or its `beforeID ≠ slotAnchor(current)`):
   - `keep` = `clearingSelection ? none : selectedID`;
   - `showEmptySlot(current)`;
   - if `keep` exists → restore `selectedID = keep`.
   (I.e. on arrival at an empty workspace the selection disappears; on other recalculations the slot is refreshed, but the selection, e.g. a window to which travel is in progress, stays.)
5. If not `occupied` and the slot is already correct → nothing.

When the slot is recalculated: change of `currentSpaceID` (with clearing the selection), change of `spaceOrder`, `updateSpaces`, `relocate`, the end of `reconcile`. When it disappears: `select(...)` (any), filling by a new window in `reconcile`, `updateEmptySlot` when the workspace has a window. Note: `select` of a window from another workspace removes the slot, but the next recalculation (e.g. on the next `reconcile` with a change) will put it back, keeping that selection.

Placement on the strip — `slotPlacement`:
- no slot → none;
- `beforeID` empty or the `beforeID` window does not belong to `visibleWindows` → `end` (at the end of the list);
- otherwise `before(beforeID)`.

`slotFilledID`: set in `reconcile` (step 5) to the window that took the slot; the UI animates that window's row from the marker's place (shared "empty-slot" geometry); reset after 0.8 s, provided it still points to the same window.

Examples:
- `[1(10), 2(10), 3(30)]`, selected 2, switching to 20 → `emptySlot = {20, before: 3}`, `selectedID = none`. Returning to 10 → the slot disappears, `selectedID = 1` (the first window of workspace 10 in queue order; not "the previously selected 2" — that may be restored later by a focus event from the system).
- `[1(10), 2(20, minimized)]`, switching to 20 → slot for 20 (the minimized one does not count).
- `[1(10), 2(30)]`, `scope = currentSpace`, switching to 20 → `visibleWindows` empty, `slotPlacement = end`, `cycle` returns none.

Context (system layer): an external focus change to a window outside the slot's workspace does not select it while the slot exists (a window just sent away from an empty workspace must not pull the selection).

---

### 9. Reordering

All operations work on the **visible slice**; windows hidden by the scope stay at their indices in `windows` (only the visible slots are rewritten).

#### 9.1 `move(by delta)` — "move left/right" shortcuts
1. If the selected one is the window in focus (`selectedID == maximizedID`) and `maximizedGroupIDs` is non-empty → `moveGroup(maximizedGroupIDs, delta)` and end (the window in focus and the windows it covers move as one block).
2. `position` = position of the selected one in the slice; none → nothing.
3. `target = position + delta`; outside the range `0…n-1` → nothing (no wrap-around, no clamping).
4. `noteManualReorder()`; **swap** the windows at positions `position` and `target` (this is a swap, not a shift — for |delta| > 1 the windows in between stay in place).
Example: `[1,2,3]`, selected 3, `move(by: -2)` → `[3,2,1]`.

#### 9.2 `moveGroup(ids, delta)` — a block by one (or more) slot
1. `visible` = the slice; `group` = windows from `ids` present in `visible`, in slice order. Empty → nothing.
2. `first` = position of the first of them in `visible`.
3. `destination = clamp(first + delta, 0, n − |group|)`.
4. If `destination == first` → nothing (no `noteManualReorder`; non-adjacent windows are not even gathered together).
5. `noteManualReorder()`; `order` = `visible` without the group's windows; insert `group` (contiguously, keeping their mutual order) at index `destination` in `order`; write `order` back into the visible slots.
Examples (`[1,2,3,4]`, block `{2,3}`): `+1` → `[1,4,2,3]`; then `+5` → no change; then `−1` → `[1,2,3,4]`.

#### 9.3 `move(ids, toVisiblePosition target)` — a block to an absolute position
1. `group` = windows from `ids` in the slice (slice order). If empty or `|group| == n` (everything would be moved) → nothing.
2. `noteManualReorder()` — **always**, even when the position does not change.
3. `order` = the slice without the group; `destination = clamp(target, 0, |order|)`; insert the block; write into the visible slots.
The application uses this for dragging the collapsed tile and for "to start/to end" for multiple aimed windows (`target = 0` or `target = n`, which is clamped to the end).

#### 9.4 `move(id, toVisiblePosition target)` — one window to a position
1. If `id == maximizedID` and `maximizedGroupIDs` is non-empty → `move(ids: maximizedGroupIDs, toVisiblePosition: target)`.
2. `position` = position of `id` in the slice; required: it exists, `0 ≤ target < n`, `position ≠ target` — otherwise nothing.
3. `noteManualReorder()`.
4. Remove the window from `windows`; recompute the slice (`remaining`).
5. Insertion index in `windows`: `target ≤ 0` → index of the first visible one (`remaining[0]`, or 0); `target ≥ |remaining|` → right after the last visible one; otherwise `remaining[target]` (before the window that is now at that position). Insert.
Effect: the window lands exactly at position `target` of the slice, the rest shift. Example: `[a,b,c]`, `a → 2` → `[b,c,a]`.

`moveToStart()` = `move(selectedID, toVisiblePosition: 0)`; `moveToEnd()` = `move(selectedID, toVisiblePosition: n − 1)`. No selection → nothing.

#### 9.5 The block of the window in focus
`maximizedGroupIDs`: if `maximizedID` is set → the windows of `visibleWindows` that are the window in focus or are covered, in slice order; returned only when there are ≥ 2 of them, otherwise an empty list. The strip draws the covered windows as one collapsed tile.

Example: `[1(10), 2(10), 3(20), 4(20)]`, selected 1, `beginFocus(1)` → block `[1,2]`; `move(by: +1)` → `[3,1,2,4]`; `move(id: 1, toVisiblePosition: 0)` → `[1,2,3,4]`.

---

### 10. Focus mode ("fullscreen"/maximization with covering)

When the user fills the screen with a window using the "toggle maximize" shortcut (and the `focusMaximizedWindow` preference, enabled by default, is active), the application calls `beginFocus(on: id)`. When the window returns to its previous frame via the same shortcut — `endFocus()`. Clicking a covered window on the strip first calls `endFocus()`, then selects it.

#### 10.1 `beginFocus(on id)`
1. If `maximizedID == id` → nothing (filling the screen again with the same window does not overwrite the remembered place).
2. `endFocus()` (another window in focus first returns to its place — only then is it known where this window is).
3. Find the window in `windows`; none → end (focus stays off).
4. `placeBeforeMaximize = {after: id of the window right before it in the full queue or none, before: id of the window right after it or none}`.
5. `maximizedID = id`.
6. If the window has a `spaceID`: move it to the index of the first queue window with the same `spaceID` (to the front of "its workspace"; with auto‑sort, the front of the workspace's contiguous block). A window without `spaceID` stays in place.
No `noteManualReorder`, no sorting.

#### 10.2 `isCovered(window)`
True when: `maximizedID` is set, the window ≠ the window in focus, the window in focus exists in the queue, `window.spaceID` is known and equal to the `spaceID` of the window in focus. (A window in focus without a workspace covers nothing.)

Effects of covering: covered windows are skipped when cycling (§5.2), are not aimable (§12), cannot be picked with Shift‑click; they move together with the window in focus (§9.5); the strip draws them as collapsed/greyed out.

#### 10.3 `endFocus()`
1. No `maximizedID` → nothing. Reset `maximizedID`; `placeBeforeMaximize` will be reset at the end in every case.
2. No remembered place or no window in the queue → end.
3. `rest` = the queue without this window. The function `sameSpace(x)` = index in `rest` of window `x`, provided it has **the same `spaceID`** as the returning window.
4. Rules, in order:
   - the former predecessor (`after`) exists and is on the same workspace → insert right after it;
   - otherwise the former successor (`before`) exists and is on the same workspace → insert right before it;
   - otherwise, if the window was at the very front of the queue (`after == none`) and `rest` contains some window of that workspace → insert before the first such one;
   - otherwise → **leave the window where it is** (end, without sorting).
5. `windows = rest` with the insertion; if `autoSortByWorkspace` → `sortByWorkspace()`.

Examples:
- `[1,2,3 (10), 4(20)]`, `beginFocus(3)` → `[3,1,2,4]`; `endFocus()` → `[1,2,3,4]`.
- `[1,2,3]`, `beginFocus(3)` → `[3,1,2]`; `beginFocus(2)` → first 3 returns (`[1,2,3]`), then 2 to the front → `[2,1,3]`; `endFocus()` → `[1,2,3]`.
- `beginFocus(3)` twice, then `endFocus()` → `[1,2,3]`.
- `[1,2,3 (10), 4,5 (20)]`, `beginFocus(3)` → `[3,1,2,4,5]`; window 1 vanishes → `[3,2,4,5]`; `endFocus()` → `[2,3,4,5]` (after predecessor 2).
- The window in focus is closed → `reconcile` resets `maximizedID`, nothing is covered any more.

---

### 11. Window groups (`WindowGroup`)

A group is a set of windows shown on the strip under a single entry (a single tile). **A group does not change the queue**: each window stays in its place, members can be scattered across the queue and across workspaces. A group changes only drawing and the way of traversal.

- `WindowGroup {id: Int (number ≥ 1), ids: [id]}`; `group(of id)` — the first group containing the window (a window is in at most one).
- `members(of group)` — the group's windows **in queue order** (from the full `windows`, regardless of scope and covering).
- `openGroup` — the group with `openGroupID`.

`makeGroup(ids)`:
1. Remove these windows from all existing groups; groups now having < 2 windows disappear.
2. If `openGroupID` or `aimInsideGroupID` points to a group that disappeared → reset.
3. If `|ids| ≤ 1` → return none (side effect: the single window has been taken out of its group).
4. Number = **the smallest positive number not used** by existing groups.
5. Append the group `{number, ids}` to the end of the list and return it. The new group is **not** opened.

Example: `[1,2,3]`, `makeGroup([1,2])` (number 1), `select(1)` → `openGroupID = 1`; `makeGroup([2,3])` → group 1 loses 2, has 1 window and disappears, `openGroupID = none`; the new group `{2,3}` gets number **1**, but is not open.

`ungroup(containing id)`: if the window is in a group — remove that group; if it was open → `openGroupID = none`. The windows stay in the queue in their places. (`aimInsideGroupID` is not reset here.)

Opening/closing: `openGroupID` is set by `select` (selecting a member opens its group, selecting anything else closes it) and by `enterAimedGroup`; it is closed by `leaveAimedGroup` (when the selection is not in that group), `ungroup`, `makeGroup`/`reconcile` when the group ceases to exist. `endAiming` does **not** close the group.

Traversing groups: §5.2–5.3 (a closed group = a single stop, entered from the side of arrival; an open one = window by window). `isSkippedInsideGroup` is described in §5.2.

Application context (toggle group): in aiming mode with ≥ 2 aimed windows → end of aiming, `makeGroup(aimed)`, `select(first aimed)`, message "Grouped N windows as group K"; with < 2 → message "Aim at two or more windows to group them". Outside aiming: if the selected one is in a group → `ungroup`, message "Ungrouped N windows"; otherwise "Nothing to ungroup".

Groups and tiled groups are not saved between launches.

---

### 12. Aiming mode (aiming)

Aiming is a mode for choosing windows on the strip without changing focus: the aim (`aimingID`) walks along the strip, a range (run) can be built, windows can be picked one by one, groups can be entered; only confirmation selects and focuses something. `selectedID` is not touched during aiming. The mode is on ⇔ `aimingID ≠ none`.

#### 12.1 Aimable windows (`aimableWindows`)
- If the aim is in a group (`aimInsideGroupID` points to an existing group) → `members(of: group)` (all members in queue order).
- Otherwise: `reachable` = `visibleWindows` without covered ones; of these keep the windows outside groups and, for each group, **only the first reachable member** (in queue order — regardless of the direction of movement; this is a difference from cycling). A group is thus a single stop.

`aimedWindow` = the entry with `aimingID`. `aimedGroup` = if the aim is **not** in a group, the group of the `aimingID` window (i.e. the aim stands on the group as a whole); otherwise none.

#### 12.2 Range and the set of aimed windows (`aimedWindows`, `aimedIDs`)
Function `run(over candidates)`:
1. `aim` = position of `aimingID` in `candidates`; none → empty list.
2. `ids` = `aimPinnedIDs` ∪ all candidates between the anchor position and `aim` inclusive (anchor = position of `aimAnchorID` in `candidates`, and when it is absent — the `aim` position itself).
3. Result: `candidates` filtered to `ids` (candidate order). Pinned windows outside the candidates are skipped.

`aimedWindows`:
- in a group → `run(over: members(group))` (the range is computed along the group's members, not the queue — windows lying in the queue between members are not included);
- outside a group → `run(over: visibleWindows)` (note: over the whole slice, so the range also includes covered windows and non-first members of groups lying in between), then **group expansion**: for each window in the result add all members of its group; result = `visibleWindows` filtered to this set (members outside the slice drop out).
`aimedIDs` = the set of ids from `aimedWindows`.

#### 12.3 `beginAiming()`
1. `aimAnchorID = none`, `aimPinnedIDs = ∅`, `lastAimStep = 1`.
2. `aimInsideGroupID` = the group of the selected window, if the selected one belongs to a group (aiming started in a group starts inside it).
3. `aimingID` = the selected window, if it is aimable; otherwise the first aimable window; otherwise none (the mode does not turn on).
4. Returns `aimedWindow`.
(The application does not turn the mode on when `visibleWindows` is empty.)

#### 12.4 `moveAim(by delta)` — moving the aim with wrap-around
1. If `delta ≠ 0` → `lastAimStep = delta`.
2. Anchor = none, pinned = ∅ (movement collapses the range to a single window).
3. `list = aimableWindows`; empty → none.
4. `current` = position of the aim in `list`, or `-1` for `delta > 0` / `0` for `delta ≤ 0`.
5. `aimingID = list[((current + delta) mod n + n) mod n]`.

#### 12.5 `extendAim(by delta)` — extending/narrowing the range (Shift+arrow)
1. If `delta ≠ 0` → `lastAimStep = delta`.
2. `list = aimableWindows`; the aim is not in it → none, change nothing.
3. If the anchor is empty → anchor = the current aim.
4. `aimingID = list[clamp(current + delta, 0, n − 1)]` — **without wrap-around**, stops at the ends. Pinned windows stay.

Example: `[1,2,3,4]`, selected 2, `beginAiming`, `extendAim(+1)` → aimed `[2,3]`; `moveAimedGroup(+1)` → queue `[1,4,2,3]`, aimed still `[2,3]`; `moveAimedGroup(+5)` → no change; `moveAimedGroup(−1)` → `[1,2,3,4]`; `extendAim(−3)` → aim on 1, anchor 2 → `[1,2]`.

#### 12.6 `moveAimedGroup(by delta)`
= `moveGroup(aimedIDs in aimedWindows order, delta)` (§9.2) — moves the whole aimed set by a slot, gathers it into a contiguous block and leaves it aimed (this is a manual change → turns off auto‑sort).

#### 12.7 `toggleAim(id)` — Shift‑click
1. Required: the mode is active, the window is in `visibleWindows` and is not covered — otherwise nothing.
2. `picked` = the current `aimedIDs` (everything aimed: range + pinned + expanded groups).
3. Anchor = none.
4. If `id ∈ picked`:
   - if `|picked| == 1` → end (the last aimed window cannot be unaimed);
   - remove `id`; if the aim stood on `id`, move it to the nearest (by position in `visibleWindows`) window remaining in `picked`, on a tie the earlier one.
5. If `id ∉ picked`: add it, `aimingID = id`.
6. `aimPinnedIDs = picked`.

Example: `[1,2,3,4]`, aim on 1: `toggleAim(3)` → `[1,3]`; `extendAim(+1)` → `[1,3,4]` (anchor 3, aim 4, pinned {1,3}); `toggleAim(1)` → `[3,4]`; `moveAim(+1)` → a single window.

Edge cases (preserve literally):
- Outside a group, unaiming a single member of a group aimed as a whole does not work permanently — group expansion (§12.2) brings it back, because the remaining members stay in the set.
- Aim inside a group + Shift‑click on a window outside the group: the window goes into the pinned ones and becomes the aim, but because the range is computed only over the group's members, and the aim is not among them, `aimedWindows` becomes empty (the window outside the group is never aimed). Confirming in this state will nevertheless focus the window under the aim.

#### 12.8 `aimAll()` — "everything in reach" (key A) and back
1. Mode inactive → `false`. `reachable` = ids of the aimable windows; empty → `false`.
2. Anchor = none.
3. If `reachable ⊆ aimedIDs` (computed after resetting the anchor) → `aimPinnedIDs = ∅`, return `false` — the second press returns to just the window under the aim.
4. Otherwise `aimPinnedIDs = reachable`, return `true`.
Outside a group: the whole slice is aimed (groups expanded, covered ones not). In a group: only the group's members.

Examples: `[1,2,3,4]`, group `{2,3}`, selected 1: `aimAll()` → `true`, `{1,2,3,4}`; again → `false`, `{1}`. Selected 2 (in the group), `beginAiming`, `aimAll()` → `{2,3}`. Group `{1,3}` in `[1,2,3,4]`, selected 3 → `aimAll()` → `{1,3}`.

#### 12.9 Entering and leaving a group
`enterAimedGroup()` (the arrow "into the screen" or Return, when the aim stands on a group):
1. Requires `aimedGroup` — otherwise `false`.
2. `aimInsideGroupID = group`, `openGroupID = group`, anchor = none, pinned = ∅.
3. Aim on the **last** member if `lastAimStep < 0` (one came from below/backward), otherwise on the **first** (in queue order). Returns `true`.

`leaveAimedGroup()` (the arrow "toward the strip"):
1. Requires the aim to be in an existing group — otherwise `false`.
2. `aimInsideGroupID = none`; if the selected window does not belong to that group → `openGroupID = none` (otherwise the group stays open).
3. Anchor = none, pinned = ∅; aim on the group's first member (queue order). Returns `true`.

Examples (group `{1,3}` in `[1,2,3,4]`; the strip shows `[group(1,3)] [2] [4]`):
- selected 4, `beginAiming`: outside the group; `moveAim(−1)` → 2; `moveAim(−1)` → 1, `aimedGroup = 1`, aimed `{1,3}` (not 2);
- `enterAimedGroup()` → in the group, aim 3 (came backward), aimed `{3}`; `leaveAimedGroup()` → outside, aimed `{1,3}`;
- selected 1, `beginAiming` → immediately in group 1, aimed `{1}`; `extendAim(+1)` → aim 3, aimed `{1,3}` (window 2 is not included); `moveAim(+1)` → wraps to 1.
- Group `{2,3}` in `[1,2,3,4]`: from 1 `moveAim(+1)` → the group, entering → aim 2; from 4 `moveAim(−1)` → the group, entering → aim 3.

#### 12.10 `keepAimOnQueue(previousOrder)` — windows vanishing during aiming
Called in `reconcile` (step 12):
1. An anchor whose window no longer exists → none.
2. `aimPinnedIDs` ∩ present windows.
3. If the window under the aim no longer exists, but was in `previousOrder`: new aim = the window from `previousOrder` present in the current `visibleWindows`, nearest to the old aim's position in `previousOrder` (tie → the earlier one); when there is none → the first window of the slice (or none — the mode then turns off). If the new aim equals the anchor → anchor = none.
(Uses `visibleWindows`, not the aimable ones — the aim may land on a covered window or a non-first member of a group.)

#### 12.11 `endAiming()` and confirmation
`endAiming()` resets `aimingID`, the anchor, the pinned ones and `aimInsideGroupID`. It does not touch `selectedID` or `openGroupID`.

Confirmation (Return/Space, when not entering a group or opening the layouts menu): the application takes `aimedWindow` (**the single window under the aim**, not the whole range), calls `endAiming()`, `select(that window, announce: false)` and gives it focus. Cancellation (Esc, a click outside the panels): `endAiming()` without selecting. An ordinary click on a window on the strip: cancels aiming, selects the clicked window and focuses it. Multi-window actions (maximize, minimize, close, to start/end, move to workspace, group, snapshot) use `aimedWindows`; with a single aimed window the application first ends aiming and selects that window, then performs the ordinary action. The tiling layouts menu is available when `|aimedWindows| ≥ 2` and the aim does not stand on a group as a whole.

---

### 13. Tiled groups (`TiledGroup`)

A record of the fact that a set of windows holds a shared layout (tiling). The layout follows the queue: reordering the windows in the queue causes them to be laid out again in the new order. Independent of `WindowGroup`.

- `TiledGroup {id: Int (number ≥ 1), ids: [id], layout: String}` — `layout` is the name of the layout (e.g. "Main and stack", "Side by side", "Stacked").
- `setTiled(ids, layout)`:
  1. remove these windows from other tiled groups (a window is in at most one layout); groups with < 2 windows disappear;
  2. `|ids| < 2` → return none (but notify about the change);
  3. number = the smallest positive number not used; append to the end of the list; return.
- `clearTiled(containing id)` — remove the group containing the window (the windows keep their frames, they simply stop being held); no such group → nothing.
- `clearTiled()` — remove all (when already empty → nothing).
- `isTiled(window)`, `tiledGroup(of id)`, `tiledIDs` (flattened ids of all groups in list order).
- `tiledWindowsInQueueOrder(group)` — the group's windows in the **current queue order**; this is the placement order in the layout.
- Cleanup in `reconcile` (§6 step 10): closed windows drop out, a group < 2 disappears.

Examples:
- `[1,2,3]`, `setTiled([1,2,3], "Main and stack")` → number 1; selected 3, `move(by: −2)` → order in the layout `[3,2,1]`; 2 vanishes → `ids = [1,3]`; 1 vanishes → no group.
- `[1,2 (10), 3,4 (20)]`: `setTiled([1,2])` → 1, `setTiled([3,4])` → 2; `clearTiled(containing: 3)` → `[1]` remains; `setTiled([3,4])` → 2 again; `setTiled([2,3])` → both old groups drop to 1 window and disappear, the new one gets number 1, the only group `ids = [2,3]`.

Application context: after every change of `windows` the application compares each group's `tiledWindowsInQueueOrder` with the last laid-out order and on a difference lays it out again (skipping a group containing the window in focus — then it only remembers the new order). A manual move/resize by the user of a window from the layout → `clearTiled(containing:)`.

---

### 14. Announcements (`announcement`)

- The event carries a window entry; the consumer shows a bubble (toast) with the window title next to its icon.
- The only source is `select(id, announce: true)`. Callers with `announce: true`: `cycle(by:)` (the "previous/next" shortcuts and scrolling the wheel over the strip) and the diagnostic command "focus".
- **Not** announced: a click on the strip, a choice in the finder, confirming aiming, adopting an external focus change, mouse hover (focus‑follows‑mouse), jumps to a workspace, and also all direct changes of `selectedID` in the model (filling the slot, `followVanishedSelection`, `clampSelection`, `updateEmptySlot`).

---

### 15. Order persistence (`QueueOrderStore`)

- Storage: user preferences (UserDefaults; on GNOME e.g. GSettings or a file in `~/.config`), key **`queueOrder.v1`**, value: a list of strings = the `orderKey` of the successive windows of the whole queue (regardless of scope).
- **Saving**: after observation starts, every change of `windows` is taken into account, but:
  - empty lists are ignored (an empty queue is a transient state — startup, closing the last window — and must not overwrite a good save);
  - 2 s debounce: saving happens only after 2 s without further changes, with the latest value.
- **Restoring**: exactly once per launch, when the queue first becomes non-empty (on the next turn of the event loop, so that the list is already in the model). If a save exists and is non-empty → `applyOrder(keys)`. Only after that does saving begin. Windows discovered later are no longer matched.
- `applyOrder(keys)` — greedy and lenient matching:
  1. `remaining` = the current queue, `ordered` = [].
  2. For each key in turn: move the first window in `remaining` with that `orderKey` to the end of `ordered`; none → skip the key.
  3. Append `remaining` (in its existing order) at the end.
  4. If the id order did not change → nothing. Otherwise `windows = ordered`; if `autoSortByWorkspace` → `sortByWorkspace()` (i.e. with auto‑sort the save decides only the order within workspaces).
  Duplicates (two windows with the same `orderKey`) are handled naturally: each key entry takes the next matching window. A window with a changed title simply does not match. This is not a "manual change" (it does not turn off auto‑sort).
  Example: `[1,2,3]` (titles `w1,w2,w3`, app `App1`), keys `["App1\u{1}w3", "App1\u{1}w1"]` → `[3,1,2]`.
- Not saved: the selection, groups, tiled groups, focus, the slot.

---

### 16. Fuzzy matching (window finder)

The finder (independent of scope) builds for each window the text `appName + " " + title` and computes `score(query, in: text)`. Empty `query` → all windows in queue order (without scoring). Otherwise: windows with a result ≠ none, sorted descending by result (ties in queue order). The highlight returns to position 0 on every query change; moving the highlight wraps around.

`score(query, candidate)`:
1. `terms` = `query` split on spaces, **without empty pieces** (multiple spaces = one). No words → result `0` (everything matches).
2. `haystack` = `candidate` converted to lowercase, as an array of characters (graphemes). Each word also in lowercase. No stripping of diacritics (`ł` ≠ `l`).
3. Each word must match on its own: if any returns none → the whole result is none. Otherwise `total` = the sum of the words' results.
4. Result = `total − (length of haystack div 20)` (integer division; a penalty for long titles, so that on a tie the shorter one wins).

Word separators (the preceding character makes the position a "word start"): space, `-`, `_`, `.`, `/`, `:`, `—` (em dash), `–` (en dash), `(`, `[`, `|`, `,`, `'`. Position `i` is a word start when `i == 0` or `haystack[i−1]` is a separator.

Word result (`scoreTerm`):
1. Empty word → 0.
2. **Contiguous substring**: find the **first** (leftmost) occurrence at position `i`. Result = `100 − min(i, 40)`, plus `25` if `i` is a word start. (The bonus is computed only for the first occurrence, even if a later one starts a word.)
3. If there is no substring → **matching with gaps** (tight only):
   - walk the haystack from the left greedily: each character equal to the next not-yet-found character of the word is a match (no backtracking);
   - on the first match remember `first`; `+25` if it is a word start;
   - on each subsequent match `+4` if it lies right after the previous match;
   - if not all characters were matched → none;
   - `span = last − first + 1`; if `span > word length + 3` → none (at most 3 skipped characters in total are allowed);
   - result = bonuses `− min(first, 20)`.
   Note: because the matching is greedy from the left, an early accidental hit of the first letter may yield too wide a `span` and rejection, even though a tight match exists further on — this is intended/preserved behavior.

Examples:
- `"saf"` in `"Safari Start"` → substring at 0, word start: `100 + 25 = 125`; length 12 → penalty 0 → **125**.
- `"start"` in `"Safari Start"` → substring at 7 (after a space): `100 − 7 + 25 = 118` → **118**.
- `"sfri"` in `"safari"` → no substring; greedily: s@0 (start, +25), f@2, r@4, i@5 (+4, because 5 = 4+1) → bonuses 29, `span = 6 ≤ 4+3` → `29 − 0 = 29`, penalty `6 div 20 = 0` → **29**.
- `"gle"` in `"go to the example"` → no substring `gle`; greedily g@0, l@15, e@16 → `span = 17 > 6` → none → the window drops out.
- The query `"term code"` matches only windows in which both `term` and `code` match; the result is the sum minus the length penalty.

---

### 17. Set of control scenarios (from unit tests)

Model with workspaces `[10,20,30]`, current 10 (unless given), auto‑sort enabled:

1. `[1(10),2(10),3(30)]`, select 2; current → 20: slot `{20, before 3}`, selection empty. Current → 10: no slot, a window from workspace 10 selected.
2. `[1(10),2(20),3(30)]`, current 20, select 2; 2 vanishes → slot `{20, before 3}`, no selection; `4(20)` appears → `[1,4,3]`, 4 selected, no slot.
3. `[1(10),2(20),3(20),4(20)]`, current 20, select 3; 3 vanishes → 2 selected (or 4 — the test allows both; the reference implementation gives 2).
4. `[1(10),2(20)]`, select 1; 2 vanishes → 1 selected, no slot.
5. `[1(10),2(20),3(30)]`; `spaceOrder = [30,10,20]` → `[3,1,2]`.
6. `[1(10),2(10),3(20)]`, select 1; `5(10)` arrives → `[1,5,2,3]`.
7. `relocate`: `[1(10),2(10),3(30)]` → `[1]→20` → `[2,1,3]` → `[3]→10` → `[2,3,1]`.
8. `[1(10),2(20)]`, select 1, `relocate([1],20)` → slot for 10.
9. Scope `currentSpace`, `[1(10),2(20),3(10)]`, select 1: cycle +1 → 3, +1 → 1.
10. A minimized window does not occupy a workspace (the slot appears).
11. `applyOrder(["App1\u{1}w3","App1\u{1}w1"])` on `[1,2,3]` → `[3,1,2]`.
12. Closing the window under the aim → the aim moves to a neighbor.
13. Scope `currentSpace` on the empty workspace 20 (`[1(10),2(30)]`): slice empty, slot at the end, cycle → none.
14–26. Aiming, focus, group and tiled group scenarios — given as examples in §5, §9–§13.

---

## Interface: strip, panels and overlays

This section describes everything WindowQueue draws on the screen: the strip (one per monitor), the
group panel ("second strip"), the name popup (toast), the screen dimming in aiming mode, the
on-screen window outlines, the tiling cell preview while dragging, and all mouse interactions on
the strip. Numbers are in logical points (on GNOME: logical pixels, before HiDPI scaling), times in
seconds. User-visible texts are in English and must be reproduced verbatim.

The action panel for mouse aiming (`ActionPanel`), the tiling layouts menu (`TilingMenu`) and the
finder window are described in the sections on aiming mode, tiling and the window finder; here
I mention them only where they touch the strip.

### 1. Properties common to all overlays

Every element drawn by WindowQueue (strip, group panel, popup, outlines, cell preview, dimming) is a
separate borderless overlay window with the following traits:

- **Never takes keyboard focus** and does not activate the WindowQueue application when clicked
  (a "non-activating" panel, `canBecomeKey = false`). A click on the strip does not take focus away
  from the window the user is typing in.
- **Present on all workspaces** (sticky), regardless of switching; they do not take part in the
  desktop sliding animation (see 1.1), do not appear in window switchers or in the taskbar, are not
  movable, and have no system appearance animation (`animationBehavior = .none`).
- **Can appear above fullscreen windows** (`fullScreenAuxiliary`).
- Transparent background; only what is drawn is visible.
- Layers (from the bottom): regular windows → dimming ("status" level, 25) → window outlines and cell
  preview (same level, but ordered later, so above the dimming) → strip, group panel, popup, action
  panel ("status + 1" level, 26). The dimming also covers the top menu bar.
- The strip, group panel and popup have the system window shadow (`hasShadow = true`) — a subtle
  shadow around the opaque pixels. The dimming, outlines and cell preview have no shadow.
- The dimming, outlines and cell preview **ignore the mouse** (they let clicks through).

#### 1.1. Layer above the desktops (`OverlaySpace`)

On macOS, windows that are "on all workspaces" still belong to the currently shown desktop, so
when switching workspaces they slide away together with it and are redrawn after the animation (the
strip would "blink"). Therefore WindowQueue creates a private WindowServer space at absolute level
100 (above all desktops and fullscreen spaces) and moves into it: every strip, the group panel,
popups, aiming/focus outlines and the cell preview (not the dimming). The functionally required
effect: **these overlays stand still while the desktops slide beneath them**, and they are also
visible on fullscreen spaces. The move is performed every time an overlay window is shown anew.
When the private API is not available, the behavior falls back to plain "sticky + above
fullscreen".

On GNOME the equivalent is an actor in a layer above `global.window_group` (e.g. `Main.layoutManager`
/ `uiGroup` in a Shell extension), which does not belong to any workspace and does not take part in
the switching animation.

### 2. Metrics (`StripMetrics`)

All sizes derive from the `iconSize` setting (default 34). The "Default" column shows the
value for `iconSize = 34`.

| Name | Formula | Default |
|---|---|---|
| `spacing` — gap between strip elements | constant | 6 |
| `padding` — inner margin of the strip (on all sides) | constant | 6 |
| inner margin of a row (icon → highlight edge) | constant | 4 |
| `rowHeight` — row height (along the strip) | `iconSize + 8` | 42 |
| `thickness` — strip thickness (across) | `rowHeight + 2·padding` | 54 |
| `corner` — corner radius of the strip and the group panel | `thickness · 0.28` | 15.12 |
| `rowCorner` — row highlight radius | `rowHeight · 0.24` | 10.08 |
| `badgeCorner` — radius of the workspace badge background | `iconSize · 0.27` | 9.18 |
| `iconCorner` — clipping radius of icons in a cascade, the placeholder icon, the empty slot | `iconSize · 0.23` | 7.82 |
| `slotThickness` | `iconSize` | 34 |
| `slotLength` — length of the empty slot in the layout | `iconSize + 8` | 42 |
| `stackStep` — offset of each successive cascade card | constant | 5 |
| `stackPeek` — max. number of icons in a cascade | constant | 3 |
| `stackLength` — length of the stack tile and the group tile in the layout | `rowHeight + 5·(3−1)` | 52 |
| `labelSize` — font size of the label under the icon | constant | 10 |
| `layoutDuration` / `foldDuration` | constant | 0.32 s |

All corner roundings are "continuous" (squircle style, `.continuous`); on GNOME a regular
rounded rectangle with that radius is enough.

**Spring animations.** The code uses SwiftUI springs described by a pair (`response`, `dampingFraction`).
Conversion to a classic oscillator (mass 1): stiffness `k = (2π / response)²`, damping
`c = 4π · dampingFraction / response`. Springs used:

- `layoutAnimation`: response 0.32, damping 0.82 — strip layout changes (adding/removing/
  reordering an element, collapsing/expanding the stack tile).
- unfolding/folding the page in invisible mode: response 0.32, damping 0.78.
- enlarging the strip in aiming mode (and the group panel): response 0.25, damping 0.8.
- aiming series highlight: response 0.22, damping 0.85.
- "settling" of a dropped icon: response 0.22, damping 0.9.

**System colors** (reproduce from the GNOME theme or with constants):

- `accent` — the system accent color (default macOS blue ≈ `#007AFF`; on GNOME: the accent color
  from settings, e.g. libadwaita's `accent-color`).
- `orange` — system orange ≈ `#FF9500` (light theme) / `#FF9F0A` (dark).
- `primary` — the theme's text color: black in light, white in dark. "primary 12%" = this color
  with opacity 0.12.
- `secondary` — gray secondary text (≈ primary with opacity ~0.5).
- `ultraThinMaterial` — a translucent, heavily blurred, theme-dependent background (light: white ~40–50%
  with background blur; dark: graphite ~40–50% with blur). Without blur, a background in the theme's
  window color with opacity ~0.75 is acceptable.

### 3. Strip: where and when it is on screen

#### 3.1. Display modes (`stripDisplay`)

- `activeScreenOnly` ("Selected monitor only"): a strip only on the **active monitor** — the one
  with the window that has keyboard focus (`NSScreen.main`). Nothing on the others.
- `highlightActiveScreen` ("All monitors, highlight selected", **default**): a strip on every
  monitor. The strip on an inactive monitor is **desaturated** (saturation 0 — grayscale) and has
  opacity `inactiveStripOpacity` (default 0.55). The activity change is animated easeOut 0.2 s.
  In aiming mode all strips are drawn as active (aiming chooses among all windows, wherever they
  are).
- `hidden`: no strip at all; the strip panels are destroyed.

In `activeScreenOnly` mode the single strip is always drawn as active.

Every strip shows **the same queue** (the same visible slice); they differ only in the workspace
number in the badge and its colors (dependent on the background beneath it), and possibly in being
grayed out.

The strips are recomputed (shown/hidden/moved) on: every change of the queue model, every
settings change, a change of the monitor configuration, activation of another application and a
change of the active workspace. A strip panel for a given monitor (key: display identifier), once
created, is kept even in the hidden state so that returning is instant; it is removed only when the
monitor disappears or the mode changes to `hidden`.

#### 3.2. Hiding in fullscreen

When `hideInFullscreen` (enabled by default) and the workspace currently shown on a given monitor
is an application's **system fullscreen space**, the strip on that monitor is hidden immediately
(without animation). This applies only to system fullscreen, not to WindowQueue's "fullscreen mode"
(which only maximizes the window and collapses the covered windows into the stack tile). When
workspaces have no separate space per monitor (one shared set), the only available information is
used.

#### 3.3. Workspace number for a monitor

The number in the badge is the index of the workspace (numbering as in the rest of the
specification: from 1, consecutively across monitors) currently shown **on that monitor**. When it
is unknown: for the active monitor — the number of the current workspace from the model; for the
others — none, and the badge shows "–" (en dash U+2013). Fullscreen spaces have no number → "–".

#### 3.4. Side, alignment, margin

- `stripSide` ∈ {`left` (default), `right`, `top`, `bottom`}. A left/right strip is **vertical**
  (elements one below another, from the top), a top/bottom one **horizontal** (from left to right).
  Hereafter "along" = the direction in which elements are laid out, "across" = the thickness.
- `stripAlignment` ∈ {`start`, `center` (default), `end`} — position of the content along the edge,
  like `justify-content`: start = top/left, end = bottom/right. Fraction: 0 / 0.5 / 1.
- `stripMargin` (default 4) — distance from the screen edge:
  - across: the strip is offset from its screen edge by `stripMargin`;
  - along: the margin is a distance from the **ends** of the edge, but **only from the end the
    strip is not aligned to**. A strip aligned to `start` touches the beginning of the work area
    (e.g. it starts right below the menu bar, without a margin), and `stripMargin` only keeps the
    other end away from the edge; for `end` the reverse; for `center` the margin is on both sides.
    Thanks to this, an aligned strip is in line with the windows next to it.

The reference area is **the monitor's work area without WindowQueue's own reservation** (see 3.7):
i.e. what remains after subtracting the menu bar and possibly the Dock, but with the band that
WindowQueue reserved for itself given back. Otherwise the strip would move away from the edge by
its own width.

#### 3.5. Strip window: fixed size, content inside

The strip window (panel) **occupies the entire length of the edge** of the reference area and
**never changes size** when the queue changes. Its thickness is `thickness · max(1, aimingScale)`
(default 54 · 1.2 = 64.8), i.e. always as much as the strip can reach in aiming mode — enlarging
the window during the animation would clip the strip. Window position (for reference area `V`,
thickness `T`, margin `m`):

- left: `x = V.minX + m`, `y = V.minY`, width `T`, height `V.height`;
- right: `x = V.maxX − T − m`, the rest as above;
- top: `x = V.minX`, `y = V.maxY − T − m` (coordinates with the y axis pointing up), width `V.width`,
  height `T`;
- bottom: `x = V.minX`, `y = V.minY + m`.

The window is set immediately (without animation), only when the target frame has changed (a change
of settings or monitors).

Inside the window, the actual strip (a bar of thickness `thickness`) is:

- across, **stuck to the screen edge** (for left: to the left side of the window; the excess
  window thickness remains on the screen side, empty);
- along, placed according to the alignment within the space `window length − margins from 3.4`;
- with `center` alignment and an open group panel, additionally shifted by `companionLength / 2`
  toward the beginning (up / left), so that the strip and the group panel are centered as a whole
  (see 7.2). This shift is animated easeOut 0.32 s. With `start`/`end` nothing shifts — the pair
  grows "inward".

Queue changes are therefore a pure content animation inside a stationary window. **Empty,
transparent areas of the window do not accept clicks** — they go to the application underneath. On
GNOME the input region must be set exactly to the visible shape of the strip (taking into account
the enlargement in aiming mode and the floating icon while dragging); pointer motion for tooltips
is, however, tracked over the whole window (pointer over the empty part = "over nothing").

Content offset along for a point in the window: `along − contentStart`, where `along` is measured
from the top (vertical) or from the left (horizontal), and
`contentStart = leading + free · fraction − shift`,
`leading = (alignment == start ? 0 : stripMargin)`,
`trailing = (alignment == end ? 0 : stripMargin)`,
`free = max(0, windowLength − leading − trailing − totalHeight)`,
`shift = (alignment == center ? companionLength / 2 : 0)`.
`totalHeight` comes from `StripLayout` (section 5). This offset is used by hover and middle-click
hit-testing, popup anchoring and badge background sampling.

#### 3.6. Always on top, on every workspace

The strip is visible on all workspaces and above fullscreen windows (1, 1.1), except for
3.2. Switching workspaces does not move the strip.

#### 3.7. Reserving screen space (`reserveScreenSpace`)

Goal: maximized/tiled windows do not go under the strip. Width of the reserved band:
`reservedWidth = ceil(thickness + 2·stripMargin)` (default `ceil(54 + 8) = 62`), and in invisible
mode 0 (a strip that exists only in aiming mode does not take space from windows).

On macOS this is done in two ways:

1. **"Dock-like" reservation** (`DockReservation`): only when `reserveScreenSpace`, the strip is not
   `hidden`, is not invisible, and the system Dock is in auto-hide mode. It covers only the main
   monitor (with the menu bar): a band of width `reservedWidth` at the strip's edge, for
   left/right from the bottom edge of the menu bar to the bottom of the screen, for top — a band just
   below the menu bar, for bottom — at the bottom of the screen. Checked every 2 s and on monitor
   changes; restored on exit.
2. **After-the-fact trimming** (`ScreenEdgeGuard`, when also `trimWindowsOutsideReservation`, enabled by
   default): a standard window that **has changed size** (not just moved) and, after 0.3 s of
   quiet with the mouse button not pressed, lies at the strip's edge (tolerance 2 pt from the
   edge of the reference area) and reaches further than the band, is trimmed so that it starts
   `reservedWidth` from the edge (for left: `x = edge + gap`, right edge unchanged). Windows
   in true fullscreen (the whole screen including the menu bar) and windows arranged by WindowQueue
   itself are skipped. Zooming a trimmed window again returns it to the frame from before the first
   zoom. The frame is checked again after 0.15/0.35/0.7/1.2 s and set once more if the application
   changed it.

On GNOME a strut / exclusive zone (`_NET_WM_STRUT_PARTIAL`, or in the Shell
`Main.layoutManager.addChrome(actor, { affectsStruts: true })`) of width `reservedWidth` on
each monitor that has a strip is enough, together with computing the reference area while
ignoring the own strut. After-the-fact trimming is then unnecessary.

### 4. Invisible mode (`invisibleStrip`) and the "page" animation

When `invisibleStrip` is enabled, the strip is on screen **only in aiming mode**. Outside it,
the queue exists, and changes are announced by the popup (toast) alone. The group panel is also
hidden then (7.4). Toggled with the shortcut "Hide or show the strip (invisible mode)".

Opening and closing animation: the strip is a **page hanging on a hinge at the screen edge**.

- Rotation axis: for a vertical strip — a vertical axis (Y), for a horizontal one — a horizontal
  axis (X). The hinge (anchor point) = the same point as for enlargement during aiming: the strip's
  edge at the screen, at the alignment position along it (left: `(x=0, y=fraction)`, right:
  `(x=1, y=fraction)`, top: `(x=fraction, y=0)`, bottom: `(x=fraction, y=1)` in the strip's unit
  coordinates).
- Fold angle: **+100°** for left and top, **−100°** for right and bottom (the page lies "face down"
  over the screen, beyond 90°), with perspective (SwiftUI parameter `perspective: 0.9`, i.e. a
  pronounced perspective — camera distance on the order of the strip's size).
- A folded page has opacity 0; an unfolded one — 1. Angle and opacity are animated together with a
  spring of response 0.32, damping 0.78. Opening looks like turning a page from the screen onto the
  edge.

Opening sequence (aiming starts): the strip window, which was not visible, is shown in the folded
state (angle ±100°, opacity 0), and on the next run of the event loop the state changes to
unfolded, which starts the animation. Closing sequence (aiming ends): the "folded" state
(animation), and after 0.32 s the window is hidden — provided that the strip is still supposed to
be folded, invisible mode is still enabled, and aiming is not in progress. Folding applies only to
monitors on which the strip should exist at all; where the strip disappears for another reason
(monitor mode, fullscreen), it hides immediately. When invisible mode is disabled, the strip
appears immediately unfolded, without animation.

Space reservation (3.7) is disabled in invisible mode.

### 5. Element layout (`StripLayout`)

The strip is a list of elements in this order:

1. **workspace badge** (`badge`) — first, if `showSpaceBadge` (default yes);
2. window elements in the order of the visible slice of the queue, where:
   - a window belonging to a **group** is shown in the **group tile** — one tile per group,
     inserted at the position of the group's **first** member (in queue order); subsequent members
     point to the same tile. A group takes precedence over collapsing into a stack: a window in a
     group is in the group, even if it is covered;
   - a window belonging to the **collapsed** set (fullscreen mode, see below) — in a single **stack
     tile**, inserted at the position of the first collapsed window; subsequent ones point to it;
   - every other window — its own **row**;
3. **empty slot** (`emptySlot`), if the model has one: inserted **before** the element of the window
   with the indicated identifier (if that window is visible as a row; if it is not — at the end) or
   at the end of the list.

Length (along) of each element in the layout: badge and row — `rowHeight`; empty slot —
`slotLength`; stack tile and group tile — `stackLength`. Elements are laid out starting at `padding`
(6), each next one at `height + spacing`. `totalHeight = last_end + padding` (no gap after the last);
an empty strip has `2·padding`.

**The collapsed set** (stack tile) exists only when: `focusMaximizedWindow` (default yes) and
`collapseCoveredWindows` (default yes) and there is a window in fullscreen mode (`maximizedID`) and at
least one window of the visible slice is covered by it. The set = the covered windows + the
fullscreen window itself (it is the "top card" of the tile). While dragging a **single icon** that
has already moved (≥ 4 pt), the set is empty — the tile expands into rows so that the icon can be
dropped anywhere between them. Dragging the stack tile itself leaves it collapsed. A mere press
without movement expands nothing.

**Hit-testing** (offset `o` measured from the start of the strip's content):

- window under the point: the first position in the queue whose element satisfies
  `top ≤ o < top + height + spacing` (the band includes the gap below the element, so the gaps
  between icons are "live"). A point on a stack/group tile returns the tile's **first window** in
  queue order. The badge and the empty slot are not windows — a point on them yields "nothing";
- badge / stack tile / group tile (group number): the same band for the given element;
- "nearest window" (for dragging): as above, and when the point does not hit any band (above,
  below, outside the strip) — the window whose element center is closest.

Compatibility note: the drawn group tile actually has length `rowHeight` (icon +
2·4), and the drawn stack tile `rowHeight + 5·(number of cards − 1)`; the layout (hit-testing,
anchors) assumes `stackLength` = 52. Drawing uses a plain stack with spacing 6, so with fewer than 3
cards, or with a group, the elements after the tile are a bit higher on screen than hit-testing
assumes. A new implementation should draw and compute with the same lengths (recommended: stack
tile and group tile of length `stackLength`, with centered content).

The strip **has no headers** (e.g. workspace sections) and no workspace numbers next to individual
icons — the only number is in the badge.

### 6. Appearance of the strip and its elements

#### 6.1. Strip background and border

- Bar: thickness `thickness` across, length `totalHeight` along, inner margin 6.
- Background: rounded rectangle (`corner`) filled with `ultraThinMaterial`, with opacity
  `stripOpacity` (default 1.0; applies only to the background, not the icons).
- Border: 1 pt, `primary` 12%, inside the edge, same radius.
- Under the icons, above the background: the aiming series highlight (6.8).
- The whole strip (background + icons): saturation 0 and opacity `inactiveStripOpacity` on an
  inactive monitor; on the active one opacity **0.55 when some group is open** (`openGroupID`, one is
  working "in a group"), otherwise 1. A change of the open group is animated easeOut 0.18 s.

Content animations: a change of the set/order of elements and of the collapsed set — `layoutAnimation`;
a change of selection — easeOut 0.16 s; a change of the fullscreen window — easeOut 0.2 s.

Transitions (elements appearing/disappearing):

- window row: appearing — scale from 0.4 + opacity fade-in from 0; disappearing — scale to 0.6 +
  opacity to 0;
- group tile: scale 0.6 + opacity (both directions);
- stack tile: opacity only (the icons "fly over" from the rows — see 6.6);
- empty slot: scale 0.5 + opacity.

#### 6.2. Workspace badge

An element of size `iconSize × iconSize` with a margin of 4 around it (`rowHeight` in total, like a row).

- Text: the monitor's workspace number or "–", rounded system font (SF Rounded;
  on GNOME e.g. Cantarell/Inter bold or a rounded font), size `iconSize · 0.55`, weight
  semibold, centered.
- Background: rounded square `badgeCorner`.
- Colors depending on the brightness of the screen background under the badge (6.2.1):
  - light background: text black 85%, fill white 55%;
  - dark background: text white 100%, fill black 35%;
  - unknown (before the first measurement): text in the accent color, fill accent 16%.
  - The color change is animated easeOut 0.25 s.
- Tooltip: "Current workspace".
- **Recording indicator**: while screen recording is in progress, instead of the number the badge
  shows a "filled circle in a ring" icon (`record.circle.fill`) in red, size
  `iconSize · 0.6`, semibold, **pulsing** (cyclic dimming/brightening of the opacity), on a
  rounded square `badgeCorner` filled with red 16%. Tooltip "Recording the
  screen". The screen background colors have no effect then.
- **Click on the badge** (without a drag of ≥ 4 pt) opens aiming mode "from the mouse" (6.2.2), if
  aiming is not in progress.

##### 6.2.1. Background brightness sampling (luminance with hysteresis and a two-sample rule)

- Measurement every **1.5 s** (plus once at startup), separately for each visible strip, only when
  `showSpaceBadge`.
- **Quiet period**: after every application activation or change of the active workspace, for
  **1.2 s** nothing is measured, and results that arrive during that time are discarded (the
  switching animation moves windows under the strip).
- Measured rectangle: the place of the badge icon on screen, `iconSize × iconSize`: along from
  `contentStart + padding + 4`, across centered in the `thickness` band at the screen edge
  (offset `(thickness − iconSize)/2` from the side of the strip window at the edge). It does not
  account for the enlargement during aiming.
- Source: when screen recording permission is granted — a capture of this rectangle **excluding
  WindowQueue's own windows** (i.e. what is under the strip), downscaled to 8×8, averaged
  to a single pixel. Without permission or on error — the **wallpaper** of that monitor: a thumbnail
  (max. 1024 px on the longer side, cached for the last URL), fitted like a
  "fill" wallpaper (scale `max(image.w/screen.w, image.h/screen.h)`, centered crop),
  the corresponding fragment cut out, averaged.
- Luminance: `0.2126·R + 0.7152·G + 0.0722·B` on 0–1 components (gamma-encoded values, without
  linearization).
- **Hysteresis**: if the current verdict is "light", the new verdict is "light" ⇔ `L > 0.45`; otherwise
  (dark or unknown) "light" ⇔ `L > 0.55`.
- **Two-sample rule**: the first verdict (when the state is unknown) is applied immediately. Later the
  color changes only when the new verdict differs from the current one **and** equals the verdict of
  the previous sample. The verdict of every successful sample is remembered as "previous". A sample
  that returned nothing is ignored (it does not change "previous" either).

##### 6.2.2. Aiming from the mouse

A click on the badge starts aiming mode "from the pointer": with no delay for a possible double
tap of the super key — immediately the dimming appears, the name popup of the aimed window on all
strips, the window outlines, and the **action panel** (tiles with the mode's actions, next to the strip on
the screen side, 10 pt from it, centered on the strip; details in the section on aiming mode).

#### 6.3. Window row

Structure: icon `iconSize × iconSize` + margin 4 = a `rowHeight` square; across, centered in the
strip (6 pt from the strip's sides).

- **Icon**: the icon of the window's owning application, scaled with high quality, **not clipped**
  (macOS icons have their own shape). When the application has no icon: a rounded square `iconCorner`
  filled with `secondary` 30%. All windows of the same application have the same icon (the icon
  object is cached per process so that animations do not "blink").
- **Title label** (`showWindowLabels`, enabled by default): at the bottom of the icon, **on it**, not
  under it (the row does not grow). Text: 10 pt semibold, white, single line, truncated at the end
  with an ellipsis ("…"), horizontal margin 2, max. width = `iconSize`, background: rounded
  rectangle radius 3, black 62%, hugging the text, centered horizontally, flush with the bottom edge
  of the icon. Label content: the window title with whitespace trimmed from both ends; if empty —
  the application name; otherwise the title with **all leading characters that are not a letter or
  a digit removed** (markers, dots, emoji, "•", "*" etc. drawn by applications). If the title
  consists solely of such characters, the label is empty.
- **States**:
  - minimized window: icon (with label) at opacity 0.45;
  - window **covered** by the fullscreen window, when covered windows are not collapsed (condition:
    `focusMaximizedWindow` and the collapsed set is empty — e.g. `collapseCoveredWindows` disabled): icon at
    opacity 0.5 and saturation 0.2, row background **blue 22%** (system blue). Minimization
    takes precedence for opacity (0.45);
  - **selected** (and no aiming series in progress): background accent 28%, border accent 1.5 pt,
    radius `rowCorner`;
  - **aim** (the window with the aim, when only one window is aimed): background orange 28%,
    border orange **2.5 pt** — it takes precedence over the selection, so it is never confused
    with the focused window. A selected row outside the aim still has its blue highlight;
  - during a **series** (≥ 2 windows aimed) rows have no individual highlights — neither selection
    nor aim; a shared series highlight is drawn (6.8).
- **Tiled group mark** (a window held in a tiling layout): in the top-left corner of the row,
  offset by (−1, −1): a black 55% capsule with a margin of 2 horizontally / 1 vertically, inside it
  a "2×2 grid of filled squares" icon (`square.grid.2x2.fill`) and — only when more than one tiled
  group exists — the group number, spacing 1; font bold size `max(7, iconSize · 0.3)`,
  accent color. Tooltip "Tiled group N — moving or resizing a window frees it".
- Row tooltip: the window title (or the application name when the title is empty).

The strip has **no** separate highlighting of the window in fullscreen mode other than the stack tile
(or the blue rows of covered windows).

#### 6.4. Empty slot

A marker of the place where the windows of the empty workspace the user is on would appear
(nothing is selected then).

- Square `iconSize × iconSize` (in both directions), margin 4.
- Fill: **diagonal hatching** — parallel lines at 45°, running from bottom left to top
  right, spacing 5 pt (horizontally), thickness 1.2 pt, color accent 45%, clipped to a rounded
  square `iconCorner`.
- Border: dashed, accent 85%, 1.5 pt, dash 3 / gap 3, radius `iconCorner`.
- Tooltip "Empty workspace".
- When a window appears on this workspace, it takes the slot's place, and for 0.8 s its row is
  geometrically linked to the slot (a "matched geometry" effect) — the new icon **grows out of the
  slot's place and size**, rather than appearing out of nowhere.

#### 6.5. Group tile

A group of windows is a single entry on the strip.

- Cascade: up to the first 3 members of the group (in queue order), drawn from back to front
  (the first member on top). For a card at depth `d` (0 = front, `n = min(count, 3)`):
  offset along the strip `(d − (n−1)/2) · 5` (the cascade spreads symmetrically from the center,
  farther cards lower/further right), saturation `1 − 0.25·d`, opacity `1 − 0.2·d`, scale `1 − 0.08·d`.
  Each icon is clipped to a rounded square `iconCorner`. The cascade frame is `iconSize ×
  iconSize` (the cards stick out of it by the offset).
- **Counter** in the bottom-right corner, offset by (+3, +3): the number of windows in the group,
  rounded font bold `max(8, iconSize · 0.3)`, white, horizontal margin 3, on a capsule accent 95%.
- Margin 4, background rounded `rowCorner`: when the selected window is in this group — accent 28%;
  otherwise `primary` 8%.
- Border 1.5 pt: when the group contains the selection — accent, otherwise `primary` 25%; **dashed
  (4/3) when the group is not open; solid when it is open** (its windows are in the group panel).
- Tooltip "Group of N windows".
- While this tile is being dragged, its place in the strip is invisible (opacity 0), and a
  floating copy is drawn (6.9).
- When the aim is on the group (the group aimed as a whole, ≥ 2 windows), the tile is covered by
  the orange series highlight (6.8).

#### 6.6. Stack tile (fullscreen mode with collapsing)

A single element replacing the fullscreen window and all the windows it covers.

- Card order: the fullscreen window **always first** (on top), then the covered ones in queue
  order. The first 3 are shown ("peek").
- Card at depth `d`, `mid = (card_count − 1)/2`: offset along `(d − mid) · 5`,
  saturation `1 − 0.35·d`, opacity `1 − 0.28·d`, scale `1 − 0.1·d` (from the center), clipped to
  `iconCorner`. The cascade frame is `iconSize + 5·(card_count − 1)` along and `iconSize` across.
- Each card is geometrically linked to its window's row: when collapsing, the icons **fly
  from the rows into the cascade**, when expanding, back to their places (`layoutAnimation` animation).
- Counter "+N" in the bottom-right corner, offset (+3, +3): N = number of covered windows (without
  the fullscreen window), rounded font bold `iconSize · 0.34`, white, margin 3 horizontally / 1 vertically,
  capsule accent 95%.
- Margin 4; when the selected window is in this stack — background accent 28% and border accent 1.5 pt
  (radius `rowCorner`), otherwise transparent. The change is animated easeOut 0.16 s.
- Tooltip "N window(s) behind the maximized one" ("window" without "s" for 1).

#### 6.7. Drawing order of the layers of one strip

From the bottom: background with material → aiming series highlight → elements (badge, rows, tiles) →
strip border → floating copy of the dragged element. The whole (including the floating copy) is
subject, in order, to: graying out/opacity (6.1), page rotation (4), aiming enlargement (8.1).

#### 6.8. Aiming series highlight

When ≥ 2 windows are aimed (series, pinned, whole group): the aimed windows are grouped into "runs"
of adjacent positions in the visible slice of the queue. For each run, one rounded rectangle
(`rowCorner`): fill orange 28%, border orange 2.5 pt; across, width
`rowHeight`, centered; along, from the start of the element of the run's first window to the end of
the element (`+ rowHeight`) of its last one. Positions come from the committed layout (not from the
drag preview). Windows in one tile (group) yield the same element, so a group's run covers the tile
over a length of `rowHeight`. A change of the set of aimed windows is animated with the 0.22/0.85
spring.

#### 6.9. Floating copy (dragging)

The dragged element (row, stack tile or group tile) is drawn above the strip, **at the
cursor**: scale 1.12, shadow black 30% radius 6, centered across the strip, along at the
position `elementStart + cursorOffset`. Its place in the list is preserved (opacity
0), and the other elements move apart, showing where it will land (6.10.3).

### 7. Group panel ("second strip")

#### 7.1. When it is visible

Recomputed on every model change. It shows the windows of group `G`, where `G` is (in this order):

1. **the open group** — the group of the selected window (selecting a window in a group "enters"
   it; selecting a window outside — leaves it), or
2. in aiming mode: the group the aim is on (aimed as a whole, a "peek" — so that one can see what
   entering it would give), or the group the aim has entered.

The panel is hidden when there is no such group, when the group has ≤ 1 window, and in invisible
mode outside aiming. Hovering over a group tile **does not open** the panel (it only names it, 10.4);
a click opens it.

The "peek" state (`peek`) = no open group (the panel is shown only because the aim is on a
group).

#### 7.2. Position and size

- Content dimensions along: `L(n) = 2·padding + n·rowHeight + (n−1)·spacing`, where `n` = the number
  of panel rows (the covered windows + the fullscreen window in this group count as a single row —
  their cascade).
- `scale` = `aimingScale` when the aim is **inside** this group, otherwise 1.
- Panel window: across `thickness · max(1, aimingScale)` (room for enlargement), along
  `L(n) · scale`.
- The panel **continues the strip in the same line** (the same band at the screen edge), separated
  by a gap of **8 pt**: for a vertical strip below it (downward — "behind" the strip, like the queue),
  for a horizontal one after it (to the right). **With `end` alignment — before the strip** (above it /
  to the left of it). If it does not fit in the work area of the monitor the strip is on, it goes to
  the other side; finally it is clipped to the work area. Across: for left `x` = left side of the
  strip, for right the right side of the panel window = right side of the strip, for top the top
  side = top side of the strip, for bottom the bottom = bottom.
- The reference is the strip's **content** rectangle (not its window), on the monitor of the anchor
  strip (10.6), taking the centering shift into account. When there is no strip, the panel is in the
  center of the main monitor's work area.
- **Room for the pair**: the main strip gets `companionLength = L(n) · (aiming scale in the group
  ? aimingScale : 1) + 8`, and with `center` alignment it shifts by half of this value toward the
  beginning (animation easeOut 0.32 s), so the strip + gap + panel are centered as a whole.
  This value applies to all strips (on all monitors), although the panel is next to only
  one. When the panel disappears, `companionLength = 0`.
- Inside the panel window the content is stuck to the screen edge (left → to the left, etc.) and
  enlarged from that edge (anchor point: the middle of the edge on the screen side).

#### 7.3. Appearance

The same material and size as the strip — it reads as an extension of the strip, not as a menu:

- background: `ultraThinMaterial` with opacity `stripOpacity`, radius `corner`, margin 6, thickness
  `thickness`;
- border: in peek `primary` 12%, 1 pt; when the group is open (or the aim has entered) — accent 55%,
  1.5 pt;
- no workspace badge, no title labels, no dimming of minimized windows;
- rows in group order (queue order), each like a strip row: icon `iconSize`,
  margin 4, highlight (`rowCorner`): aim (when not a series) — orange 28% +
  orange border; selected (when not the aim and not a series) — accent 28% + accent
  border; border thickness 2.5 pt for the window with the aim, 1.5 pt for the others; tiled group
  mark as on the strip (number, when > 1 tiled group exists); tooltip = title;
- windows covered by the fullscreen window of this group (with `focusMaximizedWindow` and
  `collapseCoveredWindows`) together with that fullscreen window form **a single cascade at the end of the list**
  (not at their queue position): like the stack tile (6.6: fullscreen window on top, up to 3 cards, the same
  coefficients 0.35/0.28/0.1 and step 5), but the cascade frame is `iconSize × iconSize`; counter "+N"
  in font `max(8, iconSize · 0.3)`; accent highlight when it contains the selection; tooltip
  "N window(s) behind the fullscreen one";
- aiming series inside the group: orange run rectangles as in 6.8, positions computed
  uniformly: start `6 + index · (rowHeight + 6)`, length `k·rowHeight + (k−1)·6`;
- the `scale` enlargement is animated with the 0.25/0.8 spring.

#### 7.4. Show, change and hide animations

- **Opening**: the window appears with opacity 0 in a "folded" frame — 25% of the target length, on
  the side adjoining the main strip (panel below the strip: top 25%; above the strip: bottom 25%;
  after a horizontal strip: left 25%; before it: right 25%) — and over 0.32 s (easeOut) animates opacity to 1
  and the frame to the target. It looks like the strip unrolling from the end of the main one.
- **Change** (a different group, a different number of windows, a different `scale`) while the panel is visible:
  frame animation to the new one (0.32 s easeOut), without fading out again; if the panel was in the
  middle of disappearing — it comes back (opacity → 1). The animation is not restarted when the
  target has not changed.
- **Hiding**: 0.192 s (0.32 · 0.6) easeIn: opacity → 0 and frame → folded (25% on the strip
  side), then the window is hidden. Showing during hiding intercepts the panel and restores it.
- At the same time the main strip shifts (with `center`) with the same duration of 0.32 s.

#### 7.5. Interactions in the group panel

- **Click** (press and release in a row, with no movement threshold) selects the window and gives
  it focus (without moving the cursor). The cascade does not respond to clicks.
- **Hover**: the row under the pointer → a pinned name popup of that window, next to that row in
  the panel (with a thumbnail, 11); leaving → end of the popup hold. The row under the pointer is
  computed uniformly: `index = floor((along − 6) / (rowHeight + 6))` over the rows without the cascade
  (without accounting for enlargement).
- **Middle click** on a row closes that window.
- The mouse wheel is not supported in the group panel.

### 8. Aiming mode — visual elements

#### 8.1. Strip enlargement (`aimingScale`)

In aiming mode the strip **that has the aim** is enlarged by `aimingScale` (default
1.2) — everything (background, border, icons) uniformly, from the anchor point at the screen edge at
the alignment position (4), i.e. it grows into the screen and away from the end it is aligned to.
Animated with the 0.25/0.8 spring. When the aim has entered a group, the main strip returns to scale 1,
and the group panel is enlarged instead (7.2). The enlargement applies to all strips (on all monitors) simultaneously.
Hover hit-testing does not know the scale, so hover is disabled during aiming (10.4); clicks
and dragging work in unscaled coordinates (just as SwiftUI converts the gesture before the
transform) — a new implementation should convert the point with the inverse scale transform.

#### 8.2. Screen dimming (`DimOverlay`)

- On **every** monitor, a window covering the whole monitor frame (also under the menu bar), uniformly black,
  ignoring the mouse, at the level just below the strip.
- Appearing: opacity 0 → `aimingDimOpacity` (default 0.45) in 0.18 s; disappearing: → 0 in 0.18 s,
  then hidden. With `aimingDimOpacity = 0` nothing is shown. Every show first
  removes the previous one without animation.
- Shown when aiming mode "reveals itself": immediately when started from the mouse or when no action
  is assigned to the double tap of the super key; otherwise after 0.4 s (the double-tap
  window), or immediately on the first move of the aim. Hidden on leaving the mode.
  (The same overlay is used by the window finder.)

#### 8.3. On-screen outlines of aimed windows (`AimHighlightOverlay`)

- For each aimed window that is **on the current workspace** and has a frame larger than 20×20:
  a separate transparent window ignoring the mouse, exactly at that window's frame, and in it a
  rounded rectangle (radius 10) stroked with a **3 pt** line, inset into the frame (offset by 1.5 pt, so
  a window at the screen edge has its outline entirely on screen). **Outline only, no fill.**
- Color: orange; opacity 1 for the window with the aim ("brightest"), 0.65 for the other windows of the
  series.
- A new outline appears from opacity 0 to 1 in 0.12 s; outlines of windows that are no longer aimed
  disappear immediately; on leaving the mode all disappear immediately.
- Updated on every change of the target (move, extension, entering a group). Frames are not
  tracked live if a window moves without the target changing.
- Above the dimming, so the aimed windows look "lifted out" of the dimmed screen.

#### 8.4. Focus flash (`flashFocusedWindow`)

After every time WindowQueue gives focus to a window (click, aiming confirmation, cycling, workspace
switch, etc.; **not** with focus-follows-mouse, which gives focus by another route), if `flashFocusedWindow` (default yes) and `flashFocusedWindowDuration > 0`
(default **0.15 s**):

- an outline as in 8.3 (3 pt, radius 10, inside the window frame), but in the **accent** color, opacity 1;
  a single shared outline window (a new flash moves the previous one);
- it appears **immediately** at opacity 1, holds for `flashFocusedWindowDuration`, then fades to 0
  over **0.5 s** (easeIn) and disappears;
- if the window is on another workspace, the flash waits until that workspace is visible and the window
  has a frame: checking every 0.1 s, max. 20 attempts (2 s), then it gives up;
- not in aiming mode; the window must have a frame > 20×20.

#### 8.5. Popup in aiming mode

See 11.3: with one aimed window, the popup with its name (and thumbnail) is pinned next to the
icon **on every strip**; with a series of ≥ 2 or aiming at a group, the popup disappears (the series has the
layouts menu next to the strip).

### 9. Tiling cell preview (`TilePreviewOverlay`)

When dragging (≥ 4 pt) the icon of **a single window belonging to a tiled group**, the screen
shows the cell that this window will get when dropped at the current place
(the group is arranged in queue order, so the drop decides the position):

- the queue after the hypothetical drop → the window's position among the group's members → the rectangle of that position
  in the group's layout (the layout whose name is stored in the group, or the first one available for that number of windows)
  → converted to the tiling area (shrunk by `tileOuterGap`) and shrunk by half of
  `tileInnerGap` on each side (layout details — the section on tiling);
- an overlay window at this frame, ignoring the mouse: a rounded rectangle inset by 2 pt,
  radius 10, fill accent 18%, stroke accent 85% with a thickness of 3 pt;
- first appearance: opacity 0 → 1 in 0.1 s; subsequent position changes — instant repositioning;
  hiding — immediate (drop, return below the threshold, window not in a tiled group, position
  outside the layout).

### 10. Mouse interactions on the strip

The whole strip has **one** drag gesture recognizer with a minimum distance of 0 (pressing the left
button starts a "gesture"; a click = a gesture without movement). Positions are measured along the strip in its
unshifted coordinate system (from the start of the content, including the margin of 6). Movement threshold:
**4 pt** along the strip.

#### 10.1. Click (left)

Press on a window element (row, tile) and release, if `|offset| < 4` and the target
position is the same as the starting one:

- **row**: window selection — if aiming is in progress **and Shift is held**: toggling the window in the
  target (adding to the aimed windows / removing), without leaving the mode. In all other cases:
  ending aiming without confirming (if it was in progress); if the window is covered by the
  fullscreen window — first leaving fullscreen mode (the queue returns to normal), then selecting the window
  (without an announcement popup) and focusing it **without moving the cursor** (+ focus flash);
- **stack tile**: like a click on the row of the **fullscreen** window (the top card), not of the first
  window of the stack;
- **group tile**: like a click on the row of its first member (in queue order) — selecting a window in the
  group opens the group (the group panel appears, the strip dims to 0.55);
- **badge**: aiming from the mouse (6.2.2), as long as aiming is not in progress;
- empty slot, empty space: nothing.

A click anywhere **outside** WindowQueue's windows (left, right or another button) during
aiming ends aiming without confirming.

#### 10.2. Press and hold → popup

At the moment of pressing on a row (not a tile), a **pinned** name popup of that window appears (with a
thumbnail, if enabled) — held as long as the button is pressed, and it follows the icon. As soon as
the offset reaches 4 pt, the popup disappears **immediately** (the user is watching where the icon will land,
not the name). After release (click) — end of the hold: the popup disappears after `min(toastDuration, 0.6)`
(default 0.6 s), with a 0.18 s fade-out.

#### 10.3. Drag and drop (reordering)

- Start: on the first gesture event the start position must hit a window (10 — hit-testing from 5,
  on the committed layout); otherwise the gesture drags nothing (a press on the badge/slot yields
  at most a click from 10.1). A hit on the stack tile → the **whole stack** is dragged (the fullscreen window
  and all the covered ones, as a block); on a group tile → the **whole group** as a block; on a row → a single
  window.
- After exceeding 4 pt the gesture is considered a drag (it stays so until the end, even if the cursor
  comes back).
- Target: the `nearest window` (5) for the position `start + offset`, always computed on the **committed**
  layout (not on the preview — otherwise the target would oscillate as the preview rearranges under the cursor).
  The cursor may move outside the strip — the target is then the first/last window.
- Preview: the strip draws the queue with the dragged window moved to the target position
  (`layoutAnimation`), its (invisible) row occupies that place, and the floating copy is under the
  cursor (6.9). For a block (stack/group): the block is taken out of the queue and inserted at
  `target − (number of block members before the target) + (1 if target > start position)`, min. 0 — i.e.
  before the window it is dropped on when carried up/left, and after it when down/right.
- A single window from a tiled group: cell preview (9).
- Dropping a single window (movement ≥ 4 or a change of target): the window is moved in the queue to the target
  position (in the visible slice); then the floating copy **"settles"** — it animates with the spring
  0.22/0.9 from the cursor to the place of the new row, and after **0.22 s** the gesture ends and the row underneath
  (which held that place all along) becomes visible. Popup: disappears immediately (10.2).
- Dropping a block: the block is moved to the computed place; no settling animation (the tile appears
  in the new place with the layout animation).
- The end of the gesture always: hides the cell preview, resets the state, ends the popup hold.
- During dragging, hover is disabled (the popup belongs to the drag).

#### 10.4. Hover

The pointer is always tracked (also when the panel is not the active window), over the whole strip window.
Disabled during dragging and in aiming mode. Rules, on every pointer move:

- **stack tile** under the pointer (only once, on entering): a pinned popup next to the **first window
  of the stack in queue order**: title "+N window(s) hidden" — note: here N = the number of **all**
  windows in the stack, including the fullscreen window (unlike the "+N" counter on the tile) — and subtitle
  "‹fullscreen shortcut› restores the maximized window and brings them back", where ‹shortcut› is the current
  shortcut of the action "Fullscreen window (again to restore)" in shortcut notation (e.g. "⌥F");
- **group tile** (only when the window under the pointer changes): a pinned popup "Group N — K windows"
  / "Click to open it in a strip of its own", next to the row of its first member (when that member
  happens to be visible in the group panel — next to its row in the panel);
- **window row** (only when the window under the pointer changes): a pinned popup with the window name **right
  away**, without delay (with a thumbnail, 11.1);
- pointer over nothing (badge, slot, empty part of the window, leaving the window): end of the hold —
  the popup fades after `min(toastDuration, 0.6)`.

Note on the original's behavior: every pointer move outside the group tile triggers "end of the group
name hold", which in practice schedules fading of the popup after ≤ 0.6 s even when the pointer moves
within the same row (the popup stays as long as the pointer is still). Recommended behavior in a new
implementation: the popup holds as long as the pointer is over the same element.

Hover does **not** change the selection or focus. The pointer leaving the strip window resets the "strip under
the pointer" (unless a drag is in progress).

#### 10.5. Mouse wheel

- Direction: of the two axes, the one with the larger absolute value is taken (horizontal scrolling also
  works); scrolling "down/right" (the way one scrolls a document onward) = a step forward in
  the queue (next window), "up/left" = backward. The system's natural scrolling setting is
  respected (the deltas are taken after it has been applied).
- **Precise scrolling** (touchpad, smooth wheel, deltas in points): the deltas are **accumulated**;
  number of steps = the integer part of `sum / rowHeight` (toward zero), subtracted from the sum —
  one step per offset of one row height, so the selection "keeps up" with the look of the strip.
- **Line scrolling** (classic notched wheel): every event with a non-zero delta = exactly
  one step; the accumulator is reset.
- In aiming mode the steps move the aim (like the cycling keys), focusing nothing.
- Outside aiming: each step cycles the selection by that many positions (skipping covered windows,
  with wrap-around) — the selection changes immediately and a **regular** (unpinned) name popup is shown
  next to the icon; the selected window gets **focus** only when scrolling stops for
  `scrollFocusDelay` (default **0.5 s**; every step restarts the countdown), without moving the
  cursor.

#### 10.6. Middle button

A middle click over a window element closes that window (for a stack/group tile — the first window of that tile
in queue order). Over the badge/slot/empty space — nothing. The same in the group panel (7.5).

#### 10.7. Anchor strip

The "strip under the pointer" is the last strip the pointer moved over (or on which a drag
was started). Anchor for the popup and the group panel: the strip under the pointer, if visible; otherwise the visible,
active strip on the active monitor; otherwise any active one; otherwise any visible one.

### 11. Name popup (toast)

#### 11.1. Appearance

- Column, left-aligned, spacing 6:
  - title: 13 pt semibold, one line; subtitle: 11 pt, color `secondary`, one line (spacing
    between them 2). The end is truncated with an ellipsis when there is not enough room;
  - optionally a **window thumbnail** below the text: the window image fitted proportionally into
    max. **420 × 315** (the thumbnail's longer side ≤ 420), corner radius 8, border 1 pt `primary` 15%.
- Padding 12 horizontal / 8 vertical; background `ultraThinMaterial` with corner radius 10; frame 1 pt
  `primary` 12%; window shadow.
- Popup window width: natural width clamped to **[140, 480]**; natural height.
- For a window: title = window title (or the app name when the title is empty), subtitle = app name.
- Thumbnail only when `showWindowPreview` (default yes) **and the popup is pinned** (hover,
  hold, aiming) — when cycling from the keyboard the window comes to the front anyway. Requires
  screen recording permission and a window on the current workspace larger than 40×40; the image is
  downscaled so that the longer side ≤ 420, cached for 2 s, max. 8 images. No image → text only.
- `toastEnabled = false` disables **all** popups (including hover and aiming ones).

#### 11.2. Position next to the icon

Anchor = the window's row rectangle on screen: across, the whole strip window (including the margin for
magnification); along, `rowHeight` centered on the center of the window's element (for a window in a tile —
the center of the tile), offset by the current drag if this window is being dragged. In aiming
mode (aim on the main strip) the position along and the length are recomputed with the scale:
`along' = a + (along − a) · aimingScale`, `a = contentStart + totalHeight · fraction`. When the window
is visible as a row in the **group panel**, the anchor is that panel row (with its scale), not
the group's tile in the strip.

Gap 8 pt; the popup is on the **screen side** of the anchor:

- left: `x = anchor.maxX + 8`, vertically centered on the anchor;
- right: `x = anchor.minX − 8 − width`, vertically centered;
- top: `y` below the anchor (gap 8), horizontally centered;
- bottom: above the anchor (gap 8), horizontally centered.

The along coordinate is clamped to the workspace area of the monitor the anchor is on, with a margin
of 8 (a popup at the end of the strip does not go off screen). Without an anchor: at the left edge of the
active monitor's workspace area (x = minX + 8), vertically centered.

#### 11.3. On every strip (aiming)

When aiming at a single window, the popup is shown **next to that window's icon on every visible
strip**: first the anchor strip, then the others sorted by the left edge of their monitor. Each
strip has its own bubble (bubbles are created as needed and reused; surplus ones are hidden). Exception:
a window shown in the group panel has a popup only next to its row in the panel.

#### 11.4. Centered variant

For messages not concerning a single window (e.g. “Grouped 3 windows as group 2”, “Aim at two or more
windows to group them” / “Shift-click or Shift with the arrows”, “Nothing to ungroup” / …): the same
appearance without a thumbnail, width [140, 480], **in the center of the active monitor's workspace area**, only
one bubble (the others hidden), disappears after `max(toastDuration, 1.2)` s.

#### 11.5. Lifetime

- Appearance of a new one: opacity 0 → 1 in **0.12 s**. If the bubble is already visible (e.g. dragging,
  successive cycling steps) — only the frame is repositioned and opacity returns to 1 in **0.08 s** (also when it was
  in the middle of fading out).
- **Regular** (announcement on keyboard cycling, wheel, actions): fades out after `toastDuration`
  (default **1.0 s**).
- **Pinned** (hover, hold, aiming): no time limit; “end of hold”
  schedules the fade-out after `min(toastDuration, 0.6)`.
- **Immediate hide** (no animation): when a drag exceeds the threshold; when aiming
  turns into a series of ≥ 2 or onto a group; after a double tap of the super key, before its action is performed.
- Fade-out: opacity → 0 in **0.18 s**, then hide — unless a new popup was shown in the meantime
  (generation counter), in which case it stays.
- Leaving aiming: end of hold (≤ 0.6 s).

### 12. Multiple monitors — summary

- **Strip**: one per monitor according to the mode (3.1); each computes its own workspace area, workspace
  number, badge colors (separate background sampling) and hiding in fullscreen; all
  show the same queue. Active monitor = the one with the focused window; the others in
  `highlightActiveScreen` mode are grey and dimmed (except during aiming). A change of monitor configuration
  recomputes everything; strips of monitors that disappeared are removed.
- **Space reservation**: on macOS only the main monitor + trimming after the fact on the others; on
  GNOME a strut on every monitor with a strip.
- **Aiming magnification**: all strips at once (if the aim is not in a group).
- **Dimming**: all monitors.
- **Aiming outlines**: windows on the current workspace (on macOS the workspace of the active monitor).
- **Focus flash**: on the window, wherever it is, after arriving at its workspace.
- **Popup**: next to the anchor strip (10.7), and during aiming next to every strip; clamped to the anchor's
  monitor. Centered variant — active monitor.
- **Group panel**: one, next to the anchor strip, clamped to that strip's monitor; the centering
  offset, however, applies to all strips.
- **Action panel** (aiming from the mouse): next to the anchor strip.
- **Cell preview**: on the tiling area (section on tiling).

### 13. Settings read by the interface (default values)

| Setting | Default | Effect |
|---|---|---|
| `stripDisplay` | `highlightActiveScreen` | 3.1 |
| `inactiveStripOpacity` | 0.55 | strip opacity on an inactive monitor |
| `stripSide` | `left` | 3.4 |
| `stripAlignment` | `center` | 3.4, 7.2 |
| `stripMargin` | 4 | 3.4, 3.5, 3.7 |
| `iconSize` | 34 | all metrics (2) |
| `showSpaceBadge` | true | badge and background sampling |
| `stripOpacity` | 1.0 | background opacity of the strip and the group panel |
| `hideInFullscreen` | true | 3.2 |
| `invisibleStrip` | false | 4 |
| `aimingScale` | 1.2 | 8.1, strip window thickness, 7.2 |
| `aimingDimOpacity` | 0.45 | 8.2 (0 = none) |
| `scrollFocusDelay` | 0.5 s | 10.5 |
| `toastEnabled` | true | 11 |
| `toastDuration` | 1.0 s | 11.5 |
| `showWindowPreview` | true | thumbnail in the popup |
| `showWindowLabels` | true | title label on the icon |
| `focusMaximizedWindow` | true | covered windows / stack tile |
| `collapseCoveredWindows` | true | stack tile instead of blue rows |
| `flashFocusedWindow` | true | 8.4 |
| `flashFocusedWindowDuration` | 0.15 s | 8.4 |
| `reserveScreenSpace` | true | 3.7 |
| `trimWindowsOutsideReservation` | true | 3.7 |
| `tileOuterGap` / `tileInnerGap` | 0 / 4 | 9 |
| `stripWidth` | 36 | unused (legacy entry), thickness follows from `iconSize` |

---

## Actions, shortcuts and aiming mode

This chapter describes everything the user can *do*: every action (`HotkeyAction`), tapping
the super key, aiming mode with its keys, action tiles and layout menu, window tiling,
fullscreen/maximize/minimize/close, moving to a workspace, the window finder,
the launcher, the workspace overview, the invisible strip, screen recording, window screenshots, the focus
flash, the status bar menu, and the *literal* texts of all popups. The whole is driven by a single
application controller (in code `AppDelegate`); the rules described here are its logic.

Shortcut notation conventions: `⌥` = super (Option by default; on GNOME the equivalent is e.g. Super/Alt —
see the chapter on GNOME), `⇧` Shift, `⌃` Control, `⌘` Command. The key name in a shortcut is the letter
according to the current keyboard layout (uppercase), and special keys: `Space`, `↩` Return, `⎋` Escape,
`⇥` Tab, `⌫` Backspace, `↖` Home, `↘` End, arrows `←→↑↓`, `F1…F12`. The order of modifier
symbols in a displayed shortcut is always `⌃⌥⇧⌘` + key (e.g. `⌥⇧W`). This is exactly how shortcuts are
inserted into popup texts (`displayString`).

Keys in shortcuts are identified by **physical key code** (position), not by character. “`[`”
means the key located at the `[` position of the US layout, regardless of the layout.

---

### 1. Ways the user invokes actions

1. **Global shortcuts** — each `HotkeyAction` has one combination (modifiers + key),
   registered system-wide so that it works in every application and is *consumed* by it (it does not
   reach the frontmost application). The combination must contain at least one modifier.
   Re-registration happens only when some shortcut has actually changed (any
   other settings change must not cause unregistration even for a moment — otherwise `⌥S` pressed at that
   moment would type “ś” in the application). A shortcut that could not be registered (taken)
   goes onto an error list shown in Settings.
2. **Tapping the super key** (the modifier alone, without any other key) — opens/confirms aiming
   mode; a double tap can invoke a chosen action (§4).
3. **Keys in aiming mode** — the mode takes over the whole keyboard; there the navigation
   keys work, as well as every shortcut also *without* the super key (§5.6).
4. **Mouse on the strip** — clicking an icon, Shift+click in aiming mode, middle-button click
   (closes the window), wheel (§16), clicking the workspace badge (opens aiming mode), dragging.
5. **Action tiles** next to the strip, when aiming mode was opened with the mouse (§5.8), and the **layout menu** (§5.9).
6. **Status bar menu** (§18).
7. (For tests only) debug commands — see §21.

Every action execution (regardless of the source: shortcut, key in aiming mode, tile, double
tap) begins by **cancelling an ongoing super key tap** (`modifierTaps.cancel()`),
because the shortcut key is consumed and the tap detector would not see it.

---

### 2. Table of all actions (`HotkeyAction`)

Default shortcuts are given for super = `⌥`. With a different super, `⌥` is replaced by the chosen combination
(e.g. `⌃⌥`). Changing the super in Settings **overwrites all shortcuts with the default values** for
the new super. The default shortcuts deliberately do not use the letters A, C, E, L, N, O, S, X, Z (Option+these letters
produce ą ć ę ł ń ó ś ź ż in the “Polish Pro” layout).

The “While aiming” column describes invoking the action while aiming mode is open (from the keyboard — with the full
combination or a bare key, see §5.6 — or with a tile). “Several” = what happens when
≥2 windows are aimed.

| Action (`id`) | Title in Settings | Default | Outside aiming | While aiming (1 window) | Several aimed | Popup |
|---|---|---|---|---|---|---|
| `cyclePrevious` | Select previous window | `⌥[` | Selects the previous window in the cycle (with wrap-around) and focuses it (moving the cursor, if enabled). | Moves the aim back by 1 (like `[`), focuses nothing, the mode stays. **Note:** with the default `⌥[` the `[` key code is intercepted as a navigation key with a modifier, so `⌥[` while aiming *moves the aimed windows in the queue* (§5.5). The “move the aim” variant works only when the action has a shortcut on a different key. | ditto (aim and series as with `[`) | Window name popup on regular cycling (outside aiming, regular, fading). |
| `cycleNext` | Select next window | `⌥]` | As above, forward. | As above, forward. | ditto | ditto |
| `moveLeft` | Move window earlier in queue | `⌥⇧[` | Swaps the selected window with its earlier neighbor in the visible slice (a fullscreen window moves together with the covered ones as a block). Disables auto-sorting. | Moves the aimed windows (the whole series as a block) 1 place earlier; the mode stays. | ditto — the whole block. | — |
| `moveRight` | Move window later in queue | `⌥⇧]` | As above, later. | As above, later. | ditto | — |
| `moveToStart` | Move window to start of queue | `⌥⇧↖` (Home) | Moves the selected window to the start of the visible slice. Disables auto-sorting. | The aimed window becomes the selection, the mode ends (without focusing), then as outside aiming. | All aimed windows are moved as a block (in their order) to the start; the mode ends. | Several: “Moved N windows to the start of the queue”. |
| `moveToEnd` | Move window to end of queue | `⌥⇧↘` (End) | To the end of the visible slice. | ditto, to the end. | Block to the end. | Several: “Moved N windows to the end of the queue”. |
| `sortByWorkspace` | Sort queue by workspace | `⌥⇧W` | Turns auto-sorting back on (saved in Settings) and sorts the queue stably by workspace (§9). | Ends the mode (without confirming), then as outside. | ditto | — |
| `closeWindow` | Close selected window | `⌥Q` | Closes the selected window (§7.4). | The aimed window becomes the selection, the mode ends, closes it. | The mode ends, closes each aimed window (in queue order). | Several: “Closed N windows”. |
| `toggleMaximize` | Fullscreen window (again to restore) | `⌥F` | Toggles “fullscreen” of the selected window (§7.2). | Ends the mode **without** selecting the aimed window, then acts on the *selected* window (see the note in §22). | **Nothing happens**, the mode stays open, popup. | Several: “Fullscreen takes one window” / “Aim at a single window, or tile the group with Return”. |
| `maximizeWindow` | Maximize window | `⌥M` | Fills the screen area (without the strip's space) with the selected window (§7.1). | Aimed → selection, end of mode, maximize. | End of mode, maximizes each in turn. | Several: “Maximized N windows”. |
| `minimizeWindow` | Minimize window | `⌥H` | Minimizes the selected window (§7.3). | Aimed → selection, end of mode, minimize. | End of mode, minimizes each. | Several: “Minimized N windows”. |
| `toggleGroup` | Group or ungroup windows | `⌥G` | Dissolves the group containing the selected window (§17). | 1 window: **the mode stays open**, warning popup. | End of mode, creates a group from the aimed windows, selects the first of them. | See §17. |
| `search` | Search windows | `⌥Space` | Opens/closes the window finder (§10). | Ends the mode, opens the window finder. **Note:** the Space key while aiming is a navigation key (“confirm”) regardless of modifiers, so `⌥Space` pressed in aiming mode *confirms the aim* rather than opening the window finder. The window finder can be opened from aiming only with a double tap (default) or a shortcut on a different key. | ditto | — |
| `openLauncher` | Open the launcher | `⌥R` | Opens the launcher: Spotlight/Raycast/Alfred (§11). | Ends the mode (releases the keyboard), then opens the launcher. | ditto | — |
| `showOverview` | Show Mission Control | `⌥W` | Opens the workspace overview (Mission Control; on GNOME: Activities overview) (§11). | Ends the mode, then opens the overview. | ditto | — |
| `toggleInvisibleStrip` | Hide or show the strip (invisible mode) | `⌥I` | Toggles invisible strip mode (§12). | Toggles; **aiming mode stays open** (the strip appears/collapses under the aim). | ditto | “Strip hidden”/“Strip shown” (§19). |
| `toggleRecording` | Start or stop recording the screen | `⌥V` | Start/stop recording of the whole screen (§13). | Start/stop; **the mode stays open** (the same key will stop it). | ditto | “Recording the screen”/“Recording saved”. |
| `screenshotWindow` | Take a picture of the window | `⌥P` | Screenshot of the selected window (§14). | Ends the mode, screenshot of the aimed window. | Ends the mode, one screenshot per aimed window. | “Screenshot saved”/“N screenshots saved” etc. |
| `space1`…`space9` | Switch to workspace N | `⌥1`…`⌥9` | Switches to workspace N (§8.2). | Ends the mode (without confirming), switches. | ditto | — |
| `moveToSpace1`…`moveToSpace9` | Move window to workspace N | `⌥⇧1`…`⌥⇧9` | Moves the selected window to workspace N and takes the user there along with it (focus on the moved window) (§8.1). | Moves the aimed window; the mode ends. | Moves all aimed windows. | “<title> / Moved to workspace N” or “<App> stayed where it was / It could not be moved to workspace N”. |

Action groups in Settings: “Queue” (`cyclePrevious, cycleNext, moveLeft, moveRight, moveToStart,
moveToEnd, sortByWorkspace, toggleMaximize, maximizeWindow, minimizeWindow, toggleGroup, closeWindow,
search, openLauncher, showOverview, toggleInvisibleStrip, toggleRecording, screenshotWindow` — in this
order), “Workspaces” (`space1…9`), “Move to workspace” (`moveToSpace1…9`).

One-time migration (flag `bindings.polishLettersFree.v1`): on the first launch of the new
version, shortcuts that still have the *old* default values switch to the new ones:
`sortByWorkspace` super+⇧S → super+⇧W, `openLauncher` super+S → super+R, `showOverview` super+O →
super+W, `toggleRecording` super+C → super+V, `screenshotWindow` super+X → super+P. A shortcut set
manually to something else stays. The migration never repeats.

---

### 3. Common behavior of actions on the “selected window”

Outside aiming mode, window actions (`closeWindow`, `toggleMaximize`, `maximizeWindow`,
`minimizeWindow`, `screenshotWindow`, `moveToSpaceN`, `moveToStart/End`, `moveLeft/Right`) act
on the queue's **selected** window (`selectedID`), not on the “window focused according to the system” (usually the same).
No selection (e.g. an empty workspace) → the action does nothing, without a popup (exception: `toggleGroup`,
which says “Nothing to ungroup”; `screenshotWindow` without a window does nothing).

If the window does not yet have an accessibility handle (e.g. it lies on a workspace that has not been visited), before
a geometry operation the controller tries to fetch it anew from the application's window list.

---

### 4. The super key: tap and double tap

#### 4.1 What a tap is

The detector observes only modifier state changes (“flags changed” events), globally and in
its own panels. State = the set of all pressed device-independent modifiers
(Shift, Control, Option, Command, and also Caps Lock, Fn, numeric keypad — so **with
Caps Lock on, a tap never works**).

Internal state: `armed` (super pressed alone, “from zero”), `invalidated` (something ruled out the tap),
`pressedAt`.

Algorithm for each modifier change:

1. **Everything released** (empty set): a tap occurs when `armed && !invalidated &&
   time_since_pressedAt ≤ 0.4 s`. Then reset (`armed=false, invalidated=false, pressedAt=nil`); if
   there was a tap → `onTap` (toggle aiming mode).
2. **Set == exactly the super combination** and not `armed` → `armed=true`, `invalidated=false`,
   `pressedAt=now`. Arming happens *only on an upward transition*: returning to super alone
   (e.g. releasing Shift while holding Option after `⌥⇧]`) does **not** re-arm.
3. **Set non-empty and different from super** → `invalidated=true` (it is a combination, not a tap).

Interruptions (each sets `invalidated=true`): any key press (key down), pressing
the left/right/other mouse button, scrolling the wheel — globally and in its own windows — and
executing any WindowQueue action (a shortcut consumed by the system does not reach the detector, so
the dispatcher cancels manually).

Constant: **maximum hold time 0.4 s**.

Consequence for two-key supers (`⌃⌥`, `⌘⌥`): releasing one key earlier than
the other gives the state “one modifier” ≠ super → invalidation. The tap works only if both
keys are released in the same event. (Pressing them one after another is OK: the intermediate state
invalidates, but later reaching the full combination re-arms from scratch with `invalidated=false`.)

#### 4.2 What a tap does (`toggleAiming`)

Preconditions: the `aimingEnabled` setting (enabled by default) and **the window finder is not
open** (otherwise nothing).

- Aiming mode closed → **open** (§5.1, “from the keyboard”).
- Mode open:
  - if a double-tap action is configured (`superDoubleTapAction ≠ nil`) **and** since the
    mode was opened (`aimingOpenedAt`) < **0.4 s** have passed → this is a double tap: close the mode
    without confirming, immediately hide the name popup (without fading), execute the configured action
    (already outside aiming mode, so it acts on the selected window);
  - otherwise → **confirm** (close the mode, focusing the aimed window, §5.10).

Since a tap is recognized on release, a double tap = the second release
happened within 0.4 s of the first release (both meet the tap conditions).

`aimingOpenedAt` is set on *every* attempt to open, also from the badge and also when there was
nothing to aim at (the mode then does not open, so the second tap simply tries to open again).
Opening with the mouse and a super key tap within 0.4 s also counts as a double tap.

#### 4.3 Double-tap configuration

Setting “Double tap of the super key”. Values: “Confirm the aim” (`nil` — the second tap
simply confirms) or one of the actions, in this order in the list: `openLauncher, showOverview,
search, toggleInvisibleStrip, toggleRecording, screenshotWindow, toggleMaximize, maximizeWindow,
minimizeWindow, toggleGroup, closeWindow, sortByWorkspace, moveToStart, moveToEnd`.
**Default: `search`** (window finder). The control is disabled when aiming mode is disabled.
Description in the UI: “Two taps of the super key in quick succession. Confirming focuses the aimed window,
which is what the second tap does on its own; any other choice leaves aiming mode and runs that
action instead.”

---

### 5. Aiming mode

A mode in which the keyboard (and mouse) moves the **aim** along the strip without changing focus; only
confirmation focuses a window, or an action acts on the aimed windows. The aim model (`aimingID`,
anchor, pinned, group entry) is described in the chapter on the model; here — the orchestration.

#### 5.1 Opening

Two ways:

- **From the keyboard**: a super key tap (§4.2).
- **With the mouse**: clicking the **workspace badge** on the strip (click = button released without dragging
  beyond the drag threshold). Works only when the mode is not already open. A mode opened this way is
  “pointer-driven” (`aimStartedWithPointer = true`) and shows action tiles (§5.8).

Procedure `beginAiming(fromPointer)`:

1. `aimingOpenedAt = now`, remember whether by mouse.
2. If the visible slice of the queue is empty → nothing (the mode does not open; no popup).
3. The model starts aiming: clears the anchor and pinned, direction of the last step = +1; if
   the selected window belongs to a group, aiming starts **inside that group**; the aim lands on the
   selected window if it is reachable, otherwise on the first reachable one (reachable = those
   the cycle reaches: excluding those covered by fullscreen; a group represented by its first
   reachable window; inside a group — the group's windows).
4. **Grab the keyboard** (§5.3) — immediately, also during a delayed reveal.
5. Start observing clicks outside its own panels (§5.7).
6. **Reveal** (function `show`): show the action tiles (pointer-driven mode only), outlines of the aimed
   windows, screen dimming and — if exactly one window is aimed — a **pinned name
   popup** for that window next to *every* strip on screen (with a window preview, if enabled). The popup
   concerns the window the aim is on *at the moment of reveal*, not at the moment of opening.
   - If a double-tap action is configured **and** the mode was opened from the keyboard → the reveal
     is **delayed by 0.4 s** (so as not to flash the mode if this is the first half of a double tap).
   - Otherwise (no double-tap action or opening with the mouse) → immediately.
   - Any change of the aim during the delay (key, wheel, Shift+click, tile) cancels the
     delay and immediately shows the dimming; the rest is shown by the regular synchronization after an aim
     change (§5.11).
   - Note: the strip reacts to aiming mode immediately (it grows by `aimingScale`, default
     1.2×; in invisible mode it unfolds), because it tracks the mere fact of aiming — only
     the dimming, outlines, name popup and tiles are delayed.

#### 5.2 What is visible in aiming mode

- **Strip** magnified (scale `aimingScale`), active appearance on all monitors; the aim
  marked in orange, series/pinned highlighted (appearance details — chapter on the strip).
  In invisible mode the strip is visible only during aiming.
- **Group panel** next to the strip: if the aim is on a group as a whole or has entered a group,
  that group's panel is shown (so that it is visible what entering offers). In invisible mode the group
  panel is always hidden outside aiming.
- **Dimming**: a black, non-clickable layer on every screen with opacity
  `aimingDimOpacity` (default 0.45; 0 = disabled; slider 0–0.85), below the strip and popups,
  above regular windows; it appears and disappears with a 0.18 s animation.
- **Window outlines**: around each aimed window lying on the *current* workspace (and having
  a readable frame > 20×20) an orange outline is drawn (line 3 pt, corner 10 pt,
  drawn *inside* the window frame, no fill), above the dimming. The window under the aim —
  full opacity, the other aimed ones — 65 %. Appearance: 0.12 s. Windows from other workspaces are not
  outlined.
- **Name popup**: with one aimed window — pinned (does not disappear on its own) next to that window's row
  on every strip (a window shown in the group panel — only there); with ≥2 windows or aiming at a group
  as a whole — hidden (in its place the layout menu or the group panel).
- **Layout menu** (§5.9) with ≥2 aimed windows (not being a group as a whole).
- **Action tiles** (§5.8) in pointer-driven mode.

#### 5.3 Keyboard grab

Aiming mode must receive keys **without moving focus** and **without passing them through** to
the frontmost application. macOS implementation: a session-level event tap that *swallows* every
key press (key down). Key releases and modifier changes pass through (which is why
the super key tap still works in the mode). On GNOME: a modal keyboard grab of the shell (e.g.
`Main.pushModal`/stage grab) without activating any window.

- Every key is swallowed, including unknown ones.
- Navigation key → handled in §5.5 (asynchronously, outside the tap callback).
- Any other key → attempt to match a shortcut (§5.6).
- **Inactivity limit: 15 s** since the last key press (the timer is restarted only by
  keys — clicks and the wheel do not renew it) → the mode closes without confirming. A safeguard
  against the keyboard being locked by a forgotten mode. Also applies to pointer-driven mode.
- The grab could not be established → the mode closes immediately without confirming.
- If the system disables the tap (timeout/user input), it is immediately re-enabled.

Navigation key mapping (macOS physical codes → meaning):

| Key | Meaning (`Key`) |
|---|---|
| Return, Enter (numeric) | `enter` |
| Space | `space` |
| Escape | `cancel` |
| ↑ ↓ ← → | `up`, `down`, `left`, `right` |
| `[` | `back` |
| `]` | `forward` |
| `A` | `all` |

Two flags from the current modifiers are attached to each navigation key:
`extends` = Shift held; `moves` = Option **or** Command **or** Control held (any).
A navigation key is recognized regardless of modifiers (e.g. `⌥A` = `all`, `⌥Space` =
`space`).

#### 5.4 Directions: “along” and “across” the strip

- Vertical strip (left/right): **along** = ↑ (−1, previous) / ↓ (+1, next); **across** = ← →.
- Horizontal strip (top/bottom): along = ← (−1) / → (+1); across = ↑ ↓.
- The **“into the screen”** arrow (from the strip toward the center): left strip → `→`, right → `←`, top → `↓`,
  bottom → `↑`. The **“toward the strip”** arrow: the opposite (left → `←`, right → `→`, top → `↑`, bottom → `↓`).
- `[` = −1, `]` = +1 always.

#### 5.5 Handling navigation keys — exact algorithm (`handleAimingPress`)

Helper variables at the moment of the press:
- `aimedGroup` = the group on which the aim stands *as a whole* (i.e. the aim has not entered the group,
  and the window under the aim belongs to a group);
- `canTile` = ≥2 windows are aimed **and** `aimedGroup == nil` (a series built by the user).

Steps:

0. If **the layout menu has keyboard focus** → menu handling (§5.9) and done.
1. Compute the step:
   - `back` → −1, `forward` → +1;
   - arrow along the strip → −1/+1 as in §5.4;
   - arrow across the strip: if `canTile` → **no step**; otherwise ← and ↑ → −1,
     → and ↓ → +1 (i.e. without the layout menu the arrows across also move the aim);
   - other keys → no step.
2. If there is a step:
   - `moves` (Option/Command/Control) → **move the aimed windows in the queue** by the step (the whole series
     as a block, §5.12); takes precedence over Shift;
   - otherwise `extends` (Shift) → **extend the series** by the step;
   - otherwise → **move the aim** by the step (with wrap-around; clears the series and pinned);
   - then synchronization after the change (§5.11). Done.
3. Without a step, the first match:
   1. arrow into the screen and `aimedGroup ≠ nil` → enter the group;
   2. arrow toward the strip and the aim is inside a group → leave the group (aim on the group as a
      whole, on its first window);
   3. `enter` and `aimedGroup ≠ nil` → enter the group;
   4. `enter` and `canTile` → give focus to the layout menu;
   5. arrow into the screen and `canTile` → give focus to the layout menu;
   6. `all` → “select all” (`aimAll`: aims at all reachable windows; if all were already
      aimed — returns to just the window under the aim);
   7. `enter` or `space` → **confirm** (§5.10);
   8. `cancel` → close without confirming;
   9. other → nothing.

Note on the actual behavior (reproduce faithfully or fix deliberately): since the step from point 1
is computed before point 3, arrows across the strip with `canTile == false` *always* produce a step.
Consequences: (a) when the aim is on a group as a whole, the “into the screen” arrow moves the aim by +1
(instead of entering the group) — the group is entered with **Return** (or a click); (b) inside a group with
one aimed window the “toward the strip” arrow moves the aim by −1; leaving the group with this arrow
works only with a series of ≥2 windows inside the group. Space on a group aimed as a whole confirms
(focuses the window under the aim). Entering a group happens from the side the aim came from:
last step negative → aim on the group's last window, positive → on the first; entering clears the series
and pinned, and the group panel becomes “open”. Leaving: if the selection does not lie in this group,
the group panel closes.

Summary table (left strip, default modifiers):

| Key | 1 window / no series | Series ≥2 (`canTile`) | Aim on a group (whole) | Inside a group |
|---|---|---|---|---|
| `[` / `]`, ↑ / ↓ | move the aim ∓1 (wraps) | move the aim (series disappears) | move the aim | move through the group's windows |
| ⇧ + the above | extend the series (no wrap-around, stops at the ends) | extend/shrink | extend (group always whole) | extend within the group |
| ⌥/⌘/⌃ + the above | move the aimed windows in the queue | move the block | move the whole group | move the aimed ones |
| → (into) | move the aim +1 | focus to the layout menu | move the aim +1 | move +1 (1 window) / layout menu (series) |
| ← (toward the strip) | move the aim −1 | nothing | move −1 | −1 (1 window) / leave the group (series) |
| Return | confirm | focus to the layout menu | enter the group | confirm / menu (series) |
| Space | confirm | confirm (focus the window under the aim) | confirm | confirm |
| A | all / back | ditto | ditto | all windows of the group |
| Esc | close without changes | ditto | ditto | ditto |
| super key tap | confirm (or the double-tap action < 0.4 s after opening) | ditto | ditto | ditto |

Known side effect: navigation keys in the mode's tap do not explicitly cancel the tap detector, and
a swallowed event may not reach the global observer. A quick `⌥]` (Option pressed and
released in ≤0.4 s) in aiming mode may therefore *also* be read as a super key tap and
confirm the mode. Recommendation for a reimplementation: every key pressed while super is held should
invalidate the tap (in line with the “nothing in between” definition).

#### 5.6 Shortcuts in aiming mode; bare keys

Global shortcuts do not work in the mode (the grab swallows keys), so every key that is not a navigation
key is matched to an action manually. `bare` = none of ⌘ ⌥ ⌃ ⇧ was held (Caps Lock
etc. do not count). Order (first match wins):

1. If `bare` — **a key assigned to aiming mode only** (`aimBindings`: a dictionary physical
   key code → action, set by the user).
2. An action whose **full combination** matches exactly (the same key, identical set of
   modifiers ⌘⌥⌃⇧) — in the order of action declaration (table in §2).
3. If `bare` — an action whose combination is **the same key + exactly the super alone** (e.g. bare
   `G` → `⌥G`). Combinations with an additional Shift are not reachable with a bare key (bare `W` is
   `showOverview`, not `sortByWorkspace`; `⇧W` matches nothing — sorting in the mode requires
   the full `⌥⇧W`).
4. No match → nothing (the key is swallowed anyway).

The found action is executed as in the table in §2 (the “While aiming” column).

Consequences with the default shortcuts (super ⌥): in the mode, bare `Q` (close), `F` (fullscreen),
`M` (maximize), `H` (minimize), `G` (group), `R` (launcher), `W` (overview), `I` (strip),
`V` (recording), `P` (screenshot), `1`…`9` (switch workspace — ends the mode) work. With full combinations:
`⌥⇧1…9` (move the aimed ones), `⌥⇧↖`/`⌥⇧↘` (to start/end), `⌥⇧W` (sort). Bare Space, Return,
Esc, arrows, `[`, `]`, `A` are always navigation keys — shortcuts and `aimBindings` on these
keys will never work in the mode.

Settings “Aiming mode only” (a list below the shortcuts): rows “key → action” from the “Queue” action list,
a delete button on each row, an “Add a key” recorder accepting a bare key (only the
key code counts) and a choice of action for the new key. Description in the UI: “While aiming, every shortcut above works
without its super key. These keys work there and nowhere else, and come first when both would
answer.”

#### 5.7 Mouse in aiming mode

- **Click on an icon on the strip** (without Shift): ends the mode **without confirming**, then a regular
  selection and focus of the clicked window (without moving the cursor). If a window covered
  by fullscreen was clicked, fullscreen mode ends first (the queue returns to normal). A click on the stack
  tile = a click on the fullscreen window; a click on a group = entering the group on its first window.
- **Shift+click on an icon**: adds the window to the aim or removes it from it (`toggleAim`): everything aimed
  so far stays as “pinned”, the anchor disappears; the added window gets the aim; removing
  the last window is impossible; removing the window under the aim moves the aim to the nearest
  (in the visible slice) still-aimed one. A covered window cannot be added. The mode stays.
- **Wheel over the strip**: each step moves the aim by 1 (like `[`/`]`, without Shift/modifiers),
  focusing nothing.
- **Middle-button click** on an icon: closes the window (§7.4) — the mode stays open.
- **Click on a window in the group panel**: selects and focuses that window (without moving the cursor), does **not**
  close aiming mode (code behavior; probably an oversight).
- **Click anywhere outside WindowQueue's own panels** (with any button: left, right,
  other) → the mode closes without confirming. Clicks on the strip, group panel, action tiles, layout
  menu, popups do not close the mode (they are delivered to the application, and the observer sees only
  clicks going to other applications). The click still reaches the clicked application.
- All its own panels are “non-activating”: they never take keyboard focus; a click on them
  registers on button release (a “zero-distance drag” gesture).

#### 5.8 Action tiles (mode opened with the mouse)

Shown **only** when the mode was opened by clicking the badge; refreshed on every aim change.
A tile does exactly what its key does. The list is rebuilt from scratch (strict order):

When **≥2 windows** are aimed:
1. “Group” (stack of layers icon) → `toggleGroup`;
2. “Tile” (2×2 grid) → *confirm*; only when the aim does **not** stand on a group as a whole.

When **1 window** is aimed:
1. “Focus” (crosshair/scope) → *confirm*;
2. “Fullscreen” (outward arrows) → `toggleMaximize`.

Then always:
3. “Maximize” (vertically stretched rectangle) → `maximizeWindow`;
4. “Minimize” (rectangle with a minus) → `minimizeWindow`;
5. “Close” (×) → `closeWindow`;
6. “Select all” (list with checkmarks) → *select all* (like `A`);
7. launcher name: “Spotlight” / “Raycast” / “Alfred” (magnifying glass) → `openLauncher`;
8. “Overview” (3×3 grid) → `showOverview`;
9. “Screenshot” (camera) → `screenshotWindow`;
10. “Record” (record circle) or “Stop” (stop circle), when recording is in progress → `toggleRecording`;
11. “Hide strip” (crossed-out eye) or “Show strip” (eye), when invisible mode is enabled →
    `toggleInvisibleStrip`;
12. “Cancel” (escape) → close without confirming.

Behavior of the special kinds:
- *confirm*: if ≥2 windows are aimed and not a group as a whole → give focus to the layout menu (and refresh
  the tiles); otherwise → confirm (focus the window under the aim).
- *select all*: like the `A` key, then synchronization.
- shortcut: exactly like executing the action in the mode (§2).

Appearance and position: tile 58×42 pt (icon 15 pt, caption 9 pt on one line, may shrink
to 70 %), spacing 4 pt, panel padding 6 pt, semi-transparent panel background with a border, corner
12 pt, background opacity like the strip's. Tiles are laid out **across the strip direction**: with
a side strip one below another (column), with top/bottom — in a row. The hovered tile is
highlighted with the accent color (30 %). The panel stands next to the strip's content, on the screen-center side, 10 pt
from it, centered relative to the strip's center, clamped to the visible area of the strip's screen with
a 10 pt margin. It appears with a 0.14 s animation; its size is recomputed on every list change.
Without a strip — in the center of the screen.

#### 5.9 Layout menu (tiling of aimed windows)

Shown when ≥2 windows are aimed and the aim does not stand on a group as a whole; updated
on every aim change; hidden with <2 windows, with a group as a whole, and when the mode closes
(hiding always takes keyboard focus away from it).

Contents (width 220 pt, material background, corner 12 pt):
- header “N windows” (N = number of aimed windows);
- rows of the layouts available for N (§6.1), each with a layout thumbnail (34×22 pt, cell rectangles)
  and a name;
- a hint at the bottom:
  - menu without focus: “<arrow>, Return or click to choose a layout”, where arrow = `→` (left
    strip), `←` (right), `↓` (top), `↑` (bottom);
  - menu with focus: “Return or click to tile · Esc to go back”.
- a menu with focus has a 2 pt orange frame (otherwise a subtle 1 pt one); highlighted row:
  orange 35 % (with focus) or grey 8 % (without).

Highlight: initially the first (most useful) layout; it resets when the set of layout
names changes (e.g. going from 2 to 3 windows), and stays when the window count changes without changing the
names (e.g. 4 → 5: Grid/Main and stack/Columns/Rows).

Position: next to the icons of the aimed windows (the rectangle spanning the rows of the first and last
aimed window — in the group panel, if they are shown there, otherwise on the strip), on the screen side,
10 pt gap, centered relative to this rectangle and clamped to the visible area.

How to choose a layout:
- **With the mouse**: click on a row → highlights it and tiles immediately (also works without menu focus).
- **With the keyboard**: first focus the menu (Return or the into-the-screen arrow with a series ≥2, or the
  “Tile” tile), then in the menu:
  - ↑ or `[` → previous layout; ↓ or `]` → next (with wrap-around);
  - with a top/bottom strip additionally ← → previous, → → next;
  - Return or Space → tile with the highlighted layout;
  - **any other navigation key** (Esc, `A`, arrows across with a side strip — including
    the “toward the strip” arrow, but also “into”) → hand focus back to the strip (aiming mode continues).
  - Modifiers (Shift/⌥) in the menu are ignored. Shortcuts (non-navigation keys) work as
    usual in aiming mode.

#### 5.10 Closing the mode

`endAiming(commit)` (no effect when the mode is not open):
1. remember the window under the aim;
2. the model ends aiming (clears the aim, anchor, pinned, group entry);
3. hide the layout menu, release the keyboard, stop observing clicks, cancel the delayed
   reveal, hide the tiles, outlines and dimming; the pinned name popup disappears after
   min(`toastDuration`, 0.6) s;
4. if `commit` → select the window under the aim (without announcing) and **focus it** (§15, with
   moving the cursor, if enabled). With a series, confirming focuses only the window under the
   aim.

Ways of closing **with confirmation**: Return/Space (except for the menu/group cases), another super key
tap (not a double one), the “Focus” tile, *confirm* with one window.

Ways **without confirmation**: Esc, the “Cancel” tile, a click outside the panels, a click on an icon on the strip (after
which it focuses the clicked window), 15 s of keyboard inactivity, grab failure, double tap (after which
the action), any action that ends the mode (table in §2), tiling.

Actions after which the mode **stays**: moving the aim/series/block, entering/leaving a group,
`A`, Shift+click, wheel, `toggleInvisibleStrip`, `toggleRecording`, `toggleGroup` with one
aimed window, `toggleMaximize` with several, focusing/leaving the layout menu, middle-button
click, click in the group panel.

#### 5.11 Synchronization after every aim change (`aimChanged`)

1. If the reveal is still pending → cancel it and show the dimming.
2. Refresh the group panel, action tiles (pointer-driven mode), outlines.
3. If the aim stands on a group as a whole → hide the name popup immediately, hide the layout menu.
4. Otherwise, when ≥2 are aimed → hide the popup immediately, show/refresh the layout menu.
5. Otherwise → hide the layout menu; pinned name popup of the window under the aim next to every strip.

#### 5.12 Semantics of aim operations (summary — full description in the chapter on the model)

- **Moving the aim** by ±1: through reachable windows, with wrap-around; clears the anchor and pinned;
  remembers the direction.
- **Extending** by ±1: when there is no anchor, anchor = the current aim; the aim moves without
  wrap-around (stops at the ends). Series = windows from the anchor to the aim + pinned, in
  queue order. Outside a group, if the series touches a group's window, the whole group is aimed.
- **Moving the aimed windows in the queue** by ±1: the aimed (visible) windows are taken out and inserted
  together, in their order, from the position (first of them + step), clamped to [0, number of visible
  − number being moved]; a change of order disables auto-sorting and (for tiled groups) may
  trigger re-tiling (§6.6).
- **All** (`A`): see §5.5.

---

### 6. Tiling

#### 6.1 Layouts and their geometry

Layout = a list of unit rectangles (0…1, origin in the top-left corner), one per window, in
window order. Windows are assigned to cells in **queue order** (the first aimed window in
the queue = the first cell = the “main” one).

Layouts offered for N windows, in this order (the first is highlighted by default):
- N < 2: none;
- N = 2: “Side by side”, “Stacked”;
- N = 3: “Main and stack”, “Columns”, “Rows”;
- N ≥ 4: “Grid”, “Main and stack”, “Columns”, “Rows”.

Geometry:
- **Side by side / Columns** (N): columns of equal width 1/N, full height, from the left.
- **Stacked / Rows** (N): rows of equal height 1/N, full width, from the top.
- **Main and stack** (N ≥ 3): window 1 = left half, full height (x 0, width 0.5); the remaining N−1
  in the right half (x 0.5, width 0.5) one below another, each of height 1/(N−1).
- **Grid** (N ≥ 4): columns `c = ⌈√N⌉`, rows `r = ⌈N/c⌉`, row height 1/r; filled
  by rows from left to right, from the top; row i has `min(c, N − i·c)` windows and divides **the whole
  width** equally among them (a short last row has wider windows). E.g. N=5: c=3, r=2 → 3 + 2;
  N=7: 3+3+1 (the last window spans the whole width).

Layout “kind” (used when the window count changes during finalization): “Side by side” ≡
“Columns”, “Stacked” ≡ “Rows”, the others — themselves.

Maximize/fullscreen is internally a “Maximize” layout with one cell (0,0,1,1).

#### 6.2 Tiling area (`tilingArea`)

1. Screen: the one with keyboard focus (“main”; on GNOME — the monitor with the active window), and failing that —
   the first one.
2. Its workspace area (without the menu bar and Dock; on GNOME — the monitor's work area), but **without**
   the space reservation that WindowQueue itself applied for the strip (if the reservation is installed
   on this screen and the area actually contains it, it is added back — so as not to subtract it twice).
3. If the strip is not hidden (`stripDisplay ≠ hidden`) **and** `reserveScreenSpace` is enabled → on
   the strip's side subtract the reservation width: `ceil(strip_thickness + 2·stripMargin)`, where thickness =
   `iconSize + 8 + 2·6` (default 34 + 8 + 12 = 54, reservation = 54 + 8 = **62 pt**). **In invisible
   mode the reservation = 0.**

Tiling always takes place in the area of *this* screen, regardless of which monitor the windows
lie on.

#### 6.3 Setting frames (`WindowTiler.tile`) and gaps

Parameters: `tileOuterGap` (default 0) — gap from the edge of the area; `tileInnerGap` (default 4)
— gap between adjacent windows.

1. `inset = outer − inner/2`; the area shrunk by `inset` on each side (with defaults:
   −2, i.e. *enlarged* by 2).
2. Cell = the unit rectangle scaled to the area, each coordinate rounded.
3. Window frame = the cell shrunk by `inner/2` on each side. Result: exactly `outer` at the
   edges, exactly `inner` between windows.
4. A minimized window is restored first.
5. Set the position, then the size. If the read-back frame differs from the requested one by > 2 pt in any
   coordinate → set the size, position and size again (for applications that clamp the size).
6. For the duration of the change, the application's frame animation is disabled (the “enhanced UI” attribute), then
   restored.
7. **Corrections**: check at 0.15, 0.4, 0.8 and 1.5 s after setting. If the frame matches (±2 pt) →
   continue. If different, but also different from the state at the previous check → the window is still moving,
   check later. If different and stable → set again (and continue the checks). A newer frame
   request for the same window invalidates the checks of the older one.
8. The “last frame assigned by WindowQueue” is remembered for each window (to recognize whether
   the user moved it afterwards).
9. Windows without a handle (e.g. on an unvisited workspace) are skipped; result = the list of those actually
   set.

After tiling, the group is **raised to the front** together: windows are raised in reverse order, so
the layout's first window ends up on the very top.

#### 6.4 Choosing the workspace for a layout (`tileAimedWindows`)

Input: the aimed windows (queue order, ≥2), the highlighted layout. First, aiming mode
closes (without confirming).

- `home` = the workspace of the **last** aimed window.
- “Strangers in place” = whether on `home` there is any non-minimized queue window (the whole queue,
  regardless of scope) from outside the layout.
- If there are strangers → search for the best workspace (`workspaceForLayout`):
  - only workspaces of **the same monitor** as `home`, in numbering order (Mission Control);
  - excluding `home` itself;
  - a workspace qualifies if **all** its non-minimized windows belong to the layout
    (an empty one also qualifies);
  - best = the most layout windows already there (“holds”); tie → the nearest by distance in the list from
    `home`; further tie → the earlier in order;
  - found → target = that workspace;
  - not found → target = `home` and a centered popup: **“Tiled where they are”** / **“No workspace
    on this monitor is free for the layout, and macOS would not add one”** (new workspaces are
    not created).
- No strangers → target = `home` (spanning several workspaces is not by itself a reason to relocate:
  the missing windows will be moved to `home`).

#### 6.5 Moving and finalization

1. `home` unknown → tile immediately in place (§6.5 step 6).
2. All windows already on the target **and** the target is visible (on any monitor) → tile immediately.
3. Otherwise move the windows not on the target to the target (as in §8.1; a window that cannot be moved
   stays) and move them in the queue into the target's block.
4. Go to the target: if the last window (after moving) is on the target or the target is visible →
   focus it (without moving the cursor; this also takes you to its workspace); otherwise switch
   workspace (carrier, falling back to the system shortcut ⌃N).
5. After **0.9 s**: if the target is now visible, each window still not on the target tries to be “pulled”
   onto the current workspace (on macOS: an application-activation trick; on GNOME: a plain window
   move). Then “gathered” = windows on the target **or** with an unreadable workspace; move them in the queue
   into the target's block.
   - Gathered < 2 → tile **all** requested windows where they are.
   - Fewer gathered than requested → centered popup **“Tiled N windows”** / **“K would not leave
     its workspace”** and tile only the gathered ones.
   Refresh window handles and the window list.
6. **Finalization** (`finishTiling`): discard windows without a handle. If the number of windows ≠ the number of cells of
   the layout → take the layout of the same *kind* for the new count, and if there is none — the first available;
   with < 2 windows nothing happens. Tile (§6.3) in the area (§6.2), raise the group to the front, save
   the tiled group (§6.6), select the first window (without announcing) and focus it (without moving
   the cursor).

#### 6.6 Tiled group lifecycle

**Creation** (`noteTiled`):
- for 2 s from now, frame changes are considered our own (global marker `tilingSettledAt`,
  shared by all groups);
- the layout's windows have their remembered pre-maximize frames cleared (the layout replaces maximization);
- the windows leave their previous tiled groups; a group left with < 2 windows disappears;
- the new group gets **the smallest free number** (from 1), the layout name and the window list; the number is
  shown on the strip (when there are > 1 groups);
- groups that lost windows but still have ≥ 2 are **re-tiled after 0.4 s** for the new window
  count: the layout with the same *name*, if available for that count, otherwise the first available (here
  “kind” is not used: e.g. “Rows” of 3 windows with 2 windows becomes “Side by side”, “Grid” of 4 with 3
  — “Main and stack”);
- the order of the group's windows is remembered; after 2 s the actual window frames are saved (after corrections).

**Re-tiling after a change of order**: after every queue change, for each tiled group
the order of its windows in the queue is compared with the remembered one. Different (and ≥ 2 windows) →
- if any window of the group is in fullscreen mode → only remember the new order (without tiling);
- otherwise tile the group anew in the new order (layout by name or the first) and save it as a new
  group (again the smallest free number — the number may change).
This is the fastest way to change the “main” window: move it in the queue to the start of the group.

**Release by manual movement**: on a window moved or resized notification (not on
a focus change):
- ignored if 2 s have not passed since the last tiling (`tilingSettledAt`), if the window is not
  in a tiled group, or if its frame differs from the saved one by ≤ 4 pt in every coordinate;
- otherwise the whole group ceases to exist; the windows stay exactly where they are.
Note: `maximizeWindow` on a window from a group causes a frame change after the protection period → releases the group.
Re-tiling via “groups that lost windows” does not refresh the saved frames — a reimplementation
should refresh them after 2 s, so that an accidental notification does not release the group.

**Fullscreen does not release the group**: toggling fullscreen sets a 2 s protection period, and returning
restores the window to its cell (§7.2).

**Disappearing windows**: a closed/vanished window drops out of the group; a group with < 2 windows disappears (the last window
stays as it is). A group left with ≥ 2 windows now has a different window list than the remembered one, so
the order-change detector (above) **re-tiles it** for the smaller window count (layout by name
or the first available). Minimization does not remove a window from the queue, so it does not change the group.

**Refit to the new space** (only after toggling invisible mode with a shortcut/tile, 0.25 s
later — `refitPlacedWindows`): in the new area
1. each tiled group (≥ 2 windows, without a window in fullscreen) is re-tiled and saved;
2. a window in fullscreen mode is filled anew;
3. every other window that was maximized (has a remembered pre-maximize frame), does not
   belong to a tiled group and still stands exactly (±2 pt) where WindowQueue last
   placed it → filled anew. Windows moved by the user stay.
(Changing the strip's visibility in Settings alone does not trigger a refit.)

**Raising the whole layout**: see §15.

#### 6.7 Cell preview while dragging

When an icon of a window belonging to a tiled group is dragged on the strip, the screen shows
the rectangle of the cell the window would occupy if dropped at the current position: the queue after
the drop is simulated, the group members are taken in that order, the index of the dragged window, the layout by name (or
the first for that count), the cell at that index in the area (§6.2) shrunk by `outer`, and then
by `inner/2`. A window outside a tiled group / end of dragging → the preview disappears.

---

### 7. Window operations

#### 7.1 Maximize (`maximizeWindow`, `⌥M`)

- If the window does not yet have a remembered "pre-maximize frame" → remember the current one.
- Fill the tiling area (§6.2) with the `outer` gap from the edges (§6.3).
- Nothing more: there is no focus mode, the queue does not change, the other windows stay. Pressing `⌥M`
  again does not restore (but `⌥F` on a window maximized this way restores the frame from before `⌥M` — §7.2).
- With several aimed windows: each window in turn (they all get the same frame, overlapping).

#### 7.2 Fullscreen (`toggleMaximize`, `⌥F`)

This is **not** the system full screen — the window fills the screen area minus the strip's space
(with the `outer` gap).

1. Take the selected window (none → nothing). Set the tiled-group guard time to 2 s.
2. **Restore**: if the window has a remembered pre-maximize frame **and** its current frame
   "fills" the area — |Δx| ≤ 12, |Δy| ≤ 12, |Δwidth| ≤ 24, |Δheight| ≤ 24 (tolerance for application
   rounding) → clear the remembered frame, restore the window to it, end focus mode (the queue
   returns to its former order).
3. **Enter**: otherwise remember the current frame (overwriting the old one), fill the area and,
   if `focusMaximizedWindow` is enabled (default yes), start **focus mode** on the window:
   the window moves to the start of its workspace's block in the queue (remembering its neighbours so it can later
   return to its place), and the remaining windows of that workspace become "covered" (on the strip collapsed into a
   stack tile or dimmed, skipped by cycling and aiming). An earlier focus on another
   window ends first.
4. A window from a tiled group stays in the group; pressing `⌥F` again restores it to its cell.

Restoring works regardless of whether the window is the "focus window" — only the remembered
frame and the match to the area decide. A window that was moved after going fullscreen (no longer fills the
area) enters fullscreen again on `⌥F` (with a newly remembered frame).

Focus mode is also exited by clicking a covered window on the strip (focus mode ends, the window
does not change) and when the fullscreen window disappears.

Hold popup of the stack tile (the pointer rests on it): **"+N window(s) hidden"** (singular
"window" for N=1) / **"<toggleMaximize shortcut> restores the maximized window and brings them
back"**, pinned next to the first hidden window.

#### 7.3 Minimize (`minimizeWindow`, `⌥H`)

Sets the window's state to "minimized" (via the Accessibility API). Nothing more — no popup (except for the variant
for several windows), no change of selection by the controller.

#### 7.4 Closing (`closeWindow`, `⌥Q`, middle button, × on the strip/group panel)

1. The **successor** is chosen *before* closing (so the selection does not fall to the start of the queue):
   - window on the **current** workspace → the nearest, in queue order, non-minimized window from
     the visible slice lying on the same workspace (excluding the window itself); there may be none;
   - window on another workspace (or without a workspace) → its neighbour in the visible slice: the next one, and for
     the last one — the previous one; none when the window is the only one.
2. Closing: pressing the window's close button via the Accessibility API. When the window has no handle
   (another workspace) or no button → focus the window and retry looking for the button every 0.12 s up to 12 times;
   on the last attempt, if the window's application is frontmost and its focused window is exactly this one
   (or this cannot be determined and the application has ≤ 1 window) → send the application `⌘W` (on GNOME: ask
   the window to close — `Meta.Window.delete`, which removes this entire workaround mechanism).
3. If there is a successor → **select** it (without announcing and without explicit focusing).
4. If the window was on the current workspace and there is no successor (the last window of the workspace was closed) →
   **hold the workspace** for 2 s: if during this time the system itself moves the user to another
   workspace (e.g. by activating another application), and the user did not ask to change workspace within the
   last 0.5 s and no WindowQueue jump of its own is in progress → return to the emptied workspace (once).
   A user request to change workspace cancels the hold. The strip then shows an empty slot.
5. Refresh the window list after 0.4 s and after 1.2 s (the system may have moved another window here).

With several aimed windows: `close` for each in turn (each computes its own successor), then the popup
"Closed N windows".

---

### 8. Workspaces

#### 8.1 Moving windows to a workspace (`moveToSpaceN`, `⌥⇧N`)

1. Windows: in aiming mode — all aimed windows (the mode ends without confirming); otherwise —
   the selected window.
2. Workspace N = the user's N-th (from 1) workspace in numbering order **across all monitors**.
   No windows, no such workspace, or the move mechanism unavailable → nothing (no popup).
3. Move — **the user goes along with the windows** to the target workspace:
   - macOS: first an attempt to move individual windows via the WindowServer; whatever did not get through —
     by assigning the whole application to the workspace, but **only** if the application has no other
     non-minimized windows besides the moved set and besides the target. The result is read
     back: "arrived" (including those that were already there) and "left behind".
   - macOS, fallback for the left-behind ones ("drag"): the window is raised to the top, and the grab point
     (middle of the width, 5 px below the top edge) must hit exactly that window — otherwise give up.
     Simulated: left button press, move by 1 px, switch to the target with a carrier window
     (not ⌃N — the user may still be holding ⌥⇧ from the shortcut, and ⌃⌥⇧N is not a Mission
     Control shortcut), wait for the target (≤ 2 s + 0.2 s), release, restore the cursor, verify.
     A window from another desktop is visited first. When no window arrived, the user returns to the
     original desktop. Meanwhile any further move is ignored, and focus follows mouse is
     suspended. (Minimizing does not work: macOS 26 restores the window to its former desktop.)
   - GNOME: each window can be moved separately (`change_workspace_by_index`), the fallback is unnecessary;
     "left behind" = only actual failures.
4. Arrived windows move in the queue to the target workspace's block (after its last window, or —
   when there are no windows there — before the first window of a later workspace, or to the end), keeping
   their mutual order.
5. The first (in the order of the moved ones) window that arrived becomes selected and focused —
   this takes the user to the target workspace, if they are not there yet.
6. Popup (regular, disappears after `toastDuration`, next to the icon):
   - some left behind → **"<application name of the first left-behind> stayed where it was"** + when
     left behind > 1: **" and K more"** (K = count − 1); subtitle **"It could not be moved to
     workspace N"**; next to the left-behind window;
   - otherwise → title = window title (or application name when the title is empty) for a single window, or
     **"N windows"**; subtitle **"Moved to workspace N"**; next to the first window.
7. Refresh the window list after 0.3 s.
8. A window moved out of a tiled group drops out of it (the group remembers its workspace), and the remaining
   windows of the group are laid out anew; a single remaining window fills the workspace area.

#### 8.2 Switching workspace (`spaceN`, `⌥N`) — summary

Details of the mechanics are in the chapter on workspaces; the controller does the following:
- records the time of the user request (for §7.4) and the request number (a newer one invalidates retries of an older one);
- strategy from Settings: "Focus a window on that workspace" — select and focus (with cursor
  warp) the selected window if it lies on the target, otherwise the first non-minimized window of the target in
  queue order; when empty — carrier jump; as a last resort the system shortcut; "Send ⌃1…⌃9" — shortcut
  only; "Carry an invisible window there" (default) — carrier jump, falling back to the shortcut;
- after 0.8 s checks whether the target is visible; if not, and the user is still on the original
  workspace → retries (1st retry: jump, falling back to the shortcut; 2nd: shortcut), at most 2 retries;
  if the user is already somewhere else — gives up.
On GNOME `workspace.activate_with_focus(window, time)` / `activate(time)` is enough.

---

### 9. Sorting the queue (`sortByWorkspace`, `⌥⇧W`, menu)

Permanently turns on the `autoSortByWorkspace` setting and sorts immediately: stably by the position of the
window's workspace in numbering order; windows with an unknown workspace (e.g. minimized) at the end;
the order within a workspace stays. Every manual change of order (shifting, dragging,
shifting a block in aiming, `moveToStart/End`) turns auto-sorting off and saves that in
Settings. No popup.

---

### 10. Window finder (`search`, `⌥Space`, by default also double tap)

Toggle: open → close; closed → open (only if the queue is not empty).

**Appearance**: a non-activating panel (does not take focus), width 560 pt; query field 52 pt high
with a magnifier icon and 19 pt text — with an empty query a grey placeholder **"Search windows"**; below
it (when there are results) a 1 pt separator and a list of 44 pt rows, max. **8 visible** (the rest
scrolls; the highlighted row is scrolled to the middle). Row: application icon 22×22, window title
(or application name for an empty title), below it the application name (smaller, grey), on the right the
workspace number in a grey pill (if known). Highlighted row: accent colour at 25%. Panel corner
14 pt, translucent background. Panel height = 52 + (results > 0 ? 1 + min(results, 8)·44 : 0) —
computed from the number of results, not from measuring the view, and recomputed after every query change. Position:
centred horizontally on the focused screen, top edge 22% of the workspace area's height below its
top edge. While the finder is open the screens are dimmed (the same dimming as in
aiming).

**Results**: all queue windows (**ignores the "current workspace only" scope**; includes
minimized ones, if they are in the queue). Empty query → queue order. Otherwise: fuzzy
matching against the text "<application name> <title>", only matches, descending by score (ties in
queue order):
- the query is split into words on spaces; **every** word must match (scores add up);
- case-insensitive comparison;
- word as a contiguous substring: score 100 − min(index, 40), +25 if it starts at a word start
  (index 0 or the previous character is one of: space `-` `_` `.` `/` `:` `—` `–` `(` `[` `|` `,` `'`);
- if there is no substring — "gapped" matching: the word's characters in order, each at its first
  occurrence after the previous one; +25 if the first matched character starts a word; +4 for each character matched
  right after the previous one; the span (from the first to the last match) may exceed the word's length
  by at most 3, otherwise no match; minus min(position of the first match, 20);
- finally `text_length / 20` (integer) is subtracted from the sum — shorter titles win ties.

**Keyboard** (grab as in aiming: nothing reaches applications, focus does not change; inactivity
limit **30 s** → close):
- Esc → close;
- Return / Enter → choose the highlighted result (no results → nothing);
- ↑ / ↓ → previous / next result (wrapping); Tab → next;
- Backspace → delete the last character of the query;
- any other key → the characters it would type (taking Shift/Option into account, e.g. "ą"), appended to
  the query if non-empty and free of control characters; otherwise ignored;
- every query change moves the highlight to the first result;
- all keys are swallowed — global shortcuts (including `⌥Space`) do not work while the finder
  is open; it is closed with Esc, a choice, or the timeout.
- Click on a row → choice.

**Choice**: close the finder, select the window (without announcing) and focus it (§15, with cursor
warp).

While the finder is open: tapping the super key does nothing, focus-follows-mouse is suspended.

---

### 11. Launcher and workspace overview

**Launcher** (`openLauncher`, `⌥R`; setting `launcher`, default Spotlight):
- Spotlight → simulated press and release of `⌘Space` (its system shortcut);
- Raycast / Alfred → launch/activate the application (bundle identifier `com.raycast.macos` /
  `com.runningwithcrayons.Alfred`), which shows their bar; if it is not installed → Spotlight.
- Settings show Raycast/Alfred as available only when they are installed.
- In aiming mode the mode closes first (releases the keyboard), and only then does the launcher open.
- GNOME: the Spotlight equivalent = search in the Activities overview (`Main.overview.show()` with
  the search field focused) or a configured external launcher (command).

**Overview** (`showOverview`, `⌥W`): opens Mission Control (launches the system application). GNOME:
`Main.overview.show()` / toggling the Activities view. In aiming mode — the mode is closed first.

---

### 12. Invisible strip (`toggleInvisibleStrip`, `⌥I`)

1. Invert the `invisibleStrip` setting (saved permanently).
2. Centred popup:
   - on: **"Strip hidden"** / **"<shortcut> brings it back; aiming mode shows it meanwhile"**;
   - off: **"Strip shown"** / **"<shortcut> hides it again"**.
3. Update the screen space reservation (in invisible mode the reservation = 0) and the integration with
   the external layout manager (Rectangle — none on GNOME).
4. After 0.25 s — fit the placed windows to the new area (§6.6 "Fitting").
In aiming mode the mode stays (the strip unfolds/folds under the aim); the tile changes its label
"Hide strip" ↔ "Show strip".

---

### 13. Screen recording (`toggleRecording`, `⌥V`)

- **Start** (when nothing is recording): start recording the **whole screen** to the file
  `"Recording <date>.mov"` in the user's screenshot directory (§14 "Directory"), where `<date>` =
  `yyyy-MM-dd 'at' HH.mm.ss` (e.g. `Recording 2026-09-24 at 14.03.22.mov`); on a name collision:
  `… (2).mov`, `… (3).mov`… On macOS: `screencapture -v <path>` as a process running until
  interrupted. GNOME: e.g. D-Bus `org.gnome.Shell.Screencast.Screencast` (a .webm/.mp4 file in
  `~/Videos/Screencasts` or the same directory as screenshots).
  Centred popup: **"Recording the screen"** / **"<shortcut> stops it and saves the file"**.
- **Stop** (when recording): send the process SIGINT (this is how the tool finalizes the file). Popup:
  **"Recording saved"** / file name without extension (e.g. `Recording 2026-09-24 at 14.03.22`).
- When the recording process ends on its own, the "recording" state goes off.
- Failed start: the code returns "not started, no file", so **"Recording saved"** /
  **"The recording has been written"** is shown (a misleading message — recommended in a reimplementation: a separate error
  popup).
- **Indicator**: while recording is in progress, the workspace badge on the strip is replaced by a red,
  pulsing recording symbol (60% of the icon size) on a reddish background (16%), with the tooltip
  "Recording the screen". Action tile: "Record" ↔ "Stop".
- In aiming mode the mode stays open.

---

### 14. Window screenshots (`screenshotWindow`, `⌥P`)

1. Windows: in aiming mode — **all aimed windows** (queue order; the mode closes first);
   otherwise — the selected window. No windows → nothing.
2. No screen recording permission → centred popup **"Screen Recording access needed"** /
   **"System Settings › Privacy & Security › Screen Recording"** and stop. (GNOME: there is no such permission;
   window capture via a shell extension / `Shell.Screenshot`.)
3. Each window in turn is raised to the top (the last one ends up on top), because an obscured window
   would be photographed together with whatever covers it; after **0.15 s** the shots.
4. **One PNG file per window**, the window alone without shadow, without shutter sound. Name:
   `"<name> <date>.png"`, where `<name>` = window title (or application name for an empty title) with
   `/` and `:` replaced by `-`, whitespace trimmed; empty result → application name; max.
   60 characters; `<date>` as for recording; collisions → ` (2)`, ` (3)`…
5. **Directory**: the screenshot save location set by the user in the system (on macOS the `location`
   preference in the `com.apple.screencapture` domain, with `~` expanded), default `~/Desktop`
   (GNOME: the screenshots directory, usually `~/Pictures/Screenshots`).
6. Centred popup:
   - nothing saved → **"Nothing captured"** / **"The window could not be photographed"**;
   - 1 file → **"Screenshot saved"**, >1 → **"N screenshots saved"**; subtitle = directory name
     (last path component, e.g. "Desktop").

---

### 15. Focusing a window and what accompanies it (`focus`)

Every focusing by the controller:
1. Window focus (mechanics in the chapter on focus): travel to its workspace, raise, activation,
   retries. **Cursor warp** to the window's centre — only when the focus comes from the keyboard
   **and** `warpCursorToWindow` is enabled (default yes). With warp: cycling, confirming
   aiming, choice in the finder, switching workspace by focusing a window, the successor after moving a
   window to a workspace. Without warp: click on the strip and in the group panel, focus after scrolling with the
   wheel, finalizing tiling.
2. **Raising the whole layout**: if the window belongs to a tiled group, its other windows lying on
   *the same workspace* are raised to the top (reverse queue order), and finally the
   focused window itself — so that choosing one window of the layout does not leave the rest under another application. Group
   windows from other workspaces are not touched.
3. **Focus flash** (if `flashFocusedWindow`, default yes, and the duration > 0): an outline as in
   aiming, but in the **accent/selection colour**, full opacity, around the window frame; it appears
   immediately, holds for `flashFocusedWindowDuration` (default **0.15 s**), then fades out over 0.5 s
   (ease-in). A window on another workspace is outlined only after arrival: checking every 0.1 s,
   up to 20 attempts (2 s), then giving up. It does not flash when aiming mode was opened in the meantime, nor when
   the window frame is unreadable / < 20×20. One shared outline (a new flash replaces the previous one).

---

### 16. Wheel over the strip

- Conversion to steps: notched wheel — each event = 1 step (sign according to direction); smooth
  scrolling (touchpad) — accumulating the delta and 1 step per strip row height
  (`iconSize + 8`), the remainder carries over. The axis with the larger value is used (horizontal scrolling
  works the same way). Scrolling "down" (content up) = next window.
- **Outside aiming**: the selection moves immediately by that many steps in the cycle (with the name popup), and
  **focus is deferred**: each scroll cancels the previous deferral; after `scrollFocusDelay`
  (default **0.5 s**) without scrolling the selected window is focused (without cursor warp).
- **In aiming**: each step moves the aim (like `[`/`]`), nothing is focused.

---

### 17. Groups (`toggleGroup`, `⌥G`)

- **In aiming, ≥ 2 aimed**: close the mode, create a group from the aimed windows (in
  queue order; windows leave their previous groups, groups < 2 disappear; number = smallest free from 1),
  select the first aimed window (without focusing; the group becomes open — the group panel next to the
  strip). Centred popup **"Grouped N windows as group G"** / **"WindowQueue"**. Aiming at a
  group as a whole and pressing `G` again recreates the group (may change its number).
- **In aiming, 1 aimed**: popup **"Aim at two or more windows to group them"** / **"Shift-click
  or Shift with the arrows"**; the mode stays open.
- **Outside aiming**: selected window in a group → dissolve that group (the windows stay in the queue in their
  places), popup **"Ungrouped N windows"** / **"WindowQueue"**. Otherwise popup **"Nothing to
  ungroup"** / **"Select a window in a group, or aim at several to make one"**.
- Hovering the pointer over a group entry on the strip: pinned popup **"Group G — N windows"** /
  **"Click to open it in a strip of its own"** (disappears when the pointer leaves).

---

### 18. Status bar menu

Icon: a "stack of rectangles" symbol (on GNOME: an indicator in the top panel). Menu items, in order:

| Item | Menu shortcut | Action |
|---|---|---|
| "Settings…" | `⌘,` | Opens the Settings window (created once, then recalled); after 0.3 s refreshes the window list. While the Settings window is open the app becomes a regular application; after closing it returns to the "no Dock icon" mode and refreshes the window list. |
| "Sort queue by workspace" | `⌘S` | Like the `sortByWorkspace` action (§9). |
| "Refresh windows" | `⌘R` | Immediate recomputation of the windows. |
| (separator) | | |
| "Quit WindowQueue" | `⌘Q` | Quits the application (restoring the screen space reservation). |

Menu shortcuts work only while the menu is open. "Launching" the already running application again
(from a launcher/file manager) opens Settings.

---

### 19. All popups — verbatim texts

All popups are turned off by a single setting `toastEnabled` (then none appears, including
centred ones). Kinds:
- **next to the icon** (title 13 pt bold, subtitle 11 pt grey, each on one line; width
  140–480 pt; 8 pt from the icon on the screen side, clipped to the screen; when there is no row —
  at the left edge of the workspace area at its vertical middle): a regular one disappears after `toastDuration` (default
  1.0 s), a pinned one lasts until the hold is released and then disappears after min(`toastDuration`, 0.6) s;
- **centred** (in the middle of the focused screen's workspace area): disappears after max(`toastDuration`, 1.2) s.
Appearing 0.12 s (0.08 s when already visible and only changing), disappearing 0.18 s. A new popup replaces
the previous one.

| When | Kind | Title | Subtitle |
|---|---|---|---|
| Announced selection change (cycling, wheel) | next to the icon, regular | window title (or application name) | application name |
| Aiming at a single window | next to the icon on **every** strip, pinned, with window preview (if `showWindowPreview` and access is granted) | window title | application name |
| Holding/hovering an icon | next to the icon, pinned, with preview | window title | application name |
| Hovering the stack tile | next to the icon, pinned | "+N window hidden" / "+N windows hidden" | "<fullscreen shortcut> restores the maximized window and brings them back" |
| Hovering a group entry | next to the icon, pinned | "Group G — N windows" | "Click to open it in a strip of its own" |
| Tiling with no free workspace | centred | "Tiled where they are" | "No workspace on this monitor is free for the layout, and macOS would not add one" |
| Tiling, some windows did not arrive | centred | "Tiled N windows" | "K would not leave its workspace" |
| Fullscreen with several aimed | centred | "Fullscreen takes one window" | "Aim at a single window, or tile the group with Return" |
| Grouping with 1 aimed | centred | "Aim at two or more windows to group them" | "Shift-click or Shift with the arrows" |
| Group created | centred | "Grouped N windows as group G" | "WindowQueue" |
| Group dissolved | centred | "Ungrouped N windows" | "WindowQueue" |
| Nothing to ungroup | centred | "Nothing to ungroup" | "Select a window in a group, or aim at several to make one" |
| Maximizing several | centred | "Maximized N windows" | "WindowQueue" |
| Minimizing several | centred | "Minimized N windows" | "WindowQueue" |
| Closing several | centred | "Closed N windows" | "WindowQueue" |
| Several to the start of the queue | centred | "Moved N windows to the start of the queue" | "WindowQueue" |
| Several to the end of the queue | centred | "Moved N windows to the end of the queue" | "WindowQueue" |
| Move to workspace — OK | next to the first window's icon, regular | window title or "N windows" | "Moved to workspace N" |
| Move — window stayed | next to that window's icon, regular | "<App> stayed where it was" [+ " and K more"] | "It could not be moved to workspace N" |
| Recording start | centred | "Recording the screen" | "<shortcut> stops it and saves the file" |
| Recording stop | centred | "Recording saved" | file name without extension (or "The recording has been written") |
| Screenshot without permission | centred | "Screen Recording access needed" | "System Settings › Privacy & Security › Screen Recording" |
| Screenshot failed | centred | "Nothing captured" | "The window could not be photographed" |
| Screenshot succeeded | centred | "Screenshot saved" / "N screenshots saved" | directory name |
| Strip hidden | centred | "Strip hidden" | "<shortcut> brings it back; aiming mode shows it meanwhile" |
| Strip shown | centred | "Strip shown" | "<shortcut> hides it again" |

`<shortcut>` is the current key combination of the given action in the notation from §"Conventions" (e.g. `⌥V`, `⌥I`, `⌥F`).

Other fixed UI texts from this chapter: action tile titles (§5.8), "N windows" and the layout menu
hints (§5.9), the "Search windows" placeholder (§10), status bar menu items (§18), the recording
indicator tooltip "Recording the screen" (§13).

---

### 20. Timing constants and thresholds

| Constant | Value |
|---|---|
| Max. super key hold time for a tap | 0.4 s |
| Double-tap window (from opening the mode) | 0.4 s |
| Mode reveal delay (when there is a double-tap action) | 0.4 s |
| Keyboard inactivity limit: aiming / finder | 15 s / 30 s |
| Wait for windows to gather before tiling | 0.9 s |
| Re-laying out groups that lost windows | +0.4 s |
| Guard time after laying out/fullscreen (frame changes treated as "own") | 2 s |
| Reading tiled-group frames after laying out | +2 s |
| "Window not moved" tolerance (tiled group) | ±4 pt |
| Frame correction checks | 0.15 / 0.4 / 0.8 / 1.5 s; tolerance ±2 pt |
| "Window fills the area" tolerance (fullscreen) | position ±12 pt, size ±24 pt |
| Closing: button search retries | 12 × every 0.12 s |
| Closing: list refreshes | 0.4 s and 1.2 s |
| Hold of the emptied workspace | 2 s; a user request in the last 0.5 s wins |
| Refresh after moving to a workspace | 0.3 s |
| Check of arrival on the workspace | 0.8 s, max. 2 retries |
| Window screenshot after raising | 0.15 s |
| Fitting after toggling the invisible strip | 0.25 s |
| Focus flash: hold / fade-out / retries | 0.15 s (configurable) / 0.5 s / every 0.1 s × 20 |
| Focus after wheel scrolling | 0.5 s (configurable) |
| Popup: regular / centred / after hold | `toastDuration` (1.0 s) / max(·, 1.2 s) / min(·, 0.6 s) |
| Animations: dimming / tiles / outlines | 0.18 s / 0.14 s / 0.12 s |
| Refresh after opening Settings | 0.3 s |

---

### 21. Debug commands (for testing only)

Enabled by the `debugCommands` preference; commands arrive as a distributed notification
`com.mpochec.windowqueue.command` with a line of text: `action <action id>` (perform the action), `aim` (like
tapping the super key), `aimkey <up|down|left|right|back|forward|enter|space|cancel> [shift] [move]`
(a key in aiming mode, only when it is open), `focus <window id>` (select with announcement and
focus), `refresh`, `dump` (write the state to the log file). On GNOME the equivalent: a D-Bus method.

---

### 22. Non-obvious behaviours (keep or deliberately fix)

1. `toggleMaximize` from aiming mode with a **single** aimed window ends the mode **without**
   selecting the aimed window, so fullscreen applies to the *selected* window — different from the
   aimed one if the user moved the aim. This also applies to the "Fullscreen" tile. (Other window
   actions — `maximize/minimize/close/moveToStart/End` — select the aimed window first.)
   Recommendation: select the aimed window before fullscreen.
2. `⌥[`/`⌥]` (the default cycling shortcuts) in aiming mode move the aimed windows in the queue (because
   Option = "moves"), not the aim; `⌥Space` confirms instead of opening the finder.
3. The arrow pointing "into the screen" does not enter a group aimed at as a whole (it moves the aim); a
   group is entered with Return or a click (§5.5).
4. Clicking a window in the group panel during aiming focuses it without closing the mode.
5. A failed recording start shows "Recording saved".
6. The 15 s inactivity limit also closes a mode opened with the mouse, even though clicks do not renew it.
7. All aimed windows moved with `⌥⇧↖`/`⌥⇧↘` when they span the whole visible slice: the queue
   does not change, yet the popup still says "Moved N windows…".
8. A quick `⌥` + navigation key in the mode may be read as a super key tap (§5.5).
9. Tiling always uses the focused screen's area, even when the target workspace is on another
   monitor.

---

## System layer

This part describes everything that connects WindowQueue to the window system: where the window list comes from,
how the application knows which workspace is visible, how it switches workspaces, how it
focuses and closes windows, how it registers global shortcuts, how it reserves space for the strip
and how it starts up. For each function, first the **contract** is given (what is to be achieved and what
it looks like to the user, with timings, retries and edge cases), then briefly
**how macOS does it**, so that a GNOME implementer can find the equivalent. The last subsection
collects the GNOME/Mutter equivalents.

Terminology: "workspace" = workspace / Space from Mission Control; "strip" = the WindowQueue strip;
"queue" = the ordered list of windows that the strip shows; "selection" = `selectedID`
in the model; "empty slot" = a marker in the queue shown when the user is on a workspace with no windows
(`emptySlot`, described in the part about the model).

### 0. General rules of the layer

- **Nothing may freeze the strip.** Queries to other applications (macOS Accessibility, "AX")
  can block until a timeout. Every AX query has a limit of **0.25 s**
  (`AXUIElementSetMessagingTimeout`), and full window enumeration runs on a separate
  background queue; the result reaches the model on the main thread. One refresh at a time (`isRefreshing`) —
  a further request while one is running is simply skipped (the next one will come from the timer).
- **Every asynchronous operation has a generation token.** Focus, workspace jump, verification
  of a workspace switch – each new request increments the counter, and old loops/retries, upon
  seeing a stale token, abort without side effects. Rule: *the user's newest request
  wins*, never a late retry of an old one.
- **Private APIs are optional.** All private macOS symbols are bound dynamically; a missing
  symbol disables the feature (or switches to a fallback variant), rather than crashing the application.
- **Window identifier** is the window server's window number (`CGWindowID`, a 32-bit number), stable for
  the window's entire life, unique within the session. The AX handle (`element`) is additional and may be absent.
- **WindowQueue's own windows** (strip, title bubble, highlight, panels) never enter
  the queue: they lie above the normal window level, and enumeration takes only layer 0. The
  WindowQueue Settings window *is* a regular window and enters the queue like any other.
- **Event log**: practically every decision described below writes a line to
  `events.log` (section 12); the spec gives these messages only where they help understand
  the behaviour.

### 1. Window discovery (`WindowEnumerator`)

#### 1.1 Which applications count

- Regular applications (with a Dock icon) **and** "accessory" ones (menu-bar, without a Dock icon) –
  the settings window of a menu-bar application is a real window the user wants to get to.
- Background processes/agents without UI do not count.
- The application name (`localizedName`, default "Unknown") and bundle identifier (`bundleID`)
  are remembered for each window.

#### 1.2 Which windows count (source: window server)

The window list is built in two steps, because macOS has two sources with different gaps: the window server
sees windows on **all** workspaces, but without titles (titles only with the Screen
Recording permission); AX has titles and allows acting on the window, but shows an application's windows **only from
the current workspace**.

Step 1 – the "seed" from the window server. A window is a candidate when **all** conditions hold:
1. layer = 0 (regular windows; menus, the Dock, the strip, system panels drop out);
2. size at least **120 × 80** px (rejects toolbars, shadows, helper windows);
3. the owner is an application from 1.1;
4. the window is assigned to some workspace (the server knows its space);
5. the window is "ordered-in", i.e. actually on the server's display list (not a closed
   but not yet released window, nor an off-screen working window). If this cannot be
   checked, the condition is skipped.
Desktop elements are skipped (`excludeDesktopElements`).

Step 2 – enrichment via AX, for each application:
- On first seeing an application, WindowQueue enables its accessibility tree
  (`AXManualAccessibility = true` – Chromium/Electron do not build it by default). Repeated after every
  activation of the application (some accept it only when they are in front).
- If the application returns an **empty** AX window list, once per its lifetime WindowQueue sets
  `AXEnhancedUserInterface = true` (what VoiceOver does; only then does Chrome expose its windows) and
  reads the list again. Only for applications with this symptom, because this mode changes window animations.
- The application's focused window (`AXFocusedWindow`) is always read – for applications that
  do not fill in the window list, it is the only handle. Its element and title (if non-empty) are
  added to the window from step 1.
- For each window from the AX list that is *standard* (subrole absent or `AXStandardWindow`,
  role absent or `AXWindow`): adds the element, title, minimized state. A
  **minimized** window is added even when the window server did not list it (minimized
  windows are not ordered-in) – this is how minimized windows enter the queue. A non-minimized window
  unknown to the server is skipped.

Step 3 – popup filter (only for applications that are "blind" in AX). The window server does not distinguish
tab tooltips, menus, download bubbles or hints from real windows. A window is a
**suspected popup** when: its application has ≥ 2 windows; the window has no title (without Screen Recording
none has one); there is another window of the same application on **the same workspace**, at least
twice as large in area, and their intersection covers ≥ **85%** of the suspect's area.
The suspect is removed only if AX has not "vouched" for it as a standard window **and** its
application has neither now nor ever before (`everListedPIDs`) listed any window via AX.
(An application that lists windows – e.g. a terminal – simply skips those from other workspaces; guessing
by geometry would throw out a small terminal lying on top of a large one.)

Step 4 – fallback "ghost" filter: only when the ordered-in check is unavailable. Then
on the current workspace AX is authoritative: a window without an AX element, on the current workspace, from
an application that responds to AX, is removed.

Order of the first fill: grouping by workspace identifier, then by window id
(≈ creation order); windows without a workspace at the end. For diagnostics, applications that
have a window on the current workspace that AX still does not see are logged ("AX blind on active space").

#### 1.3 Data of each window (`ManagedWindow`)

| Field | Meaning |
|---|---|
| `id` | window server number, key |
| `element` | AX handle or none (a window from an unvisited workspace has none until the workspace is visited) |
| `pid` | owner process |
| `appName`, `bundleID` | application name and identifier |
| `title` | title (may be empty; then the application name is displayed) |
| `isMinimized` | whether minimized |
| `spaceID` | the window's workspace (the first from the list of workspaces on which the server sees it) |

The queue persistence key between launches is `bundleID (or appName) + title` (the parts about the
model). Window equality for UI refresh purposes: id, title, minimized state, workspace.

#### 1.4 Merging with the queue (`reconcile`)

- The order of existing windows is preserved. Windows that no longer exist disappear.
- For a window that still exists: if the new reading has no workspace/element/title, the
  previous values stay (AX sees only the current workspace, so what we learned while the window
  was visible is kept).
- **New windows** are inserted right **after the selected** window (as in a tiling WM next to the
  focused client), and when nothing is selected – at the end.
- Exception: when an empty slot is shown, the first new window lying on the slot's workspace (or without a
  workspace – treated as the current one) takes the slot's place, becomes selected, the slot disappears, and
  for 0.8 s the window is marked as "just filled the slot" (for the strip animation).
- Further consequences (groups, tiles, maximization, auto-sorting, selection after a window disappears)
  are described in the part about the model.

#### 1.5 Refresh triggers

| Trigger | Response |
|---|---|
| Enumerator start | read workspace state + full refresh |
| Timer every **3.0 s** | full refresh (catches what notifications did not report) |
| Timer every **0.4 s** | read workspace state (1.8); when something changed → delayed refresh |
| Window AX notifications: creation, element destruction, window focus change, title change, minimize, deminimize | delayed refresh |
| Application launch | observer registration + delayed refresh; after **2 s** re-registration (a freshly launched application accepts the registration but delivers nothing until its AX is up) and reading of its focused window |
| Application termination | deregistration, forgetting AX flags, delayed refresh |
| Application activation | observer registration (if missing), re-enabling AX on the next refresh, adoption of its focused window (1.6), delayed refresh |
| Active workspace change (system notification) | immediate read of workspace state + delayed refresh |
| Opening Settings | refresh after 0.3 s (the own Settings window should appear quickly) |
| Closing the Settings window | switching back to accessory mode + immediate refresh |
| Closing a window by WindowQueue | refreshes after 0.4 s and 1.2 s |
| Moving windows to a workspace | refresh after 0.3 s |
| "Refresh windows" menu item, debug command `refresh` | immediate refresh |

"Delayed refresh" = **debounce 0.15 s**: each subsequent request cancels the previously
scheduled one. AX observers are registered for every application from 1.1 at startup (except
its own process).

Window **move** and **resize** notifications do not refresh the queue – they are
passed on as geometry events:
- resize → `onWindowResized` (edge guard, section 8) and `onWindowFrameChanged`
  (re-tiling, the part about tiles);
- move → `onWindowSettled` (the guard remembers the position) and `onWindowFrameChanged`;
- window focus change → also `onWindowSettled` (but *not* `onWindowFrameChanged` – focus is not
  movement).

#### 1.6 Adopting an external focus change into the selection

When the user changes focus themselves (click, Cmd-Tab, another program), the selection in the queue should follow
it, **without** showing the title bubble (`announce: false`). Rules:
1. If WindowQueue is currently bringing a window into focus (`WindowFocuser.pendingTargetID` set)
   and the reported window is **different** – ignore (an application in transition briefly reports the old
   window and would pull the selection back).
2. If the window is not yet in the queue (a new window takes focus before enumeration sees it) –
   remember its id as pending; after the next merge, when the window is there, select it (unless
   focusing of another window has started in the meantime). Only the last one is remembered.
3. If an empty slot is shown and the reported window lies on a **different** workspace than the slot –
   ignore (a window just sent away from the empty workspace may still hold the application's focus; it must not
   take the selection away from the slot the user is looking at).
4. Otherwise – select.

#### 1.7 New windows – behaviour summary

A new window appears in the queue at most ~0.15 s after the AX notification (or up to 3 s if the
application does not notify), right after the selected window or in place of the empty slot; if it took
focus, it becomes selected. Windows of a just-launched application may arrive only at the
re-registration after 2 s or at the 3 s timer.

#### 1.8 Workspace state in the model (`refreshSpaceState`)

Read: the current workspace of the screen with the strip, its number, whether it is fullscreen, the order of
all workspaces. The model receives **only changed** values (every assignment redraws
the strip). First the order (the empty slot is computed from it), then the current workspace. When the
current workspace changed → callback `onActiveSpaceChanged` (used for "holding" a workspace, 2.8).

The 0.4 s poller additionally compares "what each screen shows" (workspace number / fullscreen per
display); if only that changed (e.g. a second monitor switched to another workspace), it forces
a redraw of the strips without a full refresh. Why the poller: switching workspace via the window server
alone and adding/removing/reordering workspaces in Mission Control generate no
notification at all.

Window workspace numbers are also updated separately (`updateSpaces`): only recognized workspaces
overwrite the remembered ones; on a change – auto-sorting (if enabled) and recomputation of the slot.

### 2. Workspaces

#### 2.1 Topology and numbering

- Only **user workspaces** (type "desktop") are taken into account; fullscreen workspaces (a window
  in macOS fullscreen mode gets its own workspace) have no number.
- Numbering is 1-based, **in Mission Control order, counted across all displays**:
  first the workspaces of display 1 in order, then those of display 2, and so on (the way Mission
  Control counts). Thanks to this a window on the second monitor also has a number. The same
  numbering is used by the "switch to workspace N" and "move to workspace N" shortcuts, by the labels
  on the strip and by sorting.
- Each display has its own set of workspaces and its own current workspace. The model's "current
  workspace" is the workspace of the display with the bar = the main screen (with the menu bar), and
  when it cannot be matched – the first one.
- "The workspace is showing" (`isShowing`) = it is current on **any** display (a window on the
  visible workspace of the second monitor does not require travel).
- The current workspace is **fullscreen** when it does not belong to the list of user workspaces.
  When the topology cannot be read, "not fullscreen" is assumed (an unknown state never hides the
  strip). Current number = none when fullscreen.
- For each screen a pair (workspace number | none, whether fullscreen) is available; when monitors
  do not have separate workspaces, there is a single entry for all of them.
- Workspaces of the same display (`spacesSharingDisplay`) – used when choosing a workspace for a
  tile layout (windows can only go to a workspace on the same monitor).
- WindowQueue **never creates or deletes workspaces** (a workspace created on the side would not be
  visible in Mission Control and would throw the numbering off).

*macOS:* private SkyLight/CGS: `CGSCopyManagedDisplaySpaces` (displays → workspaces with type,
`id64`, `uuid`, "Current Space"), `CGSCopySpacesForWindows` (a window's workspaces, mask 7 = current +
others + user), `SLSWindowIsOrderedIn`. Missing symbols → `isAvailable = false`, workspace features
disabled (shown as unavailable in Settings).

#### 2.2 Workspace switching methods

Setting `spaceSwitchMethod` (default `privateAPI`):

| Method | Description for the user | Behaviour |
|---|---|---|
| `focusWindow` | "Focus a window on that workspace (recommended)" | focus a window from the target workspace; if there is none – carrier jump; if unavailable – system shortcut |
| `systemShortcut` | "Send macOS ⌃1…⌃9 shortcut" (requires enabling the "Switch to Desktop N" shortcuts) | only the ⌃N shortcut (N ≤ 9) |
| `privateAPI` | "Carry an invisible window there" (works for empty workspaces and above 9) | carrier jump; if unavailable – the ⌃N shortcut |

"Window to focus" for `focusWindow`: among the non-minimized queue windows on the target workspace
– the selected one, if it lies there, otherwise the first in queue order. It becomes selected and
is focused via the full focus path (3.1, with the cursor warp according to the preference).

A number out of range (greater than the number of workspaces): there is no target identifier, so
there is no verification; only sending the ⌃N shortcut remains (when N ≤ 9).

#### 2.3 Verification and retry chain (`ensureArrived`)

Each method can "silently do nothing", so after a request:
1. Remember the starting workspace, the request time (`lastSpaceRequest`) and increment the request
   counter (a new request – even to an already visible workspace – invalidates the old one's retries).
2. After **0.8 s** (the animated transition takes about 0.5 s; an earlier check would mistake "in
   progress" for "refusal"): if the counter has changed – stop. Read the workspace state. If the
   target is showing – success.
3. If the current workspace ≠ the starting one (the user or the system went somewhere else) – leave
   it, do not drag them back.
4. Retry no. 1: carrier jump (and when unavailable – ⌃N). Retry no. 2: ⌃N. After two
   retries – log "could not switch" and stop. Each retry again waits 0.8 s.
In total at most ~2.4 s of attempts.

#### 2.4 "Carrier window" jump (`SpaceSwitcher.jump`)

Goal: go to **any** workspace (also an empty one and one numbered > 9) with the system animation,
without keyboard shortcuts. Idea: a process can place *its own* window on any workspace, and
activating the application makes macOS animate the transition to the workspace with its window.

- The carrier is a single, permanently existing 1×1 px window, transparent (alpha 0.01), without a
  shadow, without animation, normal level, without any "collection behaviour" (e.g. `stationary` would
  make the system not treat it as a reason to change workspace).
- Sequence:
  1. Show the carrier (it must have a window number; if not – the jump is impossible, return false).
  2. Increment the jump generation; set the "heading" = (target workspace, valid for **1.2 s**).
  3. Add the carrier to the target workspace; remove it from **all** other workspaces it is on (the
     carrier stays on every workspace it was ever inserted into), as well as from the currently
     showing workspaces (a fresh one may not be listed on them yet). If it stayed on the current
     one, the system would have no reason to go anywhere.
  4. After **0.1 s** (the server must have the window on the workspace before activation), if the
     generation is current: activate WindowQueue, make the carrier key and additionally "push to the
     front" its process with a private call (the activation request alone does nothing when
     WindowQueue is already in front – e.g. when the jump took over from a previous one).
  5a. When the jump has a continuation (focusing a window on that workspace): after another
     **0.15 s** call the continuation and hide the carrier (the focused window takes over from there).
  5b. Without a continuation: after **0.45 s** hide the carrier and deactivate WindowQueue – the
     workspace is left in the same state as after a manual transition (no active application in front).
- Only the newest jump counts: an older one does not activate and does not call the continuation
  (one carrier on two workspaces would give the system a choice).
- `SpaceSwitcher.destination` – the workspace the jump *may still be heading to*: returns the target
  when the heading has not expired (1.2 s) and the target is not yet showing; when the target is
  already visible – clears the heading. Used for: (a) focusing a window on a showing workspace also
  goes through a jump if another jump is on its way (so as not to land somewhere else later);
  (b) pausing focus-follows-mouse; (c) disabling the workspace "hold".

*macOS:* `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces`, `NSApp.activate`,
`_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo`. A direct workspace switch in the
window server exists, but **is deliberately not used**: the Dock does not learn about it (the server
reports the new workspace, the screen stays on the old one).

#### 2.5 System shortcut ⌃N

Synthetic press and release of Control + digit N (1–9) at the HID level. Works only when the user
has enabled "Switch to Desktop N" in the system. For N > 9 – nothing.

#### 2.6 Focusing a window lying on another workspace ("travel first, then raise")

Activating an application moves to its workspace only when the system option "switch to a workspace
with the application's windows" is enabled, and many people disable it (and WindowQueue needs it
disabled for the trick in 2.10). Therefore `WindowFocuser.focus`:
- if the window has a known workspace that is a user workspace (not fullscreen), **and**
  (the workspace is not showing **or** another jump is on its way), performs a carrier jump with
  the continuation "raise the window" (the continuation checks the focus token – a newer focus
  invalidates it);
- otherwise raises the window right away (3.3).
Additionally the verification loop (3.4) sends ⌃N in attempt no. 3 if the window is still on a
non-showing workspace. A window in a fullscreen workspace is focused without travel (activating the
application by itself moves to its fullscreen).

#### 2.7 Holding the emptied workspace after closing the last window

Contract: the user closed a window – they did not ask to travel. When the closed window was the
**last** one on the current workspace (there was no successor on that workspace), macOS likes to
activate another application and – with switching on activation disabled – can move the user
somewhere else.
- After such a close set the "hold" = (current workspace, valid for **2 s**).
- On every change of the current workspace (`onActiveSpaceChanged`):
  - the hold has expired → clear it;
  - the user asked for a workspace change within the last **0.5 s** or a WindowQueue jump is on its
    way → clear it (the user's request wins);
  - current ≠ held and the held one is not showing → clear the hold and go back: a carrier jump to
    the held workspace, and when impossible – ⌃N.
After returning, the strip shows the empty slot of that workspace.

#### 2.8 Moving windows between workspaces (`moveWindows(toWorkspace:)`)

Contract: the "move to workspace N" shortcut sends the selected window – or all aimed windows in
aiming mode (aiming; the mode ends) – to workspace N; **the user goes there together with the
windows**.
1. No windows, number out of range, no mechanism, or a previous drag move is in progress
   → nothing.
2. **Per-window** attempt: a request to the window server to move the list of windows (several
   equivalent calls, because it is not known which one an ordinary application is allowed to use).
   The server moves asynchronously, so up to **6 reads every 40 ms**; windows still not in place move
   on. On macOS 26 none of these calls work for other apps' windows (including `SLSSpaceSetCompatID` +
   `SLSSetWindowListWorkspace` — error 1006).
3. **Per-application** fallback: assigning the whole application to a workspace ("Assign To" from the
   Dock) moves *all* its windows, after which the assignment is immediately cleared (the windows stay,
   new ones open wherever the user is). Used **only** when the application has no other
   unselected, non-minimized windows in the queue outside the target workspace ("bystanders") –
   otherwise it would drag along unrelated windows. Such windows move on to step 5.
4. Read the workspaces of all moved windows: on the target → "arrived", the rest →
   "left behind". Model: the arrived ones are moved in the queue to the end of the target workspace's
   windows (or before the first window of a later workspace), preserving their relative order.
5. **Drag** fallback for the ones left behind (`WindowDragMover`): a window held by a simulated mouse
   by its title bar during a workspace switch travels along with it — this is how macOS natively
   moves a single window. Details of the steps and timings: chapter "Actions", §8.1. Not working on
   macOS 26: `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` (error 1006), nor minimization (the
   window returns to its former workspace).
6. The first window that arrived becomes selected and focused, which takes the user to the target
   workspace (if step 5 has not taken them there yet).
7. Bubble: with windows left behind "<Application> stayed where it was[ and K more]" / "It could not be
   moved to workspace N"; otherwise the window title (or "N windows") + "Moved to workspace N".
8. Refresh after 0.3 s.

#### 2.9 Pulling a single window to the current workspace (`pullToCurrentSpace`)

Used when gathering windows for a tile layout (0.9 s after going to the target workspace, for
windows that did not arrive). Works only when the system option "when switching to an application,
switch to a workspace with open windows for the application" (`com.apple.dock workspaces-auto-swoosh`,
enabled by default) is **disabled**: then activating the application pulls its *focused* window to
the user. Sequence: window already here → success; set the window as main/focused in the application
via AX, activate the application, then up to **10 reads every 60 ms** whether the window is on the
current workspace. The result is returned (the application's other windows stay in place).

#### 2.10 Overlay workspace (`OverlaySpace`)

Contract: the strip and all WindowQueue panels (bubble, aiming highlight, action panel,
group panel, tile menu, tile preview) **do not take part in the transition animation between
workspaces** – the workspaces slide underneath them while they stay in place, also over fullscreen
workspaces. *macOS:* a private workspace created by the window server (`CGSSpaceCreate` with flag 1,
absolute level 100, `CGSShowSpaces`), to which each panel is added after it is first
shown. Missing symbols → panels stay with the ordinary "on all workspaces" (flicker during the
transition).

### 3. Focusing a window

#### 3.1 Entry point: focus from WindowQueue (`AppDelegate.focus`)

Called when a window is chosen from the strip, on cycling with shortcuts, from the window finder, on
workspace switching with the `focusWindow` method, and by the `focus` debug command. Steps:
1. `WindowFocuser.focus(window, window's workspace number, number of this application's windows in the
   queue, warpCursor)` – `warpCursor` = parameter (default yes; **not** for a click on the strip, the
   group panel or wheel scrolling) **and** the `warpCursorToWindow` preference (enabled by default).
2. **Raising the layout**: if the window belongs to a tiled group, raise the other windows of that
   group lying on the **same** workspace, and at the end the window itself once more (it is meant to
   stay on top). Windows on other workspaces are not touched.
3. **Focus flash** (preference `flashFocusedWindow`, default yes, duration default **0.15 s**):
   an outline of the window in the selection colour. Drawn only once the window is on the current
   workspace and has a readable frame; checked every 0.1 s, at most 20 times (2 s), aborted when
   aiming turns on or the window disappears.

Scrolling the wheel over the strip moves the selection immediately, but defers the focus by
`scrollFocusDelay` (default **0.5 s**; each further scroll pushes the deadline back) – so that
spinning does not fire a series of activations and workspace transitions.

#### 3.2 `WindowFocuser.focus` – contract

- A new request invalidates the previous one (token). `pendingTargetID` = target window is set
  (see 1.6), as well as the press budget for the "application window cycle" = **2 × (number of the
  application's windows − 1)**.
- If `warpCursor`: the cursor goes immediately to the window centre (the frame is known from the window
  server also for windows on other workspaces), together with the press, not after confirmation.
- Then travel (2.6) or `bringForward` right away: if there is an AX element and it accepted the raise
  (3.3) – this step ends; otherwise activate the application. Then the verification loop.

#### 3.3 Raising via the element

In order: if it was minimized → unminimize; set as main (`AXMain`); set as
focused (`AXFocused`); the `AXRaise` action; set as the application's focused window; set the
application frontmost (`AXFrontmost`). Result = whether the raise action succeeded (a remembered
element can "go stale" when the application recreates the window – then all calls fail silently).
Fallback activation: `NSRunningApplication.activate()` + `AXFrontmost = true` (public activation
alone is sometimes ignored for an accessory process).

#### 3.4 Verification loop

At most **20 attempts every 0.1 s** (~2 s). In each attempt (if the token is current):
1. Preliminary success when **the window's application is frontmost** and its focused window == the
   target (the "application's focused window" alone is not enough: a late activation from an earlier
   press can bring another application forward). → confirmation (3.5).
2. An application without a window list **and** without a focused window (Spotify, some Chromium),
   that is frontmost, from attempt no. **3** → consider it done (there is no way to confirm; further
   attempts would only fight the user).
3. In attempt no. **3**: if the window is on a user workspace that is still not showing, and the
   workspace number is known → send ⌃N.
4. If the window is in the application's AX window list → raise it (3.3), and if it refuses – activate
   the application. If it is not there and attempt ≥ 3 → activate the application and perform a single
   window-cycle press (3.6).
5. Next attempt.
After 20 attempts – `finish` without the cursor warp.

#### 3.5 Confirmation

**0.25 s** after the preliminary success check again (a late activation from the previous request
can take the focus away). Still OK → `finish`. Otherwise: log "focus of X was taken back; retrying",
raise again (or activate) and resume the loop from attempt no. 4.

`finish`: clears `pendingTargetID` and the cycle budget. If the focus was meant to warp the cursor:
after **0.15 s**, if the cursor is not inside the window's current frame (the window may have moved,
e.g. when unminimized), warp it again to the centre; a cursor already over the window stays.

#### 3.6 Application window cycle as a fallback

For applications that do not expose an AX window list (Chrome without enhanced mode), the only way
to a specific window is their own "next application window" shortcut (**Cmd + `**). Sent
only when the application is frontmost and the budget > 0; each press decrements the budget.
Verification ends the moment the focused window is the target.

#### 3.7 Cursor warp

The cursor to the centre of the window frame in global screen coordinates; after the warp,
re-associate mouse movement with the cursor (after a warp macOS temporarily "disassociates" it).

#### 3.8 Focus without raising (`focusWithoutRaising`)

Contract: the window gets the keyboard where it lies, **without changing the stacking order** (for
focus-follows-mouse). *macOS:* no public API; a sequence as in yabai/AutoRaise:
1. If the window's application is already frontmost and has *another* of its windows focused: send that
   window a "resign key" record, and the target one a "become key" record.
2. Push the process to the front in "user generated" mode (`kCPSUserGenerated`, without requesting
   windows to be brought forward; the "no windows" mode leaves the application half-active).
3. Send a pair of "make key window" records for the window.
4. Additionally via AX: `AXFocused = true` on the window and set it as the application's focused window
   (some applications, e.g. Ghostty, ignore synthetic records). No `AXRaise`.
Returns false when private symbols are missing → the caller does an ordinary focus. For diagnostics,
after 0.3 s the result is logged ("hover result: ok/MISSED").

Related: `bringToFront(pid, windowID)` – steps 2+3 (used for the carrier jump);
`isFocused(window)` – the application is frontmost and its focused window == this window.

### 4. Focus follows mouse (`FocusFollowsMouse`)

Preferences: `focusFollowsMouse` (**enabled** by default), `focusFollowsMouseDelay` (default
**0.05 s**), `focusFollowsMouseRaises` (**disabled** by default – focus without raising).

Contract:
1. Every mouse movement (global motion monitor) cancels the pending check and schedules a new one after
   `focusFollowsMouseDelay` – i.e. focus happens only once the cursor **stops**
   (passing over a stack of windows does not focus each one along the way).
2. At check time do nothing if: the feature is disabled; "suspended" mode – aiming is in progress,
   the window finder is open, or a workspace jump is on its way (whatever slides under the cursor
   during the animation is not the user's target); any mouse button is pressed; any modifier is pressed.
3. Window under the cursor: go through the on-screen windows from front to back, skipping desktop
   elements and windows with alpha 0; the first one containing the point must have layer 0 – if it is
   anything else (WindowQueue strip, menu bar, Dock, popup) → no window. If a menu is open
   **anywhere** on screen (a window at the level of context/drop-down menus) → no window.
4. The window must be in the queue, must not belong to WindowQueue and must not be minimized. If it is
   already the selected window and its application is frontmost → nothing.
5. Select the window (without the bubble) and focus it **without warping the cursor**:
   - if `focusFollowsMouseRaises` is disabled and the focus without raising succeeded: after **0.3 s**,
     if the feature is still enabled, the window does *not* have the keyboard, and the cursor is still
     over that window → log "hover focus did not land…; raising it" and a full focus with raising
     (typing where the cursor is matters more than an untouched stack);
   - otherwise – the full `WindowFocuser.focus` (without the workspace number, with the number of the
     application's windows).

### 5. Closing a window (`WindowCloser` + `AppDelegate.close`)

Invoked by the "close selected window" shortcut, by the close button on the strip/group panel, and for
aimed windows in aiming mode.

Before closing (AppDelegate):
- Determine the successor: if the window is on the current workspace – the nearest window in the
  queue **on the same workspace**; otherwise – the neighbour in the queue. After requesting the close,
  select the successor (without focusing it; the selection must not jump back to the start of the queue).
- No successor on the current workspace → workspace hold (2.7).
- Refreshes after 0.4 s and 1.2 s (the system may move another window onto the emptied workspace).

`WindowCloser.close`:
1. If the window has an AX element with a close button and its "press" succeeded → done (the window
   does not need to be focused or visible).
2. Otherwise: focus the window (full path 3.2, with the workspace number and the number of the
   application's windows) and retry every **0.12 s**, max. **12 attempts** (~1.4 s): find the window in
   the application's AX list and press its close button.
3. In the last attempt, if the window's application is frontmost: send **Cmd+W** only when its
   focused window is the target **or** (the focused window cannot be determined **and** the application
   has ≤ 1 window in the queue). Otherwise do not send it (log "has another window focused; not sending ⌘W") –
   Cmd+W would close the wrong window.

### 6. Global shortcuts (`HotkeyManager`)

Contract:
- Each action (`HotkeyAction`) has one combination (key + modifiers), configurable.
  The default combinations use the "super" modifier (default **Option/Alt**) – the table of actions and
  default combinations is in the Settings part; here only the rules: switch to workspace N =
  super+N (1–9), move to workspace N = super+Shift+N.
- The shortcut is **intercepted** (it does not reach the frontmost application) and works globally,
  regardless of which application has focus.
- The action is executed on the main thread, asynchronously. Every action invocation first
  cancels the detection of a "tap" of the super modifier alone (intercepting the key means the
  detector does not see what interrupted the tap).
- **Registration errors** (combination taken by another application/the system) are collected per action
  and shown in Settings in red: "Could not register: <action titles>. Another app probably
  owns those shortcuts."
- **Re-registration only when a combination changes.** Every preference change (including ones
  unrelated to shortcuts, e.g. a slider) goes through `apply`, and unregister+register
  leaves a moment without shortcuts – a key pressed at that moment would type a character in the
  frontmost application (e.g. "ś" for Option+S). Therefore the action→combination dictionary is compared
  with the last applied one; identical → touch nothing. On change: unregister everything, clear the
  errors, register all actions anew.
- In aiming mode (aiming) and in the window finder the keyboard is captured by a separate
  mechanism (the aiming part); the same combinations also work there without the modifier.

*macOS:* Carbon `RegisterEventHotKey` + a single `kEventHotKeyPressed` event handler (signature
`'WQKE'`, id per registration); requires no permissions beyond Accessibility.

### 7. Reserving space for the strip (`DockReservation`)

Contract: when `reserveScreenSpace` is enabled (default yes), windows maximized/"filled"/
tiled by the system should leave a free band along the strip's edge, as with the Dock.

Reservation width (`reservedWidth`) = strip thickness rounded up + 2 × strip margin
(`stripMargin`, default 4); **0** when the strip is in invisible mode (it appears only during
aiming).

Installation conditions (all): `reserveScreenSpace`; strip not hidden (`stripDisplay != hidden`);
not invisible mode; **the system Dock has auto-hide enabled** (a visible Dock needs its own
reservation more). Applies only to the screen with the menu bar (one rectangle per system). For the
other screens and cases the edge guard works (section 8).

Rectangle geometry (coordinates with the origin at the top-left corner of the menu screen, menu bar
height = difference between the screen frame and the visible area at the top): left – (0, menu, width, height−menu);
right – (W−width, menu, width, height−menu); top – (0, menu, W, width); bottom – (0, H−width, W, width);
orientation matching the edge; "reason" = shown.

Lifecycle:
- **Start:** if there is an original saved on disk from the previous run (crash) and the current
  rectangle "looks like ours" → restore the original. Force WindowQueue to read the screen's visible
  area itself *before* installation (otherwise the strip would count its reserve twice). Then
  `update`, a timer every **2 s** and a reaction to changes of screen parameters.
- **`update`:** when a suspension is active – nothing. If the current rectangle ≠ our installed one, it
  is the Dock's latest word → save it as the original (unless it looks like ours and nothing was
  installed). When the reservation is not wanted → restore. When wanted and different from the current one →
  save the original (if missing), write our rectangle, remember it as installed. Also called
  after every preference change (on the next run-loop pass).
- **"Looks like ours":** reason = shown, and the Dock has auto-hide (a hidden Dock never
  reports "shown").
- **Restoration:** on normal termination, on the signals **SIGTERM, SIGINT, SIGHUP**
  (intercepted; after restoring `exit(0)`), and when the reservation stops being wanted. Restores
  only if the current one is ours. The original is persistently saved in the preferences
  (`dockReservation.originalRect.v1`) before ours is written.
- **Suspension (`suspend(d)`):** restores the Dock rectangle for d seconds (and +0.1 s later
  `update`), so that an application launched during that time reads the real screen (Rectangle).
- **Limitations:** applications read the value at startup and when the Dock announces a change;
  already running applications do not see it, and every change of the Dock geometry overwrites it (hence
  the 2 s timer).
- **`unreservedFrame(screen)`:** the screen's visible area with our reserve *given back* – for laying out
  the strip and computing space for tiles. Given back only on the menu screen, when the reservation is
  installed **and** the visible area actually contains it (distance from the edge ≥ width −
  0.5 px; for the top: ≥ menu bar + width). Without this check the strip would jump when
  connecting/disconnecting monitors.

*macOS:* private `SLSGetDockRectWithOrientation` / `SLSSetDockRectWithOrientation`,
`CoreDockGetAutoHideEnabled`.

### 8. Edge guard (`ScreenEdgeGuard`)

Contract: when a window is **resized** by the system so that it abuts the strip's edge (zoom by
double-clicking the title, "Fill", built-in tiling), trim it so that it starts next to the strip –
the same effect as the reservation, one frame later. Enabled when
`reserveScreenSpace` **and** `trimWindowsOutsideReservation` (default yes) **and** the strip is not hidden.

1. Every window resize event (not while we are setting it – see 6.) schedules
   a correction after **0.3 s** (debounce per window; the zoom animation reports several sizes).
2. Correction: if a mouse button is pressed (the user is dragging an edge) → reschedule.
   Skip when the window is not standard, when its frame equals the frame of the whole screen (real
   fullscreen; zoom ends below the menu bar), when the window was set by WindowQueue itself (tiles,
   maximization – frame matching the remembered one ±2 px).
3. The window's screen = the one containing the window's centre, otherwise the one with the largest
   intersection. The strip edge is computed from `unreservedFrame` shifted by the reserve width. Trimming
   only when the window's border lies within ≤ **2 px** of the visible area's edge on the strip side **and**
   the window extends further than edge + width (it is big enough). Left/top: move the origin
   to the edge and shrink; right/bottom: shrink.
4. **Zoom reversal:** the application does not know its zoom was trimmed, so zooming again (to exit)
   zooms again. If the window was trimmed, its last known frame is the trimmed one, and
   another zoom arrived → restore the frame from before the first zoom.
5. **Setting the frame:** temporarily disable the application's enhanced AX mode (otherwise AppKit
   animates); set the position, then the size; if the result does not match – size, position, size
   (Rectangle's order, for applications that clamp the size to the old position). Then
   checks at **0.15 / 0.35 / 0.7 / 1.2 s** from the start: if the frame drifted (applications
   animating the zoom, terminals snapping to the character grid) – set it again; if the user
   holds a mouse button – give up. For 1.2 + 0.5 s the move/resize events of this window are
   ignored as ours.
6. **Remembering the frame** (`windowSettled`, after a move or a focus change): after **0.4 s**
   of stillness save the frame as "known" (for zoom reversal); intermediate animation frames do not
   count. A frame different from the trimmed one erases the trim record.
Ordinary moves are never corrected.

### 9. Rectangle integration (`RectangleIntegration`)

Contract: if the Rectangle window manager (`com.knollsoft.Rectangle`) is installed, its
tiling should leave room for the strip.
- Write to Rectangle's preferences: `screenEdgeGap<Side>` (Left/Right/Top/Bottom) = reserve
  width on the strip side (0 when the reservation is disabled), 0 on the other sides. Returns whether
  anything changed.
- Rectangle reads these values at startup, so a change while Rectangle is running = restart:
  quit it, suspend the Dock reservation for **6 s** (Rectangle will add its gap to the visible area;
  that area must no longer contain the strip), after **1 s** launch it again – hidden, without
  activation, without adding to "recents".
- Application: at startup and after preference changes with a **1 s debounce** (do not restart
  at every slider step); also when toggling the invisible strip mode; Settings has
  a button for manually applying and restarting, with a message about the result.
- When Rectangle starts on its own (e.g. at login), and the Dock reservation is installed and it is
  not WindowQueue restarting it → restart after 1 s (it read the screen with the strip already subtracted).
- `clear()` zeroes all four values.

### 10. Permissions and startup sequence

macOS permissions:
- **Accessibility (required)** – every AX call, synthetic keys (⌃N, Cmd+`, Cmd+W),
  global event monitors. At startup a one-time system prompt, then checking every
  **1 s** until granted; only after it is granted do enumeration and the strip start. A button in Settings
  opens the corresponding System Settings pane.
- **Screen Recording (optional)** – only to know the titles of windows from unvisited
  workspaces (and for the recording/screenshot features). Settings show the state and a button requesting
  access/opening the pane.

Startup sequence:
1. Dock reservation: start (including crash recovery), signal interception, observing
   application launches for Rectangle.
2. Log "launch: trusted=… windowIDs=… spaces=…".
3. Menu bar icon with a menu: "Settings…" (,), "Sort queue by workspace" (s), "Refresh windows"
   (r), separator, "Quit WindowQueue" (q). "Reopening" the application (Spotlight/Finder) opens
   Settings.
4. The model gets the scope and auto-sorting; preference subscription: on every change –
   scope, auto-sorting, super modifier, shortcuts (6), login item (11), Dock reservation
   (7); with a 1 s debounce – Rectangle (9).
5. Building the UI (window finder, bubbles, strip, panels), the super-modifier tap detector,
   focus-follows-mouse (starts right away), aiming key handling.
6. Shortcut handler, debug commands (if enabled), shortcut registration, applying
   Rectangle.
7. Waiting for Accessibility; once granted: restoring the saved order at the first
   non-empty queue state (and saving from then on), creating the edge guard and the
   enumerator, hooking up geometry events and `onActiveSpaceChanged`, starting the enumerator, starting the
   strip.
Termination: restoring the Dock rectangle.

### 11. Launch at login (`LoginItem`)

- Preference `launchAtLogin`, **enabled** by default, applied idempotently on every
  preference change and at startup.
- Only for the copy installed in `/Applications/`; the copy from the build directory has the state
  "notInstalled" (toggle disabled in Settings) – registering would launch a stale
  version.
- States: enabled, disabled, requires approval (Settings show an "Open Login
  Items" button), not installed. Registration errors are only logged.
*macOS:* `SMAppService.mainApp.register()/unregister()`.

### 12. Diagnostics and debug commands

Directory: `~/Library/Logs/WindowQueue/`.

| File | When | Contents |
|---|---|---|
| `events.log` | **always** (appended) | lines `[date] message`: startup, permission granted, selections, focuses, verifications, jumps, switches, workspace hold, closes, edge guard, Dock, Rectangle, mover, debug commands; some messages only with diagnostics enabled |
| `diagnostics.txt` | with diagnostics enabled, overwritten after every refresh | state: AX trust, availability of window numbers and of the workspace API, number of workspaces, current workspace and number, scope, number of windows in the queue/visible; queue list (no., id, workspace, pid, minimized, application — title); window server list (layer 0, ≥ 200×200: id, size, workspace, ordered-in, owner); per application: result/number of AX windows by several methods, number of windows in the server, hidden, focused window, and below it the AX windows (id, role, subrole, title) |
| `state.txt` | `dump` command | time; current workspace and number; workspace order; selection; aiming and anchor; empty slot; auto-sort; frontmost application and its focused window; cursor position; per window: id, workspace number, workspace in the model and in the server, minimized, whether it has an element, pid, application, title |

Enabling: `defaults write com.mpochec.windowqueue diagnostics -bool true`.

Debug commands (for scripted tests without synthetic keys): enabled with
`defaults write com.mpochec.windowqueue debugCommands -bool true`; they arrive as the distributed
notification `com.mpochec.windowqueue.command`, whose object is a line of text split on spaces:

| Command | Effect |
|---|---|
| `action <name>` | perform a shortcut action (raw `HotkeyAction` name, e.g. `cycleNext`, `space3`, `moveToSpace2`) |
| `aim` | like a tap of the super modifier (open/confirm aiming) |
| `aimkey <key> [shift] [move]` | a key in aiming mode: `up down left right back forward enter space cancel`; `shift` = extend, `move` = move; only while aiming is in progress |
| `focus <window id>` | select (with the bubble) and focus the window |
| `refresh` | full refresh |
| `dump` | write `state.txt` |

Every command is logged ("debug command: …").

### GNOME equivalents

**Architecture.** The implementation should be a **GNOME Shell extension (GJS)**. The extension
runs inside the compositor (Mutter), so it has full access to `Meta.Display`, `Meta.Window`,
`Meta.WorkspaceManager`, Clutter and St – also under Wayland. An external program under Wayland
could not enumerate other apps' windows, focus them, move them, register global shortcuts or
read the cursor position (under X11 partially via EWMH/libwnck/xdotool, but that is a dead end).
A possible separate process (e.g. a settings window in GTK/libadwaita as `prefs.js`) communicates
with the extension via GSettings (or D-Bus). Almost all of the "fight with the system" from macOS disappears: there is no
AX, there are no private APIs, there are no verification loops forced by the asynchrony of other
processes.

| Feature (macOS) | GNOME/Mutter |
|---|---|
| Window enumeration (1.2) | `global.display.list_all_windows()` or `global.get_window_actors().map(a => a.meta_window)`; filter: `window.get_window_type() === Meta.WindowType.NORMAL` (possibly also `DIALOG` without a parent), `!window.is_skip_taskbar()`, `!window.is_override_redirect()`, `window.get_transient_for() === null` for auxiliary windows. No filter for popups or "ghosts" is needed – menus, tooltips, bubbles have other types (`POPUP_MENU`, `TOOLTIP`, `DROPDOWN_MENU`…). The strip's own actors are not `Meta.Window`, so they drop out by themselves; the settings window (`prefs`) is an ordinary window and will end up in the queue as on macOS. |
| Window id | `window.get_id()` (stable within the session, `guint64`); application: `Shell.WindowTracker.get_default().get_window_app(window)` → `app.get_id()` (e.g. `org.gnome.Terminal.desktop`) instead of `bundleID`, `app.get_name()`, icon `app.create_icon_texture(size)`; `window.get_pid()`. |
| Title | `window.get_title()`, signal `notify::title` – always available, for all workspaces (Screen Recording has no equivalent and is not needed). |
| Minimization | `window.minimized`, signal `notify::minimized`; unminimizing `window.unminimize()` (or just `activate`). |
| Window's workspace | `window.get_workspace()` (null for windows "on all workspaces": `window.is_on_all_workspaces()` – treat as "no workspace"), signal `workspace-changed` on the window. |
| New/removed windows (1.5) | `global.display.connect('window-created', …)` (title/type is sometimes not yet settled – wait until the actor's `first-frame` or `GLib.idle_add`), `window.connect('unmanaged', …)`; additionally `workspace.connect('window-added'/'window-removed')`. The 3 s timer and re-registration after 2 s are not needed; a light debounce (e.g. 150 ms) can be kept for coalescing changes, and periodic reconciliation as cheap insurance. |
| External focus change (1.6) | `global.display.connect('notify::focus-window', …)` → `global.display.focus_window`. The ignore rules (target being focused, empty slot) remain, although "target being focused" usually lasts one frame. |
| Geometry events (1.5) | `window.connect('size-changed')`, `('position-changed')`; `window.get_frame_rect()`. Start and end of dragging: `global.display` `grab-op-begin`/`grab-op-end` (instead of checking the mouse button). |
| Workspace topology (2.1) | `global.workspace_manager`: `get_n_workspaces()`, `get_workspace_by_index(i)`, `get_active_workspace()`, `workspace.index()`. Number = `index()+1`. Mutter has **one** set of workspaces shared by the monitors (by default `workspaces-only-on-primary = true`: secondary monitors always show the same thing, windows on them are "on all workspaces"). One "current workspace" instead of one per display; `isShowing(ws)` = `ws === get_active_workspace()` (plus windows on non-primary monitors, when workspaces are on the primary only, are always visible). Numbering "across displays" simplifies to the index. Order: signals `workspace-added`, `workspace-removed`, `workspaces-reordered`, `notify::n-workspaces`; no need for the 0.4 s poller. GNOME dynamic workspaces (`org.gnome.mutter dynamic-workspaces`) – the last workspace is always empty; the empty slot and numbering must take this into account. |
| Fullscreen workspaces | There are no separate workspaces: a fullscreen window lies on an ordinary workspace (`window.is_fullscreen()`, signal `notify::fullscreen`; `global.display` `in-fullscreen-changed`, `Main.layoutManager.monitors[i].inFullscreen`). The state "the current workspace is fullscreen" has to be derived from "there is a fullscreen window on top on the current monitor". |
| Workspace switching (2.2–2.5) | `workspace.activate(global.get_current_time())` or `workspace.activate_with_focus(window, time)` (transition and focus in one step, with the Shell animation). Always works, also for empty workspaces and those > 9 – **no carrier window, ⌃N shortcut or verification chain is needed**. The method choice (`spaceSwitchMethod`) can be dropped or reduced to "focus a window on the workspace" vs "just go there". Optional verification: signal `active-workspace-changed`. "Heading in progress" (`destination`) = the workspace from `activate` until the end of the animation (`Main.wm` / `global.window_manager` signal `switch-workspace` and the end of the animation; a flag with a timeout of ~ the animation duration is enough). |
| Focusing a window on another workspace (2.6) | `window.activate(time)` – Mutter itself switches to the window's workspace (or `workspace.activate_with_focus(window, time)`), unminimizes and raises. One-shot, synchronous; the 20×0.1 s loop, the 0.25 s confirmation and Cmd+` go away. Time: `global.get_current_time()` (otherwise focus-stealing prevention may refuse). The "newest wins" queue is trivial. |
| Holding the workspace after closing (2.7) | Mutter does not switch workspace when the last window is closed (focus goes to another window on *the same* workspace or to the desktop), so the mechanism is probably unnecessary; with dynamic workspaces GNOME **removes the empty workspace** (if it is neither the last nor the active one – an active empty workspace is removed after leaving it). Keep only the protection: for 2 s after a close, if `active-workspace-changed` arrived not from our request – go back. |
| Moving windows (2.8, 2.9) | `window.change_workspace(ws)` or `window.change_workspace_by_index(i, false)` – **per window, without the "whole application" restriction**; synchronous result. The drag fallback and the "stayed where it was" message become unnecessary (keep a generic error message for windows that cannot be moved, e.g. `is_on_all_workspaces()` or modal windows tied to a parent). `pullToCurrentSpace` = `window.change_workspace(active)`. |
| Overlay workspace (2.10) | The strip and panels as St actors in `Main.layoutManager` (`addChrome`/`addTopChrome`) – they lie in the Shell layer above all workspaces and do not take part in the switch animation. Over fullscreen windows: `addTopChrome` or `Main.uiGroup` (the fullscreen state hides ordinary chrome if `trackFullscreen: true`). |
| Raise + focus (3.3) | `window.activate(time)` (= raise + focus + transition). Raise only: `window.raise()`; raising a tiled group: `raise()` the others in turn, finally `activate` the chosen one. |
| Focus without raising (3.8) | `window.focus(time)` – gives the keyboard without changing the stack (exactly what on macOS requires private event records). Check: `global.display.focus_window === window`. |
| Cursor warp (3.7) | Under Wayland only from inside the compositor: `Clutter.get_default_backend().get_default_seat().warp_pointer(x, y)` (centre of `get_frame_rect()`). Cursor position: `global.get_pointer()` → `[x, y, mods]`. |
| Focus flash | An St actor (outline) over `window.get_compositor_private()` / per `get_frame_rect()`, added to `global.window_group` or the chrome, removed after the duration. |
| Focus follows mouse (4) | Mutter has a built-in mode (`org.gnome.desktop.wm.preferences focus-mode = 'sloppy'/'mouse'`, `auto-raise`, `auto-raise-delay`), but it does not know WindowQueue's rules (skipping the strip, suspension during aiming/searching/transition, none with buttons/modifiers pressed, retry with raising) – a custom implementation is better: tracking motion via `global.stage` `captured-event` does not catch motion over client windows, so use a timer polling `global.get_pointer()` (e.g. every 16–50 ms, only when it changes) or the `Clutter` seat/`PointerWatcher` (`imports.ui.pointerWatcher.getPointerWatcher().addWatch(interval, cb)` – used by the magnifier). Window under the cursor: `global.get_window_actors()` from the top (reversed stacking order, e.g. `global.display.sort_windows_by_stacking`) – the first whose `get_frame_rect()` contains the point and which is visible on the active workspace; if the point is over a chrome actor (strip, top panel, dash) → `global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y)` and check that it is not our actor/the Shell. Open menu: `Main.panel.menuManager.activeMenu`, `global.display.get_grab_op?.()`/`Main.pushModal` (Shell modality), window types `POPUP_MENU`/`DROPDOWN_MENU` on top. Modifiers and buttons: the mask from `global.get_pointer()[2]` (`Clutter.ModifierType.*_MASK`, `BUTTON1_MASK`…). Focus: `window.focus(time)` or, with the raise option, `window.activate(time)`. |
| Closing (5) | `window.delete(global.get_current_time())` – closes the specific window without focus and without going to its workspace; no Cmd+W or safety condition is needed. The application may refuse/ask (unsaved document) – then the window stays, the queue does not change (the 0.4/1.2 s refreshes replaced by `unmanaged`). `window.kill()` only as a deliberately separate action. |
| Global shortcuts (6) | `Main.wm.addKeybinding(name, settings, Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW, handler)` with keys of type `as` in the extension's GSettings schema; removal `Main.wm.removeKeybinding(name)`. Conflict: `addKeybinding` returns `Meta.KeyBindingAction.NONE` (0) on failure → error list in Settings. Re-registering only the shortcut whose value changed (`settings.connect('changed::key')`) – immediately gives the "do not touch if unchanged" rule. Watch out for collisions with default GNOME shortcuts (Super+1…9 is app switching in the dock, Super+Shift+1…9, Alt+F…); the "super" modifier defaulting to Alt/Option may collide with menu mnemonics – choose the defaults accordingly. Tap of the modifier alone (opening aiming): Mutter supports "modifier only" shortcuts solely for `overlay-key` (Super); for other modifiers the modifier state has to be tracked manually – e.g. poll the mask from `global.get_pointer()[2]` with a short timer and treat a press+release without another key within a short time as a tap (invoking any shortcut cancels the tap). Capturing the keyboard in aiming/the window finder: `Main.pushModal(actor)` / `Main.popModal(grab)`. |
| Space reservation (7) | `Main.layoutManager.addChrome(stripActor, { affectsStruts: true, trackFullscreen: true, affectsInputRegion: true })` – struts are the official mechanism: the work area (`workspace.get_work_area_for_monitor(i)`) shrinks automatically, maximization, half tiling and other extensions respect it, **on every monitor** and immediately for already running applications. There is no Dock trick, no saving of the original, no 2 s timer, no restoring on signals/crash (the strut disappears together with the actor; the extension's `disable()` removes it). Invisible strip mode = `affectsStruts: false` (or removing the strut). `unreservedFrame` = work area + width of our own strut, or `Main.layoutManager.getWorkAreaForMonitor` before adding – simplest to compute from the monitor geometry (`global.display.get_monitor_geometry(i)`) minus the top panel. Note: struts must abut the screen edge (not "inside" between monitors). |
| Edge guard (8) | With struts unnecessary for Mutter's maximization and tiles (they use the work area). Can be useful for applications that size themselves to the whole monitor or with other tiling extensions: `size-changed` + 0.3 s debounce, `grab-op-end` instead of checking the mouse, `window.move_resize_frame(true, x, y, w, h)` (a single call, no size/position/size order), skipping `is_fullscreen()` and maximized windows (`get_maximized()`). The zoom reversal logic is unnecessary (Mutter remembers the frame from before maximization: `unmaximize`). |
| Rectangle (9) | No equivalent; GNOME tiling extensions (Tiling Assistant, Forge, Pop Shell, built-in edge tiling) respect the work area, so struts are enough. The section can be dropped or replaced by writing a "gap" to the GSettings of a specific extension, if the need arises. |
| Permissions (10) | None: an installed and enabled extension (`gnome-extensions enable`) has all capabilities. "Waiting for Accessibility" goes away; start = `enable()`, end = `disable()` (must clean up all signals, timers, shortcuts, actors – an extensions.gnome.org review requirement). Screenshots/recording: `Shell.Screenshot` inside the Shell, without prompts. |
| Status bar menu | `PanelMenu.Button` in `Main.panel` with `PopupMenu.PopupMenuItem` (Settings…, Sort queue by workspace, Refresh windows); "Quit" → disabling the extension is not typical – instead "Disable" or nothing. Settings: `extension.openPreferences()`. |
| Launch at login (11) | An enabled extension starts with the session automatically (`org.gnome.shell enabled-extensions`). The `launchAtLogin` preference becomes unnecessary (equivalent: enable/disable the extension). |
| Diagnostics (12) | Directory `GLib.get_user_state_dir()/window-queue/` (e.g. `~/.local/state/window-queue/`) or `~/.cache/window-queue/`; writing via `Gio.File.append_to`/`replace_contents`. Additionally `console.log`/`log()` → `journalctl --user -f /usr/bin/gnome-shell`. The `diagnostics` and `debugCommands` switches as GSettings keys. |
| Debug commands (12) | A D-Bus interface exported by the extension (`Gio.DBusExportedObject.wrapJSObject`) with a `Command(s line)` method at a path such as `/org/windowqueue/Debug`; call `gdbus call --session --dest org.gnome.Shell --object-path /org/windowqueue/Debug --method org.windowqueue.Debug.Command "action cycleNext"`. The same commands as on macOS. (Alternative in developer mode: `Looking Glass`/`org.gnome.Shell.Eval`, disabled by default.) |

**What gets simpler (summary):** no carrier window, ⌃N shortcuts or switching retry chain;
focus and the transition to a workspace are a single `activate`; moving windows per window;
closing a specific window without focus; focus without raising is the public `focus()`; space
reservation via struts on all monitors; no popup/ghost filters and no enhanced accessibility
modes; titles always available; no permissions and no login item.

**What to watch out for:** (1) everything must live in the `gnome-shell` process – a bug in the extension can
hang the session under Wayland, so split long operations with `GLib.idle_add`/`timeout_add` and
never block; (2) the Shell API changes between versions (ESM imports since GNOME 45,
`Meta.WindowType`, `get_maximized` vs `is_maximized` in newer ones) – declare the supported versions in
`metadata.json`; (3) focus-stealing prevention requires a correct timestamp
(`global.get_current_time()`); (4) dynamic workspaces and "workspaces only on the primary monitor" are
user settings – numbering, the empty slot and moving must work in both configurations;
(5) X11 windows via Xwayland and native Wayland ones are equally visible as `Meta.Window`, but
`get_pid()` may return 0 for some Wayland clients – group an application's windows via
`Shell.WindowTracker`, not via PID.

---

## Settings

All WindowQueue settings live in a single structure (`Preferences`) held by a single store
object (`PreferencesStore`). There are no "OK/Cancel/Apply" buttons: every control change
goes to the store immediately, is saved to disk immediately and takes effect immediately across the
whole application (the strip, shortcuts, space reservation etc. subscribe to store changes).

### Settings window

- Window title: "WindowQueue Settings". Fixed size 600 × 560 pt, centred on first
  opening, with close and minimize buttons (no resizing).
- The window is created once, on first opening, and afterwards only shown again (closing it
  does not destroy it).
- The application normally has no Dock icon ("accessory" mode). Opening Settings switches it to an
  ordinary application (Dock icon, can receive focus) and activates it; closing the window restores
  the icon-less mode and requests a re-enumeration of windows (so that the Settings window disappears
  from the queue). About 0.3 s after opening a refresh of the window list is also requested — the
  Settings window itself is an ordinary window and ends up in the queue like any other.
- Opened from the menu bar icon's menu ("Settings…") and when the already running application is
  launched again (e.g. from Spotlight/Finder) — in that case there is nothing to show other than Settings.
- Four tabs, in this order: **General** (gear icon), **Focus** (cursor with
  rays), **Shortcuts** (keyboard), **Strip** (sidebar).
- The General, Focus and Strip tabs are grouped forms (sections with a header). The Shortcuts tab
  is a custom layout with a scrollable list.

Common form elements:

- **Slider** (`sliderRow`): label on the left, on the right a slider with a fixed width of 200 pt and next
  to it the current value in a fixed 48 pt column (monospaced digits, right-aligned, secondary
  colour), so that the sliders on a page form an even column. Value formats:
  - points: `"<integer> pt"` (value truncated to an integer),
  - percentages: `"<value×100 rounded>%"`,
  - seconds: `"<value with at most 2 significant digits> s"`, e.g. `0.05 s`, `0.5 s`, `1 s`, `10 s`.
- **Caption**: small, secondary text below a control, wrapped; describes what it does.
- A "disabled" control = visible, but greyed out and inactive. "Hidden" = not present at all.

#### General tab

1. Section **"Queue"**
   - Picker **"Queue scope"** (`scope`): "All windows (global)" / "Current workspace only".
     Default global.
   - Toggle **"Keep the queue sorted by workspace"** (`autoSortByWorkspace`), default on.
     Caption: new windows join their workspace's group by themselves; manually reordering the queue
     turns this option off, and the sort shortcut turns it back on. (The toggle in the window reflects
     this live — it can flip by itself when the user moves a window in the queue.)
2. Section **"Workspaces"**
   - Picker **"Workspace switching"** (`spaceSwitchMethod`), three items:
     - "Focus a window on that workspace (recommended)" (`focusWindow`),
     - "Send macOS ⌃1…⌃9 shortcut" (`systemShortcut`),
     - "Carry an invisible window there" (`privateAPI`) — **the default**, even though the
       "recommended" label is next to the first one.
   - Below the picker a caption depending on the selected method:
     - focusWindow: activates the first queue window on the target workspace (the system scrolls
       there by itself); a workspace without windows is reached by moving an invisible window there;
     - systemShortcut: requires the "Switch to Desktop N" shortcuts to be enabled in System Settings;
     - privateAPI: moves an invisible WindowQueue window to that workspace and brings it to the front;
       works for empty workspaces and above 9.
   - If workspace support is unavailable (the private spaces API could not be loaded),
     an orange message below: "Workspace support is unavailable on this macOS
     version: … Workspace switching and per-workspace scope are disabled." Note: the controls are not
     actually disabled then — it is only information.
3. Section **"Tiling"**
   - Slider **"Screen gap"** (`tileOuterGap`): 0–40 pt, step 1, default 0.
   - Slider **"Gap between windows"** (`tileInnerGap`): 0–40 pt, step 1, default 4.
   - Caption: the spacing around windows that WindowQueue arranges — tiled from aiming mode,
     maximized or sent to fullscreen.
4. Section **"Fullscreen windows"**
   - Toggle **"Focus on the fullscreen window"** (`focusMaximizedWindow`), default on.
     Caption: sending a window to fullscreen moves it to the start of its workspace in the queue;
     cycling then stays on it until it is restored (which restores the queue);
     ordinary maximization does not touch the queue.
   - Toggle **"Collapse the windows it covers"** (`collapseCoveredWindows`), default on.
     **Hidden** when the previous one is off. Caption: covered windows collapse into a single tile next to
     the fullscreen window, showing the first few icons and their count; when off — each one stays
     in its own row, only dimmed/tinted.
5. Section **"Strip labels"**
   - Toggle **"Show window titles under the icons"** (`showWindowLabels`), default on.
     Caption: tells apart several windows of the same application; the icon gives up space, the strip does not grow.
6. Section **"Window titles"** (macOS-specific — the "Screen Recording" permission)
   - Caption only, depending on the permission state: when granted — "window titles are shown for
     every workspace"; when not — windows on other workspaces show only the application name,
     the system hides titles without this permission, everything else works without it.
   - Button **"Grant Screen Recording…"** only when the permission is not granted: asks the system for
     the permission and opens the corresponding System Settings page.
   - On GNOME an equivalent usually does not exist (titles are available) — the section can be omitted or
     always show the "granted" variant.
7. Section **"Startup"**
   - Toggle **"Launch at login"** (`launchAtLogin`), default on. **Disabled** when the
     application is not installed (does not reside in `/Applications/`).
   - Below it, depending on the login item state:
     - not installed: "Available once WindowQueue is in the Applications folder (make install)."
     - awaiting approval in the system: "Waiting for approval in the system's login item
       settings." + a small **"Open Login Items"** button that opens that System Settings page;
     - enabled/disabled: no caption.

#### Focus tab

1. Section **"Pointer"**
   - Toggle **"Move the pointer to windows focused from the keyboard"** (`warpCursorToWindow`),
     default on.
   - Toggle **"Focus the window under the pointer"** (`focusFollowsMouse`), default on.
   - Slider **"Hover delay"** (`focusFollowsMouseDelay`): 0–1.0 s, step 0.05, default 0.05 s.
     Disabled when focus-follows-mouse is off.
   - Toggle **"Bring the hovered window to the front"** (`focusFollowsMouseRaises`), default
     off. Disabled when focus-follows-mouse is off.
2. Section **"Aiming mode"**
   - Toggle **"Aiming mode"** (`aimingEnabled`), default on. Caption: tapping the super key alone
     lets you choose a window without focusing it; the strip grows, the screens dim, the aimed
     icon turns orange, `[` / `]` or the arrows move the aim; tapping super again
     focuses the window, as do Return and Space; Escape leaves everything as it was.
   - Picker **"Double tap of the super key"** (`superDoubleTapAction`). Items in order:
     "Confirm the aim" (no action, `nil`), then action titles: "Open the launcher", "Show Mission
     Control", "Search windows", "Hide or show the strip (invisible mode)", "Start or stop recording
     the screen", "Take a picture of the window", "Fullscreen window (again to restore)", "Maximize
     window", "Minimize window", "Group or ungroup windows", "Close selected window", "Sort queue by
     workspace", "Move window to start of queue", "Move window to end of queue". Default
     **"Search windows"**. Caption: two taps of super in quick succession; "Confirm" focuses the aimed
     window (what the second tap does anyway); any other choice exits aiming mode and
     runs that action. Disabled when aiming mode is off.
   - Slider **"Dim the screens"** (`aimingDimOpacity`): 0–0.85, step 0.05, percentage format, at 0
     shows "off". Default 0.45 (45%). Disabled when aiming mode is off.
3. Section **"Focus"**
   - Toggle **"Outline the window focus lands on"** (`flashFocusedWindow`), default on.
     Caption: a brief outline of the window that has just received focus, in the selection colour (the same mark
     that aiming mode draws); appears immediately, holds, then fades out over half a second.
   - Slider **"Outline holds for"** (`flashFocusedWindowDuration`): 0.05–1 s, step 0.05, default
     0.15 s. Disabled when the outline is off.
4. Section **"Launcher"**
   - Picker **"Open with"** (`launcher`): "Spotlight", "Raycast", "Alfred". An application that is
     not present on the system has the suffix " (not installed)" (Spotlight is always available). Default
     Spotlight. Caption: what the launcher shortcut opens, in aiming mode and outside it; Spotlight opens
     only via its own ⌘Space, sent as a key press; the others are opened
     like applications; a launcher that is not installed → Spotlight.
   - On GNOME: the natural equivalents are the GNOME Shell overview/search, possibly
     external launchers (Ulauncher, Albert etc.) — the same principle: a picker, falling back to
     the built-in one.
5. Section **"Name popup"**
   - Toggle **"Show the window name after a change"** (`toastEnabled`), default on.
   - Slider **"Popup duration"** (`toastDuration`): 0.5–10 s, step 0.5, default 1.0 s. Disabled
     when the popup is off.
   - Toggle **"Show a picture of the window"** (`showWindowPreview`), default on. Disabled
     when the popup is off. Caption: requires the Screen Recording permission and can only show windows
     from the workspace that is on screen.

#### Shortcuts tab

Layout from the top (with inner padding, no form):

1. Header row: picker **"Super key"** (width 300 pt) with the items "⌥ Option", "⌃ Control",
   "⌘ Command", "⌃⌥ Control+Option", "⌘⌥ Command+Option" (default Option); on the right a
   **"Reset all"** button.
2. Caption: "Changing the super key regenerates every shortcut from the defaults."
3. If some shortcuts could not be registered — small red text:
   "Could not register: <comma-separated action titles>. Another app probably owns those shortcuts."
   (Implementation note: in the original the error list is fetched once, when the Settings window is
   created, so it does not refresh on subsequent openings — this is a bug, not intended
   behaviour; a reimplementation should show the current state.)
4. A scrollable list with four groups, each with a bold header:
   - **"Queue"** — 18 queue actions,
   - **"Workspaces"** — "Switch to workspace 1" … "Switch to workspace 9",
   - **"Move to workspace"** — "Move window to workspace 1" … "Move window to workspace 9",
   - **"Aiming mode only"** — keys for aiming mode only (described below).
   Action row: title on the left, on the right a 130 × 24 pt shortcut recorder showing the current shortcut.

#### Strip tab

1. Section **"Visibility"**
   - Toggle **"Invisible mode"** (`invisibleStrip`), default off. Caption: the strip is
     drawn only when aiming mode is open; the queue works normally; outside aiming a change is
     announced only by the name popup; no screen space is reserved.
   - Picker **"Show strip"** (`stripDisplay`): "Selected monitor only", "All monitors,
     highlight selected" (default), "Hidden".
   - Slider **"Inactive monitors"** (`inactiveStripOpacity`): 10–100%, step 5%, default 55%.
     Disabled when "Show strip" ≠ "All monitors, highlight selected".
   - Toggle **"Hide over fullscreen windows"** (`hideInFullscreen`), default on.
2. Section **"Position"**
   - Segmented control **"Side"** (`stripSide`): Left / Right / Top / Bottom, default Left.
   - Segmented control **"Alignment"** (`stripAlignment`): Start / Center / End, default Center.
   - Slider **"Margin"** (`stripMargin`): 0–40 pt, step 1, default 4.
3. Section **"Appearance"**
   - Slider **"Icon size"** (`iconSize`): 16–48 pt, step 2, default 34.
   - Slider **"Opacity"** (`stripOpacity`): 20–100%, step 5%, default 100%.
   - Toggle **"Show workspace number"** (`showSpaceBadge`), default on.
4. Section **"Scrolling"**
   - Slider **"Focus after scrolling"** (`scrollFocusDelay`): 0.1–2.0 s, step 0.1, default 0.5 s.
5. Section **"Reserve screen space"**
   - Toggle **"Keep windows clear of the strip"** (`reserveScreenSpace`), default on.
   - Toggle **"Trim windows on other screens and in older apps"**
     (`trimWindowsOutsideReservation`), default on. Disabled when the previous one is off.
   - Dynamic caption: when the Dock auto-hides, WindowQueue "lends" the strip the Dock's
     reserved area on the screen with the menu bar, so zoom, "Fill" and tiling leave
     `<N>` pt free (in applications launched after WindowQueue); everywhere else windows resting against the
     strip's edge are trimmed after the fact. `<N>` = reservation width (see below). If
     Rectangle is installed, an addition: it also sets the `<side>` edge gap in Rectangle,
     which Rectangle reads at startup, so it has to be restarted.
   - Only with Rectangle installed: a **"Restart Rectangle to apply"** button and next to it status
     text: "Restarting…" → "Rectangle restarted." or "Could not restart Rectangle."
   - On GNOME the whole section corresponds to reserving a "strut" (work area) for the strip panel;
     the Dock and Rectangle integrations have no equivalent. The essential functional contract: with the
     option enabled, maximization/tiling do not overlap the strip; with it disabled — they may.

### Full table of stored preferences

The keys are the exact field names in the stored JSON. "UI" = whether there is a control in the Settings window.

| Key | Type | Default | Allowed values | UI | Effect and where it applies |
|---|---|---|---|---|---|
| `scope` | enum str | `global` | `global`, `currentSpace` | General › Queue | Queue scope: `currentSpace` limits the visible part of the queue (strip, cycling, window finder) to windows of the current workspace; when the current workspace is unknown, it behaves like `global`. The order of the full queue does not change. |
| `superModifier` | enum str | `option` | `option`, `control`, `command`, `controlOption`, `commandOption` | Shortcuts | The "super" modifier: the base of the default shortcuts and the key whose bare tap opens aiming mode (see the shortcut model). |
| `spaceSwitchMethod` | enum str | `privateAPI` | `focusWindow`, `systemShortcut`, `privateAPI` | General › Workspaces | Strategy for switching to workspace N. `focusWindow`: focus the first window from the queue on N; if there is none — move the app's own invisible window there; if that is not possible — the system shortcut ⌃N. `systemShortcut`: ⌃N only. `privateAPI`: invisible window, ⌃N as fallback. In all cases, after a moment it is checked whether the switch happened, and the remaining methods are tried. |
| `reserveScreenSpace` | bool | `true` | — | Strip › Reserve | Reserves the strip's space so that maximized/tiled windows do not cover it. Works only when `stripDisplay ≠ hidden` and `invisibleStrip = false`. Also affects the area in which WindowQueue itself tiles/maximizes (subtracts the reservation width from the strip's side). |
| `trimWindowsOutsideReservation` | bool | `true` | — | Strip › Reserve (dependent) | When a window is enlarged/placed under the strip in a place the reservation does not cover (other monitors, older applications), it is trimmed after the resizing stops so it does not go under the strip. Active only when `reserveScreenSpace` and `stripDisplay ≠ hidden`; does not touch windows in true fullscreen or ones being dragged with the mouse. |
| `bindings` | dictionary `{actionName: KeyCombo}` | full set of defaults for `option` (on a fresh install) | keys = raw action names | Shortcuts | Global action shortcuts. Missing entry → the default shortcut for the current super. |
| `toastEnabled` | bool | `true` | — | Focus › Name popup | Enables the window name popup (and all other popups, including central messages). Disabled: no popups are shown. |
| `toastDuration` | double (s) | `1.0` | 0.5–10 (UI) | Focus › Name popup | Display time of the popup next to the window. Central messages: `max(toastDuration, 1.2)`. After a "hold" ends (hover/aiming): `min(toastDuration, 0.6)`. |
| `showWindowPreview` | bool | `true` | — | Focus › Name popup | Window thumbnail in the popup — only in "held" popups (hovering over an icon, aiming mode), never during ordinary cycling. |
| `stripDisplay` | enum str | `highlightActiveScreen` | `activeScreenOnly`, `highlightActiveScreen`, `hidden` | Strip › Visibility | `activeScreenOnly`: strip only on the screen with the focused window. `highlightActiveScreen`: strip on every screen, dimmed to `inactiveStripOpacity` on inactive ones (in aiming mode all are drawn as active). `hidden`: no strip anywhere, no reservation and no trimming. |
| `inactiveStripOpacity` | double | `0.55` | 0.1–1.0 | Strip › Visibility | Opacity of strips on inactive monitors. |
| `hideInFullscreen` | bool | `true` | — | Strip › Visibility | Hides the strip on a screen whose current workspace is a system fullscreen. |
| `invisibleStrip` | bool | `false` | — | Strip › Visibility; shortcut `toggleInvisibleStrip` | Invisible mode: the strip (and the group panel) is visible only in aiming mode — it "unfolds" with an animation when aiming starts and "folds" when it ends. Reservation width = 0. Also toggled with a shortcut (with the central message "Strip hidden"/"Strip shown" and a recalculation of the layout of windows placed by WindowQueue). |
| `stripSide` | enum str | `left` | `left`, `right`, `top`, `bottom` | Strip › Position | The screen edge of the strip; left/right = vertical strip, top/bottom = horizontal. Affects the position of popups, group/action panels, the tiling menu, and the reservation side. |
| `stripAlignment` | enum str | `center` | `start`, `center`, `end` | Strip › Position | Position of the strip along the edge (like `justify-content`): 0 / 0.5 / 1 of the edge length. With `end` the group panel opens before the strip instead of after it. |
| `stripMargin` | double (pt) | `4` | 0–40 | Strip › Position | Gap between the strip and the screen edge (from the edge it adjoins, and from the ends — except the end it is aligned to). Included in the reservation width. |
| `stripWidth` | double | `36` | — | none | **Obsolete, unused.** The strip thickness follows from the icon size. Kept only for read compatibility. |
| `iconSize` | double (pt) | `34` | 16–48 | Strip › Appearance | Icon size. Row height = `iconSize + 8`; strip thickness = `iconSize + 20` (row + 2×6 pt padding); corner radii and badge sizes scale with it. |
| `stripOpacity` | double | `1.0` | 0.2–1.0 | Strip › Appearance | Opacity of the strip, the group panel and the aiming-mode action panel. |
| `showSpaceBadge` | bool | `true` | — | Strip › Appearance | Badge with the current workspace's number at the start of the strip (clicking it opens aiming mode). Disabled — there is no badge and no sampling of the background brightness under it. |
| `showWindowLabels` | bool | `true` | — | General › Strip labels | One line of the window title (10 pt, white on semi-transparent black) along the bottom edge of the icon; the row size does not change. |
| `autoSortByWorkspace` | bool | `true` | — | General › Queue | The queue is kept sorted by workspace on every change. The app **itself writes** `false` when the user manually reorders the queue (move by one position, drag, move to start/end), and `true` after the sort shortcut or the "Sort queue by workspace" menu item. |
| `aimingEnabled` | bool | `true` | — | Focus › Aiming | Whether a bare tap of super opens aiming mode. Does not block opening the mode by clicking the workspace badge. |
| `aimingScale` | double | `1.2` | ≥ 1 sensible | none | Magnification in aiming mode: strip thickness × `max(1, aimingScale)`, the aimed icon scaled by this factor. Stored only (no control). |
| `aimingDimOpacity` | double | `0.45` | 0–0.85 | Focus › Aiming | Opacity of the black veil on all screens behind the strip in aiming mode and in the window finder; 0 = no dimming. The veil appears/disappears in 0.18 s. |
| `superDoubleTapAction` | action name or none | `search` | `nil` or one of the "double tap" actions | Focus › Aiming | What a second tap of super within 0.4 s of opening aiming mode does (details below). |
| `scrollFocusDelay` | double (s) | `0.5` | 0.1–2.0 | Strip › Scrolling | The mouse wheel over the strip moves the selection immediately, but the window gets focus only after this many seconds without scrolling (each step resets the timer). The cursor is not moved in that case. |
| `warpCursorToWindow` | bool | `true` | — | Focus › Pointer | After a window is focused from the keyboard, the cursor jumps to the center of the window. Never on focus from the mouse (click, wheel, hover). |
| `focusFollowsMouse` | bool | `true` | — | Focus › Pointer | The window under the cursor gets focus after `focusFollowsMouseDelay` without movement. Does not work: in aiming mode, with the window finder open, during a workspace switch, with a mouse button or any modifier held, over WindowQueue's own windows, over minimized ones, when something else is above the window or a menu is open; does not repeat focusing a window that is already selected and on top. |
| `focusFollowsMouseDelay` | double (s) | `0.05` | 0–1.0 | Focus › Pointer | Time the cursor must rest before focus. |
| `focusFollowsMouseRaises` | bool | `false` | — | Focus › Pointer | On: focus from hover also brings the window to the front. Off: an attempt to give focus without raising; if that is not possible — normal focus with raising; if after 0.3 s the window still does not have focus and the cursor is still over it — raises it. |
| `flashFocusedWindow` | bool | `true` | — | Focus › Focus | A brief outline of the window after every focus given by WindowQueue (not in aiming mode). For a window on another workspace it waits until the workspace is shown (up to 20 attempts every 0.1 s). |
| `flashFocusedWindowDuration` | double (s) | `0.15` | 0.05–1 | Focus › Focus | How long the outline is held before fading (fading takes about 0.5 s more). 0 disables the outline. |
| `launcher` | enum str | `spotlight` | `spotlight`, `raycast`, `alfred` | Focus › Launcher | What the `openLauncher` action opens; also the title of the launcher tile in the aiming-mode action panel. |
| `tileOuterGap` | double (pt) | `0` | 0–40 | General › Tiling | Gap from the edge of the work area for tiling, maximizing and WindowQueue's "fullscreen" (and in the placement preview while dragging). |
| `tileInnerGap` | double (pt) | `4` | 0–40 | General › Tiling | Gap between adjacent tiles (each cell gives up half on each side). |
| `focusMaximizedWindow` | bool | `true` | — | General › Fullscreen | Whether the "fullscreen" action (`toggleMaximize`) turns on the queue's focus mode on that window. Disabled: the window only fills the screen, the queue is unchanged, nothing is covered/collapsed. |
| `collapseCoveredWindows` | bool | `true` | — | General › Fullscreen (hidden when the previous one is off) | With focus mode active: windows covered by the fullscreen one collapse into a single cascade tile with a count; disabled — they stay in their rows, tinted. Works only together with `focusMaximizedWindow`. |
| `includeMinimized` | bool | `true` | — | none | **Stored, but never read anywhere.** Minimized windows are always members of the queue (drawn dimmed). |
| `launchAtLogin` | bool | `true` | — | General › Startup | Registration in the system login items (see below). |
| `aimBindings` | dictionary `{"<key code>": actionName}` | `{}` | actions from the Queue group | Shortcuts › Aiming mode only | Bare keys that work only in aiming mode. |
| (legacy) `stripEnabled` | bool | — | — | none | Read only from very old saves: `false` → `stripDisplay = hidden` (when `stripDisplay` is not stored). Never written. |

### Shortcut model

#### Actions

List of actions (raw name → title in the UI). The order in the table = the order in the "Queue" group of the
Shortcuts tab; the order in the internal list of all actions (which breaks ties) is given in the
"#" column.

| # | Action | Title in UI | Default shortcut |
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

With the default super = Option this gives, e.g., `⌥[`, `⌥⇧]`, `⌥R`, `⌥W`, `⌥⇧W`, `⌥V`, `⌥P`, `⌥1`, `⌥⇧1`.

Rule for choosing the defaults: **no default shortcut uses the letters A, C, E, L, N, O, S, X, Z**, because
Option + these letters in the Polish "Polish – Pro" layout gives ą ć ę ł ń ó ś ź ż — with Option as
super, Polish characters can still be typed. (That is why the launcher is R, Mission Control is W, sorting is
⇧W, recording is V, window picture is P.) On GNOME Polish characters are under AltGr (right Alt); this rule
applies to a reimplementation only when super can land on AltGr/Alt — it is worth keeping as a
test invariant ("no default combination takes away a Polish letter").

Keys are identified by **physical position** (the virtual key code in the ANSI layout), not by
character: `[` is the key to the right of P regardless of layout. The name shown in the UI is translated
through the current keyboard layout (e.g. on the German layout the same key will appear as `Ü`).
On GNOME the equivalent is binding by hardware code (keycode), with the label from the keysym of the current
layout.

#### Shortcut representation (`KeyCombo`)

- `keyCode` (integer) + `modifiers` (bit mask): Command = 256, Shift = 512,
  Option = 2048, Control = 4096 (Carbon masks). Caps Lock and Fn are not taken into account.
- Matching: the key code is equal and the set of pressed modifiers (out of these four) is **exactly**
  equal to the mask.
- Display text: modifier symbols in the fixed order ⌃ ⌥ ⇧ ⌘, then the key name.
  Special names: Return "↩", Tab "⇥", Space "Space", Backspace "⌫", Delete "⌦", Escape "⎋",
  Home "↖", End "↘", PageUp "⇞", PageDown "⇟", arrows "← → ↑ ↓", F1–F12 "F1"…"F12". Others:
  the character from the current layout in uppercase; when it cannot be translated — `#<code>`.

#### Super key

Five variants: Option, Control, Command, Control+Option, Command+Option (on GNOME the natural
equivalents: Alt, Ctrl, Super/Meta and their pairs). The super key has two roles:

1. It is the base modifier of all default shortcuts (super or super + ⇧).
2. **A tap of super alone** (without other keys) opens/closes aiming mode. A tap counts
   when: the modifier state went from "nothing" to exactly the super set (for pairs — both at once),
   then everything was released within 0.4 s, and in the meantime there was no key press,
   click or scroll, and no global shortcut fired. Returning to "super
   alone" after releasing e.g. Shift in the middle of a combination does not arm the tap.

Changing super in Settings **immediately regenerates all global shortcuts** from the defaults for the
new super — the user's own assignments are lost (without asking; only a fixed caption
warns). It does not touch `aimBindings` or `superDoubleTapAction`. The tap detector switches to the new
modifier immediately.

#### Registering global shortcuts

- All 36 actions are always registered as global shortcuts (including workspaces 1–9), each
  shortcut separately. There is no "no shortcut" option — every action has some combination.
- After every settings change the registration is recalculated, **but only if any
  shortcut changed**. Re-registration leaves a moment with no shortcuts at all, and a press
  during it would reach the frontmost application as a character (e.g. "ś" instead of ⌥S) — so changing
  a slider or a toggle must not cause re-registration.
- A shortcut the system did not accept goes onto the error list (action + combination), shown in the
  Shortcuts tab (red text, see above). The action then remains unreachable globally
  (it still works in aiming mode, because there keys are recognized from raw events).
- The recorder **does not detect conflicts** between WindowQueue actions: the same
  combination can be assigned to two actions; in aiming mode the action earlier in the "#" order wins, and globally
  it depends on the system (the second identical shortcut may fail to register and appear on the error
  list). A reimplementation may improve this (a duplicate warning), but it is not required.

#### Shortcut recorder (`ShortcutRecorder`)

A 130 × 24 pt field with rounded corners (radius 5), centered text, 12 pt.

- Idle: control background, thin gray border, text = the current shortcut (e.g. `⌥⇧W`) or "Unset"
  when there is none.
- Click → the field takes the keyboard and starts recording: background in the accent color at 15% opacity,
  border and text in the accent color, text "Press keys…".
- The next key press in recording mode:
  - **Escape** (with any modifiers) — cancels, shortcut unchanged. Escape therefore cannot be
    assigned.
  - A key with at least one modifier (⌘ ⌥ ⌃ ⇧ — Shift alone counts too) — stores the
    combination, ends recording and gives up focus. The change takes effect immediately.
  - A bare key without a modifier — in the ordinary recorder a **system beep** and
    recording continues (a bare key cannot be a global shortcut). In the aiming-mode
    recorder a bare key is accepted.
  - Pressing modifiers alone does not store anything (it waits for a non-modifier key).
- Losing focus (click elsewhere, Tab) ends recording without changes.

#### Reset to defaults

The **"Reset all"** button replaces all 36 global shortcuts with the defaults for the *currently
selected* super. It does not touch super, `aimBindings`, `superDoubleTapAction` or any other
settings. No confirmation. There is no reset of the other settings and no restoring of a single
shortcut.

#### "Aiming mode only" keys (`aimBindings`)

A section at the bottom of the shortcut list. Heading "Aiming mode only", caption: in aiming mode every shortcut
above works without the super key; these keys work only there and take precedence when
both would match.

- List of existing assignments, sorted by key as text (i.e. lexicographically by the
  decimal key code, e.g. "11" before "9"). Row: key name (monospaced font,
  60 pt), action picker (no label) — a change saves immediately, a remove
  button ("minus in a circle" icon, borderless) — removes immediately.
- Add row: text "Add a key", a recorder accepting bare keys, an action picker
  (default "Start or stop recording the screen"; the value of this picker is not saved — after
  reopening the window it returns to the default). Recording a key immediately adds (or
  overwrites, if the key is already there) the assignment `code → selected action`. Only the key
  code counts — modifiers held during recording are discarded. After adding, the field returns to "Unset".
- Action choice in both pickers: only the 18 actions of the Queue group (without switching/moving to a
  workspace).

Key recognition in aiming mode (the keyboard is then fully captured, every
press is swallowed):

1. Keys reserved by the mode itself (by physical position): Return and keypad Enter
   (confirm), Space (confirm), Escape (cancel), arrows, `[`, `]`, `A` (select
   all). With Shift they "extend" the aim, with ⌥/⌘/⌃ they "move" windows. **`aimBindings`
   assignments on these keys will never work.**
2. Another key without any modifier → first `aimBindings[code]`.
3. Then the action whose global shortcut exactly matches the pressed combination (the full shortcut with
   super works too).
4. Then, for a bare key: the action whose shortcut is exactly super + that key (so shortcuts
   with super + ⇧ have no "bare" version).
5. Nothing matches → the press is swallowed with no effect.

#### Super double tap (`superDoubleTapAction`)

- Allowed values: `nil` ("Confirm the aim") or one of: `openLauncher`, `showOverview`,
  `search`, `toggleInvisibleStrip`, `toggleRecording`, `screenshotWindow`, `toggleMaximize`,
  `maximizeWindow`, `minimizeWindow`, `toggleGroup`, `closeWindow`, `sortByWorkspace`,
  `moveToStart`, `moveToEnd` (those that make sense without first pointing at a window).
- When aiming mode is open and the second tap comes **within 0.4 s of its
  opening**: if an action is set — the mode is closed without confirming, the popup disappears
  immediately and the action is performed (on the ordinary selection, outside aiming mode). If `nil` or the
  tap came later — an ordinary confirmation (focus on the aimed window).
- Side effect of a set action: after aiming mode is opened by a tap, its visible elements
  (dimming, popup, outline, action panel) appear only after 0.4 s, so that on a double
  tap the screen does not flash the mode. The keyboard is captured immediately. With `nil` and when
  the mode is opened by clicking the badge — everything is shown immediately.
- The control is disabled when `aimingEnabled = false`.

### Persistence

- Location: the app's preferences domain (`com.mpochec.windowqueue`), key **`preferences.v1`**,
  value = **a binary blob with the JSON** of the whole structure (a single object). The GNOME equivalent: a single
  JSON file in `~/.config/<app>/` or a single GSettings key with JSON — what matters is keeping the
  tolerant reading described below.
- JSON format: field names as in the table; enums as raw strings; numbers as numbers;
  `bindings` = an object `{"cycleNext": {"keyCode": 30, "modifiers": 2048}, …}`; `aimBindings` =
  an object `{"9": "toggleRecording"}` (key = the key code written in decimal as a string);
  `superDoubleTapAction` = a string or **an absent key** (for `nil` the key is omitted).
  The saved data contains all fields, including unused ones (`stripWidth`, `includeMinimized`, `aimingScale`).
- Saving: on every change, synchronously, only when the new value differs from the previous one.
  (A slider saves at every step of dragging.)
- **Fresh install** (no key, or the blob cannot be decoded as an object): all
  fields at their defaults, and `bindings` is immediately filled with the full set of defaults for Option. The blob
  is saved only on the first settings change.
- **Tolerant field-by-field reading**: each field is read separately; missing or
  invalid ones (wrong type, unknown enum value) get the default value, and the rest is loaded.
  Thanks to this, adding a new setting never invalidates an old save. Details:
  - dictionary fields are read as a whole: a single bad entry in `bindings` or `aimBindings` (e.g. an
    action name that no longer exists) resets the whole dictionary to the default (`bindings` → `{}`, i.e. in practice
    all shortcuts default for the stored super; `aimBindings` → `{}`);
  - a missing entry in `bindings` for a given action → the default shortcut of that action for the current super
    (this is how new actions get shortcuts for existing users);
  - **exception**: `superDoubleTapAction`, when missing/invalid, gets `nil` ("Confirm the aim"), and
    not the default `search` — necessary because `nil` is saved as an absent key; consequence: a user
    with a save from before this option has "Confirm the aim";
  - legacy: if there is no `stripDisplay` but there is the old `stripEnabled: false` → `hidden`.
- **One-time "Polish letters" migration** (flag `bindings.polishLettersFree.v1`, bool, in the
  same preferences domain):
  - runs at startup when a saved blob exists and the flag is not set; the flag is
    set **before** the migration, so the migration will never repeat;
  - for five actions it checks whether the saved shortcut is **exactly** the former default (the former
    key + the modifiers of the current default for the current super) and if so — replaces it with the new
    default:

    | Action | Former default | New default |
    |---|---|---|
    | `openLauncher` | super + S | super + R |
    | `showOverview` | super + O | super + W |
    | `sortByWorkspace` | super + ⇧ + S | super + ⇧ + W |
    | `toggleRecording` | super + C | super + V |
    | `screenshotWindow` | super + X | super + P |

  - shortcuts set by the user to anything else stay; a shortcut restored to the former
    key after the migration also stays (that is the user's choice);
  - if anything changed, the blob is saved again immediately;
  - the migration does not check for collisions with the user's other shortcuts (e.g. if someone already had something on
    super + R);
  - a fresh install does not set the flag, so the migration will run (usually without changes) on the second
    launch.
- Other data in the same domain that are **not** UI settings: `queueOrder.v1` (the remembered
  queue order), `dockReservation.originalRect.v1` (a copy of the original Dock area to
  restore), and the hidden diagnostic flags `diagnostics` and `debugCommands` (bool, set
  manually from the command line, they enable logging and debug commands).
- There is no "save current settings as defaults" feature, no settings export/import and no reset
  of settings other than shortcuts. Default values are constants in the code.

### Propagation of changes

On every change (and once at startup) the app:

- sets the queue scope and the auto-sort flag in the queue model,
- switches the tap detector to the modifiers of the current super,
- recalculates the registration of global shortcuts (only if the shortcuts changed),
- reconciles the login item with `launchAtLogin`,
- updates the screen space reservation (in the next pass of the event loop),
- after **1 s without any changes** (debounce — so that dragging a slider does not restart anything at every
  step) saves the gap for Rectangle and restarts it, if the value changed and Rectangle
  is running (macOS-specific).

The remaining settings are read "live" on every use (the strip redraws immediately after
an appearance change).

Reservation width (used in the caption, the reservation and the tiling area):
`ceil(iconSize + 20 + 2 × stripMargin)` pt; 0 in invisible mode. By default
`34 + 20 + 8 = 62` pt.

### Launch at login

- Enabled by default. Works only for a copy installed in `/Applications/`; a copy launched
  from the build directory never registers (registration would launch an old
  version at login), and the toggle in the UI is then grayed out with a caption about installation.
- At startup and on every change: on and not registered → register; off and registered →
  unregister; in other cases nothing. Errors go only to the diagnostic log.
- The "requires approval" state (the system is waiting for the user's consent) is shown in the UI with
  a button that opens the system login items settings.
- The user can also disable launching in the system settings — then the preference still says "on"
  and on the next startup/change the app will register itself again.
- On GNOME: a file `~/.config/autostart/<app>.desktop` created/removed according to the same logic
  (only for the installed copy).

### Menu bar icon

The app has a permanent icon in the menu bar ("stack of rectangles" symbol, accessibility description
"WindowQueue"). Clicking it opens a menu:

1. **"Settings…"** (⌘,) — opens the Settings window.
2. **"Sort queue by workspace"** (⌘S) — sets `autoSortByWorkspace = true` and sorts the queue by
   workspace (the same as the sort shortcut).
3. **"Refresh windows"** (⌘R) — forces the windows to be enumerated again.
4. separator
5. **"Quit WindowQueue"** (⌘Q) — quits the app (before exiting it gives back the reserved Dock
   area).

The shortcuts in parentheses work only while the menu is open. On GNOME the equivalent is an icon in the
notification area / a GNOME Shell extension indicator with the same menu.

---

## GNOME port plan

This chapter gathers the decisions that need to be made when porting WindowQueue to GNOME, and proposes
an architecture. Detailed equivalents of the individual system mechanisms are in the
"System layer" chapter ("GNOME equivalents" section); here is the overall picture.

### Form: a GNOME Shell extension, not a separate program

On Wayland an ordinary program cannot enumerate other programs' windows, focus them, move them or
capture the keyboard globally — all of that is done by the compositor (Mutter, inside the
`gnome-shell` process). X11 tools (`wmctrl`, `xdotool`, `EWMH`) do not work on Wayland. Therefore
WindowQueue on GNOME should be a **GNOME Shell extension** (GJS, ESM modules, GNOME Shell 45+),
which has direct access to:

- `global.display` (`Meta.Display`) — windows, focus, window signals, monitors;
- `global.workspace_manager` (`Meta.WorkspaceManager`) — workspaces;
- `Main.layoutManager` — shell interface layers, monitors, space reservation (struts);
- `Main.wm` — global shortcuts (`addKeybinding`);
- `Shell.WindowTracker` / `Shell.AppSystem` — applications and window icons;
- `St` / `Clutter` — widgets and animations;
- `Main.pushModal` — keyboard capture for aiming mode and the window finder.

Settings: the extension's GSettings schema + a `prefs.js` window (GTK4 + libadwaita).

It follows that a large part of the macOS code **disappears**, because it existed only to work around the limitations of
that system (see below), and the queue model carries over almost 1:1.

### What disappears and what gets simpler

| macOS mechanism | On GNOME |
|---|---|
| Enumerating windows from two sources (WindowServer + Accessibility), "blind" Chromium applications, ⌘\` as a workaround, popup heuristics based on geometry, checking `isOrderedIn` | Unnecessary: `Meta.Window` of every window on every workspace with its type (`Meta.WindowType.NORMAL`, `DIALOG`…), title (`title`, `notify::title`), state (`minimized`, `notify::minimized`) and workspace (`get_workspace()`, `workspace-changed`). Windows to skip: `skip_taskbar`, types other than `NORMAL` (possibly `DIALOG` with a parent — to be decided). |
| An invisible carrier window for moving to a workspace; verifying and retrying the switch; keeping consistent with the Dock | `workspace.activate(time)` / `workspace.activate_with_focus(win, time)` / `Main.activateWindow(win)` — deterministic, with the shell's animation. Verifying arrival is not needed. |
| Moving windows to a workspace only as whole applications | `win.change_workspace_by_index(i, false)` — a single window, always. The message "the application moves only as a whole" disappears. |
| Focus: verification loop, retries, `⌘\``, activation races | `Main.activateWindow(win, time)` (focus + raise + switch to the workspace) or `win.activate(time)`. Focus without raising: `win.focus(time)`. The verification loop is unnecessary. |
| Reserving space for the strip: replacing the Dock rectangle, an "edge guard" trimming windows, integration with Rectangle | `Main.layoutManager.addChrome(actor, { affectsStruts: true, trackFullscreen: true })` — struts reserve a band of the screen natively; maximizing, edge tiling and `get_work_area_for_monitor()` automatically avoid it. |
| A private WindowServer space above the desktops so the strip does not flicker on workspace change | A shell chrome actor lies above `window_group` and does not belong to any workspace — it does not disappear on switching. One only has to decide consciously about visibility in the overview — see below. |
| TCC permissions (Accessibility, Screen Recording), code signing | The extension has full access; no equivalent. |
| Detecting a super tap by observing `flagsChanged` + exceptions | See "Super key" — this is one of the few places that is *harder* on GNOME or requires a decision. |

### Super key and keyboard conflicts

This is the most important design decision of the port.

- **On Linux Polish characters come from right Alt (AltGr)** in the "Polish (programmer)" layout; left Alt
  is free. Even so, Alt as the modifier of global shortcuts collides with applications (GTK/Qt menus with
  `Alt+letter` mnemonics, shortcuts of terminals, editors, Emacs, browsers). **Recommendation: use the
  Super (Windows/Meta) key as super.** It is the natural window-manager modifier on Linux and
  does not collide with Polish characters at all.
- GNOME already has many shortcuts on Super that need to be **removed or remapped** (in GSettings, preferably
  by the extension on enable, with restoration on disable — and after asking the user):
  - `org.gnome.shell.keybindings switch-to-application-1..9` (Super+1…9 — launches/switches
    applications from the dock) → free up for workspace switching;
  - `org.gnome.desktop.wm.keybindings switch-to-workspace-1..N` and `move-to-workspace-1..N` — these can
    simply be set to Super+N / Super+Shift+N instead of registering our own (see below);
  - `org.gnome.shell.keybindings toggle-application-view` (Super+A), `toggle-message-tray`
    (Super+V), `toggle-quick-settings` (Super+S), `focus-active-notification` (Super+N),
    `org.gnome.desktop.wm.keybindings minimize` (Super+H), `toggle-maximized` (Super+Up), lock
    screen (Super+L), `switch-input-source` (Super+Space!) — check against the table of WindowQueue's default
    shortcuts and resolve each conflict.
- **Tapping the Super key alone** in GNOME opens the overview. Mutter then emits the
  `overlay-key` signal on `global.display` (the key is set by `org.gnome.mutter overlay-key`, default
  `Super_L`). The extension can intercept this signal (disconnect the shell's default handler or
  replace `Main.overview.toggle` while running) and open aiming mode — exactly the same
  gesture as in WindowQueue. The overview (the Mission Control equivalent) then gets its own shortcut
  (on macOS ⌥W → on GNOME Super+W). Mutter itself decides whether it was a "clean" tap (with no
  other key in between), so the whole `ModifierTapMonitor` logic from macOS is unnecessary.
  Double tap: measure the time between two `overlay-key` signals (0.4 s window as in the
  original).
- If the user nevertheless chooses Alt as super: `overlay-key` accepts any keysym (e.g.
  `Alt_L`), but check the interaction with application menus carefully. Do not choose `Alt_R`/AltGr.

### Global shortcuts

- `Main.wm.addKeybinding(name, settings, Meta.KeyBindingFlags.NONE, Shell.ActionMode.NORMAL, handler)`
  for each action from the action table; key names = action names, values in the extension's GSettings
  schema as arrays of accelerators (`['<Super>bracketright']`).
- Switching and moving to a workspace can be done with our own shortcuts (to keep the behavior of
  WindowQueue: focusing the *selected* or the first queue window on the target workspace,
  an empty slot on an empty workspace, handling aiming) — recommended, because the system `switch-to-workspace-N`
  focuses the workspace's "most recently used" window, not the window from the queue.
- Re-register only when shortcuts change (lesson from macOS: re-registering on every
  settings change lost key presses).
- Aiming-mode shortcuts are not global shortcuts — in aiming mode the keyboard is
  captured (see below) and the keys are interpreted by the mode itself.

### Aiming mode and window finder: keyboard capture

- `Main.pushModal(actor, { actionMode: Shell.ActionMode.POPUP })` passes all keyboard
  events to the extension's actor; `Main.popModal(grab)` releases them. Handling in
  `actor.connect('key-press-event', …)` with `Clutter.KEY_*` and `event.get_state()` for modifiers.
- Difference from macOS: during a modal capture, the focused application gets
  `wl_keyboard.leave` on Wayland and may draw itself as inactive. `global.display.focus_window` does not
  change, and after `popModal` focus returns to the same window — from the point of view of the rule "aiming does not
  move focus" that is enough. Confirmation = `popModal`, then focus on the aimed window.
- The safeguard from macOS ("the capture closes by itself after 15 s of silence") is worth keeping.
- A click outside WindowQueue's panels ends the mode: with `pushModal` mouse events also go to the shell —
  handle `button-press-event` on the capturing actor (or on `global.stage`) and check whether it
  hits the strip/group panel/action tiles.

### Strip and overlays

- A strip per monitor: `St.BoxLayout` (vertical for the left/right edge, horizontal for the
  top/bottom) in a container spanning the full length of the edge. Added via
  `Main.layoutManager.addChrome(container, { affectsStruts: <reserve space>, trackFullscreen: <hide in fullscreen> })`.
  The space reservation for a band of the strip's thickness must come from a separate, invisible actor of
  fixed size (struts are computed from the actor's geometry), because the panel visually "grows" in aiming mode.
- Monitors: `Main.layoutManager.monitors`, `primaryIndex`, the `monitors-changed` signal. "Selected
  monitor" = the monitor of the focused window (`global.display.focus_window.get_monitor()`) or
  `global.display.get_current_monitor()` (under the pointer) — to be decided; macOS used the screen with the
  key window.
- Icons: `Shell.WindowTracker.get_default().get_window_app(win).create_icon_texture(size)`; for windows
  without an application — a fallback icon.
- Name popup, group panel, action tiles, tiling menu, window finder: `St` actors in
  `Main.layoutManager.uiGroup` (`addTopChrome` for those that should be above everything), animations
  `actor.ease({ … duration, mode: Clutter.AnimationMode.EASE_OUT_QUAD })`.
- Dimming the screens in aiming mode: a semi-transparent `St.Widget` on each monitor below the
  strip, above the windows.
- Outlines of aimed windows and the focus flash: `St.Widget` with a `border` style in the frame
  `win.get_frame_rect()`, added above `global.window_group`; track `position-changed`/`size-changed`.
- Workspace number color depending on background brightness: in GNOME the pixels can be obtained via
  `Shell.Screenshot` (`screenshot_area`) or, more simply, computed from the wallpaper; this is a nice-to-have.
- Overview: decide whether the strip should be visible in the overview (chrome is visible above the
  overview by default if added to `uiGroup`). Aiming mode should close the overview.

### Workspaces — model differences

- **In GNOME a workspace spans all monitors by default**, and with
  `org.gnome.mutter workspaces-only-on-primary = true` (the default) windows on secondary monitors are
  on *all* workspaces. The "across monitors" numbering from macOS has no equivalent: in GNOME there is
  one list of workspaces and one current one, shared by all monitors. Consequences:
  - the number on the strip is the same on every monitor;
  - a window "on all workspaces" (`win.is_on_all_workspaces()`, e.g. on a secondary monitor
    or pinned) has no number — in the `currentSpace` scope it belongs to every workspace;
    sorting by workspace needs a rule (proposal: at the end, like windows without a number in
    macOS).
- **Dynamic workspaces** (`org.gnome.mutter dynamic-workspaces = true`, the default): GNOME itself
  adds an empty workspace at the end and removes empty ones in the middle. This clashes with the "empty slot" and with
  switching to an empty workspace N. Recommendation: an option in the extension's settings "fixed number of
  workspaces" (sets `dynamic-workspaces=false`, `num-workspaces=9`), or handle the
  dynamic mode: super+N for N > the number of workspaces goes to the last (empty) one.
- Reordering workspaces (dragging in the overview, `workspace_manager.reorder_workspace`)
  → the `workspaces-reordered` signal; adding/removing → `workspace-added`/`workspace-removed`;
  change of the current one → `active-workspace-changed`. The polling from macOS is unnecessary.
- "Keeping an emptied workspace after closing its last window": in GNOME with dynamic
  workspaces an empty workspace in the middle *disappears*, and the shell goes elsewhere — one must either
  disable dynamic workspaces or accept it (and not "keep" it).

### Queue model

The "Queue model" chapter carries over 1:1 into a pure JS module without imports from `gi://` — thanks to
this, unit tests (rewritten from `WindowQueueModelTests`) run under `gjs` or Node without
the shell. Window identifier: `win.get_id()` (stable within a session). Key for remembering the order
across sessions: `app id` (from `Shell.WindowTracker`) or `wm_class` + title — as on macOS (bundle id +
title), with the same matching logic.

### Tiling

- Work area: `workspace.get_work_area_for_monitor(monitorIndex)` — already reduced by the strip
  (struts), so the formulas from macOS ("screen area minus strip") simplify to "work area".
- Setting the frame: `if (win.get_maximized()) win.unmaximize(Meta.MaximizeFlags.BOTH)`, then
  `win.move_resize_frame(true, x, y, w, h)`. Some applications (terminals with a character grid)
  round the size — keep a tolerance in comparisons (macOS: 12 px position, 24 px size).
- Detecting manual moving/resizing of a window from a tiled group: window signals
  `position-changed`, `size-changed` + `global.display` `grab-op-begin`/`grab-op-end` (distinguishes
  mouse dragging from programmatic changes). Ignore changes caused by WindowQueue for a short time
  (macOS: 2 s after arranging).
- WindowQueue's own fullscreen mode (filling the work area, not the system fullscreen):
  remember `get_frame_rect()`, set the frame to the work area; restore the remembered one. One can also
  use `win.maximize()` — but then the user's maximization must be distinguished from focus mode.

### Other features

| Feature | GNOME |
|---|---|
| Focus/raise | `Main.activateWindow(win)`; without raising: `win.focus(global.get_current_time())` |
| Focus follows mouse | Can rely on GNOME: `org.gnome.desktop.wm.preferences focus-mode 'sloppy'`, `auto-raise true`, `auto-raise-delay` (ms). Own implementation: tracking the pointer (`global.get_pointer()` in a timer or `Clutter` events), the window under the pointer from `global.get_window_actors()` in stacking order, ignore rules as on macOS. |
| Close window | `win.delete(global.get_current_time())` |
| Minimize | `win.minimize()`; restoring: `win.unminimize()` + `activate` |
| Move to workspace N | `win.change_workspace_by_index(N-1, false)` |
| Switch workspace | `global.workspace_manager.get_workspace_by_index(N-1).activate_with_focus(win, time)` or `.activate(time)` for an empty one |
| Overview (Mission Control) | `Main.overview.toggle()` |
| Launcher | The overview with the search field (`Main.overview.show()` + focus on search) or an external launcher (`Gio.Subprocess`, e.g. Ulauncher/Albert) — a setting like Spotlight/Raycast/Alfred on macOS |
| Screen recording | D-Bus `org.gnome.Shell.Screencast` (`Screencast`/`StopScreencast`) available inside the shell; or the built-in `Main.screenshotUI` in video mode. A recording indicator on the strip instead of the number. |
| Window picture | `new Shell.Screenshot().screenshot_window(includeFrame, includeCursor, stream)` to a file in `~/Pictures/Screenshots` (or the directory from `org.gnome.gnome-screenshot`/XDG) — name with the application and date, as on macOS |
| Remembering the queue | a JSON file in `~/.local/share/<extension-uuid>/` or a GSettings key (array of strings) |
| Launch at login | unnecessary — the extension is enabled with the session |
| Menu bar (status item) | `PanelMenu.Button` in the top panel with the same menu items |
| Diagnostics | `console.log` (journal: `journalctl /usr/bin/gnome-shell -f`) + an optional file; debug commands via the extension's D-Bus instead of scattered notifications |

### Proposed order of work

1. **Model** — a pure JS module + tests rewritten from macOS (all rules from the "Queue
   model" chapter). Without it the rest makes no sense.
2. **Enumeration + read-only strip** — window list, icons in order, the selection follows
   focus, workspace number, new windows after the selected one, remembering the order.
3. **Basic shortcuts** — cycling, moving in the queue, close/minimize/maximize, super+N,
   super+⇧+N, name popup.
4. **Mouse interactions on the strip** — click, drag, wheel, middle click, hover.
5. **Empty slot, `currentSpace` scope, sorting by workspace, auto-sort.**
6. **Aiming mode** — keyboard capture, series, pinning, select all,
   dimming, outlines, super tap/double tap, action tiles.
7. **Tiling and tiled groups**, then **groups** with the group panel, then **fullscreen mode**
   with the stack tile.
8. **Window finder**, launcher, overview, invisible mode, recording and pictures, focus
   flash, focus follows mouse.
9. **Settings** (`prefs.js`) — add keys to the schema continuously at each stage.

### GNOME-specific pitfalls

- After `disable()` the extension must clean up everything: disconnect signals, remove shortcuts and actors,
  restore changed GNOME settings (overlay-key, Super shortcuts, dynamic workspaces). The shell
  disables extensions e.g. on the lock screen.
- A bug in the extension can bring down the whole shell (on Wayland — the whole session). Do heavy work (e.g.
  matching the queue after a restart) in small steps; handle exceptions in signal handlers.
- Windows appear before they have a title and an application (`window-created` comes early); wait for
  the first `notify::title`/`shown` or defer (`GLib.idle_add`) before inserting into the queue —
  the equivalent of the macOS "accept focus of a window we do not know yet, on the next
  refresh".
- Xwayland and native Wayland windows behave the same from the point of view of `Meta.Window`, but the icons
  of Xwayland applications without a `.desktop` file are sometimes empty.
- The shell API changes between versions (45: switch to ESM; 46–48: minor changes in
  `LayoutManager`, `Screencast`). Declare the supported versions in `metadata.json`.
