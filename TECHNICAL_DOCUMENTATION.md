# Work Camera Technical Documentation

This document is based on the seven Swift source files, Xcode project/workspace, scheme management, and asset catalog in the repository working directory on 2026-10-01. It includes existing uncommitted and untracked content. Historical memory, filenames, and UI labels are not treated as evidence of completed functionality. See the [README](README.md) for setup and usage.

Camera selection, app-controlled Auto Macro, and related validation notes were updated on 2026-10-02 against the current `CameraService.swift`. Other sections retain the original documentation scope.

## 1. System Overview and Evidence Categories

Work Camera has a single iPhone application target. The normal entry path is `MyApp` → `ContentView`, where the view creates `CameraService` and `MediaStore`. Captures are written to the app's Application Support directory. Library uses the same store, with editing callbacks, Report sidecars, and the system sharing UI for output.

| Status | Meaning and current evidence |
| --- | --- |
| **Implemented** | Source exists and is called by the normal UI/lifecycle; capture, Library, albums, search, editing, Reports, templates, sharing, and the Photos activity meet this definition |
| **Test-covered** | Corresponding automated tests exist, independently of whether they were run; no tests or test target were found, so there is no coverage to list |
| **Verified in this task** | Limited to the successful static checks in Section 12; does not establish an app build or runtime result |
| **Externally unverified** | Device capabilities, capture output, SDK type compatibility, location, MapKit, Photos, signing, and receiving-app behavior remain unverified except for the specific user-supplied macro runs recorded in Section 12 |
| **Experimental / Inactive** | Remaining `favorite` keys/cleanup have no UI for creating or displaying favorites; root-level PNGs are not referenced by the AppIcon manifest |
| **Planned / Not implemented** | Recommendations in Section 15 have no completed implementation |

Location metadata, reverse geocoding, Photos export, and third-party sharing are integrated optional paths. Optional does not mean inactive. There is no mock, fixture, demo backend, or separate experimental runtime mode.

## 2. Architecture and Lifecycle

```mermaid
flowchart TD
    App[MyApp / Scene delegates] --> UI[ContentView / LibraryView / MediaDetailView]
    UI --> Camera[CameraService]
    Camera --> AV[AVCaptureSession / PhotoOutput / MovieOutput]
    Camera --> Location[CLLocationManager]
    Camera -->|onPhoto / onVideo| Store[MediaStore]
    UI --> Store
    Store --> Files[Application Support / Media / Sidecars]
    Store --> Search[PhotoSearchIndex]
    Search --> Vision[Vision detached analysis]
    Search --> Cache[PhotoSearchIndex.json]
    UI --> Editors[PhotoEditorView / VideoEditorView]
    Editors -->|save closures| Store
    UI --> Share[UIActivityViewController / Photos activity]
    UI --> Maps[MapKit / Reverse geocoding]
```

The composition root is the `@StateObject` ownership in `ContentView`. Library and detail views receive the store through `@ObservedObject`; the store owns the search index. There is no DI container or repository protocol layer. Camera closures return `Data` or a temporary MOV URL with `VideoCaptureDetails`. Editors write through synchronous or asynchronous throwing save closures. The video callback in `CameraService` references a DTO defined in `MediaStore.swift`, so capture and storage models are not fully decoupled.

`CameraService`, `MediaStore`, and `PhotoSearchIndex` are `@MainActor`, matching the project's default actor isolation. Capture session `startRunning`/`stopRunning` execute on the `WorkCamera.captureSession` serial queue; other session configuration mainly follows the service's MainActor path. Delegate callbacks are `nonisolated` and dispatch back to MainActor. Vision analysis and photo thumbnails use utility detached tasks; these are not system background-processing jobs.

Opening Library cancels the countdown, closes camera control panels, and calls `camera.stop()`. Returning to the active camera starts it again while preserving zoom. Entering the background only marks zoom for reset on the next start; the source does not stop the session for every scenePhase transition away from active. During recording, `stop()` updates wantsRunning/location state and then returns early without automatically ending recording. Background recording must not be treated as verified.

`CameraOrientationPolicy` tracks Library presentation by scene ID: the camera page stays portrait, while Library allows all orientations. Preview uses the sensor-to-portrait angle. Photos and videos use the capture rotation coordinator's horizon-level angle at the shutter or recording start. Button labels rotate with handset orientation and retain their last readable direction when the handset lies flat.

The preview controller observes app/capture interruptions and runtime errors, covering stale frames with black. On foreground recovery, `CADisplayLink` waits up to three seconds for a running, uninterrupted session and a previewing layer. A timeout leaves the cover visible; a subsequent session-start or interruption-ended event retries. This protects preview presentation; it is not a complete session-reconstruction mechanism.

## 3. Project Structure and Core Components

