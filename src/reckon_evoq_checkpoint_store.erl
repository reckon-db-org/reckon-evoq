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
    reckon_evoq_adapter:delete(store_id(), stream_id(ProjectionName)).

%% @private
checkpoint_result(undefined) -> {error, not_found};
checkpoint_result(Checkpoint) -> {ok, Checkpoint}.

%% @private

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
