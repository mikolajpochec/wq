# WindowQueue

A Linux-WM-style window queue for macOS: an ordered, keyboard-cyclable list of every window, an
always-on-top strip showing that list, and workspace switching by number.

- Ordered queue of all windows — scope is either every window or only the current workspace.
- `⌥[` / `⌥]` cycle the selection; the selected window is raised and focused.
- `⌥⇧[` / `⌥⇧]` move the selected window earlier/later in the queue, `⌥⇧↖` / `⌥⇧↘` to the ends.
- Icons can also be dragged in the strip to reorder. Scrolling over the strip walks the selection,
  focusing the window shortly after the scrolling stops; a middle click closes a window.
- The queue's order is remembered between runs. Hovering an icon shows the window's name
  straight away, and it stays up for as long as the icon is held.
- A vertical strip floats above everything on every Space, showing the app icons in queue order,
  the current selection, and the current workspace number.
  It can show on the selected monitor only, on every monitor with the inactive ones greyed out,
  or not at all. The strip lives in a private WindowServer space above the desktops, so switching
  workspaces slides the desktops underneath it instead of hiding and redrawing it.
- Focus follows the mouse: resting the pointer on a window focuses and raises it (macOS cannot
  focus without raising). It waits for the pointer to settle, and ignores the strip, menus, the Dock
  and anything held with a button or modifier down. Opt out in Settings › General.
- A popup shows the window name for 2 seconds after a selection change (duration configurable).
- Tapping the super key on its own opens **aiming mode**: the screens dim, the strip grows, the aimed icon is
  outlined in orange, `[`/`]` or the arrow keys move the aim without focusing anything, and tapping the
  super key again — or Return, or Space — focuses it. Escape leaves the queue as it was.
- `⌥Space` opens a **window finder**: type to narrow the queue by application or title, arrows to
  pick, Return to focus. Like aiming mode it takes the keyboard without taking focus.
- `⌥Q` closes the selected window, wherever it is, and hands the selection to its neighbour.
- `⌥⇧S`, or "Sort queue by workspace" in the menu bar item, groups the queue by workspace in
  Mission Control order, keeping the order you arranged inside each one.
- `⌥1` … `⌥9` switch workspace.
- Option is the "super" key by default; the super key and every individual shortcut are remappable.

Order is **stable**: a new window is inserted directly after the currently selected one, cycling
never reorders, and only the move shortcuts change the order.

## Build and run

```sh
make bundle          # builds WindowQueue.app and ad-hoc signs it
make run             # builds and launches
make install         # stops any running copy and installs to /Applications
```

Run the installed copy from then on — it is the one Launchpad and Spotlight find, and the only one
that can register to **launch at login** (on by default, switchable in Settings › General). A copy
started from the build directory refuses to register, since it would start a stale build at login
and break on the next rebuild.

Requires Swift 6 / Xcode command line tools and macOS 14+.

`make bundle` signs with the first code-signing identity in your keychain, falling back to an ad-hoc
signature. Prefer a real identity: an ad-hoc signature changes on every build, and macOS then revokes
the Accessibility grant each time. `make cert` creates a self-signed one if you have none.

## Accessibility permission

WindowQueue drives other applications' windows through the Accessibility API, so it must be granted
**System Settings › Privacy & Security › Accessibility**. It prompts on first launch and waits,
polling once a second, until access is granted.

If the app stops seeing windows after a rebuild, its code signature identity changed. Reset the grant
with `tccutil reset Accessibility com.mpochec.windowqueue` and relaunch to get a fresh prompt.

## Optional: window titles from other workspaces

Windows on a workspace you have not visited show only their app name. macOS hides `kCGWindowName`
from apps without Screen Recording access; granting it in Settings › General fills the titles in.
Nothing else depends on it.

## Keeping windows clear of the strip

Only the Dock and menu bar can shrink `NSScreen.visibleFrame`, so a third-party strip cannot reserve
screen space on macOS through public API. WindowQueue works around it three ways:

- Every app derives its visible frame from one Dock rectangle kept by the WindowServer, and any
  process can overwrite it. While the Dock auto-hides, WindowQueue replaces it with a strip-wide rect
  on the menu bar screen, so zoom, Fill and tiling leave room natively. Apps only read the rect at
  launch and whenever the Dock announces its own, so this reaches apps started after WindowQueue and
  is lost for everyone when the Dock rewrites it; WindowQueue puts it back, and restores the Dock's
  rect on quit (including `kill`). Rectangle is relaunched with the Dock's rect in place, since it
  adds its own gap on top.

- Zoom (double-clicking a title bar), Fill and the built-in tiling size windows to the visible frame.
  WindowQueue watches for a window resized flush against the strip's screen edge and trims it to
  start beside the strip. Plain moves and resizes with a mouse button still held are left alone.
- Rectangle honours its own hidden screen-edge gap preferences, so WindowQueue writes
  `screenEdgeGapLeft`/`screenEdgeGapRight` to match the strip and restarts Rectangle when the value
  changes.

Turn both off in Settings › Strip.

## Workspace switching

`⌥1` … `⌥9` focus the first queued window on that workspace, which makes macOS animate to it. For a
workspace with no windows it falls back to the system's own `⌃N` Mission Control shortcut — macOS
only ships those for desktops 1-4, so `Scripts/enable-desktop-shortcuts.sh` registers 5-9.

