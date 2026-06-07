## ADDED Requirements

### Requirement: Per-lane frame streams

CameraKit SHALL deliver frames per lane via `subscribe(stream:buffering:)`
returning an `AsyncThrowingStream<Frame>` that yields only the subscribed lane's
`Frame` (carrying that lane's `PixelHandle`). A subscription to one lane MUST NOT
pin another lane's pool buffer. The bundled all-lanes `FrameSet` type SHALL be
removed.

#### Scenario: A lane subscription yields only its lane

- **WHEN** a consumer subscribes to `.tracker`
- **THEN** each yielded `Frame` has `lane == .tracker` and carries only the tracker
  `PixelHandle`
- **AND** no `.primary` pool buffer is retained on behalf of that subscription

### Requirement: Lane vocabulary uses primary and tracker

The camera's full-resolution output lane SHALL be named `.primary` (renamed from
`processed`); the downscaled coarse-motion lane SHALL be named `.tracker`. The
Flutter Pigeon `StreamId` and `TextureBridge` SHALL be updated to the new names.

#### Scenario: Primary replaces processed end to end

- **WHEN** a consumer or the Flutter preview subscribes to the full-resolution lane
- **THEN** the lane identifier is `.primary` and no `.processed`/`.natural` case
  remains in `StreamId`

### Requirement: Per-lane buffering policy

Each subscription SHALL accept a `BufferingPolicy`. The `.primary` lane SHALL use
`latestWins`; the `.tracker` lane SHALL support `keepBuffered(depth:)` so an
every-frame consumer can observe a bounded buffer rather than only the newest frame.
A fixed global buffering policy SHALL NOT be imposed on all lanes.

#### Scenario: Tracker lane keeps a bounded buffer

- **WHEN** a consumer subscribes to `.tracker` with `keepBuffered(depth: N)` and
  consumes slower than delivery
- **THEN** up to N frames are retained and only the oldest are dropped on overflow

#### Scenario: Primary lane keeps the newest

- **WHEN** a consumer subscribes to `.primary` with `latestWins` and consumes
  slower than delivery
- **THEN** only the newest frame is retained between pulls

### Requirement: Terminal-vs-transient stream termination

The per-lane stream SHALL terminate by throwing **only** when CameraKit judges the
error terminal (`CameraError.isFatal`). Transient, recoverable faults SHALL NOT
terminate the stream; delivery resumes after recovery. A clean end of capture
finishes the stream without throwing.

#### Scenario: Transient fault does not end the stream

- **WHEN** a recoverable fault occurs and CameraKit recovers
- **THEN** the lane stream does not throw or finish, and resumes yielding frames

#### Scenario: Terminal fault throws on the stream

- **WHEN** CameraKit determines a fault is terminal (`isFatal == true`)
- **THEN** the lane stream finishes by throwing that error to the consumer's
  `for try await` loop

### Requirement: Lease-returning pixel borrow helper

CameraKit SHALL expose `lockedPixels()` on a lane buffer returning a `PixelHandle`
whose lifetime keeps the IOSurface read lock held until the handle is released. A
scoped closure form that unlocks at closure exit SHALL NOT be the only option,
because a consumer may hold the pixels for a bounded pipeline duration.

#### Scenario: Lease keeps pixels valid across a hold

- **WHEN** a consumer obtains a `PixelHandle` from `lockedPixels()` and retains it
  across an `await`
- **THEN** the pixels stay locked and valid until the handle is released

### Requirement: Tracker lane absent when unsubscribed

The tracker lane SHALL be genuinely absent when no consumer subscribes to
`.tracker` (or it is not rendered). CameraKit MUST NOT substitute the
full-resolution `.primary` buffer under the `.tracker` label.

#### Scenario: No tracker substitution

- **WHEN** there is no `.tracker` subscriber
- **THEN** no `Frame` is delivered on `.tracker` and no full-resolution buffer is
  presented as a tracker frame

### Requirement: Consumer-specified tracker resolution

The tracker lane resolution SHALL be set by the consumer via
`OpenConfiguration.trackerHeight` (aspect-preserving, even, clamped). The motion
consumer's expected size is authoritative; CameraKit produces exactly that size and
does not silently re-resize.

#### Scenario: Tracker honors the configured size

- **WHEN** a consumer opens with `trackerHeight` set for a square working resolution
- **THEN** the delivered tracker frames are exactly that square size

### Requirement: Remove the C-ABI PixelSink path

CameraKit SHALL remove the C-ABI `PixelSink` / `PixelSinkPool` delivery path (the
`CameraKitCxx` sink, its `CameraKitInterop` bridge, and the C-ABI dispatch in
`CameraEngine`). The Swift `subscribe()` path is the supported zero-copy consumer
path.

#### Scenario: C-ABI sink no longer present

- **WHEN** CameraKit is built after this change
- **THEN** no C-ABI `PixelSink`/`PixelSinkPool` symbols are vended and the Swift
  `subscribe()` consumer registry remains functional

## REMOVED Requirements

### Requirement: Bundled FrameSet delivery

**Reason**: Replaced by per-lane `Frame` streams; a bundled all-lanes envelope
forced a shared cadence and pinned unused lanes' pool buffers, and its
`Hashable` conformance on a transient pool-backed GPU value was misleading.

**Migration**: Subscribe per lane with `subscribe(stream:buffering:)` and read the
single-lane `Frame`; correlate lanes by `Frame.index`.
