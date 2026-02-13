%% @doc Gateway adapter implementation for evoq
%%
%% Implements the adapter behaviors using esdb_gater_api to route
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
-include_lib("reckon_gater/include/esdb_gater_types.hrl").

%% evoq types (what we return to evoq consumers)
%% Included second - uses ifndef guards for shared macros
-include_lib("evoq/include/evoq_types.hrl").

%%====================================================================
%% evoq_adapter callbacks (Event Store Operations)
%%====================================================================

-export([
    append/4,
    read/5,
    read_all/3,
    read_by_event_types/3,
    read_by_tags/3,
    read_by_tags/4,
    version/2,
    exists/2,
    list_streams/1,
    delete_stream/2
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
    case esdb_gater_api:append_events(StoreId, StreamId, ExpectedVersion, TransformedEvents) of
        {ok, NewVersion} ->
            {ok, NewVersion};
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
    case esdb_gater_api:get_events(StoreId, StreamId, StartVersion, Count, Direction) of
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
            NextVersion = case Direction of
                forward -> StartVersion + length(Events);
                backward -> max(0, StartVersion - length(Events))
            end,
            read_all_batched(StoreId, StreamId, NextVersion, Direction, Events ++ Acc);
        {error, _} = Error ->
            Error
    end.

%% @doc Read events by type via gateway.
%%
%% Uses the server-side native Khepri filtering for efficient type-based queries.
%% Events are filtered at the database level, avoiding loading all events into memory.
-spec read_by_event_types(atom(), [binary()], pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_by_event_types(StoreId, EventTypes, BatchSize) ->
    case esdb_gater_api:read_by_event_types(StoreId, EventTypes, BatchSize) of
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
    case esdb_gater_api:read_by_tags(StoreId, Tags, #{match => Match, batch_size => BatchSize}) of
        {ok, {ok, Events}} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {ok, Events} when is_list(Events) ->
            {ok, events_to_evoq(Events)};
        {error, _} = Error ->
            Error
    end.

%% @doc Get current stream version via gateway.
-spec version(atom(), binary()) -> integer().
version(StoreId, StreamId) ->
    case esdb_gater_api:get_version(StoreId, StreamId) of
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
    case esdb_gater_api:get_streams(StoreId) of
        {ok, Streams} -> {ok, Streams};
        {error, _} = Error -> Error
    end.

%% @doc Delete a stream via gateway.
-spec delete_stream(atom(), binary()) -> ok | {error, term()}.
delete_stream(StoreId, StreamId) ->
    case esdb_gater_api:delete_stream(StoreId, StreamId) of
        {ok, ok} -> ok;
        ok -> ok;
        {error, _} = Error -> Error
    end.

%%====================================================================
%% Snapshot Operations
%%====================================================================

%% @doc Save a snapshot via gateway.
-spec save(atom(), binary(), non_neg_integer(), map() | binary(), map()) ->
    ok | {error, term()}.
save(StoreId, StreamId, Version, Data, Metadata) ->
    %% esdb_gater_api uses SourceUuid, StreamUuid pattern
    %% For aggregate snapshots, both are typically the same
    SnapshotRecord = #{
        data => Data,
        metadata => Metadata,
        timestamp => erlang:system_time(millisecond)
    },
    esdb_gater_api:record_snapshot(StoreId, StreamId, StreamId, Version, SnapshotRecord).

%% @doc Read the latest snapshot via gateway.
-spec read(atom(), binary()) ->
    {ok, evoq_snapshot()} | {error, not_found | term()}.
read(StoreId, StreamId) ->
    %% List all snapshots and get the latest one
    case esdb_gater_api:list_snapshots(StoreId, StreamId, StreamId) of
        {ok, []} ->
            {error, not_found};
        {ok, Snapshots} ->
            %% Find the snapshot with highest version
            Latest = lists:foldl(
                fun(S, Acc) ->
                    SVersion = maps:get(version, S, 0),
                    AccVersion = maps:get(version, Acc, -1),
                    case SVersion > AccVersion of
                        true -> S;
                        false -> Acc
                    end
                end,
                #{version => -1},
                Snapshots
            ),
            {ok, map_to_evoq_snapshot(StreamId, Latest)};
        {error, _} = Error ->
            Error
    end.

%% @doc Read snapshot at specific version via gateway.
-spec read_at_version(atom(), binary(), non_neg_integer()) ->
    {ok, evoq_snapshot()} | {error, not_found | term()}.
read_at_version(StoreId, StreamId, Version) ->
    case esdb_gater_api:read_snapshot(StoreId, StreamId, StreamId, Version) of
        {ok, SnapshotMap} ->
            {ok, map_to_evoq_snapshot(StreamId, SnapshotMap#{version => Version})};
        {error, _} = Error ->
            Error
    end.

%% @doc Delete all snapshots via gateway.
-spec delete(atom(), binary()) -> ok | {error, term()}.
delete(StoreId, StreamId) ->
    %% List and delete all versions
    case esdb_gater_api:list_snapshots(StoreId, StreamId, StreamId) of
        {ok, Snapshots} ->
            lists:foreach(fun(S) ->
                Version = maps:get(version, S, 0),
                esdb_gater_api:delete_snapshot(StoreId, StreamId, StreamId, Version)
            end, Snapshots),
            ok;
        {error, _} ->
            ok  %% Nothing to delete
    end.

%% @doc Delete snapshot at version via gateway.
-spec delete_at_version(atom(), binary(), non_neg_integer()) ->
    ok | {error, term()}.
delete_at_version(StoreId, StreamId, Version) ->
    esdb_gater_api:delete_snapshot(StoreId, StreamId, StreamId, Version).

%% @doc List snapshot versions via gateway.
-spec list_versions(atom(), binary()) ->
    {ok, [non_neg_integer()]} | {error, term()}.
list_versions(StoreId, StreamId) ->
    case esdb_gater_api:list_snapshots(StoreId, StreamId, StreamId) of
        {ok, Snapshots} ->
            Versions = [maps:get(version, S, 0) || S <- Snapshots],
            {ok, lists:sort(Versions)};
        {error, _} = Error ->
            Error
    end.

%% @private Convert map to evoq snapshot record
-spec map_to_evoq_snapshot(binary(), map()) -> evoq_snapshot().
map_to_evoq_snapshot(StreamId, Map) ->
    #evoq_snapshot{
        stream_id = StreamId,
        version = maps:get(version, Map, 0),
        data = maps:get(data, Map, #{}),
        metadata = maps:get(metadata, Map, #{}),
        timestamp = maps:get(timestamp, Map, 0)
    }.

%%====================================================================
%% Subscription Operations
%%====================================================================

%% @doc Subscribe to events via gateway.
-spec subscribe(atom(), evoq_subscription_type(), binary() | map(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
subscribe(StoreId, Type, Selector, SubscriptionName, Opts) ->
    StartFrom = maps:get(start_from, Opts, 0),
    SubscriberPid = maps:get(subscriber_pid, Opts, undefined),

    %% Map subscription type to gateway type atom
    GaterType = subscription_type_to_gater(Type),

    esdb_gater_api:save_subscription(StoreId, GaterType, Selector, SubscriptionName, StartFrom, SubscriberPid),

    %% Generate subscription ID (gateway doesn't return one)
    SubscriptionId = generate_subscription_id(StoreId, SubscriptionName),
    {ok, SubscriptionId}.

%% @doc Unsubscribe from events via gateway.
-spec unsubscribe(atom(), binary()) -> ok | {error, term()}.
unsubscribe(StoreId, SubscriptionId) ->
    %% Parse subscription info from ID
    case parse_subscription_id(SubscriptionId) of
        {ok, {Type, Selector, Name}} ->
            esdb_gater_api:remove_subscription(StoreId, Type, Selector, Name),
            ok;
        {error, _} = Error ->
            Error
    end.

%% @doc Acknowledge event via gateway.
-spec ack(atom(), binary(), binary() | undefined, non_neg_integer()) ->
    ok | {error, term()}.
ack(StoreId, SubscriptionName, _StreamId, Position) ->
    %% Gateway ack expects an Event map, but we have position
    %% Create a minimal event map with version as position
    EventMap = #{version => Position},
    esdb_gater_api:ack_event(StoreId, SubscriptionName, self(), EventMap),
    ok.

%% @doc Get checkpoint for subscription via gateway.
-spec get_checkpoint(atom(), binary()) ->
    {ok, non_neg_integer()} | {error, not_found | term()}.
get_checkpoint(StoreId, SubscriptionName) ->
    case esdb_gater_api:get_subscription(StoreId, SubscriptionName) of
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
    case esdb_gater_api:get_subscriptions(StoreId) of
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
    case list(StoreId) of
        {ok, Subscriptions} ->
            case lists:filter(
                fun(#evoq_subscription{subscription_name = N}) -> N =:= SubscriptionName end,
                Subscriptions
            ) of
                [Sub | _] -> {ok, Sub};
                [] -> {error, not_found}
            end;
        {error, _} = Error ->
            Error
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

%% @private Translate reckon_gater event to evoq event
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
    metadata_content_type = MetadataContentType
}) ->
    #evoq_event{
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
        metadata_content_type = MetadataContentType
    }.

%% @private Translate a list of reckon_gater events to evoq events
-spec events_to_evoq([event()]) -> [evoq_event()].
events_to_evoq(Events) ->
    [event_to_evoq(E) || E <- Events].

%% @private Transform an evoq event (flat map) to reckon_db format (nested data)
%%
%% Evoq events are flat maps with all fields at the top level.
%% ReckonDB expects events with a nested data field.
%%
%% Handles both atom and binary keys in the event map (e.g., event_type or <<"event_type">>).
%%
%% Input (evoq):  #{event_type => artifact_installed, name => "...", metadata => #{}, tags => [...]}
%% Output (reckon_db): #{event_type => artifact_installed, data => #{name => "..."}, metadata => #{}, tags => [...]}
-spec evoq_to_reckon_event(map()) -> map().
evoq_to_reckon_event(Event) ->
    %% Extract fields that should be at top level (handles atom OR binary keys)
    EventType = get_flex(event_type, Event, undefined),
    Metadata = get_flex(metadata, Event, #{}),
    Tags = get_flex(tags, Event, undefined),
    CorrelationId = get_flex(correlation_id, Event, undefined),
    CausationId = get_flex(causation_id, Event, undefined),
    EventId = get_flex(event_id, Event, undefined),

    %% Build metadata with causation/correlation if present
    MetadataWithCausation = case {CorrelationId, CausationId} of
        {undefined, undefined} -> Metadata;
        {Corr, undefined} -> Metadata#{correlation_id => Corr};
        {undefined, Caus} -> Metadata#{causation_id => Caus};
        {Corr, Caus} -> Metadata#{correlation_id => Corr, causation_id => Caus}
    end,

    %% Everything else goes into data (excluding top-level fields, both atom and binary)
    TopLevelAtoms = [event_type, metadata, tags, correlation_id, causation_id, event_id,
                     data_content_type, metadata_content_type],
    TopLevelBins = [atom_to_binary(K) || K <- TopLevelAtoms],
    Data = maps:without(TopLevelAtoms ++ TopLevelBins, Event),

    %% Build reckon_db event
    BaseEvent = #{
        event_type => EventType,
        data => Data,
        metadata => MetadataWithCausation
    },

    %% Add optional tags if present
    EventWithTags = case Tags of
        undefined -> BaseEvent;
        [] -> BaseEvent;  %% Don't include empty tags
        TagList when is_list(TagList) -> BaseEvent#{tags => TagList}
    end,

    %% Add optional event_id if present
    case EventId of
        undefined -> EventWithTags;
        Id -> EventWithTags#{event_id => Id}
    end.

%% @private Get a value from a map, checking atom key first, then binary key.
%% Handles event maps that may use either convention.
-spec get_flex(atom(), map(), term()) -> term().
get_flex(AtomKey, Map, Default) ->
    case maps:find(AtomKey, Map) of
        {ok, V} -> V;
        error ->
            BinKey = atom_to_binary(AtomKey),
            maps:get(BinKey, Map, Default)
    end.

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
