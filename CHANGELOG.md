# Changelog

All notable changes to reckon-evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.10.0] - 2026-10-23

### Fixed: a projection checkpoint is kept, and one that is not says so (reckon-evoq#1)

`reckon_evoq_checkpoint_store` had three faults, each making a projection
replay from the start on boot, or skip events after a rebuild, without a
word:

- **One snapshot per event, and the oldest could win.** Every save added a
  snapshot, and a reset to -1 left the old ones in place, so after a rebuild
  the checkpoint from before it outranked every one the rebuild saved. A
  stream now holds one snapshot, at a version equal to the checkpoint: a
  save records the new one and removes the others, and the reset to -1
  removes them all. Load reads the highest version, which is the last save.
- **Fire and forget.** `record_snapshot` and `delete_snapshot` are casts,
  so save/2 answered `ok` for a write the store refused. It now uses
  reckon-gater 3.15.0's `record_snapshot_sync` and `delete_snapshot_sync`
  and returns their errors; a reset whose snapshots cannot be listed returns
  that error instead of `ok`.
- **Never persisted on an integrity store.** The checkpoint lived on a user
  stream with no events, which an integrity store cannot anchor a snapshot
  to, so it refused every checkpoint. The stream is now the system stream
  `$evoq-checkpoint:<projection>`, which reckon-db 5.11.14+ seals with a
  store-bound MAC and no anchor (reckon-db#25).

- **Read unverified.** The checkpoint, and the latest aggregate snapshot
  through `reckon_evoq_adapter:read/2`, was read by listing the stream's
  snapshots and picking the highest version here, and reckon-db's list was
  never verified: a planted, raised or unsealed snapshot was served and the
  seal protected nothing on this path. `read/2` now asks the store for the
  latest (`read_snapshot` at version 0, reckon-db's verifying `load/2`), so
  a snapshot that fails comes back as `{error, {integrity_violation, _}}`.
  It needs reckon-gater 3.15.1, which no longer retries that refusal (3.15.0
  answered `{retries_exhausted, _}` after the whole backoff), so the floor is
  `~> 3.15 and >= 3.15.1`.

On a store with integrity on, a tampered snapshot also refuses the list a
save prunes from and a reset removes from (reckon-db 5.11.14 verifies every
listed snapshot). Both return that error and leave the store as it is: fail
closed, never a checkpoint read past it.

The stream id changes, so a checkpoint saved under the old
`projection-checkpoint-<projection>` id is not read: each projection
replays once from the start after the upgrade. The reckon-gater floor is
now 3.15.1 (`~> 3.15 and >= 3.15.1`).

## [2.9.0] - 2026-10-21

### Changed: lineage metadata is binary on the wire and atom-keyed in the BEAM (evoq#22)

evoq 1.28.0 stamps every process-manager-issued command with the triggering
event's `causation_id` and `correlation_id`. Those ids were in the store all
along and unreachable: evoq builds metadata maps with **atom** keys, and
reckon-db indexes and scans `{meta, <<"causation_id">>}` by **binary** key
(`reckon_db_index.erl`, `reckon_db_streams.erl`). `evoq_to_reckon_event/1`
passed the map through unchanged, so the index matched nothing and
`evoq_lineage:get_effects/2` and `get_correlated/2` always answered `[]`.

The adapter now rewrites **the reserved lineage keys and nothing else**
(`causation_id`, `correlation_id`, `conversation_id` - the set evoq's lineage
stamps, held in the adapter's own `?RESERVED_LINEAGE_KEYS`) to their binary
spelling on append. Values are untouched, `data` is untouched, and a map that
is already binary-keyed is passed through as it was. Events already in the
store keep their atom keys and stay unqueryable; only new appends are indexed.

**On the way back in, those same three keys are atoms again.** Without that
the delivered metadata would depend on when an event was written: atom keys
for old events, binaries for new ones, and a handler matching
`#{correlation_id := C}` - the spelling evoq's guides use - would crash on
every new event.

An application's own metadata keys are **never touched in either direction**:
an atom goes in, an atom comes back. Only the keys evoq itself defines are
translated, and only because the store's index can only match the binary
form of those.

That asymmetry is the contract: binary on the wire, because that is what the
`{meta, Key}` index matches; atoms in the BEAM, because that is what evoq
code reads. It is why this is 2.9.0 and not a patch.

### Fixed: start_from was passed to reckon-db as a symbolic value

`subscribe/5` forwarded evoq's `start_from` option - `origin`, `current` or
`{position, N}` - straight to `reckon_db_subscriptions`, which holds an
integer offset and crashed on the symbolic form. It is mapped now: `origin`
is 0, `{position, N}` is N, an integer is itself, and `current` is refused
with `{error, {unsupported_start_from, current}}` rather than silently
starting at 0 and replaying the whole store to a subscriber that asked for
new events only.

Anything that is not one of those is answered `{error, {bad_start_from,
Value}}` rather than crashing with a `function_clause`, and `current` - which
is a valid evoq value with no store equivalent - is answered
`{error, {unsupported_start_from, current}}` instead of silently meaning 0,
the whole log replayed at every restart. The start position is INCLUSIVE (the
store's replay read starts at it): a subscriber that has consumed up to `C`
asks for `{position, C + 1}`.

### Fixed: a refused ack was discarded

`ack/4` always answered `ok`, whatever the gateway said. An ack for a
removed subscription answers `{error, {subscription_not_found, _}}` - the
subscription is gone and its events will be redelivered on the next boot -
and that error is returned now, because an ack that silently does nothing is
how a checkpoint stops moving with nothing saying so. The adapter does not
log it as well: the evoq store subscription that calls ack/4 logs a failed
ack, and two warnings for one failure hide the next one.

### Fixed: the read side had the same overwrite, in reverse

A stored metadata map that carries both spellings of a reserved key - and
maps like that are real: a write whose command metadata carried a binary copy
of the key, which 2.8.0 and earlier kept beside evoq's atom stamp - read back
whichever the fold reached last. The atom wins now, as it does on the write
side, and the losing spelling is dropped rather than left beside it: one key,
one answer. Tested on a two-key map (a flatmap, so the binary always won
before: the deterministic red) and on a 64-key one, which is a guard - a
hashmap's fold order varies per VM, and that half was red in 1 of 9 runs on
the old code.

`read_by_metadata/3`'s documentation said an application key can be queried
with whichever spelling it was written as. That is wrong: the store's query
takes a BINARY key, so an app key written as an atom is stored under the atom
and cannot be found by this function at all. The contract is stated in the
`@doc` and the README now: write the keys you intend to query as binaries.

A non-binary key or value is answered here as
`{error, {invalid_metadata_key, Key}}` or
`{error, {invalid_metadata_value, Value}}`, before the gateway is called. It
used to reach the store's callback, which had no clause for it: the gateway
worker died on the `function_clause`, the gateway read the exit as transient,
and the caller waited out ten retries - about 89 seconds - for an answer it
could have had at once. No gateway call is made for a refused query, so the
answer is the first call's: reckon-gater never sees these errors from this
path.

### Fixed: a caller could overwrite evoq's own lineage stamp

A metadata map carrying BOTH spellings of a reserved key - the atom evoq
stamped and the binary form a caller sent - kept whichever the fold reached
last, which for the small maps this happens with is the binary one: the
caller's value silently replaced the `causation_id` or `correlation_id` the
framework had just recorded, and only for callers that sent one. The atom
spelling wins now, and a map with both ends up with exactly one entry per
reserved key. `evoq_aggregate:execute_command/2` - which merges a command's
metadata with the ids it now mints itself - was one way to reach it. Covered
for a two-key map and for a map with 64 other keys.

### Docs

`evoq_dispatcher` -> `evoq_router`; the `tags` subscription type;
`#subscription{}` -> `#evoq_subscription{}`; `ack/4` returns
`ok | {error, Reason}`; `read_by_metadata/3` documents what it matches on -
the store's BINARY keys, which for the three reserved lineage keys means
asking for `<<"causation_id">>`, while an application's own keys are stored
as the application wrote them; and `save/5` says what it is - the gateway
records a snapshot on a `route_cast`, so a returned `ok` is not proof it
landed.

## [2.8.0] - 2026-10-19

### Added: new_stream_id/1, so evoq can mint a stream id through the adapter

evoq 1.27.0 made `new_stream_id/1` an optional `evoq_adapter` callback, and
this adapter implements it: it delegates to `reckon_gater_stream_id:new/1`,
which is the one definition of the format (`<prefix>-<32 lowercase hex>`,
UUIDv7, so `ORDER BY stream_id` is birth order).

A service that needs a fresh aggregate id calls
`evoq_event_store:new_stream_id(Prefix)` and never names `reckon_gater` to
get one, which is what the mcl-chess referee needs for its game ids. The
prefix may be an atom or a binary; a malformed prefix raises
`{invalid_prefix, Prefix}` from the generator rather than minting an id the
store would reject on append.

The dependency floor does not move: the callback is optional in evoq, so
this release builds and works against evoq 1.22 as before, and only a
consumer on evoq 1.27.0 or later can reach the new call.

## [2.7.2] - 2026-09-26

The release of the 2.7.1 fixes below. **2.7.1 was tagged and never
published**: `rebar3 hex build` failed at edoc on two `%% @private` tags left
dangling in `reckon_evoq_checkpoint_store.erl` when the helpers they belonged
to were removed, and nothing before the tag ran edoc. The tag stays; hex
goes from 2.7.0 to 2.7.2.

### Fixed

- The dangling `@private` tags are gone, so the docs build.

### Added — CI builds the package and docs on every push

`lint-and-test` runs `rebar3 hex build`, the same build `publish-hex` runs,
so a docs break fails on main instead of after a release tag.

## [2.7.1] - 2026-09-26 (tagged, not published)

### Fixed — snapshots read back with empty data and metadata

`save/5` hands reckon-gater `#{data, metadata, timestamp}`. Since reckon-db
5.5.2 (2026-07-01) the gateway worker unwraps that and stores the user's data
in the snapshot's own `data` field and the metadata in its `metadata` field.
`read/2` and `read_at_version/3` still unwrapped a second time
(`maps:get(data, UserData, #{})`), so every snapshot came back with
`data = #{}` and `metadata = #{}`. An aggregate restored from a snapshot started
from an empty map: evoq snapshots every 100 events, so every aggregate past
that point was reloaded wrong, and ones whose `from_snapshot/1` match on
their fields (the mcl-victron and mcl-bookclub aggregates) crash on load. reckon-e2e's
`adapters_produce_equivalent_outcomes` caught it against a real store once
that suite could compile again.

The read takes data and metadata from the record's own fields. A snapshot
written by a reckon-db older than 5.5.2 holds the whole wrapper in `data` and
is still read correctly: it is recognised by exactly the keys `data`,
`metadata` and `timestamp`, in the record and in the gateway's map shape. That
also keeps consumers resolving reckon-db 5.4.x to 5.5.1 working. The one
collision: an aggregate whose `snapshot/1` returns a map with exactly those
three keys and nothing else would be read as the wrapper; no known aggregate
does, and a test names the case. A snapshot whose data is a binary (allowed by
the record's type) crashed the read with `function_clause`; it is returned as
the data now.

### Fixed — the checkpoint store crashed on every load

`reckon_evoq_checkpoint_store:load/1` and `delete/1` called `maps:get` on the
`list_snapshots` reply, which is a list of `#snapshot{}` records, so they
raised `badmap`: a projection started with
`checkpoint_store => reckon_evoq_checkpoint_store` saved its first checkpoint
and then could not start again. Its tests were green because they mocked
maps. Both now go through the adapter's `read/2` and `delete/2`, so they read
the same shapes, including a checkpoint saved before reckon-db 5.5.2; the
tests use records.

### Also in this release

The first release through CI (lint, eunit, Dialyzer ratchet, and a
tag-to-release publish workflow, OTP 28.4.3), and every repository reference
pointing at GitHub.

## [2.7.0] - 2026-06-25

### Added — CCC payload-condition adapter callbacks (evoq Part A)

Implements the four `evoq_adapter` callbacks evoq 1.22.0 added for CCC
(payload-conditioned DCB decisions), delegating to reckon-gater:

- `ccc_read_by_payload/4` → `reckon_gater_api:ccc_read_by_payload/4`
- `ccc_read_by_payload_hash/4` → `reckon_gater_api:ccc_read_by_payload_hash/4`
- `payload_indexes/1` → `reckon_gater_api:get_payload_indexes/1`
- `payload_hash_indexes/1` → `reckon_gater_api:get_payload_hash_indexes/1`

The two read functions return events mapped through `events_to_evoq/1` (same
shape as `read_by_tags`/`read_by_event_types`); the introspection functions
return the raw key lists evoq's decision runtime uses to fail loudly on an
undeclared payload index.

### Changed — dependency floors raised

- `evoq` `~> 1.15` → `~> 1.22` (the CCC adapter callback contract).
- `reckon_gater` `~> 3.4` → `~> 3.7` (`get_payload_indexes/1` and
  `get_payload_hash_indexes/1` introspection; `ccc_read_by_payload*` reads
  shipped in 3.6.0).

## [2.6.0] - 2026-06-22

### Changed — reckon_gater floor raised to 3.4

Raises the `reckon_gater` dependency floor from `~> 3.3` to `~> 3.4` to pull
in the `{event_type, binary()}` tag-filter leaf (reckon-gater 3.4.0).

The adapter itself is unchanged: `append_if_no_tag_matches/4` passes
`TagFilter` opaquely to `reckon_gater_api`, so `{event_type, T}` flows through
without any adapter changes. The new filter shape is usable from day one via
`evoq_decision:context_filter()` in evoq 1.21.0.

No code changes; API-compatible with reckon_gater 3.x.

## [2.5.0] - 2026-06-10

### Fixed — reckon_gater requirement missing from the published package

`reckon_evoq` 2.4.0 (and earlier) shipped to hex with **no
`reckon_gater` requirement**: the `_checkouts/reckon_gater` dev
symlink kept the dep out of `rebar.lock`, and rebar3_hex derives the
published requirements from the lock. Consumers only received
reckon_gater transitively (via reckon_db), and nothing enforced a
compatible version for this adapter's direct `reckon_gater_api`
calls.

- `rebar.lock` now pins `reckon_gater` from hex; the package
  declares `{reckon_gater, "~> 3.3"}`.
- Floor raised to 3.3 to pull the security release (capability
  checks on by default, real token verification; see reckon-gater
  3.3.0 changelog).
- rebar.config documents the publish-time footgun: remove
  `_checkouts` symlinks before `rebar3 hex publish` and check the
  requirements list in the confirmation prompt.

No code changes; the adapter is API-compatible with gater 3.x.

## [2.4.0] - 2026-06-08

### Added — `read_by_metadata/3` adapter passthrough

`reckon_evoq_adapter:read_by_metadata(StoreId, Key, Value)` forwards to
`reckon_gater_api:read_by_metadata/3` (reckon_gater 3.2.0 / reckon-db 5.0.0),
returning events whose metadata `Key` equals `Value`, converted to evoq form.
This is what backs `evoq_lineage:get_effects/get_correlated/get_conversation`
(evoq 1.20.0) and the broader cross-cutting metadata query. Additive;
`reckon_gater ~> 3.0` already admits 3.2.0.

## [2.3.0] - 2026-06-07

### Changed — require `reckon_gater ~> 3.0`

Widened the `reckon_gater` constraint from `~> 2.3` to `~> 3.0` so the
adapter resolves alongside `reckon_db 4.0`. No code change — reckon-evoq
uses append/read/subscribe, never the causation API that gater 3.0.0
removed. `rebar3 compile` + eunit green against gater 3.0.0.

## [2.2.1] - 2026-05-27

### Notes — Why 2.2.1 and not 2.2.0

2.2.0 was tagged locally but never published to hex: a parallel docs
fix shipped after the tag was cut, and the `reckon_gater` constraint
was tightened to `~> 2.3.0` (only 2.3.x). Both fold into 2.2.1, paired
with `reckon_gater 2.3.1` + `reckon_db 3.1.1`.

### Changed — `reckon_gater` constraint widened

`rebar.config`: `{reckon_gater, "~> 2.3.0"}` → `{reckon_gater, "~> 2.3"}`.
Per workspace loose-constraint convention; allows coordinated minor-
version updates without re-tagging consumers.

### Fixed — EDoc-incompatible backticks in DCB passthrough doc

The `append_if_no_tag_matches/4` `@doc` block used markdown-style
backticks, which EDoc's parser rejected with
`` `-quote ended unexpectedly ``. Replaced with plain text;
`rebar3 ex_doc` now builds clean.

## [2.2.0] - 2026-05-27

### Added — DCB adapter passthrough (paired with reckon-db 3.1.0)

`reckon_evoq_adapter:append_if_no_tag_matches/4` — thin passthrough
to `reckon_gater_api:append_if_no_tag_matches/4` (reckon-gater 2.3.0+).
Translates evoq-shaped events through the existing
`evoq_to_reckon_event/1` shim, then routes the conditional-append via
the gateway. Returns the same `{ok, LastSeq}` / `{error, {context_changed, MaxSeq}}`
shape as the wire layer.

```erlang
reckon_evoq_adapter:append_if_no_tag_matches(
    StoreId, TagFilter, SeqCutoff, Events).
```

`TagFilter` is `reckon_gater_types:tag_filter()`.
`SeqCutoff` is `integer()` (`-1` = "saw nothing yet").

### Changed — `reckon_gater` dep constraint

`{reckon_gater, "~> 2.1"}` -> `{reckon_gater, "~> 2.3.0"}`. Required
for the `append_if_no_tag_matches` API and the `tag_filter()` type.

**Publish ordering**: reckon-gater 2.3.0 must be on hex before
reckon-evoq 2.2.0 can be cleanly hex-published. For local development,
add `_checkouts/reckon_gater` symlink.

### Notes

This release adds the adapter shim only. The user-facing
`evoq_decision` behaviour that drives this primitive ships in evoq
1.18.0 (P3.6). Apps that don't use DCB are unaffected by this
release.

## [2.1.1] - 2026-05-16

### Fixed — Snapshot read path

The four snapshot adapter call sites (`read/2`, `read_at_version/3`, `delete/2`, `list_versions/2`) assumed `reckon_gater_api:list_snapshots/3` and `read_snapshot/4` returned `[map()]` / `map()`. The API spec says so. The actual reckon-db side returns `#snapshot{}` records — drift that landed during the 2.1.0 tamper-resistance work without updating the consumer.

Symptom: any aggregate snapshot load through reckon-evoq crashed with `badmap` inside `lists:foldl` (`read/2`) or directly on `maps:get/3` (`delete`, `list_versions`).

Surfaced by the `reckon-e2e` `adapter_swap_torture` harness — the unit tests in this repo never crossed the gateway boundary so the drift was invisible until then.

### Changed

- New private helper `snapshot_version/1` accepts both `#snapshot{}` and `map()` shapes so the adapter is tolerant of future spec realignment.
- `map_to_evoq_snapshot/2` → `gater_to_evoq_snapshot/2` — clearer name, two clauses (record + map), unwraps the user's `data`/`metadata`/`timestamp` from the wrapper that `save/5` stores them in.

## [2.1.0] - 2026-05-15

### Added — Chain hash propagation

Layer 6 of the cross-package tamper-resistance work in
reckon-db/plans/PLAN_TAMPER_RESISTANCE.md. Single-block change
in `event_to_evoq/1` that forwards reckon-gater's new
`prev_event_hash` field on `#event{}` through to evoq's matching
field on `#evoq_event{}`.

The `mac` and `signature` fields on the storage-side record are
intentionally NOT forwarded — they belong to the storage layer
and require the per-store HMAC / public key that consumers above
the adapter do not (and must not) hold.

### Dependencies

- `reckon_gater` bumped to `~> 2.1` (was `~> 2.0`) — needs the
  `prev_event_hash` field on `#event{}`.
- `evoq` bumped to `~> 1.15` (was `~> 1.14`) — needs the matching
  field on `#evoq_event{}` and the `is_integrity_violation/1`
  classifier in `evoq_aggregate`.

### Compatibility

Pure forward-pass addition. Apps using `reckon_evoq_adapter`
through `evoq_dispatcher` see no change in observable behaviour
except that events received in projections / process managers
now carry `prev_event_hash` (populated when the underlying
reckon-db store has integrity enabled; `undefined` otherwise).

Integrity violations from the storage layer continue to flow
through unchanged — they were already pattern-matched as
`{error, _}` and forwarded by the existing read path. No new
handling code in the adapter; evoq 1.15.0's dispatcher does
the recognition.

### Changed

- `src/reckon_evoq.app.src`: `{"GitHub", ...}` updated to
  `{"Codeberg", ...}` to match canonical hosting.

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
