%% @doc Persistent checkpoint store backed by ReckonDB snapshots.
%%
%% Implements evoq_checkpoint_store using reckon-gater snapshot API.
%% Projection checkpoints survive restarts by storing them as snapshots
%% in a ReckonDB store.
%%
%% Each projection gets a dedicated system stream named
%% "$evoq-checkpoint:{module_name}", holding ONE snapshot: the latest
%% checkpoint, at a snapshot version equal to the checkpoint. A save records
%% the new one and then removes the others; the checkpoint -1 ("nothing
%% projected", what a rebuild resets to) is no snapshot at all. So the
%% snapshot load/1 reads, the highest version, is always the last save: a
%% checkpoint from before a rebuild cannot outrank the rebuild's own, and no
%% clock is involved (reckon-evoq#1).
%%
%% The stream holds no events. On a store with integrity on, reckon-db
%% 5.11.14+ seals a snapshot on such a "$" stream with a store-bound MAC and
%% no chain anchor (reckon-db#25); a user stream would need an event to
%% anchor to and is refused. Every write is acknowledged (reckon-gater
%% 3.15.0+), so a refusal reaches the caller instead of a log line on the
%% store.
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

-include_lib("evoq/include/evoq_types.hrl").

%%====================================================================
%% evoq_checkpoint_store callbacks
%%====================================================================

%% @doc Load the checkpoint for a projection.
%% Read through the adapter, which picks the latest snapshot and reads both
%% what reckon-db 5.5.2+ returns (a #snapshot{} record, data in its own
%% field) and a checkpoint saved before 5.5.2 (the save/2 wrapper in data).
%% This read maps:get on the reply directly, which is a record, so it crashed
%% with badmap and a projection using this store could not start.
-spec load(atom()) -> {ok, non_neg_integer()} | {error, not_found | term()}.
load(ProjectionName) ->
    loaded(reckon_evoq_adapter:read(store_id(), stream_id(ProjectionName))).

loaded({ok, #evoq_snapshot{data = Data}}) when is_map(Data) ->
    checkpoint_result(maps:get(checkpoint, Data, undefined));
loaded({ok, #evoq_snapshot{}}) ->
    {error, not_found};
loaded({error, _} = Error) ->
    Error.

%% @doc Save a checkpoint for a projection.
%%
%% The new snapshot is recorded first and the older ones are removed after,
%% so a crash in between leaves two, and load/1 still reads the new one
%% (checkpoints only rise between resets). A refused record is returned and
%% nothing is removed. A removal that fails leaves an older, lower snapshot
%% behind, which load/1 never picks; its error is returned and the next save
%% removes it. The reset to -1 removes every snapshot.
-spec save(atom(), integer()) -> ok | {error, term()}.
save(ProjectionName, -1) ->
    delete(ProjectionName);
save(ProjectionName, Checkpoint) when is_integer(Checkpoint), Checkpoint >= 0 ->
    StoreId = store_id(),
    StreamId = stream_id(ProjectionName),
    SnapshotRecord = #{
        data => #{checkpoint => Checkpoint},
        metadata => #{saved_at => erlang:system_time(millisecond)},
        timestamp => erlang:system_time(millisecond)
    },
    recorded(reckon_gater_api:record_snapshot_sync(StoreId, StreamId, StreamId, Checkpoint,
                                                   SnapshotRecord),
             StoreId, StreamId, Checkpoint).

recorded(ok, StoreId, StreamId, Checkpoint) ->
    prune(reckon_evoq_adapter:list_versions(StoreId, StreamId), StoreId, StreamId, Checkpoint);
recorded({error, _} = Error, _StoreId, _StreamId, _Checkpoint) ->
    Error.

%% @private Remove every snapshot but the one at Keep.
prune({ok, Versions}, StoreId, StreamId, Keep) ->
    remove_versions([V || V <- Versions, V =/= Keep], StoreId, StreamId);
prune({error, _} = Error, _StoreId, _StreamId, _Keep) ->
    Error.

%% @doc Delete the checkpoint for a projection.
-spec delete(atom()) -> ok | {error, term()}.
delete(ProjectionName) ->
    StoreId = store_id(),
    StreamId = stream_id(ProjectionName),
    prune(reckon_evoq_adapter:list_versions(StoreId, StreamId), StoreId, StreamId, none).

%% @private Remove each version, every one tried; the first error is the
%% answer.
remove_versions(Versions, StoreId, StreamId) ->
    lists:foldl(fun(Version, Acc) ->
                    first_error(Acc, reckon_gater_api:delete_snapshot_sync(
                                       StoreId, StreamId, StreamId, Version))
                end, ok, Versions).

first_error(ok, Result) -> Result;
first_error({error, _} = Error, _Result) -> Error.

%% @private
checkpoint_result(undefined) -> {error, not_found};
checkpoint_result(Checkpoint) -> {ok, Checkpoint}.

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
    <<"$evoq-checkpoint:", NameBin/binary>>.
