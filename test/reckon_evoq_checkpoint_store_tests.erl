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
    meck:expect(reckon_gater_api, record_snapshot,
        fun(test_store, StreamId, StreamId, 42, Record) ->
            ?assertMatch(<<"projection-checkpoint-", _/binary>>, StreamId),
            ?assertEqual(42, maps:get(checkpoint, maps:get(data, Record))),
            ok
        end),
    ?assertEqual(ok, reckon_evoq_checkpoint_store:save(my_projection, 42)),
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
