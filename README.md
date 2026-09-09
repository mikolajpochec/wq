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

## Accessibility permission

WindowQueue drives other applications' windows through the Accessibility API, so it must be granted
**System Settings › Privacy & Security › Accessibility**. It prompts on first launch and waits,
polling once a second, until access is granted.

Because the bundle is ad-hoc signed, macOS may treat a rebuilt binary as a new identity and ask for
the permission again. If the app stops seeing windows after a rebuild, remove its entry in the
Accessibility list and re-add it.

## Private API caveat

macOS exposes no public API for Mission Control Spaces. Workspace reading and switching go through
private SkyLight symbols (`CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`,
`CGSManagedDisplaySetCurrentSpace`), and stable window identity uses `_AXUIElementGetWindow`.

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
```
