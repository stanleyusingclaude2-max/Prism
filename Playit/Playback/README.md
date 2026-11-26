# Playback implementation

`PlaybackController` is the `@MainActor` observable UI API. `PlaybackSurface` is a
`UIViewRepresentable` that always returns its controller's persistent Metal view.
The playback position is published separately by `PlaybackClock` (see below).
Start with `.task { await controller.load() }`, and call `stop()` when the player
is dismissed. Changing between portrait and landscape should change the layout
around that same surface, rather than creating a second simultaneous surface.

## Native dependency

The app links the **MPVKit** product (LGPL, not MPVKit-GPL), pinned by the project
to MPVKit commit `98c3453e252922e3136422da3fbb2e341ed9edc8`
(`1.1.0-n9.0.2`). Its C module is `Libmpv`.

Metal setup follows the upstream iOS example: `gpu-next`, `vulkan`, `moltenvk`,
and a retained `CAMetalLayer` passed through the int64 `wid` option. Hardware
decoding uses VideoToolbox when available; FFmpeg/libmpv handles demuxing and
software fallback for other supported codecs and containers. This is the
actual playback backend for MP4/MOV/MKV/AVI and other imported video types,
not a file-extension claim layered over AVPlayer.

Sources consulted:

- https://github.com/mpvkit/MPVKit/blob/98c3453e252922e3136422da3fbb2e341ed9edc8/Demo/Demo-iOS/Demo-iOS/Player/Metal/MPVMetalViewController.swift
- https://github.com/mpvkit/MPVKit/blob/98c3453e252922e3136422da3fbb2e341ed9edc8/Demo/Demo-iOS/Demo-iOS/Player/Metal/MetalLayer.swift
- https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/client.h
- https://github.com/mpv-player/mpv/blob/v0.41.0/DOCS/man/input.rst

## Seeking and real frame stepping

1. `beginScrubbing()` records whether playback was running and pauses audio/video.
2. `scrub(to:)` updates the UI position immediately and sends a seek request to
   the serial decoder queue. `PlaybackSeekCoordinator` (PlayitCore) keeps at
   most **one in-flight seek** and **one latest waiting target**. New waiting
   positions replace obsolete ones. During a playing scrub, a large move can
   preview a nearby keyframe. After 120 ms without a newer target, the same
   position is refined exactly. Paused inspection uses exact previews while
   exact seeks are fast.
3. Long videos usually have long GOPs, and an exact frame then means decoding
   up to several hundred frames from the previous keyframe. `ExactSeekCost`
   follows how long exact seeks take for the open file. Once they average
   200 ms or more, every preview uses keyframes, a move smaller than 0.75 s
   keeps the picture until the pointer rests, and a newer target replaces an
   exact preview that is still decoding: mpv abandons a seek when the next one
   arrives. Keyframe previews and final commits are never replaced, so the
   picture keeps moving and the last target always lands.
4. `endScrubbing(at:)` enqueues a final `seek <seconds> absolute+exact` request.
   When that exact frame is already being decoded by a refinement, the
   refinement becomes the commit; when it is already on screen, the commit
   finishes without another decode.
5. Seek completion uses `MPV_EVENT_SEEK` followed by
   `MPV_EVENT_PLAYBACK_RESTART`. mpv replies to an async `seek` command when it
   queues the seek, before the seek starts, so a seek event counts only after
   the running command's reply. Events of a replaced seek arriving late cannot
   complete the newer one.
6. Only after the final selected frame is decoded does the controller leave
   scrubbing mode and restore the pre-drag playback state. An explicit pause
   or background transition invalidates a previously queued resume request.

`stepFrame(1)` and `stepFrame(-1)` issue libmpv's native `frame-step` and
`frame-back-step`. They do not use nominal FPS or assume constant frame duration.
Backwards stepping can take longer for files with long GOPs or variable frame
rates; the actual decoder determines the preceding frame.

The thin timeline uses a 44-point touch target. The **main viewport** is always
the actual decoder surface, including while scrubbing; the minimal controls do
not add a second thumbnail decoder.

### Horizontal dragging on the video