| Source/configuration | Components and responsibilities |
| --- | --- |
| [MyApp.swift](Work%20Camera/MyApp.swift) | `MyApp`, `CameraAppDelegate`, `CameraSceneDelegate`, `CameraOrientationPolicy`; scene creation and orientation ownership |
| [ContentView.swift](Work%20Camera/ContentView.swift) | `ContentView`, `ExposureRuler`, `CameraGrid`, `LibraryView`, `MediaDetailView`, Reports/templates, Info summaries, thumbnails, playback/zoom UIKit bridges, share payload, and Photos activity |
| [CameraService.swift](Work%20Camera/CameraService.swift) | `CameraService`, capture/location delegates, `PhotoMetadataCustomizer`, `CameraPreview`, its controller, and layer view |
| [MediaStore.swift](Work%20Camera/MediaStore.swift) | `MediaItem`, `MediaAlbum`, `VideoCaptureDetails`, `MediaStore`, and storage errors |
| [PhotoSearchIndex.swift](Work%20Camera/PhotoSearchIndex.swift) | `PhotoSearchRecord`, `PhotoSearchCache`, `PhotoSearchIndex`; Vision, search, and cache |
| [PhotoEditorView.swift](Work%20Camera/PhotoEditorView.swift) | `PhotoEditorView`, `CropSelection`, `MarkupCanvas`, `ResizingMarkupCanvas`, and HEIC encoder |
| [VideoEditorView.swift](Work%20Camera/VideoEditorView.swift) | `VideoEditorView`, scrub/trim/crop controls, video composition, and HEVC exporter |
| [project.pbxproj](Work%20Camera.xcodeproj/project.pbxproj) | One application target, Debug/Release configurations, synchronized file group, generated Info.plist, and signing settings |
| [Workspace](Work%20Camera.xcodeproj/project.xcworkspace/contents.xcworkspacedata) | A `self:` project reference, with no additional projects |
| [AppIcon manifest](Work%20Camera/Assets.xcassets/AppIcon.appiconset/Contents.json) | References `AppIcon-1024.png` in the same directory as an iOS universal 1024 × 1024 entry |

`PBXFileSystemSynchronizedRootGroup` points to `Work Camera`; source/resource build phases do not manually enumerate the Swift files. The frameworks phase has no third-party entries. The repository contains no tests, scripts, CI, package manifests, lockfiles, environment examples, or separate entitlement file.

## 4. Data Flow

### 4.1 Photo Capture

1. `ContentView` installs `onPhoto`/`onVideo` callbacks and starts the camera. The service requests camera and microphone permissions in sequence, using wantsRunning guards to prevent a cancelled start from continuing.
2. Initial configuration selects the physical back lens for 1×, rejects virtual camera inputs, and attaches photo output and an available audio input. Photo/video mode determines the preset and whether movie output is attached.
3. The shutter calls `takePhoto` directly or uses a countdown protected by a UUID guard. Leaving the active state, entering Library, or switching to video cancels the countdown.
4. The service checks ready/busy/recording state, the HEVC photo codec, and rotation support. It snapshots a valid location and requests the active format's maximum photo dimensions with `.quality` prioritization.
5. The delegate obtains the HEIC file representation. When location is available, only the metadata dictionary is replaced, preserving the capture image and attachments.
6. `MediaStore.savePhoto` allocates a filename, atomically writes a staging file, publishes it as HEIC using a hard link, removes staging, and reloads the library. It does not re-encode the capture as JPEG.

Maximum photo dimensions are selected by pixel count from the current `activeFormat.supportedMaxPhotoDimensions`. There is no algorithm that searches all formats to select 48 MP. Diagnostic logs enumerate other high-resolution formats without selecting them.

### 4.2 Video Recording

Video configuration first tries 4K/1080p 10-bit bi-planar HLG BT.2020 formats supporting 30 FPS, with HEVC. If none has a compatible codec, it tries 8-bit bi-planar sRGB SDR formats, ordered by 4K, 1080p, 720p, then remaining sizes by pixel count. SDR prefers HEVC and permits H.264. Every candidate uses `.inputPriority` and a fixed `1/30` frame duration, with codec availability re-evaluated after applying its format. Configuration state is invalidated before selection. Recording start checks the selected device, format, color space, codec availability, and rotation support; a stale or unsupported configuration gives an actionable error. These checks do not prove runtime camera or file compatibility.

`recordingCaptureDetails` snapshots the date, device hardware identifier, valid location, and available physical-lens details. Recording uses a physical camera input; camera/zoom switching is blocked while recording. The retained metadata guard omits lens/aperture/focalLength if given a virtual device, but the current capture-input paths reject such devices. Physical-camera focal length is the nominal 35 mm equivalent, without video crop/zoom calculations.

Movie output metadata includes make, model, an ISO 8601 date using the current time zone, and valid coordinates as an ISO 6709 string. It replaces only app-owned top-level identifiers and does not write Dolby Vision track metadata itself. MOV output is first generated in the temporary directory. The completion callback considers either a nil error or `AVErrorRecordingSuccessfullyFinishedKey == true` successful; only unsuccessful completion removes the temporary recording. A successful callback asks the store to write captureDetails to the INFO sidecar before moving the MOV into Media. A failed move attempts to remove the new sidecar. A saved movie is inserted into items even if reload fails. The UI save callback attempts to remove the temporary MOV on failure.

### 4.3 Library, Search, and Rendering

`load()` creates the Media directory and enumerates nonhidden regular files whose names exactly match `^IMG_[0-9]{4}\.(HEIC|MOV)$`. It sorts by filesystem creation date descending, reads modification dates, and reconciles the search index. Albums stay in memory after their first successful load. There is no filesystem watcher or cross-process synchronization.

Library filters by media type or album. Entering Search calls index `start`; subsequent store reloads and photo overwrites reconcile it. Photos display the full image with 1–5× UIKit scroll-view zoom. Left/right swipes navigate within the current photo list only at fitted scale, without wrapping at the ends. Bounds or image changes reset fitted zoom.

Photo thumbnails use ImageIO in a detached task with a maximum edge of 256 pixels. Video thumbnails use AVAssetImageGenerator at the first frame. There is no persistent thumbnail cache. Video detail starts playback muted, updates the UI with a 0.25-second timer, and normally hides controls after three seconds. Seeking, modals, and errors delay hiding.

### 4.4 Reports, Info, and Sharing

Reports are saved atomically as UTF-8 TXT, normalizing CRLF/CR to LF. Video Caption and Report share the TXT sidecar without rewriting the MOV description. Keywords are saved in INFO JSON without rewriting MOV metadata. When no annotation sidecar is present, Info can display the movie's description/keywords as a fallback. An unchanged fallback is not a saved sidecar and is not guaranteed to appear in the shared Report.

