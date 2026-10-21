%% @doc Gateway adapter implementation for evoq
%%
%% Implements the adapter behaviors using reckon_gater_api to route
%% all operations through the reckon-gater load balancer.
%%
%% This adapter ensures that evoq never directly calls reckon-db
%% modules, instead routing through the gateway for:
%% - Automatic retry with exponential backoff
%% - Load balancing across workers
%% - High availability
%%
%% @author rgfaber

-module(reckon_evoq_adapter).

%% Implement behaviors defined in evoq
-behaviour(evoq_adapter).
-behaviour(evoq_snapshot_adapter).
-behaviour(evoq_subscription_adapter).

%% reckon-gater types (what the backend uses internally)
%% Must be included FIRST to define macros
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

%% evoq types (what we return to evoq consumers)
%% Included second - uses ifndef guards for shared macros
-include_lib("evoq/include/evoq_types.hrl").

%% The lineage keys evoq defines (evoq.hrl). They are the only metadata keys
%% this adapter renames, in either direction.
-define(RESERVED_LINEAGE_KEYS, [causation_id, correlation_id, conversation_id]).

%%====================================================================
%% evoq_adapter callbacks (Event Store Operations)
%%====================================================================

-export([
    append/4,
    append_if_no_tag_matches/4,
    read/5,
    read_all/3,
    read_all_global/3,
    has_events/1,
    read_by_event_types/3,
    read_by_tags/3,
    read_by_tags/4,
    read_by_metadata/3,
    ccc_read_by_payload/4,
    ccc_read_by_payload_hash/4,
    payload_indexes/1,
    payload_hash_indexes/1,
    version/2,
    exists/2,
    list_streams/1,
    delete_stream/2,
    new_stream_id/1
]).

%%====================================================================
%% evoq_snapshot_adapter callbacks (Snapshot Operations)
%%====================================================================

-export([
    save/5,
    read/2,
    read_at_version/3,
    delete/2,
    delete_at_version/3,
    list_versions/2
]).

%%====================================================================
%% evoq_subscription_adapter callbacks (Subscription Operations)
%%====================================================================

-export([
    subscribe/5,
    unsubscribe/2,
    ack/4,
    get_checkpoint/2,
    list/1,
    get_by_name/2
]).

%%====================================================================
%% Store Inspector Operations
%%====================================================================

-export([
    store_stats/1,
    list_all_snapshots/1,
    list_subscriptions/1,
    subscription_lag/2,
    event_type_summary/1,
    stream_info/2
]).

%%====================================================================
%% Event Store Operations
%%====================================================================

%% @doc Append events to a stream via gateway.
%%
%% Events from evoq have a flat structure, but reckon_db expects events
%% with a nested data field. This function transforms the events to
%% the format expected by reckon_db.
-spec append(atom(), binary(), integer(), [map()]) ->
    {ok, non_neg_integer()} | {error, term()}.
append(StoreId, StreamId, ExpectedVersion, Events) ->
    %% Transform events to reckon_db format
    TransformedEvents = [evoq_to_reckon_event(E) || E <- Events],
    case reckon_gater_api:append_events(StoreId, StreamId, ExpectedVersion, TransformedEvents) of
        {ok, NewVersion} ->
            {ok, NewVersion};
        {error, _} = Error ->
            Error
    end.

%% @doc Conditionally append events under the DCB pseudo-stream
%% (Dynamic Consistency Boundary, paired with reckon-db 3.1.0+).
%%
%% Unlike append/4, the precondition is a tag-filter context query
%% rather than a stream-version check. Returns
%% {error, {context_changed, MaxSeq}} when any event matching
%% TagFilter has seq above SeqCutoff.
%%
%% TagFilter is reckon_gater_types:tag_filter() (see reckon-gater
%% 2.3.0+ for the canonical type).
%% SeqCutoff is an integer; -1 means "saw nothing yet".
%%
%% Events are transformed via the same evoq_to_reckon_event/1 shim
%% as append/4, so callers pass evoq-shaped events and the adapter
%% bridges to the reckon_db payload shape.
-spec append_if_no_tag_matches(atom(), term(), integer(), [map()]) ->
      {ok, non_neg_integer()}
    | {error, {context_changed, non_neg_integer()}}
    | {error, no_events}
    | {error, integrity_not_supported_in_dcb_v1}
    | {error, term()}.
append_if_no_tag_matches(StoreId, TagFilter, SeqCutoff, Events) ->
    TransformedEvents = [evoq_to_reckon_event(E) || E <- Events],
    case reckon_gater_api:append_if_no_tag_matches(
           StoreId, TagFilter, SeqCutoff, TransformedEvents) of
        {ok, LastSeq} ->
            {ok, LastSeq};
        {error, _} = Error ->
            Error
    end.

