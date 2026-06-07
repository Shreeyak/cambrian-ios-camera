## ADDED Requirements

### Requirement: Platform-neutral transport package

The shared frame vocabulary SHALL be exposed as a standalone SPM product
`FrameTransport` that compiles on both iOS and macOS and MUST NOT import
AVFoundation or any iOS-only capture API. Consumers MUST be able to depend on
`FrameTransport` without depending on the rest of CameraKit.

#### Scenario: Builds on macOS without AVFoundation

- **WHEN** the `FrameTransport` product is built for a macOS target
- **THEN** it compiles successfully using only CoreVideo, IOSurface, and Foundation
- **AND** it does not reference any AVFoundation symbol

#### Scenario: Importable independently of CameraKit

- **WHEN** a package depends on the `FrameTransport` product alone
- **THEN** it can use `Frame`, `PixelHandle`, `FrameMetadata`, `Lane`,
  `PixelFormat`, and `BufferingPolicy` without linking the `CameraKit` product

### Requirement: Frame envelope

`Frame` SHALL be a `Sendable` value carrying exactly one lane of one capture:
the `lane`, a `UInt64` `index` (the cross-lane correlation key), a `timestampNs`
in nanoseconds, a `pixels: PixelHandle`, and a `metadata: any FrameMetadata`.

#### Scenario: Two lanes of one capture share an index

- **WHEN** a producer emits the `.primary` and `.tracker` frames of capture N
- **THEN** both frames carry the same `index` value N and the same `timestampNs`

#### Scenario: Gaps in index are permitted

- **WHEN** a latest-wins lane drops intermediate captures
- **THEN** the consumer observes a jump in `index` and this is a valid sequence
  (the `index` is monotonic and session-scoped, not gap-free)

### Requirement: Self-describing pixel lease

`PixelHandle` SHALL be a reference type that carries `baseAddress`, `width`,
`height`, `bytesPerRow`, and `format`, and SHALL release its underlying IOSurface
read lock and buffer reference on `deinit`. `bytesPerRow` MUST be the real
IOSurface stride, never an assumed `width * 4`. A bounded hold of a `PixelHandle`
beyond the delivering call MUST be permitted.

#### Scenario: Stride is the real IOSurface stride

- **WHEN** a `PixelHandle` wraps an IOSurface whose stride exceeds `width * 4`
  (padded rows)
- **THEN** `bytesPerRow` reports the padded stride, not `width * 4`

#### Scenario: Lock released on deinit

- **WHEN** the last reference to a `PixelHandle` is dropped
- **THEN** its IOSurface read lock is released and its buffer reference is freed

#### Scenario: Bounded hold across an async boundary

- **WHEN** a consumer retains a `PixelHandle` across an `await` for a bounded
  duration
- **THEN** the pixels remain valid for the lifetime of the held reference

### Requirement: Producer-specific metadata

`FrameMetadata` SHALL be a `Sendable` marker protocol. Each producer SHALL define
its own concrete conforming type. Any datum a consumer makes a control decision on
MUST be a typed member of a concrete `FrameMetadata` type, not an untyped payload.

#### Scenario: Concrete metadata travels on the frame

- **WHEN** a producer constructs a `Frame`
- **THEN** the `metadata` value is a concrete type conforming to `FrameMetadata`
  (e.g. the camera's `CameraFrameMetadata`)
- **AND** a consumer can downcast to that concrete type to read its typed fields

### Requirement: Lane, format, and buffering vocabulary

`Lane` SHALL enumerate `primary` (full-resolution) and `tracker` (downscaled
coarse-motion). `PixelFormat` SHALL enumerate at least `bgra8`. `BufferingPolicy`
SHALL enumerate `blocking` (back-pressure the producer), `latestWins` (keep newest
1), and `keepBuffered(depth:)` (keep up to depth, drop oldest on overflow).

#### Scenario: keepBuffered drops the oldest on overflow

- **WHEN** a `keepBuffered(depth: N)` buffer is full and a new frame arrives
- **THEN** the oldest buffered frame is dropped and the newest is retained

#### Scenario: latestWins keeps only the newest

- **WHEN** a `latestWins` buffer holds an unconsumed frame and a new frame arrives
- **THEN** the older frame is dropped and only the newest is retained
