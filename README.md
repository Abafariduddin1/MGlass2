# MangaGlass 3.1

Spotify-injected iOS source with a cloud library, an adaptive manga reader, EPUB reading, audio/video playback, document previews, and customizable appearance. Targets arm64 and iOS 14 or later. Native Liquid Glass requires iOS 26; earlier versions use UIKit materials and rounded controls.

This archive contains source. Rebuild the dylib with the GitHub workflow, inject it into your Spotify IPA, and test on your phone. Local checks do not establish runtime compatibility with every Spotify build or a measured frame rate on an iPhone 13.

## Installing this update

1. Unzip the source archive and open its `MangaGlass` folder.
2. Copy that folder's **contents** into your existing GitHub repository's main folder, replacing matching files. `Makefile`, `Tweak.x`, and every `.h`, `.m`, and `.c` belong at the repository root. Keep `scripts/`, `tests/`, and `worker/` in their folders. The existing workflow remains in `.github/workflows/build.yml`.
3. If you already deployed the version 3 Worker, leave Cloudflare as it is: this UI fix does not change the Worker. Otherwise replace its code with **`worker/worker.mjs`**, not `worker.test.mjs`, and deploy. Keep the existing `DRIVE_API_KEY` secret and `ROOT_FOLDER_ID` variable. The new file types need that version 3 Worker.
4. Commit the repository changes and run **Actions → Build MangaGlass Dylib**. Download and unzip **MangaGlass-Dylib**.
5. In Sideloadly, inject this build into a clean Spotify IPA; include the same Substrate/Substitute compatibility support used by your working IPA. Export the updated IPA and install it through your usual SideStore process. Keep one MangaGlass dylib; do not inject this build alongside the previous version.

Settings and bookmarks use the same preferences suite as version 2. No file migration is required. The Worker endpoint and Drive root configuration are unchanged. No API key is embedded in the source.

## Supported content

| File | Reader | Limits |
| --- | --- | --- |
| PDF | Adaptive pages or original PDFKit view | Password-protected PDFs show an error. |
| JPG, PNG, WebP, GIF, HEIC and other ImageIO images | Manga reader | Animated images display a still page; decoding depends on iOS. |
| EPUB 2/3 | Local WebKit chapter reader | Unencrypted EPUBs with XHTML/HTML/SVG spine content. Scripts and remote resources are blocked. DRM content and ZIP64 are not supported. |
| MP3, M4A, AAC, WAV, AIFF, CAF, FLAC | Apple player | Native iOS codec support applies. Files stream from Drive through the Worker. |
| MOV, MP4, M4V and other listed video MIME types | Apple player | Container recognition does not guarantee that iOS supports the codec. Unsupported streams show a retry/error screen. |
| TXT, RTF, CSV, DOC/DOCX, XLS/XLSX, PPT/PPTX, Pages, Numbers, Keynote | Quick Look | Preview support depends on iOS. Uploaded files are supported; Google Docs/Sheets links are not exported. |

EPUB chapters follow the package spine rather than filename order. The chapter menu shows resource names. Reflowable books have text-size and serif/system-font choices. Fixed-layout books preserve their layout and WebKit zoom. Standard font obfuscation permits reading with the system-font fallback; no content decryption is performed.

Version 3.1 resolves package/chapter paths explicitly and supports raw or percent-encoded spaces, Unicode names, nested folders, and literal percent signs in package filenames. Both sides of WebKit's directory check use canonical paths. Missing/generic MIME declarations for HTML/SVG are recognized by extension. XML errors identify the file and line. Failed books are removed from the cache so Retry fetches a fresh copy. The failing EPUB was not attached; these changes address parser defects and packaging variations, rather than a verified repair of that particular file.

EPUB extraction runs on a serial background queue, validates paths and checksums, and reads one file at a time. Limits: 4,096 entries, 32 MiB per extracted file, and 256 MiB total. Temporary extracted files are removed when their reader is released. Only the original book download is kept in the existing bounded cache.

**PDF fitting:** Adaptive view fits the artwork inside an oversized white PDF sheet by default. Turn off **Fit PDF artwork in adaptive view** to keep the whole sheet. Cropping happens before spread splitting; layout uses the resulting aspect ratio. Original PDF view preserves the file's layout and uses native swipe paging horizontally or continuous scrolling vertically. Landscape two-page PDF view scrolls continuously.

