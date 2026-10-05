# Work Camera

Work Camera is an iPhone app for recording work photos and videos, built with SwiftUI, UIKit, and AVFoundation. Photos, videos, and written reports are stored in the app's local media library before users organize, edit, or share them. No custom backend or account login is required.

This document describes the repository source and settings, with Library Back-button handling updated on 2026-10-05 and Library presentation, thumbnail caching, and build-number notes updated on 2026-10-04. Camera and privacy-manifest notes retain their dated evidence below. See the [technical documentation](TECHNICAL_DOCUMENTATION.md) for implementation details and dated validation boundaries.

The camera description was updated on 2026-10-02 to reflect physical-camera-only capture with app-controlled Auto Macro.

## Features and Evidence Status

**Implemented** means the source is connected to the normal UI path. It does not mean compilation or device validation was completed in this task.

- **Implemented**: HEIC photo capture, front/back camera switching, device-filtered zoom shortcuts, flash, exposure compensation, a grid, and 3/5/10-second capture timers. Preview, photos, and videos use physical camera inputs; virtual Triple/Dual cameras are used only to read lens/zoom metadata and are rejected as capture inputs.
- **Implemented; selected device scenarios manually verified**: Auto Macro defaults to on for supported back cameras and can be toggled with the macro button. The app uses stable autofocus-position readings to switch to the physical ultra-wide lens for close subjects. Startup keeps that input fixed through the 2-second cooldown and at least one second of stable focus samples, then establishes its exit baseline from the settled readings. Exit requires the same lens's focus position to reach `min(baseline + 0.04, 0.80)` for at least 1.25 seconds. Initial autofocus travel never triggers a normal-lens probe; that fallback has been removed. It preserves the requested zoom when the ultra-wide camera supports it, with dwell times and a cooldown to reduce repeated switching. Switching pauses during photo processing and recording; video preview can select a macro lens before recording starts. The 0.5× shortcut remains available. Focus thresholds require device calibration, especially in low light or low-detail scenes; they do not measure distance or reproduce Apple's virtual-camera Auto Macro. The `0.80` cap addresses a distant startup baseline observed after immediate withdrawal. It is an empirical value from the supplied device traces, applies across supported zooms and lighting conditions, and may cause unwanted exit if a close subject produces readings at or above it. Temporary Auto Macro diagnostic output has been removed.
- **Implemented; hardware results Externally unverified**: MOV recording at 30 FPS. The code first tries 10-bit HLG BT.2020 at 4K or 1080p with HEVC, then falls back to 8-bit sRGB SDR, preferring 4K, 1080p, and 720p before other supported sizes. SDR uses HEVC when available, otherwise H.264. Configurations with neither a supported format nor codec show a recovery message. Actual codec, color metadata, Dolby Vision output, and lens compatibility require device verification.
- **Implemented, optional**: Capture locations are saved when permission is granted and a valid, recent location is available. Shutter sound suppression, flash, torch, Auto Macro/ultra-wide close focusing, and resolution depend on device capabilities.
- **Implemented**: A local Library, photo/video filters, album creation and renaming, album membership management, and individual or batch deletion. Photos support zooming and adjacent-photo navigation; videos have playback, progress, and mute controls.
- **Implemented; final device behavior Externally unverified**: Home Screen quick actions open Library, Collections, or Templates. Launch routing resolves the window scene before creating the camera page and requests the selected Library tab. A UIKit presentation bridge opens Library without animation, using the entry orientation; the Library Back button directly requests dismissal from the UIKit controller while updating SwiftUI presentation state, and returning to Camera waits for portrait scene geometry before dismissal. The Back-button change has passed static checks; portrait and landscape returns still require device confirmation. The shortcut registration array is reversed to target the requested Library → Collections → Templates display order after the user reported the opposite order. The final display order and camera-flash fix still require device confirmation.
- **Implemented; limited user-supplied device evidence**: Library prepares the initial viewport plus one row before revealing thumbnails together. The cache preloads the newest 40 items, uses an 80-entry `NSCache` count limit and a 32 MiB cost limit, and prepares remaining previews on disk. JPEG previews have a maximum edge of 256 pixels and do not change HEIC photos or HEVC/H.264 MOV originals. Limits are eviction guidance, not a hard cap on total app memory. Cold loads and rapid scrolling can still require disk reads or thumbnail generation; zero waiting is not guaranteed. The user reported that thumbnails no longer appeared one by one and supplied a later log without missing-preview-file errors; large-library scrolling remains unverified.
- **Implemented**: Vision photo OCR, object classification, and document detection for search, with a local index cache and failure retry. Videos are searched by filename only. Recognition is not guaranteed to be complete or accurate.
- **Implemented**: Per-item Reports, reusable templates, and video Captions/Keywords. Caption and Report share a text sidecar; Keywords are not included in the current search.
- **Implemented**: Photo cropping, rotation, and PencilKit markup; video cropping, rotation, trimming, and audio removal. Both editors support overwriting or saving a new item.
- **Implemented; external results Externally unverified**: Photo sharing uses a temporary JPEG, video sharing uses a MOV URL, and a nonempty Report is included separately. Custom Save Image/Save Video actions add the original library file to system Photos. Receiving apps control caption handling, line breaks, transcoding, and metadata processing.

