%% @doc Header file for reckon-evoq adapter
%%
%% Contains macros and type definitions specific to the reckon-db adapter.
%%
%% @author rgfaber

-ifndef(RECKON_EVOQ_HRL).
-define(RECKON_EVOQ_HRL, true).

%% Include shared types from reckon-gater (event, snapshot, subscription)
-include_lib("reckon_gater/include/esdb_gater_types.hrl").

%%====================================================================
%% Telemetry Events
%%====================================================================

-define(EVOQ_ESDB_TELEMETRY_PREFIX, [reckon_evoq]).

-define(ADAPTER_APPEND_START, [reckon_evoq, adapter, append, start]).
-define(ADAPTER_APPEND_STOP, [reckon_evoq, adapter, append, stop]).
-define(ADAPTER_APPEND_ERROR, [reckon_evoq, adapter, append, error]).

-define(ADAPTER_READ_START, [reckon_evoq, adapter, read, start]).
-define(ADAPTER_READ_STOP, [reckon_evoq, adapter, read, stop]).
-define(ADAPTER_READ_ERROR, [reckon_evoq, adapter, read, error]).

-define(ADAPTER_SNAPSHOT_START, [reckon_evoq, adapter, snapshot, start]).
-define(ADAPTER_SNAPSHOT_STOP, [reckon_evoq, adapter, snapshot, stop]).

-define(ADAPTER_SUBSCRIBE_START, [reckon_evoq, adapter, subscribe, start]).
-define(ADAPTER_SUBSCRIBE_STOP, [reckon_evoq, adapter, subscribe, stop]).

-endif. %% RECKON_EVOQ_HRL
