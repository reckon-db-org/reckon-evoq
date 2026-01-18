# Changelog

All notable changes to reckon-evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
