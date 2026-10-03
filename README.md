# MangaGlass 2.0

Updated native iOS / Theos source for the Spotify tweak described in your handoff. It targets arm64 and iOS 14 or later, keeps your existing Worker URL, and includes the updated cloud proxy.

**This archive contains source, not a compiled dylib.** Page planning and the Worker have been tested locally. The UIKit / PDFKit / Logos code still needs the included macOS build and testing in your actual Spotify IPA.

## What changed

| Requested feature | Implementation |
| --- | --- |
| Fit the screen | Responsive library columns, aspect-fit reader pages, and layouts based on the available viewport rather than a fixed screen size. |
| One or two pages automatically | Portrait uses single pages. A viewport at least 600 points wide and 1.25 times wider than tall can pair consecutive single pages. Existing wide scans stay together in landscape. The first page can remain a single cover. |
| Split wide scans | Scans with an aspect ratio of at least 1.2 split into two halves in portrait. Right-to-left mode shows the right half first. Disable the setting for landscape illustrations that should remain intact. |
| Zoom and pan | Pinch to zoom, double-tap to zoom or reset, and pan while enlarged. Horizontal page swipes are suspended while zoomed. |
| Reading direction | Right-to-left by default, left-to-right, and continuous vertical / webtoon mode. Two pages in an RTL spread are arranged in reading order. |
| Bookmarks | A bookmark button, an exit prompt with save / leave / keep reading, a separate Bookmarks screen, and a Continue shortcut on the library screen. Bookmarks preserve file ID, page, split half, reading direction, and vertical offset. Original PDF view also saves the PDF destination. |
| Fullscreen | Hide the bars and status bar. Tap the middle of a page to restore controls. |
| Reader controls | Edge taps, page swipes, Previous / Next controls, and a tappable page counter to jump directly to a page. |
| Display options | Pure black background, conservative white-margin cropping, grayscale, sharpening, and a lower-resolution mode. |
| Existing PDF support | Adaptive reader uses PDFKit documents and Core Graphics page rendering. Reader options also expose the original native PDFKit view. |
| Dock entry | A glass Manga accessory sits at the upper edge of Spotify's bottom dock. Existing Spotify tabs and selected-index logic are preserved. Recognizes native tab bars and common custom dock classes. A draggable fallback appears if no dock is recognized. |
| Glass throughout the host app | Idempotent materials on Spotify-owned screens and navigation surfaces. Neutral backgrounds in lists and newly mounted cells become translucent. Artwork and colored surfaces keep their appearance. Native `UIGlassEffect` is used when available on iOS 26+, with dark blur materials on earlier iOS versions. |
| Cloud library reliability | Natural numeric ordering, nested folders, mixed image / PDF / folder listings, complete pagination, image dimensions, resource keys, useful errors, retry controls, streamed downloads, and range responses. |

Bookmarks are explicit: opening a chapter never silently creates or updates a bookmark. Back asks before leaving unless you turn that preference off. The automatic iOS back-swipe is disabled while reading so it cannot bypass the prompt.

The adaptive reader supports the image filters and split scans. **Original PDF view** preserves PDFKit's own rendering, selection, and zoom; image filters and portrait half-splitting apply in the adaptive view.

## Replace the old GitHub build

The old workflow generated and overwrote the source during every build. This version builds real source files from the repository so edits are retained.

1. Unzip this archive.
2. Copy the **contents** of the `MangaGlass` folder into the root of your existing GitHub repository. Include `.github/workflows/build.yml` and replace the previous build workflow. The Makefile should be at the repository root.
3. Remove any other old workflow that regenerates MangaGlass source. Keep one build workflow.
4. Commit the files to `main` / `master`, or open **Actions → Build MangaGlass Dylib → Run workflow**.
5. When the macOS build succeeds, download **MangaGlass-Dylib**, unzip it, and use `MangaGlass.dylib`.

The workflow installs Theos, selects the runner's Xcode iOS SDK, runs the portable tests, builds arm64, and checks the Mach-O file before exporting it. It selects the actual dylib from explicit paths; it cannot accidentally select the debug-symbol file that caused the earlier launch crash.

For a Mac with Xcode and Theos installed:

```bash
export THEOS="/path/to/theos"
bash scripts/test.sh
make FINALPACKAGE=1
bash scripts/export-dylib.sh
```

## Sideloadly

Use the injection / **Export IPA** process from your handoff:

1. Open your Spotify IPA and add the newly built `MangaGlass.dylib` in advanced injection settings.
2. Include the Cydia Substrate / Substitute compatibility support needed for Logos hooks.
3. Keep automatic bundle-ID changes and app renaming disabled, as described in your existing working process.
4. Export the modified IPA, then sign / install it using your existing working SideStore process.

The archive does not include Spotify, an IPA, a signing identity, or a compiled dylib. Existing preferences and bookmarks live inside the installed Spotify app's container; deleting the app can remove them.