Device evidence on 2026-10-02 confirmed 1× near-to-far entry/exit with the previous `+0.10` exit increment. A low-light 1× run entered macro but did not exit: baseline `0.753`, threshold `0.853`, and distant focus readings around `0.808–0.827`. A later `+0.04` run still failed with immediate withdrawal: a late baseline `0.802` gave threshold `0.842` while readings stayed around `0.815–0.827`. A previous physical-lens recheck revision passed the four reported 1×/2× normal-/low-light near-to-far cases, but stationary 1× low-light runs caused unwanted probes. Even a startup-settling gate failed: an initial `0.690` rose to a stationary `0.749–0.757` plateau and eventually triggered `recheck → recheck_exit`. The subsequent probe-free revision passed a reported 1× low-light stationary hold through approximately 16 seconds and exited about two seconds after withdrawal. Immediate withdrawal still failed: baseline `0.816`, threshold `0.856`, and distant readings around `0.812–0.831`. The current revision caps the exit threshold at `0.80` while retaining startup convergence and the 1.25-second dwell. With the capped-threshold revision, supplied 1× low-light logs verified immediate withdrawal entry/exit and a stationary 15-second hold without switching followed by exit on withdrawal. The user also reported successful 1×/2× normal-light retests, 2× low-light entry/exit, and no lens switching when moving closer or farther during recording. These results cover the reported device scenarios, not all devices or focus conditions. Temporary macro diagnostics were subsequently removed without changing the switching conditions; the cleanup received static validation only.

**Experimental / Inactive**: The `favorite` key has cleanup logic only, with no favorite action or list. PNG files at the repository root are not the target's configured app icon; the active icon is in the asset catalog.

**Test-covered**: No automated tests or test target were found. **Verified** covers the documentation/configuration checks from the original documentation revision and the static checks for the 2026-10-02 camera and quick-action updates, as detailed in the technical documentation. Build/Test were not run. Extension ideas are **Planned / Not implemented**.

## Requirements

Settings source: [project.pbxproj](Work%20Camera.xcodeproj/project.pbxproj).

| Item | Repository setting or limitation |
| --- | --- |
| Target/product | `Work Camera` / `Work Camera.app` |
| Platforms | `iphoneos iphonesimulator`; `TARGETED_DEVICE_FAMILY = 1`, iPhone only |
| Deployment target | iOS `27.0`, inherited from project settings in Debug and Release |
| SDK | `SDKROOT = auto`; no pinned SDK version |
| Swift | `SWIFT_VERSION = 5.0` is the language mode, not the compiler version; default actor isolation is `MainActor` |
| Xcode/macOS | No minimum versions declared; project metadata records creation tool `26.3` and `LastUpgradeCheck = 2700`, which do not establish minimum requirements or a successful build |
| App version | Marketing `1.1.1`; build `20261004` |
| Dependencies | Apple/system frameworks only; no third-party package manifest or lockfile |

