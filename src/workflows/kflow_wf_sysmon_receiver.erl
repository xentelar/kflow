%%%===================================================================
%%% @copyright 2020 Klarna Bank AB (publ)
%%%
%%% @doc This workflow receives `system_monitor' messages and puts
%%% them to postgres tables.
%%%
%%% == Configuration ==
%%%
%%% The following parameters are mandatory:
%%%
%%% === kafka_topic ===
%%%
%%% Type: `brod:topic()'.
%%%
%%% === group_id ===
%%%
%%% Type: `binary()'. Kafka group consumer ID used by the workflow.
%%%
%%% === database ===
%%%
%%% Type: `epgsql:connect_opts()'. See
%%% [https://github.com/epgsql/epgsql/blob/devel/src/epgsql.erl#L63]
%%%
%%% @end
%%%
%%% This module is made out of recycled old sequalizer code, answers
%%% to why everything was desinged like that are lost in history.
%%%
%%%===================================================================
-module(kflow_wf_sysmon_receiver).

-include_lib("kernel/include/logger.hrl").

-include("kflow_int.hrl").

%% API
-export([workflow/2]).

%% Internal exports:
-export([ nullable/1
        , timestamp/1
        , to_string/2
        , format_function/1
        , format_stacktrace/1
        ]).

-export_type([config/0]).

%%%===================================================================
%%% Types
%%%===================================================================

-type config() ::
        #{ kafka_topic    := brod:topic()
         , group_id       := binary()
         , database       := epgsql:connect_opts()
         , retention      => non_neg_integer()
         , partition_days => non_neg_integer()
         }.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Create a workflow specification
-spec workflow(atom(), config()) -> kflow:workflow().
workflow(Id, Config) ->
  Config1 = Config#{ auto_commit    => false
                   , flush_interval => 1000
                   },
  kflow:mk_kafka_workflow(Id, pipe_spec(Config), Config1).

%%%===================================================================
%%% Field transform functions copied from Seqializer
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Transform undefined to "null"
%% @end
%%--------------------------------------------------------------------
-spec nullable(term()) -> term().
nullable(undefined) ->
  [];
nullable(A) ->
  A.

%%--------------------------------------------------------------------
%% @doc
%% erlang timestamp to epgsql timestamp
%% @end
%%--------------------------------------------------------------------
-spec timestamp(erlang:timestamp()) -> tuple().
timestamp(Timestamp = {_, _, _}) ->
  Timestamp.

%%--------------------------------------------------------------------
%% @doc
%% Convert arbitrary erlang term to string
%% @end
%%--------------------------------------------------------------------
-spec to_string(term(), integer()) -> string().
to_string(Term, Limit) ->
  case io_lib:printable_latin1_list(Term) of
    true ->
      Str = Term;
    false ->
      Str = lists:flatten(io_lib:format("~p", [Term]))
  end,
  lists:sublist(Str, Limit).

%%--------------------------------------------------------------------
%% @doc
%% Convert function definition to string
%% @end
%%--------------------------------------------------------------------
-spec format_function({module(), atom(), arity()}) -> string().
format_function({Mod, Fun, Arity}) ->
  Module = lists:sublist(atom_to_list(Mod), 30),
  Function = lists:sublist(atom_to_list(Fun), 40),
  lists:flatten(io_lib:format("~s:~s/~p", [Module, Function, Arity]));
format_function(_) ->
  "no data".

-spec format_stacktrace(list()) -> string().
format_stacktrace(Stacktrace) ->
  io_lib:format("~p", [Stacktrace]).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec pipe_spec(config()) -> kflow:pipe().
pipe_spec(Config = #{database := DbOpts}) ->
  [ {mfd, fun parse_sysmon_message/2}
  , {aggregate, kflow_buffer, #{}}
  , {route_dependent,
     fun(Record) ->
         {Table, Fields0} = record_specs(Record),
         Fields = [case I of
                     {A, _, _} -> A;
                     {A, _}    -> A;
                     A         -> A
                   end || I <- Fields0],
         MapConfig = #{ database     => DbOpts
                      , table        => Table
                      , fields       => Fields
                      , partitioning =>
                          #{ days         => maps:get(partition_days, Config, 1)
                           , retention    => maps:get(retention, Config, 30)
                           , index_fields => [ts]
                           }
                      },
         {map, kflow_postgres, MapConfig}
     end}
  ].

%% @private
-spec parse_sysmon_message(kflow:offset(), #{value := binary()}) ->
                              {true, atom(), map()} | false.
parse_sysmon_message(_Offset, #{value := Bin}) ->
  try
    [Record|Fields] = tuple_to_list(binary_to_term(Bin)),
    case record_specs(Record) of
      {_, FieldSpecs} when length(Fields) =:= length(FieldSpecs) ->
        Ret = [case FieldSpec of
                 {Field, Fun, Arg} ->
                   {Field, ?MODULE:Fun(Val, Arg)};
                 {Field, Fun} ->
                   {Field, ?MODULE:Fun(Val)};
                 Field when is_atom(Field) ->
                   {Field, Val}
                 end || {FieldSpec, Val} <- lists:zip(FieldSpecs, Fields)],
        {true, Record, Ret};
      _ ->
        ?LOG_WARNING(#{ what   => "Unknown record"
                        , record => Record
                        , fields => Fields
                        }),
        false
    end
  catch EC:Err:Stack ->
      ?LOG_WARNING(#{ what        => "Badly formatted sysmon message"
                      , message     => Bin
                      , error_class => EC
                      , error       => Err
                      , stacktrace  => Stack
                      }),
      false
  end.

%% @private "Schema" of system monitor data
-spec record_specs(atom()) -> {_Table :: string(), _Fields :: list()} | undefined.
record_specs(op_stat_kafka_msg1) ->
  {"opstat",
   [ {name, to_string, 60}
   , {data, to_string, 50}
   , {unit, to_string, 10}
   , {sess, nullable}
   , node
   , {ts, timestamp}
   ]};
record_specs(erl_top) ->
  {"prc",
   [ node
   , {ts, timestamp}
   , {pid, to_string, 34}
   , dreductions
   , dmemory
   , reductions
   , memory
   , message_queue_len
   , {current_function, format_function}
   , {initial_call, format_function}
   , {registered_name, to_string, 39}
   , stack_size
   , heap_size
   , total_heap_size
   , {current_stacktrace, format_stacktrace}
   , group_leader
   ]};
record_specs(fun_top) ->
  {"fun_top",
   [ node
   , {ts, timestamp}
   , {'fun', format_function}
   , fun_type
   , num_processes
   ]};
record_specs(app_top) ->
  {"app_top",
   [ node
   , {ts, timestamp}
   , {application, to_string, 60}
   , {unit, to_string, 60}
   , value
   ]};
record_specs(node_role) ->
  {"node_role",
   [ node
   , {ts, timestamp}
   , data
   ]};
record_specs(_) ->
  undefined.