Photo Info uses ImageIO to expand metadata and summaries. Video Info uses AVAsset/track metadata, formatDescriptions, size/transform, duration, and nominal frame rate, with sidecar fallback. When movie lens identity is present, it does not mix that identity with the sidecar's starting aperture/focal length. Missing values display Not provided. HDR classification uses the codec, `dvcC`/`dvvC` atoms, and transfer function to distinguish Dolby Vision, HLG, PQ, SDR, or unknown; it is not inferred from UI labels.

MapKit reverse geocoding resolves saved coordinates using the current locale. Requests are cancellable, and results must match the active request identity. Failures leave coordinates visible. There is no persistent address cache or retry/backoff.

Sharing first attempts to save the Report. Photos use a UIKit renderer to generate an opaque temporary JPEG at quality 1.0, using UIImage size/scale without deliberate downscaling. The HEIC metadata dictionary is not copied. Videos use the library MOV URL. A nonempty normalized Report is a separate activity item. Temporary JPEGs are removed after the share sheet dismisses. Receiving-app dimensions, captions, line breaks, and metadata retention require external verification.

The custom `SaveOriginalMediaActivity` excludes the system `.saveToCameraRoll` action. After requesting `.addOnly`, it adds the current library file through `PHAssetCreationRequest.addResource`, with `shouldMoveFile = false`. Photo location comes from HEIC GPS; video location comes from the capture sidecar. It does not request the current location. If the file was previously overwritten, this “original” library file is the edited file, not an immutable capture backup.

## 5. Data Models, Persistence, and State

| Model/storage | Structure and boundaries |
| --- | --- |
| `MediaItem` | URL, kind, createdAt, modifiedAt; id is the filename, not a UUID; rebuilt from the filesystem on each load |
| `MediaAlbum` | UUID id, name, `Set<String>` memberKeys; stored in `Media/Albums.json` |
| `VideoCaptureDetails` | Codable date, device, optional lens/focal length/aperture/coordinates; stored in INFO's `captureDetails` field |
| `<stem>.INFO.json` | JSON dictionary that may contain captureDetails/keywords; keyword writes preserve unknown fields and do not overwrite malformed JSON |
| `<stem>.TXT` | Report/video Caption, UTF-8, LF line endings |
| `PhotoSearchCache` | `PhotoSearchIndex.json` at the Application Support root, `version = 1`, records keyed by filename |
| `PhotoSearchRecord` | fingerprint, OCR text, labels, complete; partial results can be retained |
| `ReportTemplate` | UUID, name, content; a Codable array in UserDefaults `reportTemplates.v1` |
| UserDefaults | `nextCaptureNumber`, `shutterSoundEnabled`; also residual cleanup for `favorite.<filename>.<creation timestamp>` |
| View state | Selection, filter, player, editor/share/Info/Report modals, and annotation drafts mainly use SwiftUI `@State`; no centralized reducer |

Media lives in `FileManager`'s Application Support directory under `Media`; temporary MOV/JPEG files use the system temporary directory. There is no database, Keychain, cloud container, or sync adapter. Media/Albums/INFO have no schema version or migration runner. The template key and search cache have v1 markers but no upgrade migration. Undecodable or incompatible search caches are ignored and rebuilt. Initial cache-read failures do not set cacheError; persistence failures produce a UI warning.

Album member keys combine the filename and filesystem creation timestamp to avoid inheriting old membership after normal filename reuse. This depends on stable creation dates; it is not a content hash or immutable capture ID.

## 6. Important Logic

### Filenames, Albums, and Deletion

The allocator starts at the next number in UserDefaults and cycles through 1–9999, checking at most 9,999 slots. A matching HEIC, MOV, TXT, or INFO.json with the same stem occupies a slot. Finding a slot immediately advances the counter, so a failed write can still advance it. This is not a cross-process lock. The loader regex can also accept `IMG_0000`, although the allocator never generates it.

Album names are trimmed and reject empty names, case-insensitive duplicates, and the reserved name `Not in an Album`. Media can belong to multiple albums. Unassigned items are the complement of all memberKeys, not a separately persisted album. Delete Album Only keeps media; deleting an album with its media removes the files and their membership in other albums.

Single-item deletion removes media first, then independently attempts album persistence, Report deletion, INFO deletion, and directory refresh. A failure in one cleanup step does not skip the others; failures are collected in an incomplete-deletion error. A defer removes deleted media from items and reconciles the index. Reconciliation loads and purges persisted OCR even before Search is opened, while Vision jobs remain gated until Search starts. Unreadable/unsupported caches are preserved with an error, and failed cache writes remain pending for a later reconciliation. Multi-file deletion is not transactional: filesystem failures can still leave partial changes or orphaned data, and a batch stops on its first thrown item error. There is no trash or rollback.

### Zoom, Macro, Exposure, and Location

Preview, photos, and videos use physical camera inputs only. `backCameraLensMetadata` prefers triple, dual-wide, dual, then wide devices solely to read lens/zoom metadata. Virtual constituent devices are filtered out of `physicalBackLenses`. Initial configuration rejects a virtual device before creating its input; `replaceVideoInput` rejects one before changing the session and reports "Virtual cameras are not allowed." Back-zoom application, the photo shutter, and recording start also reject virtual devices. No virtual-camera autofocus or recording switch-over policy is enabled.