Save EPUB bookmarks with the bookmark button or exit prompt. They restore chapter and scroll fraction. Media bookmarks restore playback time; document bookmarks reopen the file, without a page-position guarantee. **Bookmarks → tap** and the library's **Continue** shortcut support the new types.

Media begins with your play tap. Pause Spotify before starting your own audio if it is already playing: this tweak does not hook Spotify's playback engine or replace its remote-command handlers. Media streaming is not an offline-download feature.

## Glass and appearance

Open **Manga → settings → Spotify and Manga appearance**.

- Five presets: Spotify, Midnight, Ocean, Rose, and Pearl; plus a Custom palette.
- Custom accent, background, and text colors have a color wheel, brightness slider, preview, and editable six-digit hex field at the bottom. Changes apply when you tap Apply.
- Regular or Clear native glass, a glass-buttons toggle, and corner-shape choices.
- Optional matching of neutral Spotify text to the theme. Artwork and existing colored content keep their colors.
- Copy/paste appearance themes as JSON. Imports accept appearance preferences only.

Example:

```json
{"theme":"ocean","glass":true,"glassStyle":"regular","glassButtons":true,"hostText":true,"roundness":"20"}
```

Standard navigation bars, tab bars, and toolbars use UIKit's appearance API. App-owned buttons use native Clear glass on iOS 26 and transparent outlined controls on older systems. Spotify keeps its button configurations, images, titles, layout and update handlers; explicit neutral fills are cleared without replacing its buttons with generic glass configurations. Neutral content surfaces share the theme background instead of accumulating grey rectangles. The Spotify preset uses pure black. Artwork, videos and original PDF content retain their colors and layout.

Spotify's private/custom surfaces vary by version. The bounded adapter covers recognized Spotify screens, UIKit bars, visible foreground buttons, and neutral list/text surfaces; it cannot promise that every custom-rendered component adopts native glass. This is appearance customization, not desktop Spicetify's CSS/plugin runtime.

Reduce Transparency disables glass materials. The theme remains available with solid backgrounds. On older iOS releases the fallback is an approximation, not the native iOS 26 Liquid Glass renderer.

## Manga beside Create

The default **Manga entry → Beside Create** option identifies a visible Create tab and places an app-owned tab row over the original row. Each Spotify item routes to its original tab controller or original control action. Spotify's tab views, transforms, controller order and hit-test geometry are untouched. Manga has a separate action that opens the library; it does not invoke Create. Selection follows Spotify's active tab, so Manga is not permanently highlighted.

The adapter needs identifiable tab labels, usable original actions and enough room for the row. Private/custom dock hierarchies or localized labels may prevent detection. In that case Spotify's original row remains visible and a draggable Manga fallback appears above it; turn it off with **Show fallback if dock unavailable**. **Floating button** remains an explicit placement choice. Rotation, screen changes, and standard tab-bar layout trigger coalesced refreshes; the replacement row never triggers the original row's layout hook.

## UI fixes in this update

- Removed generic glass configurations from Spotify buttons, which could erase their custom icons and labels.
- Grey neutral fills now match the selected background; native reader buttons use Clear glass.
- Replaced tab-view translations with a separate tab row and explicit original-action routing.
- Manga is an unselected tab while Spotify is visible and hides while its library/reader is open.
- Adaptive PDF fitting trims large empty margins and reports the artwork's aspect ratio.
- Original PDF mode enables horizontal paging and vertical continuous scrolling.
- Theme colors have a wheel, brightness control and hex input.
- EPUB path resolution and error reporting are more tolerant of common packaging variations; failed downloads can be retried fresh.

Idle stability changes remove stock-tab transforms, repeated configuration assignment on each dock refresh, and native glass construction inside small Spotify controller views. Backgrounding hides the overlay and its replacement bar does not re-enter the stock layout hook. There is no 13-second timer in this source. The reported idle crash cannot be confirmed resolved without running the injected IPA on the affected phone or examining its crash report.

Earlier reader fixes remain:

- Bar materials no longer sit over buttons; normal, compact, and scroll-edge appearances share explicit foreground colors.
- Manga's opener stays hidden even when a reader presents another dialog.
- Reusing a zoomed manga cell restores page-swiping state.
- A page turn that does not move no longer waits indefinitely for a scrolling-animation callback.
- Folder requests reject stale callbacks after refresh or another request.
- Initial/very narrow collection widths produce valid cell sizes.
- Continue and bookmark labels distinguish pages, EPUB chapters, and playback time.
- EPUB link anchors keep their destination instead of always resetting to the chapter top.
- Themed counters, settings, and document titles remain legible and use the original file name.

