// AppCxx bridging header — exposes the app-target C-ABI to Swift.
// Phase 1B (2026-05-15). Set as SWIFT_OBJC_BRIDGING_HEADER on the
// ios_example_app app target and the ios_example_appTests target (so the
// C-ABI symbols are reachable from Stage08CannyTests + CABIParityTests).
#pragma once
#include "include/CannyConsumer.h"
#include "include/CounterConsumer.h"
