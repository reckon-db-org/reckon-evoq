%% @doc Persistent checkpoint store backed by ReckonDB snapshots.
%%
%% Implements evoq_checkpoint_store using reckon-gater snapshot API.
%% Projection checkpoints survive restarts by storing them as snapshots
%% in a ReckonDB store.
%%
%% Each projection gets a dedicated snapshot stream named
%% "projection-checkpoint-{module_name}".
%%
%% == Configuration ==
%%
%% Set the ReckonDB store to use for checkpoints:
%%   application:set_env(reckon_evoq, checkpoint_store_id, my_store).
%%
%% Default: default_store
%%
%% @author rgfaber
-module(reckon_evoq_checkpoint_store).
-behaviour(evoq_checkpoint_store).

-export([load/1, save/2, delete/1]).

%%====================================================================
%% evoq_checkpoint_store callbacks
%%====================================================================

%% @doc Load the checkpoint for a projection.
-spec load(atom()) -> {ok, non_neg_integer()} | {error, not_found | term()}.
load(ProjectionName) ->
    StoreId = store_id(),
    StreamId = stream_id(ProjectionName),
    case reckon_gater_api:list_snapshots(StoreId, StreamId, StreamId) of
        {ok, []} ->
            {error, not_found};
        {ok, Snapshots} when is_list(Snapshots) ->
            Latest = find_latest(Snapshots),
            Data = maps:get(data, Latest, #{}),
            checkpoint_result(maps:get(checkpoint, Data, undefined));
        {error, _} = Error ->
            Error
    end.

%% @doc Save a checkpoint for a projection.
-spec save(atom(), non_neg_integer()) -> ok | {error, term()}.
save(ProjectionName, Checkpoint) ->
    StoreId = store_id(),
    StreamId = stream_id(ProjectionName),
    SnapshotRecord = #{
        data => #{checkpoint => Checkpoint},
        metadata => #{saved_at => erlang:system_time(millisecond)},
        timestamp => erlang:system_time(millisecond)
    },
    reckon_gater_api:record_snapshot(StoreId, StreamId, StreamId, Checkpoint, SnapshotRecord).

%% @doc Delete the checkpoint for a projection.
-spec delete(atom()) -> ok | {error, term()}.
delete(ProjectionName) ->
    StoreId = store_id(),
    StreamId = stream_id(ProjectionName),
    case reckon_gater_api:list_snapshots(StoreId, StreamId, StreamId) of
        {ok, Snapshots} when is_list(Snapshots) ->
            delete_all_snapshots(StoreId, StreamId, Snapshots),
            ok;
        {error, _} ->
            ok
    end.

%% @private
checkpoint_result(undefined) -> {error, not_found};
checkpoint_result(Checkpoint) -> {ok, Checkpoint}.

%% @private
delete_all_snapshots(StoreId, StreamId, Snapshots) ->
    lists:foreach(fun(S) -> delete_snapshot(StoreId, StreamId, S) end, Snapshots).

delete_snapshot(StoreId, StreamId, S) ->
    Version = maps:get(version, S, 0),
    reckon_gater_api:delete_snapshot(StoreId, StreamId, StreamId, Version).

%%====================================================================
%% Internal
%%====================================================================

%% @private Get the configured store ID for checkpoints.
-spec store_id() -> atom().
store_id() ->
    application:get_env(reckon_evoq, checkpoint_store_id, default_store).

%% @private Build the snapshot stream ID for a projection.
-spec stream_id(atom()) -> binary().
stream_id(ProjectionName) ->
    NameBin = atom_to_binary(ProjectionName),
    <<"projection-checkpoint-", NameBin/binary>>.

%% @private Find the snapshot with the highest version.
-spec find_latest([map()]) -> map().
find_latest([Single]) ->
    Single;
find_latest(Snapshots) ->
    lists:foldl(fun keep_later/2, hd(Snapshots), tl(Snapshots)).

keep_later(S, Acc) ->
    later_of(maps:get(version, S, 0) > maps:get(version, Acc, 0), S, Acc).

later_of(true, S, _Acc) -> S;
later_of(false, _S, Acc) -> Acc.
