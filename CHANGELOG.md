# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-10-12

### Added
- **Liquid Glass** on macOS 26+, with `NSGlassEffectView` as the panel background:
  - Glass top-bar chips (interactive, accent-tinted when selected), subtle clear-glass cards, a `.glass` *Paste as Plain Text* button, and a glass clear button and undo toast.
  - Older systems keep the vibrancy look; the deployment target is still macOS 14.
  - Corners stay fully transparent (alpha 0.00 in light and dark).

### Changed
- **Smoother clear animations**:
  - The trash button morphs into *Confirm clear?*: the width springs over ~0.32 s while the top bar's other buttons and the search field slide aside smoothly, the background crossfades from gray to red, the label fades and slides in, and the icon wiggles. A thin bar drains over the 3 s countdown, and on timeout everything morphs back.
  - On confirm, cards leave with a staggered fade + scale + slide-down (20 ms stagger, ≤ 300 ms), then the empty state fades in. *Undo* brings them back with a reverse stagger.
  - The undo toast slides up with a spring, shows a 5 s countdown bar and fades out smoothly.
- **Reduce Motion** is respected: crossfades only, with no width spring, slide, wiggle or scale.

### Measured
- Frame sampling during the morph: button width 26 → 95 → 121 → 123 pt and red 0 → 0.17 → 0.84 → 0.92 between +150 and +320 ms; the collapse runs 123 → 77 → 39 → 26 pt.
- The toast's slide offset goes −22 → −15 → −6 → +1.8 (overshoot) → 0 pt.
- Card-strip brightness changes gradually over ~280 ms on clear and on undo.
- Resources with glass: idle 23.5 MB, 500 items 39.9 MB, panel open 8–10 ms avg, idle CPU 0.03 %.

## [1.2.3] - 2026-10-12

### Added
- **One-click Clear History** in the panel's top bar, a 🗑 next to ×:
  - The first click turns it red (*Confirm clear?*). A second click within 3 s clears all non-favorite history, with no modal dialog and no focus stealing.
  - A **5 s undo toast** (*Cleared N · Undo*) follows. Image and thumbnail files are deleted only after the undo window ends, or when you quit.
  - Favorites are always kept. The button is hidden in the Favorites tab.

### Fixed
- App chips' counts refresh after clearing or undoing.

## [1.2.2] - 2026-10-12

### Added
- **Movable panel**: press and drag any empty area to move the panel. That includes the grabber pill at the top center, the top-bar gaps, the margins, the space between and around cards, and the empty part of the card row. Cards, chips, buttons, stars and the search field keep their own behavior.
- **Settings → General → Panel position**: *Follow cursor (default)* or *Remember last dragged position*. In remember mode the dragged position is saved and restored, clamped to the visible screens. In follow-cursor mode a drag only moves the panel for the current showing.

## [1.2.1] - 2026-10-12

### Fixed
- The bottom panel no longer shows a white rectangle behind its rounded corners.
  - The window and content container are fully transparent.
  - The vibrancy view is clipped with a 9-slice rounded mask image as well as a layer corner radius, and the hosting view is clear.
  - The shadow is recomputed on show and resize so it follows the rounded shape.
  - Verified by rendering the panel window: corner alpha is 0.00 in both light and dark mode, and the center is 1.00.
- Cards use a translucent fill instead of an opaque white `controlBackgroundColor`, so they blend with the panel.

## [1.2.0] - 2026-10-12

### Added
- **Edit favorites**: right-click → *Edit…*, a pencil on hover in the Favorites tab, or double-click the card title.
  - The title is optional and shown prominently on the card.
  - For text and URL items you can edit the content, which changes what gets pasted. Editing rich-text content converts it to plain text, and the editor says so.
  - Images and files: title only.
  - ⌘↵ saves, Esc cancels. The editor is a real key window, so typing, IME and ⌘A/C/V/X/Z work.
- **Manual favorites**: a **+** in the Favorites tab, *New Favorite…* in the **>** menu, or right-click an empty list. These create a favorited text item with the source *Manual*.
- Search covers titles and edited content: the item's search key is rebuilt on edit.