The persistent render view recognizes a one-finger horizontal pan anywhere in
its video/black-margin viewport. Real overlay buttons and the timeline retain
their own touches. Seeking is disabled while the picture is magnified; one finger
then pans the image instead. `ScreenSeekState` captures the starting playback time and
viewport width; one full width maps to the clip duration, capped at 60 seconds.
Every target is relative to that same origin, so reversing the finger does not
accumulate drift. Targets clamp to the clip boundaries. A custom continuous
recognizer uses `ScreenSeekDirectionLock`: six points of mainly horizontal
movement locks seeking, ambiguous early movement remains pending, and only a
clearly vertical gesture is rejected. This replaces UIPan's one-shot
`shouldBegin` direction rejection, which lost slow or slightly slanted touches.

`beginScreenSeeking` / `updateScreenSeeking` / `endScreenSeeking` reuse the
existing scrub queue and actual video preview. The time/delta HUD remains
noninteractive and stays until the final frame is committed. A pan keeps itself
enabled while it owns the finger; otherwise the first published `isScrubbing`
update would cancel it. Single/double taps wait for drag failure. Long-press
movement tolerance is six points. Only the hold/drag recognizer pair may
recognize simultaneously: if a stationary hold becomes a drag, its original
rate and playing/paused state are restored before seeking takes ownership,
and the hold is then disabled for the remainder of that touch.

`isScreenSeekTouchActive` becomes false at finger-up, independently of the
decoder's final frame. A new drag can therefore start while an earlier commit
is pending, anchored at the latest target time. `ScreenSeekSessionState` keeps
the original playing/paused intent across these consecutive drags and rejects
stale commit UUIDs. The engine preserves its in-flight seek while replacing
the session and latest pending target, so completion events cannot be confused
with a cancelled/restarted decoder request.

Normal finger-up restores the saved playing/paused state after the final exact
seek. Cancellation, viewport-size change, locking, backgrounding or audio
interruption invalidates the scrub session and pauses instead; stale commits
cannot restore their saved resume intent. Twenty-three actual Core tests cover
the relative-time mapping, multi-sample direction lock, consecutive sessions,
stale commits and boundary/invalid-input handling.
UIKit recognition, visible-control hit testing and decoder preview latency
still require a physical iPhone.

## Fullscreen and video orientation

Fullscreen is an explicit UI state, independent of the current device geometry.
The same Metal surface expands to the entire screen; controls and navigation
move into overlays instead of reducing the video area. `keepaspect=yes`,
`panscan=0`, and `video-zoom=0` preserve the complete image without stretching
or automatic cropping. Different screen/video aspect ratios can retain necessary
letterboxing.

`PlayitCore.VideoDisplayGeometry` resolves aspect-corrected display dimensions
and the remaining metadata rotation. In mpv 0.41, `dwidth/dheight` alias
`video-out-params/dw/dh`; they do **not** apply `video-out-params/rotate`.
Post-filter rotation is applied once, so a filter that already rotates the
picture is not rotated a second time. A known source rotation plus source
display aspect is the fallback. Encoded w/h without a known rotation is
insufficient to choose a fullscreen direction.

Since 0.3.1 the player always uses the whole screen in both orientations; the
controls alone respect the safe area, and the status bar and home indicator hide
with them. "Fullscreen" therefore only means a landscape session: the rotate
button appears for wide video on an upright phone. Portrait and square video
already fill an upright phone and show no button; a portrait video that arrives
in a landscape session (switching videos) ends the session. The session ID lives
in `PlaybackSessionView`, so consecutive landscape videos reuse it instead of
rotating back to portrait and forward again. If metadata is not ready, no button
is shown, instead of guessing landscape. Metadata
arrival later triggers the correct request. Shrinking fullscreen restores the
scene's previous interface orientation and allowed rotation mask. The app
delegate must use `PlayitOrientationAppDelegate` for these per-session masks.

The actual geometry helper has 14 XCTest cases covering portrait, landscape,
90°/270° rotations, squares, output/source precedence, aspect correction,
missing metadata, invalid dimensions and rotation normalization. Scene rotation
and immersive safe-area behavior still require an Xcode/iPhone run.

### Stable rendering while playing and paused

The pinned MPVKit MoltenVK backend only reads `CAMetalLayer.drawableSize` in
its `reconfig` callback. Its `control` callback always returns `VO_NOTIMPL` and
does not deliver host resize events. `gpu-next` caches its destination rectangle
until a resize/reconfig; even if Vulkan recreates a swapchain automatically,
that does not update the cached rectangle. Resizing the layer's drawable to the
new phone orientation can therefore leave the image in an old viewport, or
stretch the last presented image differently while paused.

