#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>

#include "erl_nif.h"

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  ERL_NIF_TERM term;
  if (!enif_make_existing_atom(env, name, &term, ERL_NIF_LATIN1)) {
    term = enif_make_atom(env, name);
  }
  return term;
}

static ERL_NIF_TERM probe(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  long pgid;
  if (argc != 1 || !enif_get_long(env, argv[0], &pgid)) {
    return enif_make_badarg(env);
  }
  if (pgid <= 1) {
    return atom(env, "unsafe");
  }
  if (kill((pid_t)(-pgid), 0) == 0) {
    return atom(env, "alive");
  }
  switch (errno) {
  case ESRCH:
    return atom(env, "absent");
  case EPERM:
    return atom(env, "forbidden");
  default:
    return atom(env, "unknown");
  }
}

static ErlNifFunc nif_funcs[] = {
    {"probe", 1, probe, 0},
};

ERL_NIF_INIT(Elixir.Consigliere.ProcessGroup.NIF, nif_funcs, NULL, NULL, NULL,
             NULL)