Use an Xcode version that can open this project and provides an SDK compatible with the APIs used by the source. Physical capture, HEIC/HEVC, HLG, location, and Photos behavior require validation on an iPhone meeting the deployment target. There is no macOS or Mac Catalyst target. Project-level deployment values for other platforms do not mean the app supports those platforms.

## Installation / Setup

1. Obtain a complete repository checkout, including the Swift sources and the configured AppIcon asset. This document does not prescribe a clone URL.
2. Open `Work Camera.xcodeproj` in Xcode from the repository root, or run this command manually:

   ```sh
   open "Work Camera.xcodeproj"
   ```

3. Confirm that the target is `Work Camera`. Select a scheme pointing to that target, the Debug configuration, and a compatible iPhone runtime or device.
4. The repository contains no actual `.xcscheme` file. User scheme management records `Work Camera` and the old `MyApp` name, but does not provide portable scheme definitions. If Xcode has no suitable scheme, create one manually in Manage Schemes and select the `Work Camera` target.
5. No dependency installation is required. There is no `.env`, API key, backend URL, or app-defined environment variable configuration.
6. For device development, select your own Team in Signing & Capabilities and adjust the bundle identifier if needed. The project uses Automatic signing with a specific Team. It does not include signing credentials or guarantee that another account can sign it unchanged.

Camera, Microphone, Location When In Use, and Photos Add usage descriptions are generated into Info.plist from build settings. Camera permission is required for capture. If microphone permission is denied, initial session configuration can omit the audio input. Denied location permission prevents new location metadata. Adding media to Photos requests add-only permission separately.

## How to Run

After selecting the target, scheme, and destination in Xcode, manually Build/Run the app. These operations were not performed in this documentation task. Simulator is a possible environment for manual compilation and UI checks, but the repository has no mock camera, demo data, import tool, or Simulator-specific mode. Simulator execution cannot establish physical capture behavior.

There is no checked-in shared scheme, so this document does not provide an `xcodebuild` command that assumes one exists. A reproducible CLI build requires separately approved creation of a shared scheme before defining commands using the actual scheme and destination.

Local capture, viewing, editing, and Vision search do not use an app-defined network service. MapKit maps and reverse geocoding in Info, and the network availability of third-party sharing destinations, depend on system or external services. Failed offline address lookups leave coordinates visible. There is no separate online/demo feature flag.

After installation or an update, open the app once to register its dynamic Home Screen quick actions. Return to the Home Screen, touch and hold the app icon, and select Library, Collections, or Templates. These actions select the existing Library tabs; returning to Camera resumes capture when the app is active. iOS controls the system menu items such as Edit Home Screen, Require Face ID, and Remove App; the app supplies only its own shortcut array. Verify the visible shortcut order at the intended icon position.

## Project Structure

| Path | Responsibility |
| --- | --- |
| [Work Camera/](Work%20Camera/) | Eight Swift source files and `Assets.xcassets` |
| [MyApp.swift](Work%20Camera/MyApp.swift) | App entry, scene delegates, quick-action registration/routing, window-scene reader, UIKit Library presentation, fixed portrait camera hosting, and orientation policy |
| [ContentView.swift](Work%20Camera/ContentView.swift) | Camera UI, Library, media details, Reports/templates, metadata, sharing, and Photos activity |
| [CameraService.swift](Work%20Camera/CameraService.swift) | Capture session, lenses, formats, permissions, location, and preview bridge |
| [MediaStore.swift](Work%20Camera/MediaStore.swift) | Media, sidecars, albums, and filename allocation |
| [MediaThumbnailCache.swift](Work%20Camera/MediaThumbnailCache.swift) | Memory cache, JPEG disk previews, preloading, and stale-preview cleanup |
| [PhotoSearchIndex.swift](Work%20Camera/PhotoSearchIndex.swift) | Vision analysis, search, progress, and cache |
| [PhotoEditorView.swift](Work%20Camera/PhotoEditorView.swift) / [VideoEditorView.swift](Work%20Camera/VideoEditorView.swift) | Editing previews, output generation, and save callbacks |
| [Work Camera.xcodeproj/](Work%20Camera.xcodeproj/) | Project, embedded workspace, and user scheme management |