%% @doc Read events from a stream via gateway.
%%
%% For event sourcing, a non-existent stream just means no events yet,
%% so we translate stream_not_found to an empty list.
-spec read(atom(), binary(), non_neg_integer(), pos_integer(), forward | backward) ->
    {ok, [evoq_event()]} | {error, term()}.
read(StoreId, StreamId, StartVersion, Count, Direction) ->
    case reckon_gater_api:get_events(StoreId, StreamId, StartVersion, Count, Direction) of
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        %% Handle double-wrapped error (gateway bug workaround)
        {ok, {error, {stream_not_found, _}}} ->
            {ok, []};
        {ok, {error, _} = Error} ->
            Error;
        {error, {stream_not_found, _}} ->
            %% Non-existent stream = no events yet (valid for new aggregates)
            {ok, []};
        {error, _} = Error ->
            Error
    end.

%% @doc Read all events across all streams in global order via gateway.
%%
%% Returns events sorted by epoch_us, starting from Offset.
%% Used for catch-up subscriptions and global event replay.
-spec read_all_global(atom(), non_neg_integer(), pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_all_global(StoreId, Offset, BatchSize) ->
    case reckon_gater_api:read_all_global(StoreId, Offset, BatchSize) of
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @doc Check if a store contains at least one event.
-spec has_events(atom()) -> boolean().
has_events(StoreId) ->
    reckon_gater_api:has_events(StoreId).

%% @doc Read all events from a stream via gateway.
-spec read_all(atom(), binary(), forward | backward) ->
    {ok, [evoq_event()]} | {error, term()}.
read_all(StoreId, StreamId, Direction) ->
    %% Read in batches of 1000 and accumulate
    read_all_batched(StoreId, StreamId, 0, Direction, []).

%% @private Read all events in batches
-spec read_all_batched(atom(), binary(), non_neg_integer(), forward | backward, [evoq_event()]) ->
    {ok, [evoq_event()]} | {error, term()}.
read_all_batched(StoreId, StreamId, StartVersion, Direction, Acc) ->
    BatchSize = 1000,
    case read(StoreId, StreamId, StartVersion, BatchSize, Direction) of
        {ok, []} ->
            {ok, lists:reverse(Acc)};
        {ok, Events} when length(Events) < BatchSize ->
            {ok, lists:reverse(Events ++ Acc)};
        {ok, Events} ->
            NextVersion = next_batch_version(Direction, StartVersion, length(Events)),
            read_all_batched(StoreId, StreamId, NextVersion, Direction, Events ++ Acc);
        {error, _} = Error ->
            Error
    end.

%% @private Next batch start version for forward/backward paging.
next_batch_version(forward, StartVersion, N) -> StartVersion + N;
next_batch_version(backward, StartVersion, N) -> max(0, StartVersion - N).

%% @doc Read events by type via gateway.
%%
%% Uses the server-side native Khepri filtering for efficient type-based queries.
%% Events are filtered at the database level, avoiding loading all events into memory.
-spec read_by_event_types(atom(), [binary()], pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_by_event_types(StoreId, EventTypes, BatchSize) ->
    case reckon_gater_api:read_by_event_types(StoreId, EventTypes, BatchSize) of
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @doc Read events by tags via gateway (default: ANY match).
%%
%% Tags provide cross-stream querying for the process-centric model.
%% Use this to find all events related to specific participants.
-spec read_by_tags(atom(), [binary()], pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_by_tags(StoreId, Tags, BatchSize) ->
    read_by_tags(StoreId, Tags, any, BatchSize).

%% @doc Read events by tags via gateway with match mode.
%%
%% Tags provide cross-stream querying for the process-centric model.
%% Events are filtered at the database level.
%%
%% Match modes:
%%   any - Return events matching ANY of the tags (union)
%%   all - Return events matching ALL of the tags (intersection)
-spec read_by_tags(atom(), [binary()], any | all, pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_by_tags(StoreId, Tags, Match, BatchSize) ->
    case reckon_gater_api:read_by_tags(StoreId, Tags, #{match => Match, batch_size => BatchSize}) of
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @doc Read events by a metadata key=value pair via gateway.
%%
%% The cross-cutting lineage primitive: events whose metadata Key equals
%% Value (e.g. all events with causation_id == some event id). O(matches)
%% when the store declared the {meta, Key} index, else a server-side scan.
%%
%% THE KEY MUST BE A BINARY, and the match is on what the store holds. The
%% adapter renames exactly the reserved lineage keys (causation_id,
%% correlation_id, conversation_id) to their binary spelling on the way in,
%% so ask for the binary "causation_id". An application's own metadata keys
%% are stored exactly as the application wrote them, and the store's query
%% takes a binary key only: an app key written as an atom is stored under the
%% atom and CANNOT be found by this function at all. Write the keys you
%% intend to query as binaries.
%%
%% A non-binary Key or Value answers {error, {invalid_metadata_key, K}} or
%% {error, {invalid_metadata_value, V}} without reaching the store, which
%% used to be a function_clause in the gateway worker: the worker died, the
%% gateway read the exit as transient, and the caller waited out ten retries
%% - about 89 seconds - for an answer it could have had at once.
-spec read_by_metadata(atom(), binary(), binary()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_by_metadata(StoreId, Key, Value) ->
    case metadata_query(Key, Value) of
        ok ->
            read_metadata_matches(StoreId, Key, Value);
        {error, _} = Error ->
            Error
    end.

%% @private The gateway's answer. It carries the store's result, which is
%% either a list or an {ok, List}; anything else is the caller's error.
-spec read_metadata_matches(atom(), binary(), binary()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_metadata_matches(StoreId, Key, Value) ->
    case reckon_gater_api:read_by_metadata(StoreId, Key, Value) of
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @private The store's metadata query takes binaries, and the gateway worker
%% has no error channel for anything else: an atom reached the callback and
%% crashed the worker. Refuse it here, where it is a plain answer.
-spec metadata_query(term(), term()) -> ok |
    {error, {invalid_metadata_key | invalid_metadata_value, term()}}.
metadata_query(Key, _Value) when not is_binary(Key) ->
    {error, {invalid_metadata_key, Key}};
metadata_query(_Key, Value) when not is_binary(Value) ->
    {error, {invalid_metadata_value, Value}};
metadata_query(_Key, _Value) ->
    ok.

%% @doc Read DCB events whose payload field Key equals Value (CCC).
%%
%% Backed by reckon-db's {payload, Key} index. O(matches) when the
%% store declared the index; an undeclared index returns a backend
%% error, which evoq's decision runtime maps to payload_index_unavailable.
-spec ccc_read_by_payload(atom(), binary(), binary(), pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
ccc_read_by_payload(StoreId, Key, Value, BatchSize) ->
    case reckon_gater_api:ccc_read_by_payload(StoreId, Key, Value, BatchSize) of
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @doc Read DCB events matching a composite payload field set (CCC).
%%
%% Backed by reckon-db's {payload_hash, Keys} index. All Keys must
%% match their Values; field order is ignored.
-spec ccc_read_by_payload_hash(atom(), [binary()], [binary()], pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
ccc_read_by_payload_hash(StoreId, Keys, Values, BatchSize) ->
    case reckon_gater_api:ccc_read_by_payload_hash(StoreId, Keys, Values, BatchSize) of
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @doc Payload field keys individually indexed in a store ({payload, Key}).
-spec payload_indexes(atom()) -> {ok, [binary()]} | {error, term()}.
payload_indexes(StoreId) ->
    case reckon_gater_api:get_payload_indexes(StoreId) of
        {ok, {ok, Keys}} when is_list(Keys) -> {ok, Keys};
        {ok, Keys} when is_list(Keys) -> {ok, Keys};
        {error, _} = Error -> Error
    end.

%% @doc Payload field key-sets hash-indexed in a store ({payload_hash, Keys}).
-spec payload_hash_indexes(atom()) -> {ok, [[binary()]]} | {error, term()}.
payload_hash_indexes(StoreId) ->
    case reckon_gater_api:get_payload_hash_indexes(StoreId) of
        {ok, {ok, KeySets}} when is_list(KeySets) -> {ok, KeySets};
        {ok, KeySets} when is_list(KeySets) -> {ok, KeySets};
        {error, _} = Error -> Error
    end.

%% @doc Get current stream version via gateway.
-spec version(atom(), binary()) -> integer().
version(StoreId, StreamId) ->
    case reckon_gater_api:get_version(StoreId, StreamId) of
        {ok, Version} -> Version;
        {error, _} -> ?NO_STREAM
    end.

%% @doc Check if stream exists via gateway.
-spec exists(atom(), binary()) -> boolean().
exists(StoreId, StreamId) ->
    version(StoreId, StreamId) >= 0.

%% @doc List all streams via gateway.
-spec list_streams(atom()) -> {ok, [binary()]} | {error, term()}.
list_streams(StoreId) ->
    case reckon_gater_api:get_streams(StoreId) of
        {ok, Streams} -> {ok, Streams};
        {error, _} = Error -> Error
    end.

%% @doc Delete a stream via gateway.
-spec delete_stream(atom(), binary()) -> ok | {error, term()}.
delete_stream(StoreId, StreamId) ->
    case reckon_gater_api:delete_stream(StoreId, StreamId) of
        {ok, ok} -> ok;
        ok -> ok;
        {error, _} = Error -> Error
    end.

%% @doc Mint a fresh stream id in the store's own contract.
%%
%% evoq asks the adapter for this rather than minting one itself: the format
%% (`<prefix>-<32 lowercase hex>`, UUIDv7 so ORDER BY stream_id is birth
%% order) is reckon's, and reckon_gater_stream_id is its one definition. A
%% caller reaches it as evoq_event_store:new_stream_id/1, so a service never
%% names reckon_gater to get an aggregate id.
%%
%% A malformed prefix raises {invalid_prefix, Prefix}, from the generator:
%% refusing loudly beats minting an id the store would reject on append.
-spec new_stream_id(atom() | binary()) -> nonempty_binary().
new_stream_id(Prefix) ->
    reckon_gater_stream_id:new(Prefix).

%%====================================================================
%% Snapshot Operations
%%====================================================================

%% @doc Save a snapshot via gateway.
-spec save(atom(), binary(), non_neg_integer(), map() | binary(), map()) ->
    ok | {error, term()}.
save(StoreId, StreamId, Version, Data, Metadata) ->
    %% reckon_gater_api uses SourceUuid, StreamUuid pattern
    %% For aggregate snapshots, both are typically the same
    SnapshotRecord = #{
        data => Data,
        metadata => Metadata,
        timestamp => erlang:system_time(millisecond)
    },
    reckon_gater_api:record_snapshot(StoreId, StreamId, StreamId, Version, SnapshotRecord).

%% @doc Read the latest snapshot via gateway.
-spec read(atom(), binary()) ->
    {ok, evoq_snapshot()} | {error, not_found | term()}.
read(StoreId, StreamId) ->
    fold_latest(
        reckon_gater_api:list_snapshots(StoreId, StreamId, StreamId),
        StreamId).

fold_latest({ok, []}, _StreamId) ->
    {error, not_found};
fold_latest({ok, Snapshots}, StreamId) ->
    Latest = lists:foldl(fun pick_higher_version/2, undefined, Snapshots),
    {ok, gater_to_evoq_snapshot(StreamId, Latest)};
fold_latest({error, _} = Error, _StreamId) ->
    Error.

pick_higher_version(S, undefined) -> S;
pick_higher_version(S, Acc)       -> higher(S, Acc, snapshot_version(S),
                                            snapshot_version(Acc)).

higher(S, _Acc, Sv, Av) when Sv > Av -> S;
higher(_S, Acc, _Sv, _Av)            -> Acc.

%% @doc Read snapshot at specific version via gateway.
-spec read_at_version(atom(), binary(), non_neg_integer()) ->
    {ok, evoq_snapshot()} | {error, not_found | term()}.
read_at_version(StoreId, StreamId, Version) ->
    convert_read_at(
        reckon_gater_api:read_snapshot(StoreId, StreamId, StreamId, Version),
        StreamId, Version).

convert_read_at({ok, S}, StreamId, _Version) ->
    {ok, gater_to_evoq_snapshot(StreamId, S)};
convert_read_at({error, _} = Error, _StreamId, _Version) ->
    Error.

%% @doc Delete all snapshots via gateway.
-spec delete(atom(), binary()) -> ok | {error, term()}.
delete(StoreId, StreamId) ->
    delete_all(
        reckon_gater_api:list_snapshots(StoreId, StreamId, StreamId),
        StoreId, StreamId).

delete_all({ok, Snapshots}, StoreId, StreamId) ->
    lists:foreach(
        fun(S) ->
            reckon_gater_api:delete_snapshot(
                StoreId, StreamId, StreamId, snapshot_version(S))
        end, Snapshots),
    ok;
delete_all({error, _}, _StoreId, _StreamId) ->
    ok.  %% Nothing to delete

%% @doc Delete snapshot at version via gateway.
-spec delete_at_version(atom(), binary(), non_neg_integer()) ->
    ok | {error, term()}.
delete_at_version(StoreId, StreamId, Version) ->
    reckon_gater_api:delete_snapshot(StoreId, StreamId, StreamId, Version).

%% @doc List snapshot versions via gateway.
-spec list_versions(atom(), binary()) ->
    {ok, [non_neg_integer()]} | {error, term()}.
list_versions(StoreId, StreamId) ->
    extract_versions(
        reckon_gater_api:list_snapshots(StoreId, StreamId, StreamId)).

extract_versions({ok, Snapshots}) ->
    {ok, lists:sort([snapshot_version(S) || S <- Snapshots])};
extract_versions({error, _} = Error) ->
    Error.

%%====================================================================
%% Internal — snapshot shape adaptation
%%====================================================================
%%
%% reckon-gater's snapshot operations return reckon_gater_types
%% `#snapshot{}' records (the spec says map, but the spec drifted
%% during the 2.1.0 tamper-resistance work). The adapter accepts both
%% shapes to be tolerant of future spec realignment; the field
%% accessor here is the seam.

snapshot_version(#snapshot{version = V})       -> V;
snapshot_version(M) when is_map(M)             -> maps:get(version, M, 0).

%% @private Translate a gater snapshot (record or map) into the
%% evoq-side `#evoq_snapshot{}'. anchor_hash and mac (storage-only) are
%% intentionally not propagated.
%%
%% save/5 hands the gateway #{data, metadata, timestamp}. Since reckon-db
%% 5.5.2 the gateway worker unwraps it, so the record's own `data' and
%% `metadata' fields hold what was saved. This read unwrapped them a second
%% time, `maps:get(data, UserData, #{})', and every snapshot came back with
%% empty data and metadata. A snapshot written before 5.5.2 still holds the
%% whole wrapper in `data' (metadata lost); it is recognised by that exact
%% key set.
gater_to_evoq_snapshot(StreamId, #snapshot{version = V, data = Data, metadata = Meta,
                                           timestamp = Ts}) ->
    evoq_snapshot_from(StreamId, V, legacy_wrapper(Data), Data, Meta, Ts);
gater_to_evoq_snapshot(StreamId, M) when is_map(M) ->
    Data = maps:get(data, M, #{}),
    evoq_snapshot_from(StreamId, maps:get(version, M, 0), legacy_wrapper(Data), Data,
                    maps:get(metadata, M, #{}), maps:get(timestamp, M, 0)).

%% A pre-5.5.2 record: the save/5 wrapper sits in `data'.
evoq_snapshot_from(StreamId, V, true, #{data := D, metadata := M, timestamp := T}, _Meta, _Ts) ->
    #evoq_snapshot{stream_id = StreamId, version = V, data = D, metadata = M, timestamp = T};
%% What reckon-db 5.5.2+ stores: data and metadata in their own fields.
evoq_snapshot_from(StreamId, V, false, Data, Meta, Ts) ->
    #evoq_snapshot{stream_id = StreamId, version = V, data = Data,
                   metadata = empty_if_undefined(Meta), timestamp = zero_if_undefined(Ts)}.

legacy_wrapper(Data) when is_map(Data) ->
    lists:sort(maps:keys(Data)) =:= [data, metadata, timestamp];
legacy_wrapper(_Data) ->
    false.

empty_if_undefined(undefined) -> #{};
empty_if_undefined(Meta) -> Meta.

zero_if_undefined(undefined) -> 0;
zero_if_undefined(Ts) -> Ts.

%%====================================================================
%% Subscription Operations
%%====================================================================

%% @doc Subscribe to events via gateway.
%%
%% When a subscriber_pid is provided, a bridge process is spawned that
%% receives raw #event{} records from ReckonDB and translates them to
%% #evoq_event{} records before forwarding to the subscriber.
%%
%% The subscriber always receives: {events, [#evoq_event{}]}
-spec subscribe(atom(), evoq_subscription_type(), binary() | map(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
subscribe(StoreId, Type, Selector, SubscriptionName, Opts) ->
    case start_from_position(maps:get(start_from, Opts, origin)) of
        {error, _} = Error ->
            Error;
        StartFrom ->
            SubscriberPid = maps:get(subscriber_pid, Opts, undefined),

            %% Map subscription type to gateway type atom
            GaterType = subscription_type_to_gater(Type),

            %% Interpose a bridge that translates #event{} -> #evoq_event{}
            RegistrationPid = registration_pid(SubscriberPid),

            reckon_gater_api:save_subscription(StoreId, GaterType, Selector, SubscriptionName,
                                               StartFrom, RegistrationPid),

            %% Generate subscription ID (gateway doesn't return one)
            SubscriptionId = generate_subscription_id(StoreId, SubscriptionName),
            {ok, SubscriptionId}
    end.

%% @private evoq's subscription adapters declare start_from as
%% origin | current | {position, N}; reckon-db's subscription holds an
%% integer offset. Passing the symbolic form straight through crashed
%% reckon_db_subscriptions when it used it as a checkpoint.
%%
%% `current' has no integer that means it here - "only events from now on"
%% is not "an offset" - so it is refused rather than silently started at 0,
%% which would replay the whole store to a subscriber that asked not to.
start_from_position(origin) ->
    0;
start_from_position({position, N}) when is_integer(N), N >= 0 ->
    N;
start_from_position(N) when is_integer(N), N >= 0 ->
    N;
start_from_position(current) ->
    {error, {unsupported_start_from, current}};
start_from_position(Other) ->
    {error, {bad_start_from, Other}}.

%% @private A bridge process per live subscriber; none for undefined.
registration_pid(undefined) -> undefined;
registration_pid(Pid) when is_pid(Pid) ->
    spawn_link(fun() -> subscription_bridge(Pid) end).

%% @doc Unsubscribe from events via gateway.
-spec unsubscribe(atom(), binary()) -> ok | {error, term()}.
unsubscribe(StoreId, SubscriptionId) ->
    %% Parse subscription info from ID
    case parse_subscription_id(SubscriptionId) of
        {ok, {Type, Selector, Name}} ->
            reckon_gater_api:remove_subscription(StoreId, Type, Selector, Name),
            ok;
        {error, _} = Error ->
            Error
    end.

%% @doc Acknowledge event via gateway.
%%
%% The gateway refuses an ack for a subscription that has been removed
%% ({error, {subscription_not_found, _}}), which is a caller error worth
%% seeing: the listening process is gone. The result is returned, not
%% swallowed, because an ack that silently does nothing is how a checkpoint
%% stops moving without anything saying so - and it is the caller that logs
%% it (evoq's store subscription already does), so this does not log it a
%% second time.
%%
%% The gateway answers {ok, _}, never a bare `ok', whatever its published
%% spec says; counting that as a failure is how every ack looked broken.
-spec ack(atom(), binary(), binary() | undefined, non_neg_integer()) ->
    ok | {error, term()}.
ack(StoreId, SubscriptionName, _StreamId, Position) ->
    %% The gateway ack reads a map: the position, and optionally the stream
    %% to acknowledge in. evoq acks the node's $all subscription, which has
    %% no stream of its own.
    EventMap = #{version => Position},
    ack_result(reckon_gater_api:ack_event(StoreId, SubscriptionName, self(), EventMap),
               StoreId, SubscriptionName, Position).

%% @private Any success answers ok, whatever the gateway wraps it in: the
%% reply is `{ok, Term}` today and the published spec has said bare `ok`, so
%% this deliberately does not enumerate the success shapes. The error is
%% returned, not logged here as well: the evoq store subscription that calls
%% this already logs a failed ack, and two warnings for one failure is noise
%% that hides the next one.
ack_result({error, _} = Error, _StoreId, _SubscriptionName, _Position) ->
    Error;
ack_result(_Success, _StoreId, _SubscriptionName, _Position) ->
    ok.

%% @doc Get checkpoint for subscription via gateway.
-spec get_checkpoint(atom(), binary()) ->
    {ok, non_neg_integer()} | {error, not_found | term()}.
get_checkpoint(StoreId, SubscriptionName) ->
    case reckon_gater_api:get_subscription(StoreId, SubscriptionName) of
        {ok, {ok, SubMap}} when is_map(SubMap) ->
            extract_checkpoint(SubMap);
        {ok, SubMap} when is_map(SubMap) ->
            extract_checkpoint(SubMap);
        {ok, {error, not_found}} ->
            {error, not_found};
        {error, not_found} ->
            {error, not_found};
        {error, _} = Error ->
            Error
    end.

%% @private Extract checkpoint from subscription map
-spec extract_checkpoint(map()) -> {ok, non_neg_integer()} | {error, not_found}.
extract_checkpoint(SubMap) ->
    case maps:get(checkpoint, SubMap, undefined) of
        undefined -> {error, not_found};
        Checkpoint when is_integer(Checkpoint) -> {ok, Checkpoint};
        _ -> {error, not_found}
    end.

%% @doc List subscriptions via gateway.
-spec list(atom()) -> {ok, [evoq_subscription()]} | {error, term()}.
list(StoreId) ->
    case reckon_gater_api:get_subscriptions(StoreId) of
        {ok, Subscriptions} ->
            Records = [map_to_evoq_subscription(S) || S <- Subscriptions],
            {ok, Records};
        {error, _} = Error ->
            Error
    end.

%% @doc Get subscription by name via gateway.
-spec get_by_name(atom(), binary()) ->
    {ok, evoq_subscription()} | {error, not_found | term()}.
get_by_name(StoreId, SubscriptionName) ->
    find_by_name(list(StoreId), SubscriptionName).

find_by_name({ok, Subscriptions}, SubscriptionName) ->
    first_subscription(
        lists:filter(
            fun(#evoq_subscription{subscription_name = N}) -> N =:= SubscriptionName end,
            Subscriptions));
find_by_name({error, _} = Error, _SubscriptionName) ->
    Error.

first_subscription([Sub | _]) -> {ok, Sub};
first_subscription([]) -> {error, not_found}.

%%====================================================================
%% Subscription Bridge
%%====================================================================

%% @private Bridge process that translates ReckonDB events to evoq events.
%%
%% ReckonDB emitters send {events, [#event{}]} to subscribers.
%% This bridge converts them to {events, [#evoq_event{}]} before
%% forwarding to the real subscriber, maintaining proper envelope
%% structure with nested data and metadata fields.
%%
%% The bridge is linked to the calling process (the subscriber)
%% via spawn_link, so it dies when the subscriber dies.
-spec subscription_bridge(pid()) -> no_return().
subscription_bridge(SubscriberPid) ->
    MonRef = monitor(process, SubscriberPid),
    subscription_bridge_loop(SubscriberPid, MonRef).

-spec subscription_bridge_loop(pid(), reference()) -> ok.
subscription_bridge_loop(SubscriberPid, MonRef) ->
    receive
        {events, Events} when is_list(Events) ->
            EvoqEvents = events_to_evoq(Events),
            SubscriberPid ! {events, EvoqEvents},
            subscription_bridge_loop(SubscriberPid, MonRef);
        {'DOWN', MonRef, process, SubscriberPid, _Reason} ->
            ok
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Map subscription type to gateway type atom
-spec subscription_type_to_gater(evoq_subscription_type()) -> atom().
subscription_type_to_gater(stream) -> by_stream;
subscription_type_to_gater(event_type) -> by_event_type;
subscription_type_to_gater(event_pattern) -> by_event_pattern;
subscription_type_to_gater(event_payload) -> by_event_payload;
subscription_type_to_gater(tags) -> by_tags.

%%====================================================================
%% Type Translation (reckon_gater -> evoq)
%%====================================================================

%% @private The reserved lineage keys, in the spelling evoq code uses.
%%
%% The same precedence as the write side, for the same reason: when a stored
%% map carries BOTH spellings of a reserved key the ATOM wins, because the
%% atom is what evoq stamped and the binary is the caller's copy - the pair
%% exists where a command's metadata carried a binary copy of the key, which
%% 2.8.0 and earlier stored beside the stamp. A fold would let map order
%% decide, which for a small map means the binary - the caller's value - and
%% that is the lineage the framework recorded being replaced.
-spec restore_reserved_keys(map()) -> map().
restore_reserved_keys(Metadata) when is_map(Metadata) ->
    %% Both spellings out, the winner back in: leaving the binary beside the
    %% atom hands a reader two answers for one question.
    Base = maps:without(?RESERVED_LINEAGE_KEYS ++
                            [reserved_key_binary(K) || K <- ?RESERVED_LINEAGE_KEYS],
                        Metadata),
    lists:foldl(fun(Key, Acc) -> restore_one(Key, Metadata, Acc) end,
                Base, ?RESERVED_LINEAGE_KEYS).

%% @private
-spec restore_one(atom(), map(), map()) -> map().
restore_one(Key, Metadata, Acc) ->
    case {maps:find(Key, Metadata), maps:find(reserved_key_binary(Key), Metadata)} of
        {{ok, Value}, _} -> Acc#{Key => Value};
        {error, {ok, Value}} -> Acc#{Key => Value};
        {error, error} -> Acc
    end.

%% @private Translate reckon_gater event to evoq event.
%%
%% Lineage keys come back as atoms. The store keeps metadata under the
%% binary spelling - that is what the {meta, Key} index matches, and what
%% evoq_to_reckon_event/1 writes - but an event delivered inside the BEAM is
%% read by evoq code and by the guides, both of which spell the reserved keys
%% as atoms. evoq_lineage handles either; a handler matching
%% #{correlation_id := C} does not. So the three keys evoq's lineage stamps,
%% held here as ?RESERVED_LINEAGE_KEYS, are translated on the way in, and
%% every other key is left exactly as the store holds it.
-spec event_to_evoq(event()) -> evoq_event().
event_to_evoq(#event{
    event_id = EventId,
    event_type = EventType,
    stream_id = StreamId,
    version = Version,
    data = Data,
    metadata = Metadata,
    tags = Tags,
    timestamp = Timestamp,
    epoch_us = EpochUs,
    data_content_type = DataContentType,
    metadata_content_type = MetadataContentType,
    prev_event_hash = PrevEventHash
}) ->
    #evoq_event{
        event_id = EventId,
        event_type = EventType,
        stream_id = StreamId,
        version = Version,
        data = Data,
        metadata = restore_reserved_keys(Metadata),
        tags = Tags,
        timestamp = Timestamp,
        epoch_us = EpochUs,
        data_content_type = DataContentType,
        metadata_content_type = MetadataContentType,
        prev_event_hash = PrevEventHash
        %% mac and signature intentionally NOT propagated —
        %% they belong to the storage layer.
    }.

%% @private Translate a list of reckon_gater events to evoq events
-spec events_to_evoq([event()]) -> [evoq_event()].
events_to_evoq(Events) ->
    [event_to_evoq(E) || E <- Events].

%% @private Translate an evoq event to the map reckon-db stores.
%%
%% Since evoq 1.5.0, append_events produces already-nested maps with
%% #{event_type, data, metadata}. The metadata keys are Erlang atoms in the
%% BEAM (evoq builds them that way, see evoq.hrl's reserved lineage keys),
%% and they are what evoq_lineage reads back.
%%
%% reckon-db, however, indexes and scans metadata by BINARY key: the
%% {meta, <<"causation_id">>} index (reckon_db_index.erl) and the scan that
%% answers read_by_metadata (reckon_db_streams.erl) both match the wire
%% spelling. Handing the store atom keys meant every lineage field was
%% written under a key the index could never match, so
%% evoq_lineage:get_effects/2 and get_correlated/2 always answered []: the
%% ids were in the store and unreachable.
-spec evoq_to_reckon_event(map()) -> map().
evoq_to_reckon_event(#{data := _, event_type := _} = Event) ->
    binary_key_metadata(Event);
evoq_to_reckon_event(#{<<"data">> := _, <<"event_type">> := _} = Event) ->
    Event.

%% @private
binary_key_metadata(#{metadata := Metadata} = Event) when is_map(Metadata) ->
    Event#{metadata => binary_keys(Metadata)};
binary_key_metadata(Event) ->
    Event.

%% @private Only the reserved lineage keys are rewritten, and only they are
%% translated back on read. An application's own metadata keys are stored and
%% returned exactly as the application wrote them: renaming those would mean
%% an atom goes in and a binary comes back, which is the surprise this side
%% of the adapter exists to avoid.
%%
%% When a map carries BOTH spellings of a reserved key, the atom wins. That
%% is the one evoq itself stamped (`evoq_command:ensure_id/1', the PM's
%% causation stamp); a `{<<"causation_id">>, ...}' sitting beside it is the
%% caller's copy, and letting it win would overwrite the lineage the
%% framework just recorded - silently, and only for the callers who happened
%% to send one. A fold over the map would let map order decide, so the
%% reserved keys are set last.
binary_keys(Map) ->
    Base = maps:without(?RESERVED_LINEAGE_KEYS, Map),
    lists:foldl(fun(Key, Acc) -> put_reserved_binary(Key, Map, Acc) end,
                Base, ?RESERVED_LINEAGE_KEYS).

%% @private
-spec put_reserved_binary(atom(), map(), map()) -> map().
put_reserved_binary(Key, Map, Acc) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Acc#{reserved_key_binary(Key) => Value};
        error -> Acc
    end.

%% @private
%%
%% No -spec on purpose: the three clauses answer three literals, and a
%% binary() spec is a supertype of that, which the dialyzer ratchet reports.
reserved_key_binary(causation_id) -> <<"causation_id">>;
reserved_key_binary(correlation_id) -> <<"correlation_id">>;
reserved_key_binary(conversation_id) -> <<"conversation_id">>.

%% @private Generate subscription ID
-spec generate_subscription_id(atom(), binary()) -> binary().
generate_subscription_id(StoreId, SubscriptionName) ->
    %% Simple ID format: store:name
    iolist_to_binary([atom_to_binary(StoreId, utf8), <<":">>, SubscriptionName]).

%% @private Parse subscription ID
-spec parse_subscription_id(binary()) -> {ok, {atom(), binary(), binary()}} | {error, invalid_id}.
parse_subscription_id(SubscriptionId) ->
    case binary:split(SubscriptionId, <<":">>) of
        [_StoreIdBin, Name] ->
            %% We don't have type/selector stored in ID
            %% This is a limitation - consider using different ID format
            {error, {missing_subscription_info, Name}};
        _ ->
            {error, invalid_id}
    end.

%% @private Convert map to evoq subscription record
-spec map_to_evoq_subscription(map()) -> evoq_subscription().
map_to_evoq_subscription(Map) ->
    #evoq_subscription{
        id = maps:get(id, Map, undefined),
        type = maps:get(type, Map, stream),
        selector = maps:get(selector, Map, <<>>),
        subscription_name = maps:get(subscription_name, Map, <<>>),
        subscriber_pid = maps:get(subscriber_pid, Map, undefined),
        created_at = maps:get(created_at, Map, 0),
        pool_size = maps:get(pool_size, Map, 1),
        checkpoint = maps:get(checkpoint, Map, undefined),
        options = maps:get(options, Map, #{})
    }.

%%====================================================================
%% Store Inspector Operations
%%====================================================================

-spec store_stats(atom()) -> {ok, map()} | {error, term()}.
store_stats(StoreId) ->
    reckon_gater_api:store_stats(StoreId).

-spec list_all_snapshots(atom()) -> {ok, [map()]} | {error, term()}.
list_all_snapshots(StoreId) ->
    reckon_gater_api:list_all_snapshots(StoreId).

-spec list_subscriptions(atom()) -> {ok, [map()]} | {error, term()}.
list_subscriptions(StoreId) ->
    reckon_gater_api:list_store_subscriptions(StoreId).

-spec subscription_lag(atom(), binary()) -> {ok, map()} | {error, term()}.
subscription_lag(StoreId, SubscriptionName) ->
    reckon_gater_api:subscription_lag(StoreId, SubscriptionName).

-spec event_type_summary(atom()) -> {ok, [map()]} | {error, term()}.
event_type_summary(StoreId) ->
    reckon_gater_api:event_type_summary(StoreId).

-spec stream_info(atom(), binary()) -> {ok, map()} | {error, term()}.
stream_info(StoreId, StreamId) ->
    reckon_gater_api:stream_info(StoreId, StreamId).
