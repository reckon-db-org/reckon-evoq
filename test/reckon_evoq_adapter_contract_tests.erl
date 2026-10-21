%% @doc The adapter's contract with reckon-db, where the BEAM side and the
%% store side disagree about a shape (GY-AW alignment, reckon-db-org/evoq#22).
%%
%% Three places the adapter translated (or failed to translate) between
%% what evoq hands it and what reckon-db accepts:
%%
%% 1. Lineage metadata. evoq builds metadata maps with atom keys; reckon-db
%%    indexes and scans {meta, <<"causation_id">>} by BINARY key. Passing
%%    the map through unchanged wrote every lineage field under a key the
%%    index could never match, so evoq_lineage:get_effects/2 always
%%    answered [].
%% 2. start_from. evoq declares origin | current | {position, N};
%%    reckon-db's subscription holds an integer offset and crashed on the
%%    symbolic form.
%% 3. ack. The gateway can refuse an ack for a subscription that is gone;
%%    the adapter discarded the answer and always said ok.
-module(reckon_evoq_adapter_contract_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").
-include_lib("evoq/include/evoq_types.hrl").

-define(STORE, test_store).

%%====================================================================
%% Lineage metadata
%%====================================================================

%% The metadata reaches the store with binary keys, so read_by_metadata can
%% match it.
lineage_metadata_reaches_the_store_binary_keyed_test() ->
    Events = capture_append(fun() ->
        {ok, _} = reckon_evoq_adapter:append(?STORE, <<"order-1">>, -1, [nested_event()])
    end),
    [Event] = Events,
    Metadata = maps:get(metadata, Event),
    ?assertEqual([<<"causation_id">>, <<"correlation_id">>],
                 lists:sort(maps:keys(Metadata))),
    ?assertEqual(<<"cmd-1">>, maps:get(<<"causation_id">>, Metadata)),
    ?assertEqual(<<"conv-1">>, maps:get(<<"correlation_id">>, Metadata)).

%% A metadata map that is already binary-keyed passes through untouched:
%% the adapter is not a rewriter, it is a translator for the one difference.
binary_keyed_metadata_is_passed_through_test() ->
    Events = capture_append(fun() ->
        {ok, _} = reckon_evoq_adapter:append(?STORE, <<"order-1">>, -1,
                                        [nested_event(#{<<"causation_id">> => <<"cmd-1">>})])
    end),
    [Event] = Events,
    ?assertEqual(#{<<"causation_id">> => <<"cmd-1">>}, maps:get(metadata, Event)).

%% An application's own keys are never renamed, in either direction: only
%% the three reserved lineage keys are, because only those have to match the
%% store's index.
an_applications_own_keys_are_not_renamed_test() ->
    Events = capture_append(fun() ->
        {ok, _} = reckon_evoq_adapter:append(
                    ?STORE, <<"order-1">>, -1,
                    [nested_event(#{trace => #{hop => 1},
                                    user_id => <<"usr-9">>})])
    end),
    [Event] = Events,
    Metadata = maps:get(metadata, Event),
    ?assertEqual(#{hop => 1}, maps:get(trace, Metadata)),
    ?assertEqual(<<"usr-9">>, maps:get(user_id, Metadata)).

%% Both spellings of a reserved key in one map: the ATOM wins. evoq stamps
%% the atom form (the router's ensure_id, a PM's causation stamp); a
%% <<"causation_id">> beside it is the caller's copy, and it must not be
%% allowed to overwrite the lineage the framework recorded.
atom_spelling_wins_over_the_binary_one_test() ->
    Events = capture_append(fun() ->
        {ok, _} = reckon_evoq_adapter:append(
                    ?STORE, <<"order-1">>, -1,
                    [nested_event(#{causation_id => <<"from-evoq">>,
                                    <<"causation_id">> => <<"from-the-caller">>})])
    end),
    [Event] = Events,
    Metadata = maps:get(metadata, Event),
    ?assertEqual(<<"from-evoq">>, maps:get(<<"causation_id">>, Metadata)),
    %% Exactly one entry for the key, not two spellings of it.
    ?assertEqual([<<"causation_id">>], maps:keys(Metadata)).

%% The same, with a map large enough to be a HASHMAP rather than a flatmap.
%% This one is a guard, not the evidence: a hashmap's fold order varies
%% between VM instances, so on the previous code it could pass. The two-key
%% case above is the deterministic red - a flatmap iterates in key order, and
%% an atom sorts before a binary, so the binary always won there.
atom_spelling_wins_in_a_large_map_test() ->
    Filler = maps:from_list([{<<"filler_", (integer_to_binary(N))/binary>>, N}
                             || N <- lists:seq(1, 64)]),
    Metadata = Filler#{causation_id => <<"from-evoq">>,
                       <<"causation_id">> => <<"from-the-caller">>,
                       correlation_id => <<"conv-evoq">>,
                       <<"correlation_id">> => <<"conv-caller">>},
    Events = capture_append(fun() ->
        {ok, _} = reckon_evoq_adapter:append(?STORE, <<"order-1">>, -1,
                                            [nested_event(Metadata)])
    end),
    [Event] = Events,
    Stored = maps:get(metadata, Event),
    ?assertEqual(<<"from-evoq">>, maps:get(<<"causation_id">>, Stored)),
    ?assertEqual(<<"conv-evoq">>, maps:get(<<"correlation_id">>, Stored)),
    ?assertEqual(64, length([K || K <- maps:keys(Stored),
                                  binary:match(K, <<"filler_">>) =/= nomatch])).

%% data is business payload and is not touched at all.
data_is_untouched_test() ->
    Events = capture_append(fun() ->
        {ok, _} = reckon_evoq_adapter:append(?STORE, <<"order-1">>, -1, [nested_event()])
    end),
    [Event] = Events,
    ?assertEqual(#{amount => 100}, maps:get(data, Event)).

%% The reserved lineage keys arrive atom-keyed, so a handler matching
%% #{correlation_id := C} - the spelling evoq's guides use - still matches.
%% Every other key is left as the store holds it.
lineage_keys_come_back_as_atoms_test() ->
    Stored = #event{
        event_id = <<"evt-1">>,
        event_type = <<"order_placed_v1">>,
        stream_id = <<"order-1">>,
        version = 0,
        data = #{},
        metadata = #{<<"causation_id">> => <<"cmd-1">>,
                     <<"correlation_id">> => <<"conv-1">>,
                     user_id => <<"usr-9">>},
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    },
    with_gater(fun() ->
        meck:expect(reckon_gater_api, get_events,
                    fun(_S, _St, _From, _Count, _Dir) -> {ok, [Stored]} end),
        {ok, [Event]} = reckon_evoq_adapter:read(?STORE, <<"order-1">>, 0, 10, forward),
        Metadata = Event#evoq_event.metadata,
        ?assertEqual(<<"cmd-1">>, maps:get(causation_id, Metadata)),
        ?assertEqual(<<"conv-1">>, maps:get(correlation_id, Metadata)),
        ?assertEqual(<<"usr-9">>, maps:get(user_id, Metadata)),
        ?assertEqual(<<"cmd-1">>, evoq_lineage:causation_id(Metadata))
    end).

%% The read side has the same precedence as the write side: a stored map
%% with BOTH spellings of a reserved key reads back the ATOM, whatever the
%% fold order. Maps like that are real: a write whose command metadata
%% carried a binary copy of the key, which 2.8.0 and earlier kept beside
%% evoq's atom stamp.
%%
%% The 64-key half is a guard, not the evidence: a hashmap's fold order
%% varies between VM instances, so on the previous code (3a1f453) it was red
%% in 1 of 9 runs. The two-key half is the deterministic red.
a_stored_map_with_both_spellings_reads_the_atom_test_() ->
    [?_test(both_spellings_read_the_atom(M)) || M <- [small_stored_map(),
                                                      large_stored_map()]].

both_spellings_read_the_atom(Stored) ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, get_events,
                    fun(_S, _St, _From, _Count, _Dir) -> {ok, [Stored]} end),
        {ok, [Event]} = reckon_evoq_adapter:read(?STORE, <<"order-1">>, 0, 10, forward),
        Metadata = Event#evoq_event.metadata,
        ?assertEqual(<<"cmd-evoq">>, maps:get(causation_id, Metadata)),
        ?assertEqual(error, maps:find(<<"causation_id">>, Metadata))
    end).

%% An application's own key written as a binary stays a binary on the way
%% back: the translation is a rename of the three reserved keys, not a
%% normalisation of the map. A store written by this adapter or before it
%% must read back with the spelling it was given.
an_applications_binary_key_stays_binary_on_read_test() ->
    Stored = #event{
        event_id = <<"evt-bin">>,
        event_type = <<"order_placed_v1">>,
        stream_id = <<"order-1">>,
        version = 0,
        data = #{},
        metadata = #{<<"causation_id">> => <<"cmd-1">>,
                     <<"tenant">> => <<"acme">>},
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    },
    with_gater(fun() ->
        meck:expect(reckon_gater_api, get_events,
                    fun(_S, _St, _From, _Count, _Dir) -> {ok, [Stored]} end),
        {ok, [Event]} = reckon_evoq_adapter:read(?STORE, <<"order-1">>, 0, 10, forward),
        Metadata = Event#evoq_event.metadata,
        ?assertEqual(<<"acme">>, maps:get(<<"tenant">>, Metadata)),
        ?assertEqual(error, maps:find(tenant, Metadata)),
        ?assertEqual(<<"cmd-1">>, maps:get(causation_id, Metadata))
    end).