The private `CGSManagedDisplaySetCurrentSpace` call is deliberately *not* used: on current macOS it
switches the desktop but leaves the WindowServer drawing several desktops on top of each other until
Mission Control redraws. It remains selectable in Settings for completeness.

## What macOS makes difficult

- **A modifier-only shortcut is not expressible with Carbon hotkeys.** Aiming mode is opened by
  watching `flagsChanged` events instead, and a tap only counts when the super key was pressed and
  released alone, quickly, with no key, click or scroll in between. Two details matter: Carbon
  swallows the key events of our own shortcuts before a monitor sees them, so the hotkey dispatcher
  cancels a pending tap as well; and a tap can only be armed on the way up from no modifiers at all,
  because releasing Shift during `⌥⇧]` leaves exactly the super key held and the release that follows
  is otherwise indistinguishable from a deliberate tap.
- **An event monitor observes, it cannot consume**, and an accessory app that is not active cannot
  make even a `.nonactivatingPanel` key. So neither route delivers a bare `[` to aiming mode: a
  monitor would let it through to the app in front, and the panel receives nothing at all. Aiming
  takes the keyboard with a `CGEventTap` instead, which can swallow an event and needs no focus —
  the point of the mode being that focus does not move until the user confirms. The tap closes
  itself after 15 seconds of silence, so a mode left open cannot lock the keyboard out.


Three behaviours shaped most of this code, and each is worth knowing before changing it:

- **Menu-bar apps own real windows too.** Accessory applications are enumerated alongside regular
  ones so their settings windows — WindowQueue's included — appear in the queue. The strip and the
  title popup never do: they sit above the normal window level, and only layer 0 is considered.
- **`kAXWindowsAttribute` only lists windows on the active Space.** So the window set is seeded from
  `CGWindowListCopyWindowInfo`, which sees every Space, and enriched with AX data as Spaces are
  visited. Entries keep the element and title they were last seen with.
- **The WindowServer lists windows that no longer exist for the user** — closed documents an app has
  not released, off-screen scratch windows. `SLSWindowIsOrderedIn` separates them from real ones.
- **Popups are windows too.** A tab hover card, a menu or a download bubble is an ordinary
  layer-0 window to the WindowServer, and for an app that hides its accessibility tree there is no
  role to check. They are recognised by geometry instead — a window lying almost entirely inside a
  window at least twice its size, from the same app, on the same workspace — unless the
  accessibility API vouches for it as a standard window.
- **Chromium and Electron apps keep their accessibility tree switched off.** Slack, Obsidian and
  VS Code turn it on when `AXManualAccessibility` is set; Chrome implements neither that
  (`kAXErrorAttributeUnsupported`) nor `AXEnhancedUserInterface` (`kAXErrorNotImplemented`) and
  reports an empty window list forever. It does answer `AXFocusedWindow`, so WindowQueue captures
  that element whenever it sees it, and falls back to driving the app's own `⌘\`` cycle-windows
  shortcut to reach a window it has no element for. Spotify goes further and answers neither, so
  focusing it can only activate the app: once it is frontmost the attempt is treated as done,
  because there is nothing left to verify or retry.

## Searching

Query words are matched one at a time, each as a substring first and only then as a gapped match
with a couple of characters' slack. Scoring the whole query as one long subsequence — the usual
fuzzy-finder trick — lets "google chrome" match a title that merely happens to contain those letters
spread across it, which reads as noise.

## Responsiveness

An accessibility call to a busy application blocks until it times out, and the default timeout is
long enough to be felt. Two things keep that off the interface: every application element is created
through `AXPrivate.application(_:)`, which caps a single call at 0.25s, and the whole enumeration
runs on its own queue, touching the model only once it is done.

## Troubleshooting

`defaults write com.mpochec.windowqueue diagnostics -bool true` and restart the app. It then writes
`~/Library/Logs/WindowQueue/diagnostics.txt` (a snapshot of the queue, the WindowServer's view and
every app's accessibility state) and `events.log` (an append-only trace of focus attempts). Turn it
off with `defaults delete com.mpochec.windowqueue diagnostics`.

## Private API caveat

macOS exposes no public API for Mission Control Spaces. Workspace reading goes through private
SkyLight symbols (`CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`, `SLSWindowIsOrderedIn`),
and stable window identity uses `_AXUIElementGetWindow`.

All of it is resolved at runtime with `dlsym` and confined to `System/SpacesBridge.swift` and
`System/AXPrivate.swift`. If a future macOS release removes a symbol the app keeps working with
workspace features disabled, and those two files are the only place to fix.

## Layout

```
Sources/WindowQueue/
  main.swift              NSApplication bootstrap
  AppDelegate.swift       wiring: status item, hotkey dispatch, permission gate
  Model/                  ManagedWindow, WindowQueueModel (order + selection)
  System/                 AX enumeration, focusing, Spaces bridge, Carbon hotkeys, permissions
  UI/                     strip panel and view, title toast, settings, shortcut recorder
  Settings/               Preferences (UserDefaults) and KeyCombo
Scripts/
  make-signing-cert.sh        self-signed code-signing identity
  enable-desktop-shortcuts.sh registers ⌃5 … ⌃9 "Switch to Desktop N"
```
