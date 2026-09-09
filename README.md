# WindowQueue

A Linux-WM-style window queue for macOS: an ordered, keyboard-cyclable list of every window, an
always-on-top strip showing that list, and workspace switching by number.

- Ordered queue of all windows — scope is either every window or only the current workspace.
- `⌥[` / `⌥]` cycle the selection; the selected window is raised and focused.
- `⌥⇧[` / `⌥⇧]` move the selected window earlier/later in the queue, `⌥⇧↖` / `⌥⇧↘` to the ends.
- A vertical strip floats above everything on every Space, showing the app icons in queue order,
  the current selection, and the current workspace number.
- A popup shows the window name for 2 seconds after a selection change (duration configurable).
- `⌥1` … `⌥9` switch workspace.
- Option is the "super" key by default; the super key and every individual shortcut are remappable.

Order is **stable**: new windows are appended, cycling never reorders, and only the move shortcuts
change the order.

## Build and run

```sh
make bundle          # builds WindowQueue.app and ad-hoc signs it
make run             # builds and launches
make install         # copies to /Applications
```

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

## Optional: keeping tiled windows clear of the strip

Only the Dock and menu bar can shrink `NSScreen.visibleFrame`, so a third-party strip cannot reserve
screen space on macOS. Rectangle does honour its own hidden screen-edge gap preferences, so
WindowQueue writes `screenEdgeGapLeft`/`screenEdgeGapRight` to match the strip and restarts Rectangle
when the value changes. Turn it off in Settings › Strip.

## Workspace switching

`⌥1` … `⌥9` focus the first queued window on that workspace, which makes macOS animate to it. For a
workspace with no windows it falls back to the system's own `⌃N` Mission Control shortcut — macOS
only ships those for desktops 1-4, so `Scripts/enable-desktop-shortcuts.sh` registers 5-9.

The private `CGSManagedDisplaySetCurrentSpace` call is deliberately *not* used: on current macOS it
switches the desktop but leaves the WindowServer drawing several desktops on top of each other until
Mission Control redraws. It remains selectable in Settings for completeness.

## What macOS makes difficult

Three behaviours shaped most of this code, and each is worth knowing before changing it:

- **Menu-bar apps own real windows too.** Accessory applications are enumerated alongside regular
  ones so their settings windows — WindowQueue's included — appear in the queue. The strip and the
  title popup never do: they sit above the normal window level, and only layer 0 is considered.
- **`kAXWindowsAttribute` only lists windows on the active Space.** So the window set is seeded from
  `CGWindowListCopyWindowInfo`, which sees every Space, and enriched with AX data as Spaces are
  visited. Entries keep the element and title they were last seen with.
- **The WindowServer lists windows that no longer exist for the user** — closed documents an app has
  not released, off-screen scratch windows. `SLSWindowIsOrderedIn` separates them from real ones.
- **Chromium and Electron apps keep their accessibility tree switched off.** Slack, Obsidian and
  VS Code turn it on when `AXManualAccessibility` is set; Chrome implements neither that
  (`kAXErrorAttributeUnsupported`) nor `AXEnhancedUserInterface` (`kAXErrorNotImplemented`) and
  reports an empty window list forever. It does answer `AXFocusedWindow`, so WindowQueue captures
  that element whenever it sees it, and falls back to driving the app's own `⌘\`` cycle-windows
  shortcut to reach a window it has no element for.

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