Constituent switch-over factors multiplied by the display multiplier map physical lenses to baseZoom. If virtual metadata is unavailable, the fallback lists available physical ultra-wide and wide cameras at 0.5× and 1×. Normal zoom selection uses the last lens with baseZoom no greater than the UI factor (with a 0.01 tolerance), falling back to the first lens; device zoom is factor/baseZoom, clamped to its range. Shortcuts include physical-lens base factors and 1/2, optionally ultra-wide 0.5 and an 8× crop when a 4× telephoto is present, then are filtered, deduplicated, and sorted. These shortcuts do not all represent optical magnification. An active Auto Macro override selects the physical ultra-wide lens at the requested zoom only if its device-zoom range supports that factor.

App-controlled Auto Macro defaults to enabled. `isMacroAvailable` requires a back camera and a physical ultra-wide lens supporting continuous autofocus with minimumFocusDistance in `(0, 100]`. The existing macro button toggles it; disabling restores the normal physical lens for the current zoom. Manual zoom selection clears the macro override and begins a cooldown. The 0.5× shortcut is manual ultra-wide selection, with no automatic return to a different lens. Continuous autofocus remains enabled on the selected physical lens.

`startAutoMacroMonitoring` runs a MainActor task with weak service capture, sampling every 250 ms after session start; `stop()` cancels it, and service deinitialization also cancels the task. Monitoring requires the app to be active, a ready/running back-camera session, Auto Macro enabled, zoom at least 1×, compatible ultra-wide zoom, no photo processing or recording, and settled continuous autofocus. It resets pending decisions when these conditions are not met; a sample gap longer than 0.5 seconds restarts the dwell period. Starting/resuming, input changes, mode changes, manual zoom, toggling, and automatic switching impose a 2-second cooldown. Library return retains the current input/zoom; the existing background-reset policy clears the override when zoom resets to 1×.

Entry requires the normal physical lens's `lensPosition` to remain at or below `0.12` across eligible samples for at least 0.75 seconds. On the physical ultra-wide input, eligible autofocus readings track a stable candidate during the 2-second switching cooldown. The candidate restarts when the reading differs by more than `0.02` or the sample gap exceeds 0.5 seconds. Startup completes only after cooldown and at least one continuous second within that candidate window. During startup the ultra-wide input stays fixed and no exit baseline exists. The app then establishes the baseline as the average of the candidate and current readings, regardless of the initial autofocus travel.

After startup, candidate windows lasting at least 0.5 seconds can only lower the established baseline during the same macro-lens session, so it does not follow a subject moving farther away. Exit requires the current position to remain at or above `min(baseline + 0.04, 0.80)` for at least 1.25 seconds, then restores the normal physical lens for the retained zoom. The `0.80` upper bound is an empirical value from the supplied device traces and applies to every supported macro zoom and lighting condition. It prevents a high startup baseline from pushing the threshold above the observed distant readings; close readings reaching this cap can also cause unwanted exit. This replaces the former fixed `0.85` exit requirement. There is no acquisition-anchor invalidation or normal-lens recheck: automatic decisions are only `.enter` and `.exit`. Initial focus movement cannot itself authorize replacement.

Input changes clear startup state and the baseline. Library stop/resume retains the established baseline for the same input but discards unfinished learning samples. Focus adjustment or other ineligible states reset pending dwell and baseline candidates, without discarding an established baseline. Explicit mode/zoom/camera/macro controls retain their existing episode resets and cooldowns; background zoom reset clears the override. All automatic decisions retain the active-session, photo-processing, recording, physical-input, and supported-zoom guards.

These are uncalibrated focus heuristics. Apple documents `0` as the near end and `1` as the far end, but values are not precise distances and do not represent the same distance across lenses ([lensPosition documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)). Comparing changes on the same ultra-wide lens still cannot prove subject distance. Startup autofocus convergence and immediate subject withdrawal can produce similar readings: moving away before baseline establishment may seed a distant baseline. The `0.80` exit cap limits the resulting threshold but cannot distinguish a stationary close subject whose focus readings also reach that value. Removing the probe eliminates that preview-changing fallback, but does not guarantee stationary stability against later focus drift. An unchanged focus reading, low light, autofocus failure, and low-detail scenes can still cause missed or unwanted transitions; settled readings do not prove successful focus. Actual thresholds and stability need device validation. A failed switch attempts to restore the previous physical selection, then cools down; it never falls back to a virtual device. Recording freezes the selected physical lens; automatic selection is available in video preview before recording starts.

Exposure compensation is clamped to the hardware range within at most −2…+2 EV. The ruler rounds to 0.1 EV; photo/video modes retain separate biases. Torch is used only in video mode. When camera controls are disabled, the code attempts to turn torch off and clear device exposure bias. Shutter sound suppression is set only when the output reports support.

Location updates occur only while wantsRunning and camera authorization are true. Capture snapshots require a timestamp no more than 30 seconds old and not in the future, nonnegative finite horizontalAccuracy, and valid coordinates. There is no additional accuracy threshold. Photo GPS dates/times use UTC. EXIF capture wall-clock display does not assume a missing time zone. Movie creation dates use ISO 8601 with the current time zone; UI dates generally use the current locale. These sources do not form a unified timeline in a fixed time zone.

### Search Algorithm

The fingerprint is `filename|creation timestamp|modification timestamp`. Reconciliation removes mismatched cache entries and prunes failed fingerprints. At most one worker analyzes photos sequentially, with each Vision job in a utility detached task. There is no warm-up or media-content-hash deduplication.

Analysis starts with an EXIF-transformed thumbnail whose maximum edge is 2560 pixels, then separately performs accurate OCR, image classification, and document segmentation. OCR enables language correction and automatic language detection, preferring supported `zh-Hant`, `zh-Hans`, and `en-US`. Classification keeps the first 20 observations with confidence ≥ 0.2 and adds hardcoded Chinese/English aliases. Document results with confidence ≥ 0.5 add document/paper labels.

