# Changelog

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
