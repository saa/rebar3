-module(rebar_test_utils).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-export([init_rebar_state/1, init_rebar_state/2, run_and_check/4]).
-export([expand_deps/2, flat_deps/1, flat_pkgdeps/1, top_level_deps/1]).
-export([create_app/4, create_eunit_app/4, create_empty_app/4, create_config/2]).
-export([create_random_name/1, create_random_vsn/0]).

%%%%%%%%%%%%%%
%%% Public %%%
%%%%%%%%%%%%%%

%% @doc {@see init_rebar_state/2}
init_rebar_state(Config) -> init_rebar_state(Config, "apps_dir1_").

%% @doc Takes a common test config and a name (string) and sets up
%% a basic OTP app directory with a pre-configured rebar state to
%% run tests with.
init_rebar_state(Config, Name) ->
    application:load(rebar),
    DataDir = ?config(priv_dir, Config),
    AppsDir = filename:join([DataDir, create_random_name(Name)]),
    CheckoutsDir = filename:join([AppsDir, "_checkouts"]),
    ok = ec_file:mkdir_p(AppsDir),
    ok = ec_file:mkdir_p(CheckoutsDir),
    Verbosity = rebar3:log_level(),
    rebar_log:init(command_line, Verbosity),
    State = rebar_state:new([{base_dir, filename:join([AppsDir, "_build"])}
                            ,{root_dir, AppsDir}]),
    [{apps, AppsDir}, {checkouts, CheckoutsDir}, {state, State} | Config].

%% @doc Takes common test config, a rebar config ([] if empty), a command to
%% run ("install_deps", "compile", etc.), and a list of expected applications
%% and/or dependencies to be present, and verifies whether they are all in
%% place.
%%
%% The expectation list takes elements of the form:
%% - `{app, Name :: string()}': checks that the app is properly built.
%% - `{dep, Name :: string()}': checks that the dependency has been fetched.
%%   Ignores the build status of the dependency.
%% - `{dep, Name :: string(), Vsn :: string()}': checks that the dependency
%%   has been fetched, and that a given version has been chosen. Useful to
%%   test for conflict resolution. Also ignores the build status of the
%%   dependency.
%%
%% This function assumes `init_rebar_state/1-2' has run before, in order to
%% fetch the `apps' and `state' values from the CT config.
run_and_check(Config, RebarConfig, Command, Expect) ->
    %% Assumes init_rebar_state has run first
    AppDir = ?config(apps, Config),
    State = ?config(state, Config),
    try
        Res = rebar3:run(rebar_state:new(State, RebarConfig, AppDir), Command),
        case Expect of
            {error, Reason} ->
                ?assertEqual({error, Reason}, Res);
            {ok, Expected} ->
                {ok, _} = Res,
                check_results(AppDir, Expected),
                Res;
            return ->
                Res
        end
    catch
        rebar_abort when Expect =:= rebar_abort -> rebar_abort
    end.

%% @doc Creates a dummy application including:
%% - src/<file>.erl
%% - src/<file>.app.src
%% And returns a `rebar_app_info' object.
create_app(AppDir, Name, Vsn, Deps) ->
    write_src_file(AppDir, Name),
    write_app_src_file(AppDir, Name, Vsn, Deps),
    rebar_app_info:new(Name, Vsn, AppDir, Deps).

%% @doc Creates a dummy application including:
%% - src/<file>.erl
%% - src/<file>.app.src
%% - test/<file>_tests.erl
%% And returns a `rebar_app_info' object.
create_eunit_app(AppDir, Name, Vsn, Deps) ->
    write_eunitized_src_file(AppDir, Name),
    write_eunit_suite_file(AppDir, Name),
    write_app_src_file(AppDir, Name, Vsn, Deps),
    rebar_app_info:new(Name, Vsn, AppDir, Deps).

