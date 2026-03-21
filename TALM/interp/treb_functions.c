/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *     treb_functions.c
 *
 * Authors:
 *     Tiago A.O.A. <tiagoaoa@cos.ufrj.br>, Leandro J. Marzulo <lmazrulo@cos.ufrj.br>
 *
 *
 *
 *             THIS IS NOT AN OFFICIAL RELEASE.
 *             DO NOT COPY OR REDISTRIBUTE.
 *
 *
 */
#include "queue.h"
#include "interp.h"
#include "treb_functions.h"

extern int n_tasks;
extern __thread int tid;
extern int n_procs;
extern char ** superargv;
extern int superargc;

int treb_get_n_procs()
/******************************************************************************
returns the number of processors in the system
******************************************************************************/
{
	return n_procs;
}

int treb_get_n_tasks()
/******************************************************************************
returns the number of tasks
******************************************************************************/
{
	return n_tasks;
}


int treb_get_tid()
/******************************************************************************
returns the task id

When a super-instruction is called, the VM puts on tid the value of the
immediate field at the super-instruction. The immediate is filled up at compile
time.

WARNING: a local thread variable was used to implement this feature. This may
not work in other compilers.
******************************************************************************/
{
	return tid;
}


double treb_get_time(int resolution)
/******************************************************************************
returns the time in the desired resolution

TIME_s - seconds
TIME_ms - miliseconds
TIME_us - microseconds
TIME_ns - nanoseconds
******************************************************************************/
{
	struct timespec ts;
	double ret;

	clock_gettime(CLOCK_REALTIME, &ts);
	
	switch (resolution)
	{	
		case TIME_s: 
			ret = (((double)ts.tv_sec) + (((double)ts.tv_nsec) / 1000000000));
			//printf("s %.20lf\n", ret);
			return ret;
		case TIME_ms:
			ret = ((((double)ts.tv_sec) * 1000) + (((double)ts.tv_nsec) / 1000000));
			//printf("ms %.20lf\n", ret);
			return ret;
		case TIME_us:
			ret = ((((double)ts.tv_sec)) * 1000000 + (((double)ts.tv_nsec) / 1000));
			//printf("us %.20lf\n", ret);
			return ret;
		case TIME_ns:
			ret = ((((double)ts.tv_sec)) * 1000000000 + ((double)ts.tv_nsec));
			//printf("ns %.20lf\n", ret);
	 		return ret;
		default:
			fprintf(stderr, "treb_get_time() - resolution not supported\n");
			exit(1);
	}		
}

int treb_get_n_args()
/******************************************************************************
Returns the number of arguments passed to the application (excluding the VM arguments)
******************************************************************************/
{
	return superargc;
}

char * treb_get_arg(int argnum)
/******************************************************************************
Returns one of the arguments passed to the application (argument number passed as input)
******************************************************************************/
{
	if (superargc ==0)
	{
		fprintf(stderr, "treb_get_arg() - application has no command-line argumments \n");
		exit(1);
	}

	if ((argnum < 0) || (argnum >= superargc))
	{
		fprintf(stderr, "treb_get_arg() - argument number must be between 0 and %d (application has %d command-line arguments)\n", (superargc-1), superargc);
		exit(1);
	}
	return superargv[argnum];	
}

