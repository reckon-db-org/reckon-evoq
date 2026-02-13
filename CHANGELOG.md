# Changelog

All notable changes to reckon-evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.4] - 2026-02-13

### Fixed

- **Flexible key handling**: `evoq_to_reckon_event/1` now handles both atom and binary
  keys in event maps via `get_flex/3`. Events coming from ReckonDB with binary keys
  (e.g., `<<"event_type">>`) are now correctly translated.

### Changed

- **Dependency**: Require reckon_gater ~> 1.1.2

## [1.1.3] - 2026-02-06

### Changed

- **Dependency**: Require reckon_gater ~> 1.1.1
  - Ensures gater-style subscription types (by_stream, by_event_type, etc.) are available
  - Required for proper type translation through the gateway layer

## [1.1.2] - 2026-02-01

### Fixed

- **CHANGELOG**: Corrected v1.1.1 entry to remove incorrect reckon_db dependency reference
  - reckon_evoq depends ONLY on evoq and reckon_gater
  - Does NOT depend directly on reckon_db
  - Clarified dependency chain in CHANGELOG

## [1.1.1] - 2026-02-01

### Changed

- **Compatibility**: Verified compatibility with evoq v1.2.1
  - Tested compilation and integration with updated evoq dependency
  - Version constraints `~> 1.2` for evoq already compatible with v1.2.1
  - No code changes required; release confirms compatibility
  - Note: reckon_evoq depends on evoq and reckon_gater, NOT directly on reckon_db

## [1.1.0] - 2026-01-21

### Added

- **Tag-Based Querying**: Cross-stream event queries using tags
  - `read_by_tags/3,4` - Query events by tags across all streams
  - Support for `any` (union) and `all` (intersection) matching modes
  - Tags field translation between evoq and reckon-db event types
  - Tags are for QUERY purposes only, NOT for concurrency control

### Changed

- **Dependencies**: Updated evoq from `~> 1.1` to `~> 1.2` and reckon_gater from
  `~> 1.0.3` to `~> 1.1.0` for tags support

## [1.0.10] - 2026-01-19

### Changed

- **Dependencies**: Updated reckon_gater from exact `1.0.0` to `~> 1.0.3` to include
  critical double-wrapping bugfix in `do_route_call/3`

## [1.0.9] - 2026-01-19

### Fixed

- **Double-wrapped errors**: Handle edge case where gateway returns `{ok, {error, ...}}`
  instead of `{error, ...}` for stream_not_found errors
- Added guard `is_list(Events)` to `read/5` to catch incorrect responses

## [1.0.8] - 2026-01-19

### Changed

- **Dependencies**: Relaxed evoq version constraint from exact `1.1.0` to `~> 1.1` to allow
  compatibility with evoq 1.1.x releases

## [1.0.7] - 2026-01-09

### Fixed

- **Documentation**: Removed EDoc-incompatible backticks from source documentation

## [1.0.6] - 2026-01-09

### Fixed

- **Empty streams**: `read/5` now correctly returns `{ok, []}` for new/empty streams
  instead of `{error, {:stream_not_found, StreamId}}`
- **Event format**: Fixed event format transformation between reckon_gater and evoq types

## [1.0.5] - 2026-01-08

### Changed

- **Documentation**: Added Buy Me a Coffee badge to README

## [1.0.4] - 2026-01-08

### Dependencies

- Updated evoq to 1.1.0 (adds `evoq_bit_flags` module for aggregate state management)

## [1.0.3] - 2026-01-06

### Changed

- **Type translation**: Adapter now returns evoq types (`evoq_event()`, `evoq_snapshot()`,
  `evoq_subscription()`) instead of reckon_gater types, enabling evoq to be truly
  independent of any specific storage backend

### Dependencies

- Updated evoq to 1.0.3 (macro guard compatibility fix)

## [1.0.2] - 2026-01-03

### Added

- **SVG diagram**: Added architecture.svg replacing ASCII diagram in README

### Changed

- **Documentation**: Updated version references in README (installation ~> 1.0, dependencies >= 1.0.0)

## [1.0.1] - 2026-01-03

### Changed

- **Dependencies**: Updated evoq to 1.0.1 (SVG diagram fixes)

## [1.0.0] - 2026-01-03

### Changed

- **Stable Release**: First stable release of reckon-evoq under reckon-db-org
- All APIs considered stable and ready for production use
- Updated source comments to use correct package names (evoq, reckon-gater)

## [0.3.1] - 2025-12-22

### Dependencies

- Updated reckon-gater to ~> 0.6.4 (capability opt-in mode, configuration guide)

## [0.3.0] - 2025-12-22

### Fixed

- **`delete_stream/2`**: Now functional - calls `esdb_gater_api:delete_stream/2`
  instead of returning `{error, not_implemented}`

- **`get_checkpoint/2`**: Now functional - retrieves checkpoint from subscription
  via `esdb_gater_api:get_subscription/2`

### Changed

- **`read_by_event_types/3`**: Optimized to use server-side native Khepri filtering
  via `esdb_gater_api:read_by_event_types/3` instead of fetching all streams
  and filtering client-side. Significantly improved performance for type-based
  queries.

### Dependencies

- Requires reckon-gater >= 0.6.2
- Requires reckon-db >= 0.4.3

## [0.2.0] - 2025-12-20

### Added

- Initial release of reckon-evoq adapter
- Implements `evoq_adapter` behavior for event store operations
- Implements `evoq_snapshot_adapter` behavior for snapshot operations
- Implements `evoq_subscription_adapter` behavior for subscription operations
- Routes all operations through reckon-gater for load balancing and retry
