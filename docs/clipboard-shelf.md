# Clipboard shelf view

The built-in clipboard now offers a horizontal card shelf and the existing list/detail layout. The selected layout is stored in the extension's `viewMode` preference; new installations default to cards. Existing clipboard records and model settings need no migration.

## Interaction

- Cards appear along the bottom of the current display's visible frame, avoiding the Dock and menu bar. Leaving the shelf restores the ordinary launcher geometry without overwriting its saved position.
- Detached extension windows retain their user-chosen size and never resize the launcher.
- Filter by all items, pinned items, text, links, images, or files. Search still uses native full-text/application matching before filtering.
- Image cards are up to 384 px wide, other cards up to 328 px; narrow windows shrink cards responsively. Images retain their full aspect ratio without cropping.
- Each card has **Send** and **Copy** actions. Send uses the existing paste-to-previous-app implementation; it does **not** press Return or submit a message. Copy writes only the clicked item and keeps the window open with feedback. Neither action depends on which card is currently selected.
- Click selects; double-click or Return pastes. Command-Return copies and hides the window; Command-1...9 pastes a visible item; Command-P toggles pinning; Command-Backspace deletes; Command-F focuses search.
- Left/right selects cards when search is empty; otherwise the keys retain text-editing behavior. Space opens full preview when the card list has focus.
- Clearing history still requires confirmation and preserves pinned records.
- User-visible text is provided in English and Simplified Chinese. Light/dark appearances, reduced motion, focus indicators and action labels are supported.

## Image loading and native bridge

- Thumbnails are lazy-loaded near the viewport: 96 px for list rows, 768 px for cards. Full preview requests up to 1440 px.
- `spotcat.clipboard.thumbnail(id, maxSize = 96)` remains compatible with one-argument callers. The native bridge clamps requested thumbnail sizes to 32...1024 px. This uses the existing `clipboard` permission.
- Native cache keys include both entry ID and requested size, with limits of 96 entries and 32 MiB of encoded thumbnail data. The page retains at most 64 thumbnails.
- `spotcat.clipboard.setView('cards' | 'list')` is an internal built-in clipboard layout request. The native host rejects requests from other extensions, regardless of their permissions. It does not persist the preference by itself.
- Clipboard text is inserted as text nodes, not executable HTML. Link cards do not fetch remote previews. Tests use synthetic in-memory records only.

## Regression checks

Requirements: macOS with Swift/Command Line Tools, Python 3, and Node.js for the JavaScript syntax check.

```sh
./scripts/test-clipboard.sh
./scripts/test-clipboard.sh 1200 466 --dark
./scripts/test-clipboard.sh 420 268
./scripts/test-clipboard.sh 420 268 --dark
./scripts/test-model-endpoints.sh
./scripts/bundle.sh release --universal
```

The clipboard runner creates an isolated WebKit fixture. It checks card/list switching and persistence, large-image geometry, each card's send/copy target, duplicate action prevention, error feedback, keyboard navigation, filters, preview races, clear confirmation, injection safety and 1,000-entry rendering. A separate Swift fixture tests shelf geometry on ordinary and negative-origin displays.

The endpoint tests compile the production `ModelsConfig.swift` with a persistence guard and no API keys or network requests. They cover Zhipu Coding Plan and standard BigModel `/v4` bases, complete endpoints, whitespace/trailing slashes, beta versions, existing provider paths, and both new presets.

These changes do not modify build signing, installation, application identifiers or update behavior. Local installation/certificate tooling is intentionally outside the feature contribution.