Each of the three requests has separate error handling. At least one successful request preserves a partial record; all three must succeed for complete status. Failed fingerprints are skipped in the current attempt; user Retry clears the failure set. There is no unlimited automatic retry or backoff. Results returned to MainActor are checked against the current item/fingerprint to reject stale results for edited, deleted, or reused files.

Query normalization uses POSIX locale folding for case, diacritics, and width, and replaces underscores with spaces. Whitespace-separated terms must all be substrings of the searchable string. That string contains only the filename and valid photo OCR/labels, excluding Reports, Captions, Keywords, and addresses. Chinese object aliases are a limited collection, not general semantic translation.

## 7. Editing and Output Ownership

The photo editor first normalizes the image through an opaque scale-1 renderer. PencilKit drawing is projected from canvas bounds onto the image. Rotation or applied cropping flattens annotations and resets the drawing. Crop corners enforce a minimum of 5% per dimension. Canvas resizing transforms the drawing to preserve relative annotation positions.

The HEIC encoder preserves original EXIF/TIFF/GPS dictionaries, updates dimensions and orientation, removes EXIF MakerNote, and uses quality 1.0. Re-rendering/re-encoding is not guaranteed lossless. The store validates a complete single-image HEIC before overwriting or adding it. Overwrite uses an atomic write, restores creation date on a best-effort basis, and updates modifiedAt/index. A new copy uses `savePhoto` without copying text sidecars or album membership.

The video editor reads the first video track, duration, naturalSize, preferredTransform, and frame duration. Minimum trim length is `min(duration, max(frameDuration, 0.1 seconds))`; selection uses a timescale of 60,000. Composition normalizes track orientation, then applies quarter-turn rotation and cropping. Each output dimension is `max(2, floor(dimension × selectedFraction / 2) × 2)` to produce even dimensions.

Scrubbing displays decoded frames up to 720 × 720. A single in-flight seek retains the newest pending target. During dragging, time tolerance is at most 0.1 seconds; drag completion performs a zero-tolerance player seek. `seekGeneration`, task cancellation, cancelPendingSeeks, and generator cancellation prevent old work from affecting a new preview. Individual decode failures among the eight timeline thumbnails leave placeholders.

Export uses `AVMutableComposition`, `AVAssetExportPresetHEVCHighestQuality`, and MOV, copying asset top-level metadata. When keeping audio, each track's overlap with the trim selection is aligned to the output start. There are no explicit HDR color properties or Dolby Vision preservation settings, so HDR/Dolby Vision preservation after editing cannot be claimed. The editor cleans temporary export files in defer and releases its reader before commit. Save failure attempts to restore the playback item.

The store asynchronously validates positive duration and a video track, then rechecks that the source exists after suspension. Overwrite replaces the original with a staged MOV and keeps sidecars. A new copy first validates existing INFO, copies INFO/TXT, then publishes the movie through a hard link. Failure cleans up copied sidecars. New items initially use `Date()` without an immediate `load()`, so a later reload can produce different filesystem dates. Original album membership is not copied.

## 8. External Dependencies

| Framework/system API | Purpose | Status/version |
| --- | --- | --- |
| SwiftUI, UIKit, Combine, Foundation | UI, state, bridges, timers, files/JSON/UserDefaults | Required; provided by the Xcode SDK, with no pinned framework versions |
| AVFoundation, AVKit, CoreVideo | Capture, metadata, playback, 10-bit format detection, composition/export | Required; capabilities depend on SDK, OS, and hardware |
| ImageIO, UniformTypeIdentifiers | HEIC metadata, thumbnails, validation, and encoding | Required |
| Vision | Local OCR, classification, and document segmentation | Required for search; recognition results need device validation |
| PencilKit | Photo markup | Required for photo editing |
| CoreLocation | Optional capture location | Permissions and location availability unverified |
| MapKit | Optional coordinate maps and reverse geocoding | Apple system APIs; external service behavior unverified |
| Photos | Optional addition of library files to system Photos | Requires add-only authorization and successful system import |
| Darwin | `uname` for hardware identifiers | System-provided; names resolved through a local mapping |

No third-party package, HTTP provider adapter, custom endpoint, or unofficial API was found. The DeviceKit URL in `MediaStore.swift` is a data-source comment, not a runtime network request or installed dependency. Mapping completeness and source licensing were not externally checked; unknown identifiers retain their original names.

## 9. Configuration

The only application target is `Work Camera`. Its legacy productName is `MyApp`, but `PRODUCT_NAME = $(TARGET_NAME)` and the product reference is `Work Camera.app`. There are no additional or test targets. Debug/Release target settings consistently specify iPhone, iOS/Simulator platforms, and disabled Mac Catalyst support. The project-level iOS deployment target is `27.0`. Remaining deployment values for other operating systems do not expand supported platforms.

Settings include `SDKROOT = auto`, `SWIFT_VERSION = 5.0`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, member import visibility, and generated localization strings. Debug enables testability and `-Onone`. Release uses whole-module compilation and disables assertions. There is no pinned compiler, minimum Xcode/host macOS version, or tool-version file.

Info.plist is generated from build settings with display name Work Camera. It includes camera, microphone, location when-in-use, and Photos add usage descriptions; scene/launch generation; and four interface orientations. There is no separate Info.plist, privacy manifest, or entitlements file. Settings such as `ENABLE_APP_SANDBOX` and `REGISTER_APP_GROUPS` exist, but no entitlement file establishes an App Group identifier or corresponding runtime use. App Groups functionality cannot be claimed as complete.

