## MODIFIED Requirements

### Requirement: Terminal-vs-transient stream termination

The per-lane stream SHALL terminate by throwing **only** when CameraKit judges the
error terminal (`CameraError.isFatal`). Transient, recoverable faults SHALL NOT
terminate the stream; delivery resumes after recovery. A recovery reopen or a full
restart SHALL be transparent to consumers: the teardown it performs SHALL preserve
consumer subscriptions (it MUST NOT call `ConsumerRegistry.release()` or
`failAllLanes`), so a surviving subscriber sees only a frame gap and then resumes
yielding frames from the rebuilt pipeline. A subscription SHALL be finished
(without throwing) only by a user-initiated `close()`, and SHALL be finished by
throwing only by the terminal fatal after recovery escalation is exhausted. A clean
end of capture finishes the stream without throwing.

#### Scenario: Transient fault does not end the stream

- **WHEN** a recoverable fault occurs and CameraKit recovers
- **THEN** the lane stream does not throw or finish, and resumes yielding frames

#### Scenario: A full restart is transparent to a subscribed consumer

- **WHEN** a consumer is subscribed to a lane and CameraKit performs a full restart
  (heavier teardown + settle + fresh open) during recovery
- **THEN** the consumer's stream is neither finished nor thrown; after the restart
  it resumes yielding valid frames from the new pipeline

#### Scenario: Terminal fault throws on the stream

- **WHEN** CameraKit determines a fault is terminal (`isFatal == true`), i.e.
  recovery escalation is exhausted
- **THEN** the lane stream finishes by throwing that error to the consumer's
  `for try await` loop

#### Scenario: User close finishes the stream cleanly

- **WHEN** the host calls `close()`
- **THEN** each subscribed lane stream finishes without throwing