The render target is chosen before decoder startup from screen pixels, physical
memory, Low Power Mode and thermal state. It ranges from 1536² to 4096² and
stays fixed through the playback session. `VideoSurfaceLayout` maps that square layer into the current view so
its centered video rectangle at normal zoom is exactly the complete, centered
aspect-fit rectangle. At normal zoom the parent view clips only the square's
generated black margins. A portrait/landscape transition changes only
the square layer's point frame, always by a uniform scale. It does not resize
the GPU target, reload the file, seek, or change playback state.

The layer's `contentsScale` is derived from `drawableSide / squarePointSide`.
MoltenVK tests whether the drawable extent
also matches `bounds × contentsScale`; keeping both equal avoids reporting a
suboptimal surface and repeatedly recreating the swapchain. Core Animation
still composites the uniformly scaled layer into the normal native view.

`PlaybackController` applies newly received display geometry and immediately
lays out the existing view, so a paused image does not wait for another decode
tick to be positioned correctly. `sub-use-margins=no` keeps text subtitles in
the video rectangle rather than in black margins that may be outside the view.
`sub-scale-with-window=no` sizes plain text relative to the actual video height,
avoiding the square target's extra height inflating landscape-video subtitles.
ASS retains its normal authored styling and default video-relative scaling;
no forced style or stripping override is introduced.
The memory tiers bound swapchain allocation. When the library already knows the
video's pixel size, the target also stays within what that source needs (at
least 80% of the screen's long side), so a 1080p video no longer renders into a
3328² target on an iPhone 15 Pro. Plain-text subtitle size follows the video
height; the player multiplies the chosen subtitle size by 1.5 when a landscape
video is watched on an upright phone. Prism uses sRGB output with
BT.2390 tone mapping for HDR input. The first-frame and seek timing logs are
under `com.playit.app / PlaybackTiming` in the system console. HDR appearance,
latency and GPU memory use remain part of the real-device checks.

The actual surface-layout helper has 16 XCTest cases covering centered fit,
full-image containment, square-target mapping, portrait/landscape/rotated
content, unknown metadata, invalid bounds, centered 2× zoom, restoration and
the fixed natural Metal extent at both zoom levels.
These are geometry tests, not a Metal runtime validation; play/pause transitions
still need real-device confirmation.

### Pinch zoom

0.3.1 replaced double-tap zoom with pinch zoom. A double-tap recognizer forced
every single tap to wait about 0.3 s for a possible second tap; without it the
controls toggle as soon as the finger lifts.

`PlayitCore.VideoZoomState` keeps the magnification (1–4×) and the offset of the
image centre from the viewport centre. Each pinch increment first follows the
fingers' centroid, then scales around it, so the image point under the fingers
stays there. `VideoSurfaceLayout` accepts the offset and clamps it so a magnified
image never uncovers an edge it covered; at 1× the offset has no effect. A pinch
released below 1.08× snaps back to the complete image. One finger pans while
magnified; seeking and video switching are disabled until the image is restored
by pinching back or with the "还原画面" pill. Zoom uses a uniform layer
transform only: it never resizes the square drawable, seeks, or changes playback
state. VoiceOver keeps a custom action for a centred 2× view.

## Minimal controls

### Playback clock

