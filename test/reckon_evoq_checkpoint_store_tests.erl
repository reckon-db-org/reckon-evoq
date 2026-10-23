%% @doc Tests for reckon_evoq_checkpoint_store.
%%
%% Uses meck to mock reckon_gater_api since we cannot start
%% a real ReckonDB store in unit tests. The mocked replies are
%% #snapshot{} records, which is what reckon_db_gateway_worker returns
%% for list_snapshots (reckon_db_snapshots_store builds them). The tests
%% used maps, so load/1 and delete/1 (maps:get on a record: badmap) were
%% green on a shape the store never sends.
-module(reckon_evoq_checkpoint_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

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
        fun load_reads_a_checkpoint_saved_before_reckon_db_5_5_2/0,
        fun delete_removes_all_snapshots/0,
        fun delete_reports_a_store_that_cannot_list/0,
        fun an_integrity_store_refusal_reaches_the_caller/0,
        fun a_failed_prune_is_reported/0,
        fun stream_id_includes_projection_name/0,
        fun uses_configured_store_id/0
    ]}.

%% Against a stand-in that keeps snapshots as the store does (one per
%% version, the newest by version is the one load/1 reads).
checkpoint_lifecycle_test_() ->
    {foreach, fun stateful_setup/0, fun teardown/1, [
        fun a_save_keeps_one_snapshot/0,
        fun a_reset_removes_the_checkpoint_and_records_no_negative_version/0,
        fun a_rebuild_that_stops_part_way_resumes_from_its_own_checkpoint/0,
        fun the_latest_save_is_what_load_returns/0
    ]}.

%%====================================================================
%% Tests
%%====================================================================

