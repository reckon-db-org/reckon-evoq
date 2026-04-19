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
            case maps:get(checkpoint, Data, undefined) of
                undefined -> {error, not_found};
                Checkpoint -> {ok, Checkpoint}
            end;
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
            lists:foreach(fun(S) ->
                Version = maps:get(version, S, 0),
                reckon_gater_api:delete_snapshot(StoreId, StreamId, StreamId, Version)
            end, Snapshots),
            ok;
        {error, _} ->
            ok
    end.

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
    lists:foldl(fun(S, Acc) ->
        case maps:get(version, S, 0) > maps:get(version, Acc, 0) of
            true -> S;
            false -> Acc
        end
    end, hd(Snapshots), tl(Snapshots)).
