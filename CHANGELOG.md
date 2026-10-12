# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
