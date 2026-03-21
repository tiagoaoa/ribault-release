/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *     interp.h
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

#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>



#include <dlfcn.h>

#ifdef DEBUG_MEMORY
#include <mcheck.h>
#endif

#ifdef SET_AFFINITY
#define __USE_GNU
#include <sched.h>
#undef __USE_GNU
#endif
#include "dfmem.h"

#include "treb_functions.h"



#define ISMARKER(p)  ((marker_t *)p)->ptr == 0
#define MARKER_TAG(m) (m >> TOKEN_ALIGNMENT)
#define TOKEN_ALIGNMENT 2

#define OP_CONST 0
#define OP_FCONST 0 //FCONST and CONST have can have the same opcode, because they're of the same size
#include "instset.h"

#define MAX_OPER 100
#define MAX_INSTRS 500
#define MAX_DEST 200
#define MAX_SOURCE 200
#define MAX_DESTLIST_LEN 200
#define MAX_THREADS 200
#define SIZE_OF_DYNAMIC_EXEC_TAG 20 //in bits

#define OPCODE_SIZE 22
//#define SIZE_OF_SRC_LEN 5 //in bits
#define SIZE_OF_OPERLIST_LEN 5 //in bits
#define SIZE_OF_SRC_OFFSET 5


#define CHECK_MSGS_INTERVAL 50



/*#define DEBUG_EXECUTION 1
#define DEBUG_TERMINATION 1
#define DEBUG_OP_SEND 1
#define DEBUG_COMMUNICATION
#define DEBUG_STM
#define DEBUG_GC
*/



typedef struct {
	int count;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	int n;

} barrier_t;

typedef struct instr instr_t;
typedef struct oper oper_t;

typedef struct opmatch opmatch_t;
typedef struct dstinstr {
	instr_t *instr;
	int dstn;
} dstinstr_t;

typedef union {
	float f;
	int i;
	double d;
	long int li;
	void *p;
	void *w; //word-size on the host architecture
} generic_vartype;

struct instr {
	int opcode;
	//oper_t *src[MAX_SOURCE]; //linked lists containing the source operands
	opmatch_t *opmatch;
	int n_src;	
	generic_vartype immed; //TODO: can be float too.

	dstinstr_t dst[MAX_DEST][MAX_DESTLIST_LEN];  //TODO: allocate dynamically and reallocate if more elements are needed. 
	int n_dst;

	int dst_len[MAX_DEST];

	//int bool_input[MAX_DEST]; //The boolean input received by the steer. (always zero if the instruction is not a steer) 
	int port_enable[MAX_DEST]; 
	//port_enable[i] == 1 indicates that the ith operand produced by the instruction must be sent (through the ith port). port_enable[i] == 0 indicates that the operand corresponding to the ith port must NOT be sent.
	//This is used to switch ports in the Steer instruction.
	

	int call_count; //used in callsnd instructions only to increment the dynamic part of the execution mask

	char speculative;
	int pe_id;
		
};


struct oper {
	//instr_t *dst;
	//void *value;
       	generic_vartype value;
	int tag; //this tag corresponds to the loop iteration
	int exec; //the exec tag has two parts, the callgroup number(high bits) and the dynamic part corresponding to the instance of the function call. The dynamic part is set to the counter of the callsnd instruction that sends the operand. Everytime a callsnd instruction executes it increments its counter after sending the operand.
	int spec; //speculation number.
	//char isspeculative; //indicates if the operand is speculative. used for gc. 
	int max_match; //indicates the highest spec number of an operand this one has been matched with. used for gc.
	oper_t *next; //pointer to the next oper in the instruction's linked list.
	void (*cleanup)(void *ptr, int fullcleanup); //pointer to the cleanup function of the operand. This is used to free the memory allocated to operands of previous executions when there's a reexecution due to speculation. The first operand is the pointer to the 'object' and the second is a boolean value indicating the level of cleanup (full or not full).
	
};


typedef enum msgtype {MSG_TERMDETECT, MSG_GC, MSG_OPER, MSG_DISPSND} msgtype_t;
/* IMPORTANT: The first element must be the msgtype */
typedef struct optoken {
	msgtype_t type;
	instr_t *dst;
	int dstn; //"side" of the input operand(left or right) on the input instruction
	oper_t oper;
} optoken_t;
typedef struct marker {
	msgtype_t type;	
	int tag;
} marker_t;
struct opmatch {
	int tag;
	int exec;
	int spec;
	oper_t *op[MAX_SOURCE];
	opmatch_t *next;
	int count;
};

typedef struct dispatch {
	//oper_t *op1;
	//oper_t *op2;
	oper_t *op[MAX_SOURCE];
	//opmatch_t *match;
	instr_t *instr;
	int speculative;
	char free_disp;

} dispatch_t;
typedef struct dispsnd {
	msgtype_t type;
	dispatch_t *disp;
} dispsnd_t;


typedef struct dispatch_and_tx { 
	dispatch_t *disp;
	tm_tx_t *tx;	
} dispandtx_t; 

typedef struct {
	//oper_t operands[MAX_OPER];
	int waiting;
	queue_t queue;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
} combuff_t;

typedef struct {
	int id;
	int core;
	instr_t instrs[MAX_INSTRS]; //instr_t *intrs;
	int n_instrs;
	int n_edges;		//number of edges (threads that send/receive operands to/from this one)
	int n_threads;
	queue_t ready_queue;
	int global_termination;
	int termination_tag;
	int termination_count;
	int isidle;
	
	//function pointers

} thread_args;

typedef struct waitcounter waitcounter_t;
struct waitcounter {
	int tstamp;
	int count;
	waitcounter_t *next;
};
typedef struct {
	waitcounter_t *head;
	waitcounter_t *tail;
} wcounters_list_t;

typedef union  {
	void (*nspec)(oper_t **oper, oper_t *result); //non-speculative instruction
        void (*spec)(tm_tx_t *tx, oper_t **oper, oper_t *result); //speculative instruction

} cblockptr_t;


void loader(int placement[], thread_args *args, FILE *fp); 

int treb_get_n_tasks();

int treb_get_tid();