## Cloudflare Worker

The reader still uses `https://m-proxy.19lueleaf.workers.dev` in `MGConfig.h`. The upgraded Worker keeps `/api/library` and `/api/page`, so existing callers remain compatible.

### Cloudflare dashboard

1. Open your existing `m-proxy` Worker and replace its code with `worker/worker.mjs`.
2. Add a **secret** named `DRIVE_API_KEY` containing your Google Drive API key.
3. Add `ROOT_FOLDER_ID` with the root folder ID already set in `worker/wrangler.toml`.
4. If the root folder's shared link includes a required resource key, set `ROOT_RESOURCE_KEY` too.
5. Deploy that Worker. Your Drive API must be enabled, and the folders / manga files must have the public sharing required by the API-key-based setup in your handoff.

The API key from the PDF is intentionally excluded from these source files. The new Worker reads it from its environment. Adding the secret is required when deploying this new Worker; a missing configuration returns a visible error instead of an empty screen.

### Wrangler

From `worker/`, in an environment with your Cloudflare account configured:

```bash
npx wrangler secret put DRIVE_API_KEY
npx wrangler deploy
```

Requests:

```text
GET /api/library
GET /api/library?folderId=DRIVE_FOLDER_ID
GET /api/page?fileId=DRIVE_FILE_ID
```

Folders remain arrays of `{ id, name, type }`, optionally including `width`, `height`, and `resourceKey`. All-image chapter folders open the reader directly. Mixed folders show all supported items, and selecting an image opens the image subset. Empty folders show an empty-state message.

## Performance and freeze prevention

- No global `layoutSubviews` hooks and no repeated reordering of the view hierarchy.
- One material per tracked screen / bar / dock accessory. Cells receive a lightweight color update rather than individual blur views.
- Viewport changes are handled by the reader, with a size guard and deferred layout planning. Dimension discovery waits for page dragging / zooming to finish before rebuilding the layout.
- Downloads go to disk. PDF loading, image downsampling, cropping, filtering, and page rendering happen outside the main thread.
- Serial rendering, one next-group prefetch, cancellation on cell reuse, and generation checks prevent old downloads from replacing new pages.
- Standard page limit: 3,072 pixels, or 1,536 in lower-resolution mode. Long strips use a separate bounded pixel budget to retain useful text detail.
- Rendered cache target: 48 MiB normally or 18 MiB in lower-resolution mode. The cache is cleared on memory warnings. These are cache budgets, not a guarantee of total process memory.
- Downloaded-file cache trims older files around 256 MiB; a current large volume can exceed that target. Cached files expire after 24 hours.
- Glass can be disabled in MangaGlass Settings and follows iOS Reduce Transparency.

## Ideas not included

- Face ID / Touch ID lock: requires permission handling in the signed host IPA and verification on the target device.
- Volume-button page turns: this version uses tap zones, swipes, and reader controls, preserving Spotify's audio controls.
- A separate custom Metal renderer: UIKit handles compositing / zoom, Core Graphics renders PDF pages, and Core Image handles optional filters.
- Automatic Read / In Progress labels: bookmarks follow your requested explicit-save behavior instead.

## Validation and remaining device checks

`bash scripts/test.sh` passed locally: **26 reader-geometry checks**, **5,000 randomized layouts**, and **24 mocked Worker tests**. Workflow YAML, the tweak filter, shell syntax, and absence of embedded API keys were also checked.

The local environment has no Apple SDK, Theos, or iOS device. **The native code has not been compiled or run here.** The macOS workflow is the next compilation check. The Worker tests use mocked Drive responses; they do not verify your deployed Worker or account configuration.

After building, check on the actual phone:

- Spotify launches and remains responsive on Home, Search, Your Library, and Now Playing.
- Dock Manga button opens once; existing tabs still work. If your Spotify build uses a different private dock class, the floating fallback should appear.
- Open a PDF, an image chapter, an empty folder, and a mixed folder.
- Rotate on a single page and on a wide scan. Confirm page / half, RTL ordering, and fit are preserved.
- Pinch, pan, double-tap, and swipe rapidly. Pages should retain the correct artwork.
- Try vertical mode with a long strip and resume a bookmark midway through it.
- Save / cancel / leave from the bookmark prompt; reopen from Bookmarks and Continue.
- Switch to original PDF view and resume a bookmark there.
- Toggle glass and Reduce Transparency without accumulating layers or freezing.

Spotify's private view classes and supported orientations can differ between IPA versions. Some custom surfaces may keep their original appearance, and landscape requires the host IPA to permit that orientation. A genuine whole-app appearance and on-device stability remain runtime checks.

Implementation references: [Theos variables](https://theos.dev/docs/variables), [Theos on macOS](https://theos.dev/docs/installation-macos), [Apple UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect), and [Google Drive files.list](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list).