%% @doc Creates a dummy application including:
%% - ebin/<file>.app
%% And returns a `rebar_app_info' object.
create_empty_app(AppDir, Name, Vsn, Deps) ->
    write_app_file(AppDir, Name, Vsn, Deps),
    rebar_app_info:new(Name, Vsn, AppDir, Deps).

%% @doc Creates a rebar.config file. The function accepts a list of terms,
%% each of which will be dumped as a consult file. For example, the list
%% `[a, b, c]' will return the consult file `a. b. c.'.
create_config(AppDir, Contents) ->
    Conf = filename:join([AppDir, "rebar.config"]),
    ok = filelib:ensure_dir(Conf),
    Config = lists:flatten([io_lib:fwrite("~p.~n", [Term]) || Term <- Contents]),
    ok = ec_file:write(Conf, Config),
    Conf.

%% @doc Util to create a random variation of a given name.
create_random_name(Name) ->
    random:seed(os:timestamp()),
    Name ++ erlang:integer_to_list(random:uniform(1000000)).

%% @doc Util to create a random variation of a given version.
create_random_vsn() ->
    random:seed(os:timestamp()),
    lists:flatten([erlang:integer_to_list(random:uniform(100)),
                   ".", erlang:integer_to_list(random:uniform(100)),
                   ".", erlang:integer_to_list(random:uniform(100))]).

expand_deps(_, []) -> [];
expand_deps(git, [{Name, Deps} | Rest]) ->
    Dep = {Name, ".*", {git, "https://example.org/user/"++Name++".git", "master"}},
    [{Dep, expand_deps(git, Deps)} | expand_deps(git, Rest)];
expand_deps(git, [{Name, Vsn, Deps} | Rest]) ->
    Dep = {Name, Vsn, {git, "https://example.org/user/"++Name++".git", {tag, Vsn}}},
    [{Dep, expand_deps(git, Deps)} | expand_deps(git, Rest)];
expand_deps(pkg, [{Name, Deps} | Rest]) ->
    Dep = {pkg, Name, "0.0.0"},
    [{Dep, expand_deps(pkg, Deps)} | expand_deps(pkg, Rest)];
expand_deps(pkg, [{Name, Vsn, Deps} | Rest]) ->
    Dep = {pkg, Name, Vsn},
    [{Dep, expand_deps(pkg, Deps)} | expand_deps(pkg, Rest)].

flat_deps([]) -> [];
flat_deps([{{Name,_Vsn,Ref}, Deps} | Rest]) ->
    [{{Name,vsn_from_ref(Ref)}, top_level_deps(Deps)}]
    ++
    flat_deps(Deps)
    ++
    flat_deps(Rest).

flat_pkgdeps([]) -> [];
flat_pkgdeps([{{pkg, Name, Vsn}, Deps} | Rest]) ->
    [{{iolist_to_binary(Name),iolist_to_binary(Vsn)}, top_level_deps(Deps)}]
    ++
    flat_pkgdeps(Deps)
    ++
    flat_pkgdeps(Rest).


vsn_from_ref({git, _, {_, Vsn}}) -> Vsn;
vsn_from_ref({git, _, Vsn}) -> Vsn.

top_level_deps([]) -> [];
top_level_deps([{{pkg, Name, Vsn}, _} | Deps]) ->
    [{list_to_atom(Name), Vsn} | top_level_deps(Deps)];
top_level_deps([{{Name, Vsn, Ref}, _} | Deps]) ->
    [{list_to_atom(Name), Vsn, Ref} | top_level_deps(Deps)].

