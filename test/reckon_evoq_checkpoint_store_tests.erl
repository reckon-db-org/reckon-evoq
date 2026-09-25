%% @doc Tests for reckon_evoq_checkpoint_store.
%%
%% Uses meck to mock reckon_gater_api since we cannot start
%% a real ReckonDB store in unit tests.
-module(reckon_evoq_checkpoint_store_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Setup / Teardown
%%====================================================================

setup() ->
    meck:new(reckon_gater_api, [non_strict]),
    application:set_env(reckon_evoq, checkpoint_store_id, test_store),
    ok.

teardown(_) ->
    meck:unload(reckon_gater_api),
    application:unset_env(reckon_evoq, checkpoint_store_id),
    ok.

%%====================================================================
%% Test Generators
%%====================================================================

checkpoint_store_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun save_records_snapshot/0,
        fun round_trip_preserves_tuple_order/0,
        fun load_returns_checkpoint/0,
        fun load_returns_not_found_when_empty/0,
        fun load_finds_latest_version/0,
        fun delete_removes_all_snapshots/0,
        fun delete_tolerates_errors/0,
        fun stream_id_includes_projection_name/0,
        fun uses_configured_store_id/0
    ]}.

%%====================================================================
%% Tests
%%====================================================================

save_records_snapshot() ->
    %% The snapshot VERSION is a monotonic timestamp, not the checkpoint
    %% value; the checkpoint lives in the data map verbatim.
    meck:expect(reckon_gater_api, record_snapshot,
        fun(test_store, StreamId, StreamId, Version, Record) ->
            ?assertMatch(<<"projection-checkpoint-", _/binary>>, StreamId),
            ?assert(is_integer(Version)),
            ?assertEqual(42, maps:get(checkpoint, maps:get(data, Record))),
            ok
        end),
    ?assertEqual(ok, reckon_evoq_checkpoint_store:save(my_projection, 42)),
    ?assert(meck:validate(reckon_gater_api)).

%% Check 2: the {epoch_us, stream_id, version} order key survives a store
%% and reload without changing its term or its order. Two keys that tie on
%% epoch_us but differ in stream_id and version must still compare the same
%% way after a round trip. Models the store faithfully: record_snapshot
%% keeps whatever data it is handed, list_snapshots returns it back.
round_trip_preserves_tuple_order() ->
    Table = ets:new(round_trip, [set, public]),
    meck:expect(reckon_gater_api, record_snapshot,
        fun(test_store, StreamId, StreamId, _Version, Record) ->
            ets:insert(Table, {StreamId, maps:get(checkpoint, maps:get(data, Record))}),
            ok
        end),
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, StreamId) ->
            case ets:lookup(Table, StreamId) of
                [{_, Checkpoint}] -> {ok, [#{version => 1, data => #{checkpoint => Checkpoint}}]};
                [] -> {ok, []}
            end
        end),

    KeyA = {100, <<"stream-a">>, 1},
    KeyB = {100, <<"stream-b">>, 2},
    ?assert(KeyA < KeyB),

    ok = reckon_evoq_checkpoint_store:save(proj_a, {5, KeyA}),
    ok = reckon_evoq_checkpoint_store:save(proj_b, {5, KeyB}),
    {ok, ReloadedA} = reckon_evoq_checkpoint_store:load(proj_a),
    {ok, ReloadedB} = reckon_evoq_checkpoint_store:load(proj_b),

    ?assertEqual({5, KeyA}, ReloadedA),
    ?assertEqual({5, KeyB}, ReloadedB),
    ?assert(ReloadedA < ReloadedB),

    ets:delete(Table),
    ?assert(meck:validate(reckon_gater_api)).

load_returns_checkpoint() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [#{version => 100, data => #{checkpoint => 100}}]}
        end),
    ?assertEqual({ok, 100}, reckon_evoq_checkpoint_store:load(my_projection)),
    ?assert(meck:validate(reckon_gater_api)).

load_returns_not_found_when_empty() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, []}
        end),
    ?assertEqual({error, not_found}, reckon_evoq_checkpoint_store:load(my_projection)),
    ?assert(meck:validate(reckon_gater_api)).

load_finds_latest_version() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [
                #{version => 10, data => #{checkpoint => 10}},
                #{version => 50, data => #{checkpoint => 50}},
                #{version => 30, data => #{checkpoint => 30}}
            ]}
        end),
    ?assertEqual({ok, 50}, reckon_evoq_checkpoint_store:load(my_projection)),
    ?assert(meck:validate(reckon_gater_api)).

delete_removes_all_snapshots() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [#{version => 10}, #{version => 20}]}
        end),
    meck:expect(reckon_gater_api, delete_snapshot,
        fun(test_store, _SourceId, _StreamId, _Version) -> ok end),
    ?assertEqual(ok, reckon_evoq_checkpoint_store:delete(my_projection)),
    ?assertEqual(2, meck:num_calls(reckon_gater_api, delete_snapshot, '_')),
    ?assert(meck:validate(reckon_gater_api)).

delete_tolerates_errors() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {error, store_not_found}
        end),
    ?assertEqual(ok, reckon_evoq_checkpoint_store:delete(my_projection)).

stream_id_includes_projection_name() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, StreamId, StreamId) ->
            ?assertEqual(<<"projection-checkpoint-order_summary">>, StreamId),
            {ok, []}
        end),
    reckon_evoq_checkpoint_store:load(order_summary),
    ?assert(meck:validate(reckon_gater_api)).

uses_configured_store_id() ->
    application:set_env(reckon_evoq, checkpoint_store_id, custom_store),
    meck:expect(reckon_gater_api, list_snapshots,
        fun(custom_store, _SourceId, _StreamId) ->
            {ok, []}
        end),
    reckon_evoq_checkpoint_store:load(my_projection),
    ?assert(meck:validate(reckon_gater_api)),
    %% Restore
    application:set_env(reckon_evoq, checkpoint_store_id, test_store).