%% An event written before this release stored the reserved keys as ATOMS.
%% It must read back exactly as it was written: the translation is for the
%% wire spelling, not a migration of what is already in the store.
an_old_atom_keyed_event_reads_back_unchanged_test() ->
    Stored = #event{
        event_id = <<"evt-old">>,
        event_type = <<"order_placed_v1">>,
        stream_id = <<"order-1">>,
        version = 0,
        data = #{},
        metadata = #{causation_id => <<"cmd-old">>,
                     correlation_id => <<"conv-old">>,
                     user_id => <<"usr-1">>},
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    },
    with_gater(fun() ->
        meck:expect(reckon_gater_api, get_events,
                    fun(_S, _St, _From, _Count, _Dir) -> {ok, [Stored]} end),
        {ok, [Event]} = reckon_evoq_adapter:read(?STORE, <<"order-1">>, 0, 10, forward),
        %% Same map out as in: atom keys stay atom keys.
        ?assertEqual(#{causation_id => <<"cmd-old">>,
                       correlation_id => <<"conv-old">>,
                       user_id => <<"usr-1">>},
                     Event#evoq_event.metadata)
    end).

%% A non-integer, non-symbolic start_from is refused, not a function_clause.
an_unknown_start_from_is_refused_test() ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, save_subscription,
                    fun(_S, _T, _Sel, _N, _From, _Pid) -> ok end),
        ?assertEqual({error, {bad_start_from, <<"tomorrow">>}},
                     reckon_evoq_adapter:subscribe(?STORE, stream, <<"s">>, <<"sub">>,
                                                   #{start_from => <<"tomorrow">>}))
    end).

%% A query key or value that is not a binary is answered here, before the
%% gateway is called. It used to reach the store's callback and take the
%% gateway worker with it: the worker had no clause for an atom key, the
%% gateway read the exit as transient, and the caller waited out ten retries
%% - about 89 seconds - for an answer it could have had at once.
a_non_binary_metadata_query_is_refused_at_once_test_() ->
    [?_assertEqual({error, {invalid_metadata_key, causation_id}},
                   reckon_evoq_adapter:read_by_metadata(?STORE, causation_id,
                                                        <<"cmd-1">>)),
     ?_assertEqual({error, {invalid_metadata_key, "causation_id"}},
                   reckon_evoq_adapter:read_by_metadata(?STORE, "causation_id",
                                                        <<"cmd-1">>)),
     ?_assertEqual({error, {invalid_metadata_value, 42}},
                   reckon_evoq_adapter:read_by_metadata(?STORE, <<"causation_id">>,
                                                        42))].

%%====================================================================
%% start_from
%%====================================================================

%% origin is offset 0.
origin_becomes_zero_test() ->
    ?assertEqual(0, captured_start_from(#{start_from => origin})).

%% {position, N} is N.
a_position_is_passed_through_test() ->
    ?assertEqual(42, captured_start_from(#{start_from => {position, 42}})).

%% An integer is already what the store wants.
an_integer_is_passed_through_test() ->
    ?assertEqual(7, captured_start_from(#{start_from => 7})).

%% current means "from now on", which is not an offset: refused, rather
%% than silently starting at 0 and replaying the whole store.
current_is_refused_test() ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, save_subscription,
                    fun(_S, _T, _Sel, _N, _From, _Pid) -> ok end),
        ?assertEqual({error, {unsupported_start_from, current}},
                     reckon_evoq_adapter:subscribe(?STORE, stream, <<"s">>, <<"sub">>,
                                                   #{start_from => current})),
        ?assertEqual(0, meck:num_calls(reckon_gater_api, save_subscription, 6))
    end).

%% The default is origin, and reaches the store as 0.
the_default_is_origin_test() ->
    ?assertEqual(0, captured_start_from(#{})).

%%====================================================================
%% ack
%%====================================================================

%% A refused ack is returned, not turned into ok: the subscription is gone
%% and the events will come again on the next boot.
a_refused_ack_is_returned_test() ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, ack_event,
                    fun(_S, _N, _Pid, _E) -> {error, {subscription_not_found, <<"sub">>}} end),
        ?assertEqual({error, {subscription_not_found, <<"sub">>}},
                     reckon_evoq_adapter:ack(?STORE, <<"sub">>, undefined, 7))
    end).

%% A good ack still answers ok. The gateway replies {ok, _} - the wrapped
%% form every call in reckon_gater_api uses - and a bare ok is not what it
%% returns.
a_good_ack_answers_ok_test() ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, ack_event, fun(_S, _N, _Pid, _E) -> {ok, ok} end),
        ?assertEqual(ok, reckon_evoq_adapter:ack(?STORE, <<"sub">>, undefined, 7))
    end).

%%====================================================================
%% Helpers
%%====================================================================

small_stored_map() ->
    stored_event(#{causation_id => <<"cmd-evoq">>,
                   <<"causation_id">> => <<"cmd-caller">>}).

large_stored_map() ->
    Filler = maps:from_list([{<<"filler_", (integer_to_binary(N))/binary>>, N}
                             || N <- lists:seq(1, 64)]),
    stored_event(Filler#{causation_id => <<"cmd-evoq">>,
                         <<"causation_id">> => <<"cmd-caller">>}).

stored_event(Metadata) ->
    #event{
        event_id = <<"evt-both">>,
        event_type = <<"order_placed_v1">>,
        stream_id = <<"order-1">>,
        version = 0,
        data = #{},
        metadata = Metadata,
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    }.

nested_event() ->
    nested_event(#{causation_id => <<"cmd-1">>, correlation_id => <<"conv-1">>}).

nested_event(Metadata) ->
    #{event_type => <<"order_placed_v1">>,
      data => #{amount => 100},
      metadata => Metadata}.

%% Let the append reach a mocked gateway and hand back what it was given.
capture_append(Fun) ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, append_events,
                    fun(_Store, _Stream, _Version, Events) ->
                        persistent_term:put({?MODULE, appended}, Events),
                        {ok, 1}
                    end),
        {ok, _} = Fun(),
        persistent_term:get({?MODULE, appended})
    end).

captured_start_from(Opts) ->
    with_gater(fun() ->
        meck:expect(reckon_gater_api, save_subscription,
                    fun(_Store, _Type, _Selector, _Name, StartFrom, _Pid) ->
                        persistent_term:put({?MODULE, start_from}, StartFrom),
                        ok
                    end),
        {ok, _} = reckon_evoq_adapter:subscribe(?STORE, stream, <<"sel">>, <<"sub">>, Opts),
        persistent_term:get({?MODULE, start_from})
    end).

with_gater(Fun) ->
    meck:new(reckon_gater_api, [passthrough]),
    try Fun()
    after meck:unload(reckon_gater_api)
    end.