## Performance choices

The defaults retain normal reader quality. The optional lower-memory reader mode remains available.

- No global view-layout hook, display-link polling, or continuous screen traversal. Standard tab-bar events queue one refresh; unchanged replacement items, frames and selection are left alone.
- Theme passes are bounded and happen on mount/settings changes. Theme colors are cached.
- Spotify buttons retain their own rendering. Native materials are limited to UIKit bars and app-owned controls; recycled rows do not receive their own live effects.
- Reader rendering is serial, with request cancellation, one-group prefetch, and an 18/48 MiB decoded-image cache. Long strips have a separate bounded pixel budget.
- Native PDF display and background raster jobs use separate PDF objects. Cropped pages retain only their displayed bitmap, and Core Image is initialized only when a reader filter needs it.
- EPUBs display one chapter at a time in a nonpersistent WebKit session. Video/audio streams use byte ranges rather than downloading an entire movie first.

These choices reduce CPU/GPU and memory work, but smoothness, temperature, battery use, and appearance on an iPhone 13 need device profiling in the actual IPA. Use the device checks below before relying on the build.

## Offline listening — explanation only

For Spotify catalogue music, the supported route is Premium: download a playlist/album while online, then use **Settings and privacy → Data-saving and offline → Offline mode**. Spotify requires going online at least once every 30 days to retain downloads. Cosmetic client changes do not grant account download authorization; adding more UI hooks is not a dependable replacement for that.

For audio files you own, offline playback is feasible as a separate feature: save the complete file in the app's documents directory, maintain a local download/index queue, and use `AVPlayer` with the local file URL. Background transfers and storage controls would be needed for a polished implementation. That would play your files, not unlock Spotify catalogue downloads. **Offline song downloads have not been implemented in this update.**

## Validation

`bash scripts/test.sh` passes locally:

- 28 reader-geometry checks, including centred artwork and isolated page numbers, and 5,000 randomized layouts.
- 19 production ZIP-extractor checks, including unsafe paths, CRC errors, truncated containers, unsupported encryption/compression, duplicate paths, and 1,000 mutated archives.
- 26 mocked Worker tests, including EPUB/document classification and media seek ranges.

All production native sources, including the actual Logos-generated hooks, compile for arm64/iOS 14 with `-Wall -Wextra -Werror` against an iOS SDK. A cross-link check resolves the UIKit/WebKit/AVKit/Quick Look/CoreMedia/zlib dependencies. This is not a signed/device-tested distribution binary.

On macOS the test script additionally runs the production EPUB package parser against 20 generated fixtures, checking spine order, title metadata, fixed layout/RTL, raw/encoded/Unicode/nested paths, MIME variations, malformed XML, missing chapters and encrypted content. These runtime checks are configured for GitHub CI; they cannot run in this Linux workspace. Their source compiles against the iOS SDK here. Drive calls in local Worker tests are mocked; the deployed Worker/account have not been exercised here.

## Device checks

1. Home, Search, Your Library, Now Playing, Create, and Manga still respond. Confirm that the Manga entry does not overlap another tab's tap target.
2. Open a PDF, image chapter, EPUB, MP3, MOV/MP4, and a document; try a mixed folder, a missing file, and an unsupported codec.
3. Bookmark an EPUB halfway through a chapter and media halfway through playback. Resume through Continue and Bookmarks.
4. Rotate manga on a spread, zoom/pan, reuse cells by swiping rapidly, try vertical reading, and switch to original PDF view.
5. Try all presets, custom colors, theme copy/paste, Regular/Clear glass, Reduce Transparency, and glass off. Controls should remain visible.
6. Repeat navigation and content opening while watching memory and frame pacing on the oldest target phone. Check accessibility text sizes and VoiceOver.
7. Leave Spotify Home idle for at least a minute, then repeat in Manga, original PDF and EPUB views. If the app exits, retain the Spotify .ips crash report, including the exception and crashed-thread backtrace. A screenshot alone cannot identify that crash.

References: [Apple glass button configurations](https://developer.apple.com/documentation/uikit/uibuttonconfiguration/glassbuttonconfiguration), [WebKit file access](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)), [EPUB specification](https://www.w3.org/TR/epub-33/), [Spotify offline help](https://support.spotify.com/ie/article/listen-offline/), [Theos](https://theos.dev/docs/).