## Development

There are no repository-defined build scripts, CI, test targets, fixtures, or lint/format/typecheck configurations. The following read-only checks can be run manually from the repository root. They are not repository scripts and do not establish Swift API compatibility or runtime correctness:

```sh
git status --short
git diff --check
plutil -lint "Work Camera.xcodeproj/project.pbxproj"
```

Preserve existing uncommitted changes before development. The developer performs Build/Test manually in Xcode. This documentation task did not run Build/Test, Simulator, signing, archive, deployment, or upload operations.

## Known Limitations

- Photos require HEIC; there is no JPEG capture fallback. Video prefers HLG/HEVC and falls back to SDR with HEVC or H.264; each lens must support a compatible 30 FPS configuration. Photos request the active format's maximum photo dimensions, without guaranteeing 48 MP.
- Media share 9,999 filename slots, from `IMG_0001` through `IMG_9999`. Deletion is permanent. Orphaned sidecars also occupy slots.
- Storage is in the app's Application Support directory. There is no cloud sync, database, import, backup/restore tool, or schema migration. System backup behavior was not verified.
- Editing produces new pixels or movie output. New photo copies do not inherit Reports, Keywords, or album membership. New video copies inherit existing Report/INFO sidecars, but not album membership. Preservation of HDR/Dolby Vision after editing is unverified.
- Shared JPEGs do not reuse the original HEIC metadata dictionary. The custom Photos save action uses the library's HEIC/MOV file. Original files and sidecars may contain sensitive location and text data.
- There are no automated tests. A missing shared scheme, a specific signing Team, and an unpinned toolchain leave gaps in build/CI reproducibility.

## License

No project-wide `LICENSE`, `COPYING`, or license statement was found. This document does not grant permission to use, modify, or distribute the project. Apple frameworks are governed by their SDK/platform terms, which do not replace a project license. Hardware-name mappings in [MediaStore.swift](Work%20Camera/MediaStore.swift) include a DeviceKit source comment, but the repository does not import DeviceKit or include its license file. Licensing of the mapping data requires separate clarification.

## Privacy Policy

[PRIVACY_POLICY.md](PRIVACY_POLICY.md) contains the English privacy policy for Work Camera, identifying Sunny Yu and the public contact email. It covers local media and OCR storage, permissions, Apple maps and address lookups, sharing, Photos, backups, retention, and deletion.

The document must be available at a public, login-free HTTPS URL before that URL is entered in App Store Connect. Committing the Markdown source does not verify public access or add an in-app policy link. [PrivacyInfo.xcprivacy](Work%20Camera/PrivacyInfo.xcprivacy) declares app-only UserDefaults (`CA92.1`), app-container file timestamps (`C617.1`), and elapsed-time calculations (`35F9.1`). It declares no tracking and no developer-collected data. The file is in the target's filesystem-synchronized source folder; its inclusion in the archived app must still be verified in Xcode. An easily accessible in-app privacy-policy link remains a separate submission task.

## Submission Regression Checks

See [the manual device checklist](MANUAL_VALIDATION.md) for prioritized permission, recording interruption, storage, search deletion, large-library, 48 MP editing, and HDR/SDR checks. These scenarios remain **Externally unverified** for this revision. The recording completion callback preserves a file when AVFoundation reports successful completion even with an error. Deletion reconciles cached OCR before Search opens and attempts Report/INFO cleanup independently of album persistence; filesystem errors are reported rather than treated as successful cleanup.
