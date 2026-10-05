# Changelog

## 1.3.0 (2026-10-05)

- On macOS 26 and later the strip, group strip, action panel, title popup, search and tiling menu sit on the system's Liquid Glass. The strip and group strip use the Dock's thicker glass, lit along the top and bending what's behind them at the edge; menus and popups use the standard glass. Earlier macOS keeps the translucent look it had.
- The highlights inside the panels follow the rounder corners of the panel they sit in.

## 1.2.0 (2026-10-03)

- New setting, Settings › General › Queue › **Wrap around at the ends of the queue** (on by default). Turned off, cycling with ⌥[ / ⌥] and moving the aim stop at the first and last window instead of coming round to the other end.

## 1.1.3 (2026-10-03)

- Maximizing a tiled window with ⌥M frees its layout, as moving or resizing it by hand does. Fullscreen (⌥F) still keeps the layout.

## 1.1.2 — 2026-10-03

- Focusing a tiled window brings up the whole layout even when another window of one of its apps — a second Chrome window, another terminal — was on top of it.

## 1.1.1 — 2026-10-03

- Update checks read the latest release from its page on GitHub instead of GitHub's API, which allows only 60 requests an hour per network and then refuses ("GitHub answered 403").
- A failed automatic check tries again an hour later instead of the next day.

## 1.1.0 — 2026-10-03

- **Update checks:** WindowQueue looks for a new release on GitHub at launch and once a day. A new version is announced once, with its notes and a Download button that opens the release page; after **Not Now**, an **Update Available** item stays in the menu bar menu. Nothing is ever installed for you.
- **Check for Updates…** in the menu bar menu, and Settings › General › Updates to turn automatic checks off or check now.

## 1.0.1 — 2026-10-03

Welcome tour improvements.

- Moving the aim is shown as `[` / `]`, the keys used everywhere else; the arrows still work.
- A new **Close windows** tip: ⌥Q, or Q while aiming.
- ⌥0 on the pretend desktop adds a workspace when every one is in use, so the Workspaces tip can always be finished.
- Opening the window finder (⌥Space) is enough for the Search tip.
- Finished tips get a check, the tour skips past them, and it ends on a new **All set** page once every tip is done.

## 1.0.0 — 2026-10-03

The first public release.

- **The queue:** every window in one ordered list, cycled with the super key and `[` / `]`, and
  reordered by shortcut or by dragging icons in the strip. The order is stable and remembered
  between runs, scoped to every window, a workspace or a monitor.
- **The strip:** a floating bar of app icons in queue order on any screen edge, with the workspace
  number, groups, and an invisible mode that shows it only while aiming.
- **Aiming mode:** tap the super key on its own to dim the screens and aim at windows without
  focusing them. Aim at several, then focus, tile, group, maximize, minimize, close, photograph or
  move them to a workspace in one go.
- **Tiling:** layouts from the aiming menu that respect fixed-proportion windows such as the iOS
  Simulator, and lay themselves out again when the queue is reordered.
- **Groups:** bundle windows into one strip entry, and lock a group so cycling stays inside it.
- **Workspaces and monitors:** switch and move windows by number, jump to an empty workspace, and
  move between monitors.
- Also: a window finder, declutter, maximize and fullscreen, screen recording and window photos,
  focus follows the mouse, a launcher shortcut (Raycast, Alfred or Spotlight) and Mission Control.
- **Welcome tour:** a pretend desktop to try everything in, then the few settings that matter most.
  Reopen it from the menu bar or Settings.
- Defaults adapt to the Mac: the super key avoids keyboard layouts where Option types letters, and
  the launcher falls back from Raycast to Alfred to Spotlight.
- Universal app (Apple silicon and Intel), macOS 14 or later, under the GNU GPL v3.
