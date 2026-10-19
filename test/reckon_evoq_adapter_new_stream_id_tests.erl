%% @doc New stream ids are minted through the adapter, in the store's own
%% contract (mcl-chess#1).
%%
%% evoq gained an optional evoq_adapter:new_stream_id/1 so a service can ask
%% for an aggregate id without reaching past evoq to reckon_gater and
%% hand-rolling a store-format id. This adapter delegates to
%% reckon_gater_stream_id:new/1, which is the one definition of the format,
%% so the id must validate against the same contract the store enforces on
%% append.
-module(reckon_evoq_adapter_new_stream_id_tests).

-include_lib("eunit/include/eunit.hrl").

%% The id is a valid user stream id with the prefix that was asked for.
the_id_validates_with_the_requested_prefix_test() ->
    Id = reckon_evoq_adapter:new_stream_id(game),
    ?assertEqual(ok, reckon_gater_stream_id:validate(Id)),
    ?assertEqual(<<"game">>, reckon_gater_stream_id:prefix_of(Id)),
    ?assertEqual({user, <<"game">>, reckon_gater_stream_id:suffix_of(Id)},
                 reckon_gater_stream_id:parts(Id)).

%% A binary prefix reaches the generator as happily as an atom: the
%% callback spec allows either.
a_binary_prefix_is_accepted_test() ->
    Id = reckon_evoq_adapter:new_stream_id(<<"session">>),
    ?assertEqual(<<"session">>, reckon_gater_stream_id:prefix_of(Id)),
    ?assertEqual(ok, reckon_gater_stream_id:validate(Id)).

%% Two games get two ids. A generator that answered the same id every time
%% would pass the shape assertions above and lose a game to the next one.
each_call_mints_a_different_id_test() ->
    Ids = [reckon_evoq_adapter:new_stream_id(game) || _ <- lists:seq(1, 8)],
    ?assertEqual(8, length(lists:usort(Ids))).

%% A malformed prefix is refused by the generator, not silently minted
%% into an id the store would reject on append.
an_invalid_prefix_is_refused_test() ->
    ?assertError({invalid_prefix, <<"Game-1">>},
                 reckon_evoq_adapter:new_stream_id(<<"Game-1">>)).
