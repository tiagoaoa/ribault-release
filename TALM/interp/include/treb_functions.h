#include <sys/time.h>
#include <time.h>
#include <sys/timeb.h>
#include <stdlib.h>
#include <stdio.h>

#define TIME_s 0
#define TIME_ms 1
#define TIME_us 2
#define TIME_ns 3

int treb_get_n_procs();

int treb_get_n_tasks();

int treb_get_tid();

double treb_get_time(int resolution);

char * treb_get_arg(int argnum);

int treb_get_n_args();
