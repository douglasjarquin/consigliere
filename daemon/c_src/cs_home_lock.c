#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "erl_nif.h"

typedef struct {
  int fd;
} CsLock;

static ErlNifResourceType *CS_LOCK_TYPE = NULL;

static int open_lock_file(const char *path) {
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) {
    return -1;
  }
  if (fchmod(fd, 0600) != 0) {
    /* umask already applied; keep the fd */
  }
  return fd;
}

static int try_lock(int fd) {
  struct flock fl;
  memset(&fl, 0, sizeof(fl));
  fl.l_type = F_WRLCK;
  fl.l_whence = SEEK_SET;
  fl.l_start = 0;
  fl.l_len = 0;
  return fcntl(fd, F_SETLK, &fl);
}

static int inspect_lock(int fd, pid_t *holder) {
  struct flock fl;
  memset(&fl, 0, sizeof(fl));
  fl.l_type = F_WRLCK;
  fl.l_whence = SEEK_SET;
  fl.l_start = 0;
  fl.l_len = 0;
  if (fcntl(fd, F_GETLK, &fl) != 0) {
    return -1;
  }
  if (fl.l_type == F_UNLCK) {
    *holder = 0;
    return 0;
  }
  *holder = fl.l_pid;
  return 1;
}

static void cs_lock_dtor(ErlNifEnv *env, void *obj) {
  CsLock *lock = (CsLock *)obj;
  (void)env;
  if (lock->fd >= 0) {
    close(lock->fd);
    lock->fd = -1;
  }
}

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)priv_data;
  (void)load_info;
  ErlNifResourceFlags flags =
      (ErlNifResourceFlags)(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
  CS_LOCK_TYPE = enif_open_resource_type(env, NULL, "cs_home_lock", cs_lock_dtor,
                                         flags, NULL);
  return CS_LOCK_TYPE ? 0 : 1;
}

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  ERL_NIF_TERM term;
  if (!enif_make_existing_atom(env, name, &term, ERL_NIF_LATIN1)) {
    term = enif_make_atom(env, name);
  }
  return term;
}

static ERL_NIF_TERM ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value) {
  return enif_make_tuple2(env, atom(env, "ok"), value);
}

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, ERL_NIF_TERM value) {
  return enif_make_tuple2(env, atom(env, "error"), value);
}

static int path_from_term(ErlNifEnv *env, ERL_NIF_TERM term, char *buf,
                          unsigned size) {
  ErlNifBinary bin;
  if (enif_inspect_binary(env, term, &bin)) {
    if (bin.size + 1 > size) {
      return 0;
    }
    memcpy(buf, bin.data, bin.size);
    buf[bin.size] = 0;
    return 1;
  }
  unsigned len;
  if (!enif_get_list_length(env, term, &len) || len + 1 > size) {
    return 0;
  }
  return enif_get_string(env, term, buf, size, ERL_NIF_LATIN1) > 0;
}

static ERL_NIF_TERM acquire(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  char path[4096];
  (void)argc;
  if (!path_from_term(env, argv[0], path, sizeof(path))) {
    return enif_make_badarg(env);
  }

  int fd = open_lock_file(path);
  if (fd < 0) {
    return error_tuple(env, enif_make_tuple2(env, atom(env, "open"),
                                             enif_make_int(env, errno)));
  }

  if (try_lock(fd) != 0) {
    int err = errno;
    close(fd);
    if (err == EAGAIN || err == EACCES || err == EWOULDBLOCK) {
      return error_tuple(env, atom(env, "busy"));
    }
    return error_tuple(env, enif_make_tuple2(env, atom(env, "fcntl"),
                                             enif_make_int(env, err)));
  }

  CsLock *lock = (CsLock *)enif_alloc_resource(CS_LOCK_TYPE, sizeof(CsLock));
  lock->fd = fd;
  ERL_NIF_TERM ref = enif_make_resource(env, lock);
  enif_release_resource(lock);
  return ok_tuple(env, ref);
}

static ERL_NIF_TERM release_lock(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  CsLock *lock;
  (void)argc;
  if (!enif_get_resource(env, argv[0], CS_LOCK_TYPE, (void **)&lock)) {
    return enif_make_badarg(env);
  }
  if (lock->fd >= 0) {
    close(lock->fd);
    lock->fd = -1;
  }
  return atom(env, "ok");
}

static ERL_NIF_TERM inspect(ErlNifEnv *env, int argc,
                            const ERL_NIF_TERM argv[]) {
  char path[4096];
  pid_t holder = 0;
  (void)argc;
  if (!path_from_term(env, argv[0], path, sizeof(path))) {
    return enif_make_badarg(env);
  }

  int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    if (errno == ENOENT) {
      return atom(env, "absent");
    }
    return error_tuple(env, enif_make_tuple2(env, atom(env, "open"),
                                             enif_make_int(env, errno)));
  }

  int result = inspect_lock(fd, &holder);
  close(fd);
  if (result < 0) {
    return error_tuple(env, enif_make_tuple2(env, atom(env, "fcntl"),
                                             enif_make_int(env, errno)));
  }
  if (result == 0) {
    return atom(env, "free");
  }
  return enif_make_tuple2(env, atom(env, "held"), enif_make_int(env, (int)holder));
}

static ErlNifFunc nif_funcs[] = {
    {"acquire", 1, acquire, 0},
    {"release", 1, release_lock, 0},
    {"inspect", 1, inspect, 0},
};

ERL_NIF_INIT(Elixir.Consigliere.Home.Lock.NIF, nif_funcs, on_load, NULL, NULL,
             NULL)