save_records_snapshot() ->
    meck:expect(reckon_gater_api, record_snapshot_sync,
        fun(test_store, StreamId, StreamId, 42, Record) ->
            ?assertMatch(<<"$evoq-checkpoint:", _/binary>>, StreamId),
            ?assertEqual(42, maps:get(checkpoint, maps:get(data, Record))),
            ok
        end),
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) -> {ok, [snap(42, #{checkpoint => 42})]} end),
    ?assertEqual(ok, reckon_evoq_checkpoint_store:save(my_projection, 42)),
    ?assert(meck:validate(reckon_gater_api)).

load_returns_checkpoint() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [snap(100, #{checkpoint => 100})]}
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
            {ok, [snap(10, #{checkpoint => 10}),
                  snap(50, #{checkpoint => 50}),
                  snap(30, #{checkpoint => 30})]}
        end),
    ?assertEqual({ok, 50}, reckon_evoq_checkpoint_store:load(my_projection)),
    ?assert(meck:validate(reckon_gater_api)).

%% A checkpoint written before reckon-db 5.5.2: the whole save/2 wrapper sits
%% in the record's data field.
load_reads_a_checkpoint_saved_before_reckon_db_5_5_2() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [snap(7, #{data => #{checkpoint => 7}, metadata => #{saved_at => 1},
                            timestamp => 1})]}
        end),
    ?assertEqual({ok, 7}, reckon_evoq_checkpoint_store:load(my_projection)).

delete_removes_all_snapshots() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [snap(10, #{checkpoint => 10}), snap(20, #{checkpoint => 20})]}
        end),
    meck:expect(reckon_gater_api, delete_snapshot_sync,
        fun(test_store, _SourceId, _StreamId, _Version) -> ok end),
    ?assertEqual(ok, reckon_evoq_checkpoint_store:delete(my_projection)),
    ?assertEqual(2, meck:num_calls(reckon_gater_api, delete_snapshot_sync, '_')),
    ?assert(meck:validate(reckon_gater_api)).

%% A reset whose snapshots cannot be listed did not happen, and says so: an
%% "ok" here would let a rebuild run on over the old checkpoint.
delete_reports_a_store_that_cannot_list() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {error, store_not_found}
        end),
    ?assertEqual({error, store_not_found}, reckon_evoq_checkpoint_store:delete(my_projection)).

%% The failure this closes: record_snapshot is a cast, so when an integrity
%% store refused a checkpoint it could not anchor, save/2 still answered ok
%% and the checkpoint was never persisted. The projection replayed from the
%% start on every boot and nothing said why. The refusal now reaches the
%% caller, and nothing is pruned on its account.
an_integrity_store_refusal_reaches_the_caller() ->
    Refusal = {error, {snapshot_anchor_unavailable, #{reason => event_not_found}}},
    meck:expect(reckon_gater_api, record_snapshot_sync,
        fun(test_store, _SourceId, _StreamId, 42, _Record) -> Refusal end),
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) -> {ok, [snap(41, #{checkpoint => 41})]} end),
    meck:expect(reckon_gater_api, delete_snapshot_sync,
        fun(test_store, _SourceId, _StreamId, _Version) -> ok end),
    ?assertEqual(Refusal, reckon_evoq_checkpoint_store:save(my_projection, 42)),
    ?assertEqual(0, meck:num_calls(reckon_gater_api, delete_snapshot_sync, '_')).

%% The new checkpoint is written, an older one could not be removed: load/1
%% still reads the new one, and the caller hears of the leftover.
a_failed_prune_is_reported() ->
    meck:expect(reckon_gater_api, record_snapshot_sync,
        fun(test_store, _SourceId, _StreamId, 42, _Record) -> ok end),
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _SourceId, _StreamId) ->
            {ok, [snap(41, #{checkpoint => 41}), snap(42, #{checkpoint => 42})]}
        end),
    meck:expect(reckon_gater_api, delete_snapshot_sync,
        fun(test_store, _SourceId, _StreamId, 41) -> {error, timeout} end),
    ?assertEqual({error, timeout}, reckon_evoq_checkpoint_store:save(my_projection, 42)).

stream_id_includes_projection_name() ->
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, StreamId, StreamId) ->
            ?assertEqual(<<"$evoq-checkpoint:order_summary">>, StreamId),
            %% A system stream: the id reckon-db accepts, and the one an
            %% integrity store seals without an anchor (reckon-db#25).
            ?assert(reckon_gater_stream_id:is_system(StreamId)),
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

%% A projection saves after every event: the store must hold its latest
%% checkpoint, not one snapshot per event it ever projected.
a_save_keeps_one_snapshot() ->
    [ok = reckon_evoq_checkpoint_store:save(my_projection, N) || N <- lists:seq(0, 9)],
    ?assertEqual([9], stored_versions()),
    ?assertEqual({ok, 9}, reckon_evoq_checkpoint_store:load(my_projection)).

%% A rebuild resets its checkpoint to -1, "nothing projected". That is no
%% snapshot at all; a snapshot version is a non-negative integer.
a_reset_removes_the_checkpoint_and_records_no_negative_version() ->
    ok = reckon_evoq_checkpoint_store:save(my_projection, 5000),
    ok = reckon_evoq_checkpoint_store:save(my_projection, -1),
    ?assertEqual([], stored_versions()),
    ?assertEqual({error, not_found}, reckon_evoq_checkpoint_store:load(my_projection)).

%% The failure this closes: the checkpoint before a rebuild outranked every
%% checkpoint the rebuild saved, so a rebuild stopped part way came back at
%% the old checkpoint over a cleared read model and skipped the rest.
a_rebuild_that_stops_part_way_resumes_from_its_own_checkpoint() ->
    ok = reckon_evoq_checkpoint_store:save(my_projection, 5000),
    ok = reckon_evoq_checkpoint_store:save(my_projection, -1),
    [ok = reckon_evoq_checkpoint_store:save(my_projection, N) || N <- lists:seq(0, 99)],
    ?assertEqual({ok, 99}, reckon_evoq_checkpoint_store:load(my_projection)).

%% reckon-evoq#1: "latest" is the last save, decided by the checkpoint
%% itself and never by a clock: save A, save B, load returns B.
the_latest_save_is_what_load_returns() ->
    ok = reckon_evoq_checkpoint_store:save(my_projection, 41),
    ok = reckon_evoq_checkpoint_store:save(my_projection, 42),
    ?assertEqual({ok, 42}, reckon_evoq_checkpoint_store:load(my_projection)).

stateful_setup() ->
    setup(),
    Table = snapshot_table(),
    meck:expect(reckon_gater_api, record_snapshot_sync,
        fun(test_store, Id, Id, Version, #{data := Data}) when is_integer(Version), Version >= 0 ->
                true = ets:insert(Table, {Version, snap(Version, Data)}),
                ok;
           (test_store, _Id, _Id, Version, _Record) ->
                {error, {bad_version, Version}}
        end),
    meck:expect(reckon_gater_api, list_snapshots,
        fun(test_store, _Id, _Id) -> {ok, [S || {_, S} <- ets:tab2list(Table)]} end),
    meck:expect(reckon_gater_api, delete_snapshot_sync,
        fun(test_store, _Id, _Id, Version) -> true = ets:delete(Table, Version), ok end),
    ok.

%% A fresh named table, owned by a process of its own: eunit may run a
%% fixture's setup and its test in different processes.
snapshot_table() ->
    stop_holder(persistent_term:get({?MODULE, holder}, undefined)),
    Self = self(),
    Holder = spawn(fun() ->
        ets:new(?MODULE, [named_table, public, ordered_set]),
        Self ! table_ready,
        receive stop -> ok end
    end),
    receive table_ready -> ok end,
    persistent_term:put({?MODULE, holder}, Holder),
    ?MODULE.

stop_holder(undefined) ->
    ok;
stop_holder(Pid) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', MRef, process, Pid, _} -> ok end.

stored_versions() ->
    [V || {V, _} <- ets:tab2list(?MODULE)].

%% What reckon-db 5.5.2+ returns: a record, data and metadata in their own
%% fields.
snap(Version, Data) ->
    #snapshot{stream_id = <<"$evoq-checkpoint:my_projection">>, version = Version,
              data = Data, metadata = #{saved_at => 1}, timestamp = 1}.
