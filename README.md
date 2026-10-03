<p align="center"><img src="docs/assets/icon.png" width="128" alt=""></p>

<h1 align="center">WindowQueue</h1>

<p align="center"><b>Every window on your Mac in one queue you drive from the keyboard.</b></p>

<p align="center">
  <a href="https://github.com/mikolajpochec/wq/releases/latest"><b>Download</b></a> · macOS 14+ · Apple silicon and Intel · Free and open source
</p>

---

### One queue for every window
All your windows in one ordered list, shown in a strip on the side of the screen. Step through
it, and carry a window earlier or later.

<img src="docs/assets/keys-queue.svg" height="46" alt="⌥[ ⌥] to cycle, ⌥⇧[ ⌥⇧] to move">

<img src="docs/assets/queue.gif" width="600" alt="Cycling through windows and moving one in the queue">

### Aiming mode
Tap <kbd>⌥</kbd> on its own to aim at windows without focusing them. Add <kbd>⇧</kbd> to aim at
several, then act on all of them at once.

<img src="docs/assets/keys-aiming.svg" height="46" alt="Tap ⌥, then ↓, ⇧↓, ↩">

<img src="docs/assets/aiming.gif" width="600" alt="Aiming at windows in aiming mode">

### Tiling that fits
Aim at windows and pick a layout. Fixed-shape windows like the iOS Simulator keep their
proportions, and reordering the queue lays the tiles out again.

<img src="docs/assets/keys-tiling.svg" height="46" alt="Tap ⌥, ⇧↓ to aim, → for layouts, ↩">

<img src="docs/assets/tiling.gif" width="600" alt="Tiling Xcode, the Simulator and Safari, then reordering them">

### Groups
<kbd>G</kbd> in aiming mode bundles windows into one strip entry. Lock a group and cycling stays
inside it.

<img src="docs/assets/keys-groups.svg" height="46" alt="G to group, ⌃⌥L to lock">

<img src="docs/assets/groups.gif" width="600" alt="Grouping two windows and locking cycling to them">

### Workspaces
Jump to a workspace by number, take the window along, or find an empty one.

<img src="docs/assets/keys-workspaces.svg" height="46" alt="⌥1…9, ⌥⇧1…9, ⌥0">

<img src="docs/assets/workspaces.gif" width="600" alt="Switching workspaces and moving a window to another">

### Window finder
Type part of a window's name and go straight there.

<img src="docs/assets/keys-search.svg" height="46" alt="⌥Space">

<img src="docs/assets/search.gif" width="600" alt="Finding Terminal by typing">

### Declutter
Every window in view at once, none on top of another, resized as little as possible.

<img src="docs/assets/keys-declutter.svg" height="46" alt="⌥D">

<img src="docs/assets/declutter.gif" width="600" alt="Overlapping windows spreading out">

### Drag to reorder
Drag an icon along the strip to move its window in the queue.

<img src="docs/assets/drag.gif" width="600" alt="Dragging an icon to the top of the strip">

**And more:** maximize and fullscreen, multiple monitors, focus follows the mouse, window photos
and screen recording, a launcher shortcut, and every shortcut remappable. A welcome tour lets you
try it all on a pretend desktop.

---

## Install

1. Download the DMG from the [latest release](https://github.com/mikolajpochec/wq/releases/latest)
   and drag **WindowQueue** into **Applications**.
2. Open it. macOS blocks the first launch because the app isn't notarized: choose **Done**, then
   **System Settings › Privacy & Security › Open Anyway**.
3. Follow the tour, and allow **Accessibility** access when it asks.

Or build it yourself: `make install` (needs Xcode command line tools).

## More

- [Guide](docs/GUIDE.md): every feature and setting in detail
- [Specification](docs/SPECIFICATION.md): exact behaviour, for contributors
- [Changelog](CHANGELOG.md)

## License

[GNU GPL v3.0](LICENSE)