Signing is Automatic with a specific Team and bundle identifier. No private keys, certificates, provisioning profiles, or signing setup script are included. Documentation does not reproduce the Team value or credentials. Developers must select usable signing settings for physical devices.

Scheme management records `MyApp.xcscheme_^#shared#^_` and `Work Camera.xcscheme_^#shared#^_`, but the repository contains no `.xcscheme` definition. These records do not establish a shared scheme usable by CLI/CI. This task did not query schemes with `xcodebuild` or generate one.

There are no app-defined environment variables, API keys, feature flag files, or backend configuration. `DEBUG` is a build compilation condition; photo diagnostic prints are not wrapped in a DEBUG guard. Shutter sound preference uses UserDefaults; grid, timer, and camera controls mostly use transient view state.

## 10. Error Handling and Logging

- `CameraError` covers a missing back camera or session configuration failure. Other format, orientation, permission, and device-lock errors are surfaced through the service's `errorMessage`.
- `MediaStoreError` covers exhausted filename slots, invalid edited media, missing captures/albums, invalid INFO, and invalid album names. Writes preserve malformed INFO. Some read APIs use `try?` with empty fallbacks, so the UI cannot always distinguish missing and corrupt data.
- Editors present localized alerts. Individual thumbnail, geocoding, and partial metadata failures retain usable results or placeholders. There is no unified error logger.
- Report template decode failures show an error. Template persistence has no general transaction/rollback abstraction. Successful UserDefaults encoding does not establish verified disk persistence.
- Local writes commonly use atomic operations or staging, but media/sidecars/albums do not form a multi-file transaction. Initial session configuration failure also lacks complete cleanup/reconstruction and needs manual fault validation.
- Explicit stale-work guards include wantsRunning, countdown UUIDs, Vision fingerprints, movie Info URL/cancellation checks, geocoding request identity, and video seek generations. Not every asynchronous read has equivalent identity/version protection.
- There is no global retry/backoff/rate limiter. Vision manual Retry and preview-event retries are specific paths. There is no offline queue or background task scheduler.

Photo capture uses `[WorkCamera Photo]` console prints for capture ID, camera/primary names, zoom, preset, supported/requested/resolved/file dimensions, and localized errors. It also enumerates available formats with at least 48,000,000 pixels. Temporary `[WorkCamera Macro]` prints, the periodic focus-log helper, and diagnostic-only timestamps have been removed. Autofocus monitoring, startup convergence, baseline learning, thresholds, dwell periods, cooldowns, and capture/recording guards remain active. Historical macro readings in Section 12 came from diagnostic-enabled revisions. Logs do not explicitly print locations, Reports, or tokens, but there is no general redaction policy, OSLog subsystem, log rotation, or telemetry exporter. This is not a formal secure logging system.

## 11. Security and Privacy

[PRIVACY_POLICY.md](PRIVACY_POLICY.md) is the English privacy-policy source, last updated October 2, 2026. It identifies Sunny Yu and the public contact email and describes the implemented local storage, Vision search, permission, MapKit, sharing, Photos, backup, and deletion boundaries. The document is not a Privacy Manifest and is not connected to an in-app policy screen or link. Its publicly accessible HTTPS URL must be verified separately before use in App Store Connect; repository publication alone does not establish that verification.

Camera authorization is required before capture. Denied microphone permission can omit audio input during initial configuration; the source does not automatically rebuild an already configured session's audio input after permission changes. Location requests when-in-use permission and clears the latest fix on denial/failure. Photos uses add-only access in the save activity without reading the user's system library.

Media, GPS, Reports, Keywords, and OCR text are stored in local sandbox files/UserDefaults. There is no app-defined encryption, explicit file-protection attribute, Keychain, database protection policy, or backup-exclusion setting. System backups cannot be assumed disabled, nor can data be guaranteed to stay on the device. Photos import, system/user backups, and user sharing have separate external data boundaries.

Info's MapKit/reverse-geocoding path uses saved coordinates and can invoke system external services. Vision analysis has no app-defined upload API. There is no custom authentication, token store, TLS/certificate pinning, WebView, App Attest, APNs, or cloud-sync implementation. These mechanisms are not implemented for the currently absent backend paths.

Shared photo JPEGs are redrawn rather than copied with original metadata, but no byte-level privacy-scrub validation was performed. Complete metadata removal cannot be claimed. Shared MOVs and Photos file imports can retain capture metadata; Reports are separate sharing items. There is no location/text redaction UI or sensitive-content scan before sharing. Permission dialogs, external transfers, and device results were not verified in this task.

## 12. Testing and Validation in This Task

There is no XCTest/Swift Testing source, test target, test scheme, fixture, offline test suite, or CI. `ENABLE_TESTABILITY` does not establish tests. **Test-covered: no repository evidence to list.**

**Verified during the original documentation revision** was limited to:

1. Read-only cross-checking of source call paths and build settings during initial document creation.
2. Successful `git diff --check`; no whitespace errors in the existing working-directory diff.
3. Successful `plutil -lint` checks of project.pbxproj and the existing scheme-management plist.
4. Successful Python standard-library parsing of asset `Contents.json` files and workspace XML, and confirmation that the AppIcon manifest references an existing file.
5. Checks of completed documents for code fences, relative file links, source symbols/paths, consistent settings and feature descriptions, sensitive values/personal absolute paths, and Git change scope. SHA-256 comparisons during initial creation confirmed source, configuration, and asset preservation. The only observed difference was `UserInterfaceState.xcuserstate` in workspace user data; this task did not write or restore that IDE UI state file.

The English translation retains the original technical scope and evidence distinctions. Document checks and non-document file hash comparisons are repeated after translation; the initial source investigation is not represented as a new build or runtime validation.

