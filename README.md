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
  It sits on any screen edge — left, right, top or bottom — at the start, centre or end of it.
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
  Shift with a step grows the aimed run, `A` aims at everything within reach — the open group's
  windows from inside one, the whole visible queue otherwise, and again to drop back to one.
- `⌥V` — or `V` in aiming mode, which stays open — starts recording the screen and stops it again;
  while it records, the strip shows a record mark in place of the workspace number. `⌥P`, or `P`
  while aiming, photographs the aimed windows, one file each, where your own screenshots go.
- Settings › Shortcuts › **Aiming mode only** binds bare keys that work in aiming mode and nowhere
  else; they win over the shortcut of the same key.
- `⌥I` — or `I` in aiming mode, which stays open — hides or shows the strip, saying which it now is,
  and the windows WindowQueue placed are laid out again for the room that just changed.
- **Invisible mode** (Settings › Strip › Visibility) keeps the strip off screen except while aiming,
  where it swings open from its edge like a page; the queue works as always and a change is announced
  by the name popup alone.
- The window focus lands on is outlined for a moment, in the selection colour (Settings › General ›
  Focus, with the duration; opt out there).
- While aiming, every aimed window on the workspace in view is outlined on screen, brightest for the
  one the aim is on, so a run of windows of the same application is still telling.
- Clicking the workspace number opens aiming mode, and a click anywhere outside WindowQueue's own
  panels leaves it. Opened that way, the mode's actions appear as tiles beside the strip.
- `⌥R` opens the **launcher** — Spotlight, Raycast or Alfred, whichever Settings names — and `⌥W`
  opens **Mission Control**. In aiming mode they are `R` and `W`, and the mode steps aside first so
  the launcher has the keyboard.
- `⌥Space` opens a **window finder**: type to narrow the queue by application or title, arrows to
  pick, Return to focus. Like aiming mode it takes the keyboard without taking focus.
- `⌥M` maximizes the selected window to the screen less the strip, and leaves everything else alone.
- `⌥D` — or `D` in aiming mode — **declutters**: every window on screen is moved, and only where it has to
  be shrunk, so that none covers another. Windows already in the clear stay exactly where they are; a pile
  of maximized ones ends up sharing the screen. With several windows aimed at, only those are sorted out
  among themselves. Each screen is done on its own, less the strip's room.
- Fullscreening a window (`⌥F`, again to restore) also focuses the queue on it: it moves to the front of
  its workspace, the workspace's other windows are tinted blue in the strip, and cycling skips them
  until the window is restored, which puts the order back. Off in Settings › General.
- `⌥G` puts the aimed windows in a **group**: the strip shows them as one entry, and stepping into it
  — with the cycle shortcuts, or by clicking it — selects its first window and lists the group beside
  the strip — a second strip of its own, in the same line and the same size. Resting the pointer on
  the entry names the group. `⌥G` again, with the selection inside a group, breaks it up. The queue itself is untouched throughout.
- Tiling from aiming mode leaves the windows in a **tiled group**, marked in the strip. Reordering
  them in the queue lays them out again in the new order — the quick way to change which window is
  the main one — and moving or resizing any of them by hand frees the group where it stands. Going
  fullscreen and back does not.
- `⌥H` minimizes the selected window.
- With several windows aimed at, `⌥M`, `⌥H`, `⌥Q`, `⌥⇧↖`, `⌥⇧↘` and `⌥⇧1`…`⌥⇧9` act on all of them
  at once, and a popup in the middle of the screen says what happened.
- `⌥Q` closes the selected window, wherever it is, and hands the selection to its neighbour.
- `⌥⇧W`, or "Sort queue by workspace" in the menu bar item, groups the queue by workspace in
  Mission Control order, keeping the order you arranged inside each one.
- `⌥1` … `⌥9` switch workspace, and `⌥0` goes to the nearest empty one on the same monitor (the later
  one when two are as near).
- `⌥⇧1` … `⌥⇧9` move the selected window (or every aimed window) to that workspace, and take you
  there with it. macOS only lets another app move windows a whole application at a time, so a window
  whose app has windows on other workspaces is carried the way a person would: held by its title bar
  while the desktop changes. (A minimized window is no way round it: macOS 26 restores it to the
  desktop it came from.)
- Option is the "super" key by default; the super key and every individual shortcut are remappable.
  No default takes A, C, E, L, N, O, S, X or Z, which Option turns into ą ć ę ł ń ó ś ź ż on the
  Polish Pro layout.

Order is **stable**: a new window is inserted directly after the currently selected one, cycling
never reorders, and only the move shortcuts change the order.

## Install

Requires macOS 14 or later, on Apple silicon or Intel.

1. Download `WindowQueue-<version>.dmg` from the releases page, open it and drag **WindowQueue**
   into **Applications**.
2. Open it from Applications. A welcome tour walks through the basics on a pretend desktop and asks
   for **Accessibility** access, which WindowQueue needs to move and focus other apps' windows.
   It lives in the menu bar; the tour can be reopened from there or from Settings.

Until releases are notarized, macOS refuses the first launch of a downloaded copy ("Apple could not
verify…"). Choose **Done**, then **System Settings › Privacy & Security › Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/WindowQueue.app` once. An update signed this way also
makes macOS forget the Accessibility grant: remove WindowQueue from the list and allow it again.

## Release

```sh
make release         # tests, then dist/WindowQueue-<version>.dmg and .zip
```

The app is universal (arm64 + x86_64) and signed with the hardened runtime. With a
**Developer ID Application** certificate in the keychain it is signed with that (or set
`SIGN_ID=...`), and notarized and stapled once a notarytool profile exists:

```sh
xcrun notarytool store-credentials windowqueue --apple-id <apple-id> --team-id <team-id>
```

Without one it is signed ad hoc. The version comes from `CFBundleShortVersionString` in
`Resources/Info.plist`; bump it and `CHANGELOG.md` together. `make icon` redraws the app icon from
`Scripts/make-icon.swift`.

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
**System Settings › Privacy & Security › Accessibility**. The welcome tour asks for it on first
launch, and the menu bar menu offers it for as long as it is missing; the shortcuts stay off until
it is granted.

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

`⌥1` … `⌥9` switch workspace in one of three ways (Settings › General):

- **Carry an invisible window there** (the default): a one-pixel panel of WindowQueue's own is put on
  the target desktop — a process may place its own windows on any space — and brought to the front
  through the WindowServer, and the Dock animates there the way it follows any activation. Works for
  empty desktops and past `⌃9`.
- **Focus a window on that workspace**: the selected window, if it is there, or the first queued
  one, which makes macOS travel to it; an empty workspace is reached the carrier's way.
- **The `⌃N` Mission Control shortcut**: macOS only ships those for desktops 1-4, so
  `Scripts/enable-desktop-shortcuts.sh` registers 5-9.

Whichever it is, WindowQueue checks 0.8s later that the desktop really is on show and tries the
other ways if not — unless a newer request came in, or the user went somewhere else meanwhile.

The private `CGSManagedDisplaySetCurrentSpace` call is deliberately *not* used: it switches the
WindowServer without telling the Dock, which goes on believing the old desktop is current — the
screen may not move at all, and later switches start from the wrong place.

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
  release.sh                  universal, signed (and notarized) DMG and zip in dist/
  make-icon.swift             draws Resources/AppIcon.icns
  make-signing-cert.sh        self-signed code-signing identity
  enable-desktop-shortcuts.sh registers ⌃5 … ⌃9 "Switch to Desktop N"
```

## License

WindowQueue is free software, released under the [GNU General Public License v3.0](LICENSE).