### Fixed
- The mouse wheel and vertical trackpad scrolling now scroll the tabs/app-chips row. Scroll events go to whichever row is under the cursor. The **>** menu and the item count stay pinned at the right, so the row scrolls even in a small panel.

## [1.1.0] - 2026-10-12

### Added
- **Favorites**: a star button in each card's top-right corner. It's an outline star on hover or selection and a filled yellow star when favorited, with a small bounce. Clicking it doesn't paste or close the panel.
- *Add to Favorites / Remove from Favorites* in the card's right-click menu, and ⌘D for the selected card.
- *Favorites* tab right after *History*.

### Changed
- Favorites never expire: they're exempt from retention, the item cap and *Clear History*.
- **Pin is merged into Favorites.** On first launch, pinned items become favorites and the *Pin* menu item is removed.
- Items in the default *Snippets* pinboard become favorites and that board is removed. User-created pinboards are kept.
- The Shortcuts settings page lists all panel shortcuts.

## [1.0.0] - 2026-10-12

### Added
- Animated multi-page first-run guide (welcome, capture, ⇧⌘V, search/filter/plain text, Accessibility, "Make it yours"), replayable from the menu bar.
- Settings window: General (language, open at login, pause capture, panel size), History (retention, max items, clear), Shortcuts, Privacy (concealed/transient skipping, ignored apps, Accessibility), About.
- English / Simplified Chinese localization. Follows the system language by default and switches instantly.
- Accessibility drag helper: a floating panel lets you drag Pasting into System Settings → Accessibility, and it confirms when access is granted.
- Panel opens above the text cursor (via Accessibility). Falls back to the bottom center of the screen.
- Smaller default panel (560 pt wide, 120 pt cards) with Small/Medium/Large presets, sliders and drag-to-resize, persisted.
- Resource budget test (`tests/resource_test.sh`) and an isolated `--test` mode with a temp data directory.
- Self-rendered demo screenshots (`--test screenshots`).

### Measured
- Idle 20.7 MB; with 500 items incl. 100 images: 33–38 MB; −1.3 MB growth over 50 panel cycles; panel open 4.0 ms avg; idle CPU 0.10 %.

## [0.7.0] - 2026-10-12

### Added
- Filter by source app: top-app chips sorted by clip count, plus a ">" menu for all other apps. *New Pinboard…* moved into that menu.
- Hidden Edit menu so ⌘A/⌘C/⌘V/⌘X/⌘Z/⇧⌘Z work in the search field.

### Changed
- Search uses precomputed normalized keys (case/diacritic/width-insensitive, capped at 2000 chars) with incremental narrowing: 0.2–3.8 ms per query over 500 items.

### Fixed
- Pasting no longer re-captures its own pasteboard writes.

## [0.6.0] - 2026-10-12

### Fixed
- Keyboard input never reached the panel: borderless panels can't become key by default. Arrows, Enter, Esc and typing-to-search now work with real keystrokes.
- Mouse wheel and vertical trackpad scrolling now scroll the card row horizontally.

## [0.5.0] - 2026-10-12

### Added
- Close (×) button in the panel.

### Changed
- More compact panel and cards.
- Performance: downsampled thumbnail cache (memory + disk), icon cache, background JSON writes, equatable SwiftUI cards, no per-card shadows, instant show with a pre-created panel. Panel open went from 55–180 ms to 13–30 ms, and arrow selection from 25 ms to 4 ms.

## [0.4.0] - 2026-10-12

### Added
- History retention (default 7 days; 1/7/30 days/forever) purged at launch, hourly and on capture. Pinned and pinboard items are exempt.

## [0.3.0] - 2026-10-12

### Added
- Rich text capture (RTF/HTML) with a "Rich" badge. Normal paste keeps formatting.
- Paste as Plain Text: top-bar button, ⌥↵, right-click item.

### Changed
- Card panel rewritten in SwiftUI (hosted in a non-activating `NSPanel`) with spring animations.

## [0.1.0] - 2026-10-12

### Added
- Initial release: menu bar app, clipboard polling capture (text, links, images, files, colors) with source app, ⇧⌘V bottom panel (Carbon hotkey), search, pinboards, rename/pin/delete, paste into the previous app via synthesized ⌘V, open at login, JSON persistence, first-run window.