**2026-10-02 camera updates**: The first revision prohibited virtual inputs and disabled Auto Macro. The current revision restores app-controlled Auto Macro while retaining physical-only inputs. Source inspection covers virtual-input guards, monitoring lifecycle, focus/dwell/cooldown decisions, manual controls, and capture/recording guards. Syntax-only parsing of `CameraService.swift`, whitespace/document checks, and SHA-256 comparisons of files outside the approved scope were performed. These checks do not establish SDK type compatibility or device behavior. The first syntax check's Swift launcher emitted Xcode tool-path/cache diagnostics during tool discovery; the current revision invokes the toolchain compiler directly for syntax parsing. No app build or test was requested or performed.

The user reported successful close-subject entry but no automatic exit when moving away. The follow-up revision replaces the absolute exit threshold with a learned ultra-wide focus baseline and adds focus diagnostics. The user subsequently supplied a successful 1× near-to-far run with the `+0.10` increment: the camera switched from Back Camera to Back Ultra Wide Camera, retained 1×, and returned to Back Camera at lensPosition `0.827451` with a logged baseline of `0.727` and threshold of `0.827`. This verifies that recorded run, not every lighting condition or zoom. The same syntax, whitespace/document, and out-of-scope file-preservation checks apply.

The following low-light 1× run entered macro but did not exit. Its logged baseline remained `0.753` and threshold `0.853`, while distant samples stayed around `0.808–0.827` with adjustingFocus and cooldown both false. The `+0.10` increment therefore prevented the observed samples from meeting the exit condition. The subsequent threshold-only revision changed the exit increment to `+0.04`, giving that example a threshold of `0.793`; entry, 1.25-second exit dwell, 2-second cooldown, capture/recording guards, and physical-only inputs remain unchanged. This increment applies to all lighting conditions. The lower increment makes exit more sensitive to focus changes. That threshold-only revision required both low-light and the previously successful 1× scenario to be retested.

The user then reported another low-light 1× failure with `+0.04` and confirmed immediate withdrawal as soon as macro activated. Logs showed `0.667 → 0.761 → 0.816`, a late baseline `0.802`, threshold `0.842`, and later readings around `0.815–0.827`. The acquisition loop discarded early candidates while readings rose, then seeded the baseline from a later plateau. The one-time recheck revision marked this acquisition pattern unreliable and added a single guarded physical normal-lens recheck. Source/syntax/document checks and out-of-scope file hashes were reviewed; device outcomes were still pending at that revision's delivery.

The user subsequently confirmed near-to-far success for 1× and 2× in normal and low light with the previous recheck revision. Supplied 1× low-light logs showed two ordinary baseline exits; 2× low-light logs verified `acquisition_invalidated → recheck → recheck_exit` while preserving 2×. A stationary 1× low-light trace then showed `0.690 → 0.729` initial focus travel triggering `recheck`, followed by `recheck_return`. A later startup-settling revision still failed the zero-switch requirement: a stationary `0.749–0.757` plateau crossed the initial anchor `0.690196 + 0.06`, eventually causing `recheck → recheck_exit`. The subsequent revision removed normal-lens probing and established the exit baseline from converged startup samples. The user then confirmed 1× low-light stationary stability through about 16 seconds, followed by exit about two seconds after moving away. Immediate withdrawal still failed: baseline `0.8156863`, threshold `0.856`, and distant readings approximately `0.812–0.831`. The current revision changes only the exit threshold formula to `min(baseline + 0.04, 0.80)`, retaining convergence, dwell, physical-only inputs, and capture/recording guards. The empirical cap separates the supplied stationary and distant readings. With that revision, supplied 1× low-light logs verified immediate withdrawal with threshold `0.800` and exit at `0.827451`; another run stayed on ultra-wide through the 15-second stationary hold and exited at `0.83137256` after withdrawal. The user also reported successful 1×/2× normal-light retests, 2× low-light entry/exit, and no recording-time lens switching when moving closer or farther. No separate 2× low-light stationary-hold or immediate-withdrawal trace was supplied. These are specific device results, not universal validation. Temporary macro diagnostics were then removed without changing the switching conditions; the cleanup received syntax, diff, source, document, and scope checks only, with no app build or test performed by the agent.

Existing tools can be used manually from the repository root:

```sh
git status --short
git diff --check
plutil -lint "Work Camera.xcodeproj/project.pbxproj"
```

These are local checks used for documentation work, not repository scripts. The Python checks have no project dependency or pinned Python version. No Markdown/Swift lint tool was installed. Format parsing is not Swift typechecking or building, particularly for UIKit overrides and newer SDK APIs.

**Build/Test passed in this task: none; not run.** No app build/test, Simulator/CoreSimulator, physical-device installation, archive, signing, deployment, or external-service operation was performed. Manual Xcode build/run setup is described in the README. Without a checked-in scheme, no CLI build/test command assumes one exists.

**Remaining manual validation**: Debug/Release compilation and a device smoke check of the diagnostic cleanup; permission denial/reauthorization; requested/resolved/file photo dimensions for each lens; Auto Macro button toggling, other supported zooms/devices, low-detail scenes, autofocus hunting, and Library resume while subject distance changes; separate 2× low-light stationary-hold and immediate-withdrawal scenarios beyond the reported entry/exit result; unsupported ultra-wide zoom; confirming physical inputs throughout preview, photos, and videos with no Triple/Dual capture; photo-processing switch guards; front/back and photo/video transitions; Library resume and background zoom reset; movie formats/HDR atoms; rotation; interruption recovery; post-edit codecs/metadata; Photos file/location imports; and receiving-app captions, line breaks, and file handling. The reported macro and recording passes above do not establish these remaining cases. No agent-run Build/Test or device validation was performed.