%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%
check_results(AppDir, Expected) ->
    BuildDirs = filelib:wildcard(filename:join([AppDir, "_build", "*", "lib"])),
    PluginDirs = filelib:wildcard(filename:join([AppDir, "_build", "*", "plugins"])),
    CheckoutsDir = filename:join([AppDir, "_checkouts"]),
    LockFile = filename:join([AppDir, "rebar.lock"]),
    Locks = lists:flatten(rebar_config:consult_file(LockFile)),

    InvalidApps = rebar_app_discover:find_apps(BuildDirs, invalid),
    ValidApps = rebar_app_discover:find_apps(BuildDirs, valid),

    InvalidDepsNames = [{ec_cnv:to_list(rebar_app_info:name(App)), App} || App <- InvalidApps],
    ValidDepsNames = [{ec_cnv:to_list(rebar_app_info:name(App)), App} || App <- ValidApps],

    Deps = rebar_app_discover:find_apps(BuildDirs, all),
    DepsNames = [{ec_cnv:to_list(rebar_app_info:name(App)), App} || App <- Deps],
    Checkouts = rebar_app_discover:find_apps([CheckoutsDir], all),
    CheckoutsNames = [{ec_cnv:to_list(rebar_app_info:name(App)), App} || App <- Checkouts],
    Plugins = rebar_app_discover:find_apps(PluginDirs, all),
    PluginsNames = [{ec_cnv:to_list(rebar_app_info:name(App)), App} || App <- Plugins],

    lists:foreach(
        fun({app, Name}) ->
                ct:pal("Name: ~p", [Name]),
                case lists:keyfind(Name, 1, DepsNames) of
                    false ->
                        error({app_not_found, Name});
                    {Name, _App} ->
                        ok
                end
        ; ({app, Name, invalid}) ->
                ct:pal("Name: ~p", [Name]),
                case lists:keyfind(Name, 1, InvalidDepsNames) of
                    false ->
                        error({app_not_found, Name});
                    {Name, _App} ->
                        ok
                end
        ; ({app, Name, valid}) ->
                ct:pal("Name: ~p", [Name]),
                case lists:keyfind(Name, 1, ValidDepsNames) of
                    false ->
                        error({app_not_found, Name});
                    {Name, _App} ->
                        ok
                end
        ;  ({checkout, Name}) ->
                ct:pal("Name: ~p", [Name]),
                ?assertNotEqual(false, lists:keyfind(Name, 1, CheckoutsNames))
        ;  ({dep, Name}) ->
                ct:pal("Name: ~p", [Name]),
                ?assertNotEqual(false, lists:keyfind(Name, 1, DepsNames))
        ;  ({dep, Name, Vsn}) ->
                ct:pal("Name: ~p, Vsn: ~p", [Name, Vsn]),
                case lists:keyfind(Name, 1, DepsNames) of
                    false ->
                        error({dep_not_found, Name});
                    {Name, App} ->
                        ?assertEqual(iolist_to_binary(Vsn),
                                     iolist_to_binary(rebar_app_info:original_vsn(App)))
                end
        ;  ({plugin, Name}) ->
                ct:pal("Name: ~p", [Name]),
                ?assertNotEqual(false, lists:keyfind(Name, 1, PluginsNames))
        ;  ({plugin, Name, Vsn}) ->
                ct:pal("Name: ~p, Vsn: ~p", [Name, Vsn]),
                case lists:keyfind(Name, 1, PluginsNames) of
                    false ->
                        error({dep_not_found, Name});
                    {Name, App} ->
                        ?assertEqual(iolist_to_binary(Vsn),
                                     iolist_to_binary(rebar_app_info:original_vsn(App)))
                end
        ;  ({lock, Name}) ->
                ct:pal("Name: ~p", [Name]),
                ?assertNotEqual(false, lists:keyfind(iolist_to_binary(Name), 1, Locks))
        ;  ({lock, Name, Vsn}) ->
                ct:pal("Name: ~p, Vsn: ~p", [Name, Vsn]),
                case lists:keyfind(iolist_to_binary(Name), 1, Locks) of
                    false ->
                        error({lock_not_found, Name});
                    {_LockName, {pkg, _, LockVsn}, _} ->
                        ?assertEqual(iolist_to_binary(Vsn),
                                     iolist_to_binary(LockVsn));
                    {_LockName, {_, _, {ref, LockVsn}}, _} ->
                        ?assertEqual(iolist_to_binary(Vsn),
                                     iolist_to_binary(LockVsn))
                end
        ;  ({release, Name, Vsn, ExpectedDevMode}) ->
                ct:pal("Release: ~p-~s", [Name, Vsn]),
                {ok, Cwd} = file:get_cwd(),
                try
                    file:set_cwd(AppDir),
                    [ReleaseDir] = filelib:wildcard(filename:join([AppDir, "_build", "*", "rel"])),
                    RelxState = rlx_state:new("", [], []),
                    RelxState1 = rlx_state:base_output_dir(RelxState, ReleaseDir),
                    {ok, RelxState2} = rlx_prv_app_discover:do(RelxState1),
                    {ok, RelxState3} = rlx_prv_rel_discover:do(RelxState2),

                    LibDir = filename:join([ReleaseDir, Name, "lib"]),
                    {ok, RelLibs} = file:list_dir(LibDir),
                    IsSymLinkFun =
                        fun(X) ->
                                ec_file:is_symlink(filename:join(LibDir, X))
                        end,
                    DevMode = lists:all(IsSymLinkFun, RelLibs),
                    ?assertEqual(ExpectedDevMode, DevMode),

                    %% throws not_found if it doesn't exist
                    rlx_state:get_realized_release(RelxState3, Name, Vsn)
                catch
                    _ ->
                        ct:fail(release_not_found)
                after
                    file:set_cwd(Cwd)
                end
        ;  ({tar, Name, Vsn}) ->
                ct:pal("Tarball: ~s-~s", [Name, Vsn]),
                Tarball = filename:join([AppDir, "_build", "rel", Name, Name++"-"++Vsn++".tar.gz"]),
                ?assertNotEqual([], filelib:is_file(Tarball))
        ;  ({file, Filename}) ->
                ct:pal("Filename: ~s", [Filename]),
                ?assert(filelib:is_file(Filename))
        end, Expected).

