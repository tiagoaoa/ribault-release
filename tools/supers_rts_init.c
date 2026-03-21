// tools/supers_rts_init.c
#include <HsFFI.h>
#include <stddef.h>  // NULL
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int hs_is_inited = 0;
static char hs_nopt_buf[32];

static int hs_rts_args(char **argv, int max_args) {
    int argc = 0;
    const char *disable = getenv("SUPERS_RTS_DISABLE");
    const char *nopt = getenv("SUPERS_RTS_N");

    argv[argc++] = (char *)"libsupers";
    if (disable && disable[0] != '\0' && disable[0] != '0') {
        argv[argc] = NULL;
        return argc;
    }
    argv[argc++] = (char *)"+RTS";
    if (nopt && nopt[0] != '\0' && nopt[0] != '0') {
        snprintf(hs_nopt_buf, sizeof(hs_nopt_buf), "-N%s", nopt);
        argv[argc++] = hs_nopt_buf;
    } else {
        argv[argc++] = (char *)"-N";
    }
    argv[argc++] = (char *)"-RTS";
    argv[argc] = NULL;
    return argc;
}

static int hs_manual_init_enabled(void) {
    const char *env = getenv("SUPERS_HS_INIT_MANUAL");
    return env && env[0] != '\0' && env[0] != '0';
}

// Weak refs: only available with threaded RTS.
extern void hs_init_thread(void) __attribute__((weak));
extern void hs_exit_thread(void) __attribute__((weak));
extern void hs_thread_done(void) __attribute__((weak));
extern void setNumCapabilities(int) __attribute__((weak));
extern void supers_io_init(void) __attribute__((weak));

static void hs_set_caps_from_env(void) {
    const char *nopt = getenv("SUPERS_RTS_N");
    if (!nopt || nopt[0] == '\0' || nopt[0] == '0') {
        return;
    }
    if (setNumCapabilities) {
        int n = atoi(nopt);
        if (n > 0) {
            setNumCapabilities(n);
        }
    }
}

__attribute__((constructor))
static void hs_startup(void) {
    if (hs_manual_init_enabled()) return;
    if (hs_is_inited) return;
    hs_is_inited = 1;

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    char *argv[8];
    int argc = hs_rts_args(argv, 8);
    char **pargv = argv;                 // hs_init quer char ***
    hs_init(&argc, &pargv);              // inicializa o runtime do GHC
    hs_set_caps_from_env();
    if (supers_io_init) {
        supers_io_init();
    }
}

__attribute__((destructor))
static void hs_shutdown(void) {
    if (hs_manual_init_enabled()) return;
    if (!hs_is_inited) return;
    hs_is_inited = 0;
    hs_exit();                           // finaliza ao descarregar o .so
}

__attribute__((visibility("default")))
void supers_hs_init(void) {
    if (hs_is_inited) return;
    hs_is_inited = 1;
    char *argv[8];
    int argc = hs_rts_args(argv, 8);
    char **pargv = argv;
    hs_init(&argc, &pargv);
    hs_set_caps_from_env();
    if (supers_io_init) {
        supers_io_init();
    }
}

__attribute__((visibility("default")))
void supers_hs_exit(void) {
    if (!hs_is_inited) return;
    hs_is_inited = 0;
    hs_exit();
}

// Exported wrappers for threaded RTS init per OS thread.
__attribute__((visibility("default")))
void supers_hs_init_thread(void) {
    if (hs_init_thread) {
        hs_init_thread();
    }
    hs_set_caps_from_env();
}

__attribute__((visibility("default")))
void supers_hs_exit_thread(void) {
    if (hs_exit_thread) {
        hs_exit_thread();
    }
}

__attribute__((visibility("default")))
void supers_hs_thread_done(void) {
    if (hs_thread_done) {
        hs_thread_done();
    }
}