mpv reports `time-pos` for nearly every displayed frame. Publishing it on the
controller re-rendered the whole player 24–60 times a second. `currentTime` is
now a plain property; `PlaybackClock` publishes the time and only
`PlaybackTimeRow`, the timeline and the drag preview observe it. While the
controls are hidden, the clock publishes only during scrubbing. The time shows
milliseconds only while paused, frame stepping or dragging, in system fixed-width
digits (D-DIN's figures are proportional).

### Resume and end of file

The library stores a resume position in its catalog (`playbackPosition`,
`lastPlayedAt`). `PlaybackResumePolicy` remembers positions of videos of 15 s or
longer, ignores the first 3 s and the last 5% (at least 3 s), and forgets a
position when the file is replaced. The position is saved when the player closes,
switches video, goes to the background or reaches the end. A resumed file starts
through mpv's `start` option, so frame 0 is never shown first; looping still
returns to the real start.

The "播完后" preference chooses stop, loop the file, or play the next entry. An
active A–B interval takes precedence over file looping.

### System playback controls

`NowPlayingSession` registers play, pause, toggle and position commands with
`MPRemoteCommandCenter`, plus next/previous when the list has more than one
video. Handlers hop to the main actor. Now Playing information is updated on
state changes (not per frame); the system extrapolates elapsed time from the rate.
Only the newest session owns the shared commands, so a stopping player cannot
disable its successor's controls.

### Controls

`PlaybackChromeState` owns visibility and a monotonic three-second deadline.
Ready playback can auto-hide; tapping the video toggles controls. Pausing
reveals them once and disables auto-hide, while still allowing a manual toggle
to inspect a frame. Scrubbing, settings, loading, errors, inactive scenes and
VoiceOver retain controls. A temporary 2× hold preserves the previous visibility.
Locked playback keeps only a separate unlock action.

The top and bottom overlays remain mounted with zero opacity when hidden;
their hit testing and accessibility are disabled at the same time. Their fade
never resizes or remounts the video. The cancellable timer checks its generation
and the current deadline, so an obsolete callback cannot hide a freshly used
control. Speed is a chip on the player that opens an inline row of rates; the
A–B editor also opens inline above the timeline. Both keep the controls visible
until closed. End-of-file behavior, tracks, subtitle size, sharing and locking
live in the "更多" sheet. Subtitle picking and the A–B editor are deferred until
that sheet has dismissed. While locked, a tap reveals the unlock button for 3 s.

The options sheet also opens the scrollable “操作手势” guide after dismissing
itself. Guide presentation pins the controls without remounting the decoder.
The user-facing Markdown copy is [docs/GESTURES.md](../../docs/GESTURES.md).
The frame buttons use a single-film-frame outline with a thin direction arrow,
rather than a play triangle and track-skip bar.

Upstream source evidence:

- https://github.com/mpvkit/MPVKit/blob/98c3453e252922e3136422da3fbb2e341ed9edc8/Sources/BuildScripts/patch/libmpv/0001-player-add-moltenvk-context.patch
- https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/vo_gpu_next.c
- https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/vulkan/context.c

## Lifecycle and options

- All libmpv calls and event reads occur on one background serial queue.
- C event payloads are read/copied before the next `mpv_wait_event` call.
- Flag properties use `CInt`, double properties use `Double`, track IDs use
  `Int64`; C strings from `mpv_get_property_string` are freed with `mpv_free`.
- A retained callback context holds a weak engine reference. The callback is
  removed before destruction; the Metal layer stays retained until destruction.
- Backgrounding pauses playback and temporarily disables video output; returning
  to the foreground restores output without starting playback unexpectedly.
- Audio interruptions honor iOS's `shouldResume` flag and the previous state.
- Holding the video viewport temporarily plays at **2×**. The actual
  `PlayitCore.TemporaryPlaybackState` stores the pre-hold rate and playback state;
  finger-up restores both. A paused clip therefore returns to paused, and an
  existing custom rate is preserved. Repeated begin/end callbacks are harmless.
- Locking, seeking, frame stepping, choosing a rate, pausing, dismissal,
  backgrounding, interruptions and errors cancel the temporary mode, restore its
  saved rate, and keep playback paused. A simultaneous explicit play/pause tap
  applies the button's current visible intent after cancellation.
- Non-looping EOF ends the temporary mode without resuming/restarting the file.
  Looping clips retain their normal loop behavior while the hold is active.
- Built-in audio/subtitle tracks are queried from libmpv. External SRT/ASS/SSA/VTT
  files are copied into the app's sandbox before their security scope is released.

## Verification and remaining device work

The source passed a Tree-sitter Swift syntax parse on Linux, and all 19 referenced
libmpv API symbols were checked against the v0.41.0 official client header. Those
checks are **not** an iOS build, simulator run, or GPU/performance test.

Before distributing, build with Xcode, test the Metal backend on a physical
iPhone, and verify MP4/H.264, MOV/HEVC, MKV, AVI, VFR phone recordings, long-GOP
clips, backwards stepping at the first/last frames, rapid alternating scrubs,
backgrounding during a seek, external subtitles, track changes, and audio
interruptions. MPVKit's Metal support is an upstream patch. Upstream documents
an HDR/MoltenVK Metal API Validation issue; HDR and older devices need explicit
testing. Include all required third-party license notices in distribution.
