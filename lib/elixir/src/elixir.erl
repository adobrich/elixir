%% Main entry point for Elixir functions. All of those functions are
%% private to the Elixir compiler and reserved to be used by Elixir only.
-module(elixir).
-behaviour(application).
-export([main/1, start_cli/0,
  string_to_quoted/4, 'string_to_quoted!'/4,
  scope_for_eval/1, scope_for_eval/2,
  eval/2, eval/3, eval/4, eval_forms/3,
  eval_quoted/2, eval_quoted/3, eval_quoted/4]).
-include("elixir.hrl").

%% Top level types
-export_type([char_list/0, as_boolean/1]).
-type char_list() :: string().
-type as_boolean(T) :: T.

%% OTP Application API

-export([start/2, stop/1, config_change/3]).

start(_Type, _Args) ->
  %% Set the shell to unicode so printing inside scripts work
  %% Those can take a while, so let's do it in a new process
  spawn(fun() ->
    io:setopts(standard_io, [binary,{encoding,unicode}]),
    io:setopts(standard_error, [binary,{encoding,unicode}])
  end),
  elixir_sup:start_link([]).

stop(_S) ->
  ok.

config_change(_Changed, _New, _Remove) ->
  ok.

%% escript entry point

main(Args) ->
  application:start(?MODULE),
  'Elixir.Kernel.CLI':main(Args).

%% Boot and process given options. Invoked by Elixir's script.

start_cli() ->
  application:start(?MODULE),
  'Elixir.Kernel.CLI':main(init:get_plain_arguments()).

%% EVAL HOOKS

scope_for_eval(Opts) ->
  scope_for_eval(#elixir_scope{
    file = <<"nofile">>,
    local = nil,
    aliases = [],
    requires = elixir_dispatch:default_requires(),
    functions = elixir_dispatch:default_functions(),
    macros = elixir_dispatch:default_macros()
  }, Opts).

scope_for_eval(Scope, Opts) ->
  File = case lists:keyfind(file, 1, Opts) of
    { file, RawFile } when is_binary(RawFile) -> RawFile;
    false -> Scope#elixir_scope.file
  end,

  Local = case lists:keyfind(delegate_locals_to, 1, Opts) of
    { delegate_locals_to, LocalOpt } -> LocalOpt;
    false -> Scope#elixir_scope.local
  end,

  Aliases = case lists:keyfind(aliases, 1, Opts) of
    { aliases, AliasesOpt } -> AliasesOpt;
    false -> Scope#elixir_scope.aliases
  end,

  Requires = case lists:keyfind(requires, 1, Opts) of
    { requires, List } -> ordsets:from_list(List);
    false -> Scope#elixir_scope.requires
  end,

  Functions = case lists:keyfind(functions, 1, Opts) of
    { functions, FunctionsOpt } -> FunctionsOpt;
    false -> Scope#elixir_scope.functions
  end,

  Macros = case lists:keyfind(macros, 1, Opts) of
    { macros, MacrosOpt } -> MacrosOpt;
    false -> Scope#elixir_scope.macros
  end,

  Module = case lists:keyfind(module, 1, Opts) of
    { module, ModuleOpt } when is_atom(ModuleOpt) -> ModuleOpt;
    false -> nil
  end,

  Scope#elixir_scope{
    file=File, local=Local, module=Module,
    macros=Macros, functions=Functions,
    requires=Requires, aliases=Aliases }.

%% String evaluation

eval(String, Binding) -> eval(String, Binding, []).

eval(String, Binding, Opts) ->
  case lists:keyfind(line, 1, Opts) of
    false -> Line = 1;
    { line, Line } -> []
  end,
  eval(String, Binding, Line, scope_for_eval(Opts)).

eval(String, Binding, Line, #elixir_scope{file=File} = S) when
    is_list(String), is_list(Binding), is_integer(Line), is_binary(File) ->
  Forms = 'string_to_quoted!'(String, Line, File, []),
  eval_forms(Forms, Binding, S).

%% Quoted evaluation

eval_quoted(Tree, Binding) -> eval_quoted(Tree, Binding, []).

eval_quoted(Tree, Binding, Opts) ->
  case lists:keyfind(line, 1, Opts) of
    { line, Line } -> [];
    false -> Line = 1
  end,
  eval_quoted(Tree, Binding, Line, scope_for_eval(Opts)).

eval_quoted(Tree, Binding, Line, #elixir_scope{} = S) when is_integer(Line) ->
  eval_forms(elixir_quote:linify(Line, Tree), Binding, S).

%% Handle forms evaluation internally, it is an
%% internal API not meant for external usage.

eval_forms(Tree, Binding, Opts) when is_list(Opts) ->
  eval_forms(Tree, Binding, scope_for_eval(Opts));

eval_forms(Tree, Binding, Scope) ->
  { ParsedBinding, ParsedScope } = elixir_scope:load_binding(Binding, Scope),
  { Expr, NewScope } = elixir_translator:translate_each(Tree, ParsedScope),
  case Expr of
    { atom, _, Atom } ->
      { Atom, Binding, NewScope };
    _  ->
      { value, Value, NewBinding } = erl_eval:expr(Expr, ParsedBinding),
      { Value, elixir_scope:dump_binding(NewBinding, NewScope), NewScope }
  end.

%% Converts a given string (char list) into quote expression

string_to_quoted(String, StartLine, File, Opts) ->
  case elixir_tokenizer:tokenize(String, StartLine, [{ file, File }|Opts]) of
    { ok, _Line, Tokens } ->
      try elixir_parser:parse(Tokens) of
        { ok, Forms } -> { ok, Forms };
        { error, { Line, _, [Error, Token] } } -> { error, { Line, Error, Token } }
      catch
        { error, { Line, _, [Error, Token] } } -> { error, { Line, Error, Token } }
      end;
    { error, Reason, _Rest, _SoFar  } -> { error, Reason }
  end.

'string_to_quoted!'(String, StartLine, File, Opts) ->
  case string_to_quoted(String, StartLine, File, Opts) of
    { ok, Forms } ->
      Forms;
    { error, { Line, Error, Token } } ->
      elixir_errors:parse_error(Line, File, Error, Token)
  end.