write_src_file(Dir, Name) ->
    Erl = filename:join([Dir, "src", "not_a_real_src_" ++ Name ++ ".erl"]),
    ok = filelib:ensure_dir(Erl),
    ok = ec_file:write(Erl, erl_src_file("not_a_real_src_" ++ Name ++ ".erl")).

write_eunitized_src_file(Dir, Name) ->
    Erl = filename:join([Dir, "src", "not_a_real_src_" ++ Name ++ ".erl"]),
    ok = filelib:ensure_dir(Erl),
    ok = ec_file:write(Erl, erl_eunitized_src_file("not_a_real_src_" ++ Name ++ ".erl")).

write_eunit_suite_file(Dir, Name) ->
    Erl = filename:join([Dir, "test", "not_a_real_src_" ++ Name ++ "_tests.erl"]),
    ok = filelib:ensure_dir(Erl),
    ok = ec_file:write(Erl, erl_eunit_suite_file("not_a_real_src_" ++ Name ++ ".erl")).

write_app_file(Dir, Name, Version, Deps) ->
    Filename = filename:join([Dir, "ebin", Name ++ ".app"]),
    ok = filelib:ensure_dir(Filename),
    ok = ec_file:write_term(Filename, get_app_metadata(ec_cnv:to_list(Name), Version, Deps)).

write_app_src_file(Dir, Name, Version, Deps) ->
    Filename = filename:join([Dir, "src", Name ++ ".app.src"]),
    ok = filelib:ensure_dir(Filename),
    ok = ec_file:write_term(Filename, get_app_metadata(ec_cnv:to_list(Name), Version, Deps)).

erl_src_file(Name) ->
    io_lib:format("-module(~s).\n"
                  "-export([main/0]).\n"
                  "main() -> ok.\n", [filename:basename(Name, ".erl")]).

erl_eunitized_src_file(Name) ->
    io_lib:format("-module(~s).\n"
                  "-export([main/0]).\n"
                  "main() -> ok.\n"
                  "-ifdef(TEST).\n"
                  "-include_lib(\"eunit/include/eunit.hrl\").\n"
                  "some_test_() -> ?_assertEqual(ok, main()).\n"
                  "-endif.\n", [filename:basename(Name, ".erl")]).

erl_eunit_suite_file(Name) ->
    BaseName = filename:basename(Name, ".erl"),
    io_lib:format("-module(~s_tests).\n"
                  "-compile(export_all).\n"
                  "-ifndef(some_define).\n"
                  "-define(some_define, false).\n"
                  "-endif.\n"
                  "-ifdef(TEST).\n"
                  "-include_lib(\"eunit/include/eunit.hrl\").\n"
                  "some_test_() -> ?_assertEqual(ok, ~s:main()).\n"
                  "define_test_() -> ?_assertEqual(true, ?some_define).\n"
                  "-endif.\n", [BaseName, BaseName]).

get_app_metadata(Name, Vsn, Deps) ->
    {application, erlang:list_to_atom(Name),
     [{description, ""},
      {vsn, Vsn},
      {modules, []},
      {included_applications, []},
      {registered, []},
      {applications, Deps}]}.
