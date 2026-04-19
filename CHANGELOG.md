# Changelog

All notable changes to reckon-evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-04-19

### Changed

**BREAKING**: Updated to consume the renamed reckon-gater 2.0.0 API.
All internal references to `esdb_gater_api:*` migrated to
`reckon_gater_api:*`. Include paths updated:

- `-include_lib("reckon_gater/include/esdb_gater_types.hrl")`
  → `-include_lib("reckon_gater/include/reckon_gater_types.hrl")`

### Dependencies

- Bumped `reckon_gater` to `~> 2.0`
- Kept `evoq` at `~> 1.14` (evoq 1.14.2 is a patch with only comment
  updates, fully API-compatible)

### Migration

Pure drop-in replacement for apps that use `reckon_evoq_adapter`
through `evoq_dispatcher`. No adapter contract changes.

Apps that reached directly into `esdb_gater_api` from their own code
(rather than through reckon-evoq) must do their own migration per
reckon-gater 2.0.0's migration notes.

## [1.5.1] - 2026-03-19

### Added

- **Store Inspector operations** in `reckon_evoq_adapter`:
  - `store_stats/1`, `list_all_snapshots/1`, `list_subscriptions/1`
  - `subscription_lag/2`, `event_type_summary/1`, `stream_info/2`
  - Delegates to `reckon_gater_api` inspector exports (reckon_gater 1.3.1+)

### Changed

- Updated reckon_gater dependency to ~> 1.3.1

## [1.4.1] - 2026-03-08

### Added

- **`reckon_evoq_adapter:has_events/1`**: Delegates to `reckon_gater_api:has_events/1`
  for checking if a store contains at least one event.

### Changed

- Bumped dependencies: evoq ~> 1.9.1, reckon_gater ~> 1.2.1

## [1.4.0] - 2026-03-07

### Added

- **`reckon_evoq_adapter:read_all_global/3`**: Read all events across all streams
  in global order via gateway. Used by evoq catch-up subscriptions.

## [1.3.0] - 2026-03-07

### Added

- **Persistent checkpoint store**: `reckon_evoq_checkpoint_store` implements
  `evoq_checkpoint_store` behaviour, persisting projection checkpoints as
  ReckonDB snapshots via `reckon_gater_api`. Projections can now resume from
  where they left off after restart without full event replay.
  - Stream convention: `<<"projection-checkpoint-{module_name}">>`
  - Configurable store: `application:set_env(reckon_evoq, checkpoint_store_id, my_store)`

### Changed

- **Dependency**: Require evoq `~> 1.6` (for `evoq_store_subscription` bridge
  and `evoq_projection` checkpoint support)

## [1.2.3] - 2026-03-05

### Changed

- Bumped `reckon_gater` dependency to `~> 1.1.3` (includes `debug_info` for dialyzer)

## [1.2.0] - 2026-02-25

### Fixed

- **Subscription event translation**: `subscribe/5` now interposes a bridge process
  between ReckonDB and the subscriber. ReckonDB emitters send `{events, [#event{}]}`
  (reckon_gater records). The bridge translates these to `{events, [#evoq_event{}]}`
  before forwarding to the subscriber. Previously, raw `#event{}` records were delivered
  directly, causing pattern match failures in projections expecting `#evoq_event{}`.

### Changed

- **Dependency**: Require evoq ~> 1.4 (for `evoq_subscriptions` facade)

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

- **`delete_stream/2`**: Now functional - calls `reckon_gater_api:delete_stream/2`
  instead of returning `{error, not_implemented}`

- **`get_checkpoint/2`**: Now functional - retrieves checkpoint from subscription
  via `reckon_gater_api:get_subscription/2`

### Changed

- **`read_by_event_types/3`**: Optimized to use server-side native Khepri filtering
  via `reckon_gater_api:read_by_event_types/3` instead of fetching all streams
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
