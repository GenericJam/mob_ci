%% mob_ci_haptic_nif — Erlang NIF stub for the tier-1 plugin.
%%
%% The C side (priv/native/jni/mob_ci_haptic_nif.c) registers functions under
%% this module name via ERL_NIF_INIT. On device the NIF is statically
%% linked into the host binary; on a host dev build it isn't linked, so
%% on_load tolerates the load failure (returning ok keeps the module
%% loadable) and ping/0 falls back to nif_error until the native merge
%% links it.
-module(mob_ci_haptic_nif).
-export([ping/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_ci_haptic_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

ping() ->
    erlang:nif_error(nif_not_loaded).