## 13. Known Limitations and Technical Debt

- Tooling/platform: iOS `27.0`, newer APIs, and the synchronized project format require compatible Xcode. No toolchain is pinned or scheme shared, and key source/icon files remain untracked. A Git checkout may not reproduce this working directory.
- Capture: There is no JPEG capture fallback; video now has an 8-bit SDR HEVC/H.264 fallback. The active format's maximum dimensions do not establish 48 MP on every lens. MovieFileOutput Dolby Vision output and edited HDR retention require actual file evidence. Auto Macro's lens-position thresholds are uncalibrated and cannot measure distance; they may misclassify low-light/low-detail scenes. Lens switching pauses during photo processing and recording, and unsupported ultra-wide zoom prevents automatic entry.
- Lifecycle/concurrency: Directory scans, JSON/media writes, and full-photo rendering occur on MainActor; large libraries/images may block UI. Capture start/stop use a separate queue from other session mutations, without a fully serialized configuration abstraction or interruption-reconstruction state machine.
- Persistence: There are 9,999 stem slots and no capacity prediction, rollback transaction, recovery journal, versioned migration, or import/backup tool. Orphaned sidecars can block allocation. Best-effort creation-date restoration can affect album identity.
- Cache/search: The mtime-based fingerprint is not a content hash. Vision labels/aliases are limited and can misclassify. There is no video-content or Report/Keywords search. Each result rewrites the complete JSON cache, without a database incremental index or persistent thumbnail cache.
- Editing: Photos are re-encoded with MakerNote removed; new photo copies omit text sidecars. Video copies retain annotations but not album membership. capturedAt/top-level metadata may not describe the edited timeline. There is no explicit HDR-preservation policy.
- UI coupling: `ContentView.swift` concentrates camera, Library, templates, metadata, MapKit, Photos, and sharing in about 3,700 lines, with limited independently testable boundaries. Hardcoded hardware/lens mapping completeness is unverified. Residual `favorite` cleanup is not a feature.
- External state: The signing Team is not portable. Photos, map services, location, and third-party receiving-app availability cannot be established from the repository. There is no project-wide license or mapping-data license document.

## 14. Design Decisions and Trade-offs

The following designs are supported by source. Historical motivations without a separate design record are not inferred.

- Local files with sidecars separate media from Reports/Keywords, avoiding movie re-encoding for text changes. The trade-off is multi-file consistency, orphan handling, and migration work.
- Capability or validation failures stop the operation: HEIC, compatible HDR/SDR formats and video codecs, rotation, edited-media checks, and malformed INFO write rejection have guards. This avoids silently changing the capture contract but narrows supported devices. Not every failure guarantees transactional rollback.
- Physical-only capture selects normal lenses by baseZoom and rejects virtual session inputs. App-controlled Auto Macro uses a normal-lens entry threshold and an exit baseline established only after ultra-wide startup convergence, with dwell times and cooldowns. The normal-lens probe has been removed. Virtual devices supply lens/zoom metadata only. The empirical `0.80` exit cap limits thresholds learned during immediate withdrawal. The trade-off is device-specific calibration and possible unwanted exit if a close subject sustains focus readings at that cap; switching pauses during photo processing and recording. Recording retains its physical input, and video sidecars describe that lens without crop/zoom-adjusted focal lengths.
- Local Vision with a rebuildable cache avoids an app-defined recognition provider. Partial results remain searchable, and fingerprints reject stale work. Recognition limits and local resource costs remain.
- JPEG sharing and original-library-file Photos import provide separate activity-payload and file-import paths. Destinations can transcode, so third-party original quality or caption behavior is not guaranteed.
- Editor save closures separate rendering/export from storage commit. The store owns filename and sidecar management, but URLs, Apple metadata, and capture DTOs remain directly coupled. There is no implemented provider-neutral interface.

## 15. Future Development

All items below are **Planned / Not implemented (recommended directions)**. This task did not change source or configuration.

- Add a testable filesystem dependency at the `MediaStore` boundary and tests for filename exhaustion, corrupt JSON, partial deletion, and sidecar rollback. Preserve the rule against silently overwriting malformed metadata.
- Extract template, metadata, and sharing components from `ContentView.swift` while preserving the composition root, MainActor UI ownership, and editor save callbacks. Avoid adding provider credentials or external side effects directly to UI code.
- Consolidate capture session mutations under clear ownership/queue rules and add verifiable interruption/permission recovery. Preserve location snapshots, movie lens semantics, and format guards.
- Add versioned migrations and recoverable commits for Media, Albums, and INFO with stable capture IDs. Preserve original media and unknown sidecar fields rather than discarding existing data.
- Extend annotation search or cache efficiency through `PhotoSearchIndex.matches`/reconciliation while preserving local analysis, stale-result guards, and bounded concurrency. Cloud recognition would require separate user-consent and credential boundaries.
- Add a shared scheme, toolchain documentation, license, and CI/tests under separate approval for the corresponding settings. Before extending HDR export or sharing redaction, define the output contract and validate actual files/devices; UI wording is not evidence of completion.

## Submission Reliability Update — 2026-10-02

Implemented recording-success classification, SDR/codec fallback, pre-Search persisted OCR cleanup, and independent sidecar deletion attempts. Validation for this update is limited to Swift syntax parsing, source review, scope comparison, and `git diff --check`. No application Build/Test, simulator, device, archive, signing, or upload validation was performed. See [MANUAL_VALIDATION.md](MANUAL_VALIDATION.md) for pending device acceptance scenarios. HDR/Dolby Vision preservation after editing remains unverified, and the editor exporter was not changed in this update.
