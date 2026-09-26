%% @doc A snapshot read back through the adapter carries the data and
%% metadata that were saved.
%%
%% save/5 hands reckon-gater #{data, metadata, timestamp}. Since reckon-db
%% 5.5.2 the gateway worker unwraps that, storing the user's data in the
%% snapshot's own `data' field and the metadata in its `metadata' field.
%% gater_to_evoq_snapshot/2 still unwrapped a second time, maps:get(data,
%% UserData, #{}), so every snapshot came back with data = #{} and
%% metadata = #{}: an aggregate restored from a snapshot started from an
%% empty map (mcl-victron's from_snapshot/1 crashes on it). reckon-e2e's
%% adapters_produce_equivalent_outcomes caught it against a real store.
%%
%% Snapshots written before reckon-db 5.5.2 hold the whole wrapper in
%% `data'; those must still read back.
-module(reckon_evoq_snapshot_roundtrip_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").
-include_lib("evoq/include/evoq_types.hrl").

-define(STORE, snapshot_store).
-define(STREAM, <<"account-0123456789abcdef0123456789abcdef">>).
-define(DATA, #{state => mid_stream, processed_count => 2}).
-define(META, #{trace_id => <<"swap-trace-1">>}).

snapshot_roundtrip_test_() ->
    {foreach,
     fun() -> ok = meck:new(reckon_gater_api, [non_strict]) end,
     fun(_) -> meck:unload(reckon_gater_api) end,
     [{"latest, as reckon-db 5.5.2+ stores it", fun latest_current_shape/0},
      {"at a version, as reckon-db 5.5.2+ stores it", fun at_version_current_shape/0},
      {"latest, written before reckon-db 5.5.2", fun latest_legacy_shape/0},
      {"at a version, written before reckon-db 5.5.2", fun at_version_legacy_shape/0},
      {"the gateway's map shape", fun latest_map_shape/0},
      {"the gateway's map shape, written before reckon-db 5.5.2", fun latest_legacy_map_shape/0}]}.

%% What reckon_db_gateway_worker stores since 5.5.2: data and metadata in
%% their own fields.
current() ->
    #snapshot{stream_id = ?STREAM, version = 1, data = ?DATA, metadata = ?META,
              timestamp = 1700000000000}.

%% What it stored before: the whole save/5 wrapper as `data', metadata lost.
legacy() ->
    #snapshot{stream_id = ?STREAM, version = 1,
              data = #{data => ?DATA, metadata => ?META, timestamp => 1700000000000},
              metadata = #{}, timestamp = 1700000000000}.

latest_current_shape() ->
    meck:expect(reckon_gater_api, list_snapshots, fun(_, _, _) -> {ok, [current()]} end),
    assert_roundtrip(reckon_evoq_adapter:read(?STORE, ?STREAM)).

at_version_current_shape() ->
    meck:expect(reckon_gater_api, read_snapshot, fun(_, _, _, 1) -> {ok, current()} end),
    assert_roundtrip(reckon_evoq_adapter:read_at_version(?STORE, ?STREAM, 1)).

latest_legacy_shape() ->
    meck:expect(reckon_gater_api, list_snapshots, fun(_, _, _) -> {ok, [legacy()]} end),
    assert_roundtrip(reckon_evoq_adapter:read(?STORE, ?STREAM)).

at_version_legacy_shape() ->
    meck:expect(reckon_gater_api, read_snapshot, fun(_, _, _, 1) -> {ok, legacy()} end),
    assert_roundtrip(reckon_evoq_adapter:read_at_version(?STORE, ?STREAM, 1)).

latest_map_shape() ->
    Map = #{version => 1, data => ?DATA, metadata => ?META, timestamp => 1700000000000},
    meck:expect(reckon_gater_api, list_snapshots, fun(_, _, _) -> {ok, [Map]} end),
    assert_roundtrip(reckon_evoq_adapter:read(?STORE, ?STREAM)).

latest_legacy_map_shape() ->
    Map = #{version => 1, metadata => #{}, timestamp => 1700000000000,
            data => #{data => ?DATA, metadata => ?META, timestamp => 1700000000000}},
    meck:expect(reckon_gater_api, list_snapshots, fun(_, _, _) -> {ok, [Map]} end),
    assert_roundtrip(reckon_evoq_adapter:read(?STORE, ?STREAM)).

assert_roundtrip({ok, #evoq_snapshot{} = S}) ->
    ?assertEqual(?STREAM, S#evoq_snapshot.stream_id),
    ?assertEqual(1, S#evoq_snapshot.version),
    ?assertEqual(?DATA, S#evoq_snapshot.data),
    ?assertEqual(?META, S#evoq_snapshot.metadata),
    ?assertEqual(1700000000000, S#evoq_snapshot.timestamp).
