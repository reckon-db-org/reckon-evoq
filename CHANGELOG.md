# Changelog

All notable changes to reckon-evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
