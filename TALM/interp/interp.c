/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *     interp.c
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
#define _GNU_SOURCE
#include <sched.h>

#include "queue.h"

#include "interp.h"	

#include "atomcount.h"

void * pe_main(void *args);

void initialize_threads(thread_args *args, int n_threads, FILE *fp, FILE *pla);

//void eval(instr_t *instr, oper_t **oper, thread_args  *pe_attr);
void eval(dispatch_t *disp, thread_args *pe_attr);
//oper_t * create_oper(void *value);

void treat_msgs(thread_args *pe_attr, int isblocking);
int got_waited_ops(oper_t **oper, int n_waits, dispatch_t *disp);
void add_wait_counter(wcounters_list_t *counters, int tstamp, int count, int n_threads);
void dec_wait_counter(wcounters_list_t *counters, int tstamp, int n_threads);
void spec_clean(thread_args *pe_attr, int tstamp);

void debug_oplists(thread_args *pe_attr);
oper_t ** get_oper(oper_t **oplist, int tag, int exectag);

void propagate_oper(instr_t *instr, oper_t result[], thread_args *pe_attr);
//void bypass_oper(oper_t **oplist, oper_t oper); 

void send_single_oper(instr_t *instr, oper_t result[], thread_args *pe_attr, int i);
void bypass_oper(opmatch_t **matchptr, int inport, oper_t oper);

void inter_pe_send(int pe_id, instr_t *target, int dstn, oper_t oper);
//int can_exec(instr_t *instr);

dispatch_t * can_exec(instr_t *instr, int tag, int exectag);


void init_combuff(combuff_t *comm);
void comm_send(combuff_t *comm, qelem elem);

qelem comm_recv(combuff_t *comm, int blocking);


int treat_marker(int tag, int *pmax_tag, int *pcount, thread_args *attr, int isidle);

void send_markers(int tag, int id, int n);

void send_dispatch(dispatch_t *disp, int pe_id);
int get_notnull_spec(oper_t **oper, int len);

void dispandtx_cleanup(void *disptx, int islast); //callback function to cleanup operand
/* ----------------------------
	GLOBAL VARIABLES       */
barrier_t barrier;
combuff_t comm_buffer[MAX_THREADS];
void *libhandle;
int spec_global_time = 0;
wcounters_list_t wcounters = {NULL, NULL};  //Wait-counters for garbage (old operands) collection. (head = NULL, tail = NULL)
//NOTE: This won't work if two or more Commit instructions may run in parallel. Need to change the data structure if that is desirable
#ifdef STAT_STM
int number_of_rollbacks = 0;
#endif
char **superargv;
int superargc;
int n_tasks;
__thread int tid;
int n_procs;
int n_av_procs;
/*----------------------------*/







void barrier_init(barrier_t *barrier, int n_threads)  {
	pthread_mutex_init(&(barrier->mutex), NULL);
	pthread_cond_init(&(barrier->cond), NULL);
	barrier->count = 0;
	barrier->n = n_threads; 
	
}


void barrier_wait(barrier_t *barrier) {

	pthread_mutex_lock(&(barrier->mutex));
	barrier->count++;
	if (barrier->count == barrier->n) {
		barrier->count=0;
		pthread_cond_broadcast(&(barrier->cond));

	} else 
		pthread_cond_wait(&(barrier->cond), &(barrier->mutex));
	
		
	pthread_mutex_unlock(&(barrier->mutex));
	
} 

void init_combuff(combuff_t *comm) {
	init_queue(&(comm->queue));
	pthread_mutex_init(&(comm->mutex), NULL);
	pthread_cond_init(&(comm->cond), NULL);
	comm->waiting = 0;	


}
void comm_send(combuff_t *comm, qelem elem) {
	pthread_mutex_lock(&(comm->mutex));

	enqueue(elem, &(comm->queue)); 
	if (comm->waiting) 
		pthread_cond_broadcast(&(comm->cond));
	
	
	pthread_mutex_unlock(&(comm->mutex));

}
qelem comm_recv(combuff_t *comm, int blocking) {
	qelem elem = NULL;

	queue_t *queue = &(comm->queue);
	
	pthread_mutex_lock(&(comm->mutex));
	//printf("Peguei mutex %x\n",&(comm->mutex));	
	if (HAS_ELEMENTS(queue)) {
		elem = get_first(&(comm->queue));	

	} else 
		if (blocking) {
			comm->waiting = 1;
			pthread_cond_wait(&(comm->cond), &(comm->mutex));
			
			comm->waiting = 0;
			elem = get_first(&(comm->queue));	
			
		}
 	

	
	pthread_mutex_unlock(&(comm->mutex));

	return(elem);

}

/*
Another way of getting the number of processors (without using sysconf)
int GetCPUCount()
{
 cpu_set_t cs;
 CPU_ZERO(&cs);
 sched_getaffinity(0, sizeof(cs), &cs);

 int i,count = 0;
 for (i = 0; i < (sizeof(cs)*8) ; i++)
 {
  if (CPU_ISSET(i, &cs))
   count++;
 }
 return count;
}*/
int main(int argc, char **argv) {

	int n_threads, i;
	thread_args *t_args;
	n_procs = sysconf( _SC_NPROCESSORS_ONLN );//GetCPUCount();
#ifdef SET_AFFINITY
	cpu_set_t affinity_mask;
#endif
	pthread_t *threads;
	FILE *fp, *pla;
	if (argc < 4) {

		printf("Uso: ./inter <n_pes> <input.flb> <input.fla> <superinstructions_lib>(optional)\n");
		return(1);
	}
	superargv = argv + 5;
	superargc = argc - 5;
	n_threads=atoi(argv[1]);

	if (n_threads < 1) {
		fprintf(stderr, "The number of PEs has to be >= 1\n");
		return(1);
	}
	
	//TODO separate n_tasks and n_threads
	n_tasks=n_threads;
	

	if (!(fp = fopen(argv[2], "rb"))) {
		fprintf(stderr, "Error opening file\n");	
		return(1);
	}


        if (!(pla = fopen(argv[3], "r"))) {
                fprintf(stderr, "Error opening placement file\n");
                return(1);
        }

	libhandle = dlopen(argv[4], RTLD_LOCAL | RTLD_LAZY);
	if ((argc >=5) && ! libhandle ) { //Load the object code with the superinstructions
		fprintf(stderr, "Error opening dynamic library %s\n", argv[4]);
		return(1);
	}
	
	#ifdef DEBUG_MEMORY
	mtrace();	
	#endif
	
	if ((t_args = (thread_args *)malloc(sizeof(thread_args)*n_threads)) == NULL) {
		fprintf(stderr, "Error allocating memory for thread args\n");
		exit(1);
	}
	
	if ((threads = (pthread_t *)malloc(sizeof(pthread_t)*n_threads)) == NULL) {
		fprintf(stderr, "Error allocating memory for thread structures\n");
		exit(1);
	}; 	

	barrier_init(&barrier, n_threads);

	initialize_threads(t_args, n_threads, fp, pla);
	#ifdef USE_STM
	//stm_init(); //initialize main stm
	#endif
	
	int NUMBER_OF_CORES=n_procs;
	char* NCs;
	NCs = getenv ("NUM_CORES");
	if (NCs!=NULL)
		NUMBER_OF_CORES = atoi(NCs);
		
	n_av_procs = (n_procs<NUMBER_OF_CORES) ? n_procs : NUMBER_OF_CORES;
	fprintf(stderr, "Procs %d\n", n_av_procs);
	for (i = 0; i < n_threads; i++) {

		//printf("Criando thread: %d\n", i);fflush(stdout);
#ifdef SET_AFFINITY
	CPU_ZERO(&affinity_mask);
	CPU_SET(i % n_av_procs, &affinity_mask);
	if (sched_setaffinity(0, sizeof(affinity_mask), &affinity_mask) < 0)       	
				perror("sched_setaffinity");
#endif

		pthread_create(threads+i, NULL, pe_main, (void *)(t_args+i)); 
		
	}


	for (i=0; i < n_threads; i++) {
		pthread_join(threads[i], NULL);
		free(t_args[i].ready_queue.elem);
	}
	
	#ifdef STAT_STM
	printf("STM STAT: Total number of rollbacks = %d\n", number_of_rollbacks);
	#endif
	#ifdef USE_STM
	//stm_exit();
	#endif
	free(t_args);
	free(threads);
	#ifdef DEBUG_MEMORY
	muntrace();
	#endif
	return(0);
}


void * pe_main(void *args) {
	thread_args *attr = (thread_args *)args;	
	instr_t *instr;
	
	dispatch_t *disp;
	queue_t *readyq = &(attr->ready_queue), *commq = &((comm_buffer + attr->id)->queue);
	



	int check_msgs_count = CHECK_MSGS_INTERVAL;
	while (!attr->global_termination) {  //MAIN LOOP
		while (HAS_ELEMENTS(readyq)) {
			disp = get_first(readyq);
			
			instr = disp->instr;
			#ifdef DEBUG_EXECUTION
			printf("Executando instrucao %d (pe: %d)\n", instr->opcode, attr->id);
			#endif
	 		//eval(*instr, disp->op, attr); //TODO: Why not use pointer to instr?
		//	eval(instr, disp->op, attr);
			eval(disp, attr);
			check_msgs_count--;
			if (!check_msgs_count) {
				treat_msgs(attr, 0);
				check_msgs_count = CHECK_MSGS_INTERVAL;
			}
			//free(disp);
	
		}
		// TODO: move this if outside of the loop
		if (attr->n_edges == 0) {
			attr->global_termination = 1; 
			continue;
		}
		check_msgs_count = CHECK_MSGS_INTERVAL;
		if (!HAS_ELEMENTS(commq) && !attr->isidle)  {
			attr->isidle = 1;
			attr->termination_tag++;
			attr->termination_count = 0;
			#ifdef DEBUG_TERMINATION
			printf("Initiating termination detection with tag %d. (pe: %d)\n", attr->termination_tag, attr->id);
			#endif
			send_markers(attr->termination_tag, attr->id, attr->n_edges);
			
		}
	
		#ifdef DEBUG_COMMUNICATION
	        printf("PE: %d esperando msg\n", attr->id);
	        #endif
		treat_msgs(attr, 1);
	} //END OF MAIN LOOP
	
	

	#ifdef DEBUG_GC
	debug_oplists(attr);
	#endif
	barrier_wait(&barrier);
	return(NULL);

}
void treat_msgs(thread_args *attr, int isblocking) {
	qelem rcvmsg;
	optoken_t *rcvtoken;
	dispatch_t *disp;	
#ifdef DEBUG_COMMUNICATION
	printf("PE %d verificando buffer de mensagens\n", attr->id);
#endif
        rcvmsg = comm_recv(comm_buffer + attr->id, isblocking);
	if (rcvmsg != NULL) {
		switch (((marker_t *)rcvmsg)->type) {
			case MSG_TERMDETECT:
				#ifdef DEBUG_TERMINATION
				printf("Received marker with tag: %d (pe: %d, count = %d).\n", ((marker_t*)rcvmsg)->tag, attr->id, attr->termination_count);
				#endif
				attr->global_termination = treat_marker(((marker_t *)rcvmsg)->tag, &(attr->termination_tag), &(attr->termination_count), attr, attr->isidle);
				free((marker_t *)rcvmsg);
				break;
			case MSG_GC:
				#ifdef DEBUG_COMMUNICATION
				printf("Garbage collection msg received for timestamp: %d (pe: %d)\n", ((marker_t *)rcvmsg)->tag, attr->id);
				#endif
				#ifdef DEBUG_GC
				printf("Antes..\n");
				debug_oplists(attr);
				printf("Depois..\n");
				#endif
				spec_clean(attr, ((marker_t*)rcvmsg)->tag);
				free((marker_t *)rcvmsg);				
				#ifdef DEBUG_GC
				//printf("Garbage collecting opers with timestamp:%d (pe: %d)\n", ((marker_t*)rcvmsg)->tag, attr->id);
				debug_oplists(attr);
				#endif
				break;

			case MSG_OPER:
				rcvtoken = (optoken_t *)rcvmsg;
				#ifdef DEBUG_COMMUNICATION
				printf("PE: %d - Token recebido %x - tag: %d spec: %d\n", attr->id, (int)(rcvtoken->oper).value.i, (rcvtoken->oper).tag,(rcvtoken->oper).spec);
				#endif
				//bypass_oper((rcvtoken->dst)->src + rcvtoken->dstn, rcvtoken->oper);

				bypass_oper(&((rcvtoken->dst)->opmatch), rcvtoken->dstn, rcvtoken->oper);
				if ((disp = can_exec(rcvtoken->dst, (rcvtoken->oper).tag, (rcvtoken->oper).exec))) 
					enqueue((qelem)disp, &(attr->ready_queue));
			
				free(rcvtoken);	
				attr->isidle = 0;
				break;
			case MSG_DISPSND:
				#ifdef DEBUG_COMMUNICATION
				printf("PE: %d - dispatch recebido %x\n", attr->id, ((dispsnd_t *)rcvmsg)->disp);
				#endif
				disp = ((dispsnd_t *)rcvmsg)->disp;	
				enqueue((qelem)disp, &(attr->ready_queue));
				free((dispsnd_t *)rcvmsg);
				attr->isidle = 0;
				break;


			default:
				#ifdef DEBUG_COMMUNICATION
				printf("PE: %d - Unknown msg type received: %d\n", attr->id,((marker_t *)rcvmsg)->type );
				#endif
				break;	
		}	

	}



}
/* Global termination detection algorithm: 
   This is an implementation of the termination detection algorithm based on distributed snapshots. The difference is that, since our topology is a complete graph, we don't need a leader to collect all states. 
   A node (thread) begins the termination detection after entering state (isisdle == 1). It then broadcasts a marker with termination_tag equal to the greatest marker tag seen plus 1. Other nodes enter this termination detection if they already are in (isidle == 1) state and if the tag received is greater than the greatest termination tag seen. After entering this new termination detection this other node also broadcasts the marker with the termination_tag received, this indicates his (is_idle == 1) state to all the other nodes. Once a node participating in a termination detection has received a marker corresponding to that termination detection from all neighboors (i.e. all other nodes in the complete graph topololy), it broadcasts another marker with the same tag if it is still in state (isidle == 1). 
  The second marker broadcasted carries the information that all input edges to that node were detected empty, since the node only broadcasted the marker because it stayed in (isidle == 1) state until receiving the first (node state) markers from all other nodes, meaning it did not receive a message containing an operand.

  So, in our implementation, we use only one type of message, the marker with the termination_tag, and the first one carries the node state information (isidle == 1) while the second one carries the edges state information (all empty). It is then clear that after receiving the second round of markers from all other nodes, the node can terminate.

 */


int treat_marker(int tag, int *pmax_tag, int *pcount, thread_args *attr, int isidle) {
	//Global termination detection algorithm

	int n_edges = attr->n_edges;

	int term_detected = 0;

	if (tag > *pmax_tag) {

		*pmax_tag = tag;
		if (isidle) {
			*pcount = 0; //the count will be incremented in the next if
			#ifdef DEBUG_TERMINATION
			printf("Entered termination detection tag: %d (pe: %d).\n", tag, attr->id); //Got into a new termination detection
			#endif
			send_markers(tag, attr->id, attr->n_edges); 
		}

	}


	if (tag == *pmax_tag && isidle) {
		(*pcount)++;
		
		if (*pcount == n_edges) {
			#ifdef DEBUG_TERMINATION
			printf("Sending state (pe: %d, count = %d)\n", attr->id, *pcount);
			#endif
			send_markers(tag, attr->id, attr->n_edges); //send state
		} else
				
			if (*pcount == 2*n_edges) {
				term_detected = 1; //termination detected
				#ifdef DEBUG_TERMINATION
				printf("Termination detected (pe: %d)\n", attr->id);
				#endif
			}
		
	}

	return(term_detected);

}

void send_markers(int tag, int id, int n) {
	/*NOTE: Since the communication is implemented in a complete graph topology, the target nodes of all nodes(threads) are the same, so we just have one array of communication buffers, the global variable comm_buffer[] */
	int i;

	marker_t *marker;

	for (i = 0; i < n+1; i++) {
		if (i != id) {
			marker = (marker_t *) malloc(sizeof(marker_t));
			//marker->ptr = NULL;                                      	
			marker->tag = tag;
			marker->type = MSG_TERMDETECT;
			#ifdef DEBUG_TERMINATION
			printf("Sending token with tag %d to %d. (pe: %d), nedges= %d\n", tag, i, id, n);
			#endif
			comm_send(comm_buffer + i, (qelem)marker);		
		}
	}




}
//void eval(instr_t instr, thread_args  *pe_attr) {

//void eval(instr_t *instr, oper_t **oper, thread_args  *pe_attr) {
void eval(dispatch_t *disp, thread_args *pe_attr) {	
	//oper_t **oper = disp->op;
	//
	oper_t **oper = disp->op; 
	instr_t *instr = disp->instr;
	int i, tag, exectag, spectag;
	//int free_disp = 1
	int  free_opers = !disp->speculative;
#ifdef USE_STM	
	tm_tx_t *tx;
#endif	
	cblockptr_t fptr; //pointer to the function of the SuperInstruction block

	oper_t result[MAX_DEST];
	

        if (oper[0] != NULL) {
                tag = oper[0]->tag;
                exectag = oper[0]->exec;

        } else {
                tag = exectag = 0;
        }
        if (instr->speculative) {
                spectag = atomic_inc(&spec_global_time);
                free_opers = 0;
                /*for (i=0; i<instr->n_src; i++) {
                        //if (!oper[i]->isspeculative)
                        oper[i]->max_match = spectag; //the non-speculative operands of speculative instructions should havethe instruction spectag (execution time), so they can be garbage collected
                }*/
        } else
                spectag = disp->speculative;//get_notnull_spec(oper, instr->n_src); //only one can be >0, otherwise instr would have to be speculative
        for (i=0; i<instr->n_dst; i++) {
                result[i].tag = tag;
                result[i].exec = exectag;
                result[i].next = NULL;
                result[i].spec = spectag;
                //result[i].isspeculative = (spectag > 0);
                result[i].cleanup = NULL;

        }




	switch (instr->opcode) {
			
		case OP_CONST:
			//result = create_oper((void *) instr.immed );
			result[0].value.i = instr->immed.i;
			#ifdef DEBUG_EXECUTION
			printf("CONST: %d tag: %d\n", result[0].value.i, result[0].tag);
			#endif
			break;

		case OP_DCONST:
			result[0].value.d = (double)instr->immed.f;
			#ifdef DEBUG_EXECUTION
                       	printf("DCONST: %lf tag: %d -- immed: %lf \n", result[0].value.d, result[0].tag, instr->immed.f);
                       	#endif
			break;
		case OP_ADD:
			//oper1 = get_oper(instr.src[0], instr.tag);
			//oper2 = get_oper(instr.src[1], instr.tag);   

			//result = create_oper((void *)((int) oper1->value + (int) oper2->value));
		
			
			result[0].value.i = (oper[0]->value.i + oper[1]->value.i);
			#ifdef DEBUG_EXECUTION
			printf("ADD: %d + %d = %d\n", oper[0]->value.i, oper[1]->value.i, result[0].value.i);
			#endif
			break;

	
		case OP_SUB:
			result[0].value.i = (oper[0]->value.i - oper[1]->value.i);
			#ifdef DEBUG_EXECUTION
			printf("SUB: %d - %d = %d\n", oper[0]->value.i, oper[1]->value.i, result[0].value.i);
			#endif
		   	break;


		case OP_ADDI:
			result[0].value.i = instr->immed.i + oper[0]->value.i;
			#ifdef DEBUG_EXECUTION
			printf ("ADDI: %d + %d\n", instr->immed.i, oper[0]->value.i);
			#endif
			break;


                case OP_SUBI:
			result[0].value.i =  oper[0]->value.i - instr->immed.i;
			#ifdef DEBUG_EXECUTION
  			printf ("SUBI: %d + %d\n", oper[0]->value.i, instr->immed.i);
			#endif
			break;


		case OP_MULI:
			result[0].value.i = oper[0]->value.i * instr->immed.i;
			#ifdef DEBUG_EXECUTION	
                	printf("MUL: %d + %d = %d\n", oper[0]->value.i, instr->immed.i, result[0].value.i);
                	#endif
			break;
		case OP_DIVI:
			result[0].value.i = (oper[0]->value.i / instr->immed.i);
                        
                        result[1].value.i = (oper[0]->value.i % instr->immed.i);
			#ifdef DEBUG_EXECUTION	
        		printf("DIVI: %d / %d = %d (remainder %d)\n", oper[0]->value.i, instr->immed.i, result[0].value.i, result[1].value.i);
	        	#endif
			break;


		case OP_MUL:
			result[0].value.i = (oper[0]->value.i * oper[1]->value.i);
			#ifdef DEBUG_EXECUTION	
			printf("MUL: %d + %d = %d\n", oper[0]->value.i, oper[1]->value.i, result[0].value.i);
			#endif
			break;
		
		case OP_DIV:
			result[0].value.i = (oper[0]->value.i / oper[1]->value.i);
		
			result[1].value.i = (oper[0]->value.i % oper[1]->value.i);
			#ifdef DEBUG_EXECUTION	
        		printf("DIV: %d / %d = %d (remainder %d)\n", oper[0]->value.i, oper[1]->value.i, result[0].value.i, result[1].value.i);
	        	#endif
			break;

		case OP_FADD:
			result[0].value.f = (oper[0]->value.f + oper[1]->value.f);
			#ifdef DEBUG_EXECUTION
			printf("FADD: %f + %f = %f\n", oper[0]->value.f, oper[1]->value.f, result[0].value.f);
			#endif
			break;
				
                case OP_DADD:
                        result[0].value.d = oper[0]->value.d + oper[1]->value.d;
                        #ifdef DEBUG_EXECUTION
                        printf("DADD: %17.9e + %17.9e = %17.9e\n", oper[0]->value.d, oper[1]->value.d, result[0].value.d);
			#endif
			break;
			
		case OP_AND:

			result[0].value.i = oper[0]->value.i && oper[1]->value.i;

			#ifdef DEBUG_EXECUTION
			printf("AND: %d and %d = %d", oper[0]->value.i, oper[1]->value.i, result[0].value.i);
			#endif

			break;



		case OP_STEER:
			//The steer instruction sends operand through port 0, if boolean_input == 0, or throught port 1, if boolean_input == 1.
			instr->port_enable[0] = !oper[0]->value.i; 
			instr->port_enable[1] =  oper[0]->value.i;
			result[oper[0]->value.i != 0].value = oper[1]->value;
			#ifdef DEBUG_EXECUTION
			printf("STEER boolean = %d out = %d specin = %d specout = %d\n", oper[0]->value.i, result[oper[0]->value.i].value.i, disp->speculative, result[oper[0]->value.i].spec);
			#endif
			break;
		case OP_LTHAN:
			result[0].value.i = (oper[0]->value.i <  oper[1]->value.i);  
			#ifdef DEBUG_EXECUTION
			printf("LTHAN %d < %d\n", oper[0]->value.i, oper[1]->value.i);
			#endif 
			break;
		
		case OP_LTHANI:
			result[0].value.i = (oper[0]->value.i < instr->immed.i);  
			#ifdef DEBUG_EXECUTION
			printf("LTHANI %d < %d\n", oper[0]->value.i, instr->immed.i);
			#endif 
			break;
	
		case OP_GTHAN:
			result[0].value.i = (oper[0]->value.i >  oper[1]->value.i);  
			#ifdef DEBUG_EXECUTION
			printf("GTHAN %d > %d\n", oper[0]->value.i, oper[1]->value.i);
			#endif 
			break;
	

		case OP_GTHANI:
			result[0].value.i = (oper[0]->value.i >  instr->immed.i);  
			#ifdef DEBUG_EXECUTION
			printf("GTHANI %d > %d\n", oper[0]->value.i, instr->immed.i);
			#endif 
			break;

		case OP_EQUAL:
			result[0].value.i = (oper[0]->value.i ==  oper[1]->value.i);  
			#ifdef DEBUG_EXECUTION
			printf("EQUAL (%d == %d) = %d\n", oper[0]->value.i, oper[1]->value.i, result[0].value.i);
			#endif 
			break;
		
		case OP_ITAG:
			result[0].value = oper[0]->value;
			result[0].tag = oper[0]->tag + 1;
			#ifdef DEBUG_EXECUTION
			printf("ITAG %d + 1 = %d (valor %d)\n", oper[0]->tag, result[0].tag, result[0].value.i);
			#endif
			break;

		case OP_ITAGI:
			result[0].value = oper[0]->value;
			result[0].tag = oper[0]->tag + instr->immed.i;
			#ifdef DEBUG_EXECUTION
			printf("ITAGO %d + %d = %d (valor %d)\n", oper[0]->tag, instr->immed.i, result[0].tag, result[0].value.i);
			#endif
			break;

		case OP_CALLSND:
			instr->call_count++; /* Every callsnd instruction has a counter. Since all the instructions on the same callgroup have to have the same execution id, they all have to be executed the same amount of times. It also means that incrementing all these counters is inefficient, since we could just increment a centralised one (a per callgroup counter).*/
						

			result[0].value = oper[0]->value;
			result[0].tag = oper[0]->tag;
			result[0].exec = instr->immed.i << SIZE_OF_DYNAMIC_EXEC_TAG | instr->call_count;
			#ifdef DEBUG_EXECUTION
                        printf("CALLSND TAG:%d  EXEC:%d  VAL:%d", result[0].tag, result[0].exec, result[0].value.i);
                        #endif

			break;

		case OP_RETSND:
			instr->call_count++; /* Every callsnd instruction has a counter. Since all the instructions on the sa
me callgroup have to have the same execution id, they all have to be executed the same amount of times. It also means that incrementing all these counters is inefficient, since we could just increment a centralised one (a per callgroup counter).*/
			result[0].value.i = oper[0]->exec;
			result[0].tag = oper[0]->tag;
			result[0].exec = instr->immed.i << SIZE_OF_DYNAMIC_EXEC_TAG | instr->call_count;
				
			#ifdef DEBUG_EXECUTION
			printf("RETSND TAG:%d EXEC:%d VAL:%d i:%d", result[0].tag, result[0].exec, result[0].value.i, instr->immed.i);
			#endif



			break;


		case OP_TAGTOVAL:
        		result[0].value.i = oper[0]->tag;
			#ifdef DEBUG_EXECUTION
                        printf("TAGVAL TAG:%d TAG:%d\n", result[0].value.i, oper[0]->tag);
                        #endif	
				
		break;

		case OP_VALTOTAG:
			result[0].tag = oper[1]->value.i;
			result[0].value = oper[0]->value;
			#ifdef DEBUG_EXECUTION
                        printf("VALTAG TAG:%d VALUE:%d\n", result[0].tag, result[0].value.i);
                        #endif


		break;
		case OP_RET:
			for (i=0; i < instr->n_dst; i++)
				instr->port_enable[i] = 0;
			i = oper[1]->exec >> SIZE_OF_DYNAMIC_EXEC_TAG;
			instr->port_enable[i] = 1; //enable just the output to the instructions receiving from this callgroup (see documentation) 
			instr->n_dst = i + 1; //TODO: Do this in a cleaner way
		
			result[i].tag = oper[0]->tag;
			result[i].exec = oper[1]->value.i;	
			result[i].value = oper[0]->value;

			#ifdef DEBUG_EXECUTION
                         printf("Ret tag:%d  exec:%d val: %d outport: %d\n", result[i].tag, result[i].exec,result[i].value.i, i);
			#endif

			break;
		case OP_STOPSPC:
			result[0].value = oper[0]->value;
			result[0].spec = 0;
			#ifdef DEBUG_EXECUTION
			printf("SPEC STOP\n");
			#endif
			break;
		#ifdef USE_STM
		case OP_COMMIT: 
			{	
				dispandtx_t *disptx;
				dispatch_t *disprcvd;
				disptx = oper[0]->value.p;
				disprcvd = disptx->disp;
				tx = disptx->tx;
				if (got_waited_ops(oper+2, instr->n_src - 2, disprcvd)) {	

					instr->port_enable[0] = instr->port_enable[1] = tm_commit(tx);			
					if (instr->port_enable[0]) {
					#ifdef DEBUG_STM
						printf("Instrucao commitada: opcode %d\n", disprcvd->instr->opcode);
					#endif
						result[0].value.i = 0; //Go-ahead token, could have any value
						result[1].value.i = oper[0]->spec; //Wait token, equal to the last reexecution time
						result[0].spec = result[1].spec = 0;
						//result[0].isspeculative = result[1].isspeculative = 0; 
						//A commit's outputs are not speculative, commit ends speculation.

						add_wait_counter(&wcounters, oper[0]->spec, instr->dst_len[1], pe_attr->n_threads);

						for (i = 0; i < (instr->n_src - 2); i++)				
							dec_wait_counter(&wcounters, oper[2+i]->value.i, pe_attr->n_threads); 
						//dispandtx_cleanup(disptx);

					} else {
						#ifdef STAT_STM
						number_of_rollbacks++;
						#endif
						#ifdef DEBUG_STM
						printf("Rollback no commit\n");
						if ((disprcvd->instr)->pe_id != pe_attr->id)
							printf("WARNING: Rolling back an instruction from another pe\n");
						
						#endif
						if ((disprcvd->instr)->pe_id != pe_attr->id)
							send_dispatch(disprcvd, (disprcvd->instr)->pe_id);
						else
							enqueue((qelem)disprcvd, &(pe_attr->ready_queue));
						//free_disprcvd = 0; //don't free the dispatch because it was sent for reexecution
						//do rollback
					}
				} else {
					#ifdef DEBUG_STM
						printf("No commit.\n");
					#endif
					for (i = 0; i < instr->n_dst; i++)
						instr->port_enable[i] = 0;

					//dispandtx_cleanup(disptx);
				}
			}
			break;

		#endif
		default: 
			//Super Instruction
			//pe_attr.superinsts[instr->opcode - OP_SUPER1](oper, result);
			#ifdef DEBUG_EXECUTION
			#endif
			{
				char function_name[64];	//TODO: use a macro like MAX_FUNCTION_NAME_LENGTH
				int opcode=instr->opcode;
				dispandtx_t *disptx;
				tid = instr->immed.i;				
     
				sprintf(function_name, "super%d", opcode - OP_SUPER1); //change the string to super01, super02, .. etc
				fptr.nspec = dlsym(libhandle, function_name); //TODO: measure overhead
				if (fptr.nspec == NULL) { 
					fprintf(stderr, "%s\n", dlerror());
					exit(1); //EMERGENCY EXIT
				}
				#ifdef DEBUG_EXECUTION
				printf("SuperInstruction %s\n", function_name);
				#endif	
				#ifdef USE_STM
				if (instr->speculative) {
					#ifdef DEBUG_EXECUTION
					printf("Speculative Instruction\n");
					#endif



					tx = tm_create_tx(instr);
					//stm_start(tx, NULL, NULL);
					fptr.spec(tx, oper, result);

					disptx =  (dispandtx_t *)malloc(sizeof(dispandtx_t));
					//*disptx = (dispandtx_t) {disp, tx};
					//disp->free_disp = 0; //it will be free'd by the opers' GC
					disptx->disp = (dispatch_t *)malloc(sizeof(dispatch_t));
					*(disptx->disp) = *disp;
					disptx->disp->free_disp = 0;	//It will be free'd by the GC
					disptx->tx = tx;
					//memcpy(disptx->disp, disp, sizeof(dispatch_t));
					//printf("Dispatch que estou mandando: %d\n", disptx->disp->op[0]->spec);
					result[0].value.p = disptx;
					result[0].cleanup = &dispandtx_cleanup;
				}
				else
				#endif
					fptr.nspec(oper, result);

			}

			break;
	
	}
	
	for (i=0; i<instr->n_src && free_opers; i++)  {
		if (oper[i]->cleanup != NULL)
			oper[i]->cleanup(oper[i]->value.p, 1);
		free(oper[i]);

	}
	
	
	if (disp->free_disp) {
		free(disp);
	}
	
	#ifdef DEBUG_EXECUTION
	printf("Resultado: %d executado na thread: %d instr->n_dst = %d\n", result[0].value.i, pe_attr->id, instr->n_dst);
	#endif
	
	propagate_oper(instr, result, pe_attr);	
	

}


int got_waited_ops(oper_t **waitoper, int n_waits, dispatch_t *disp) {
	int i,j, n_opers, not_found, all_found = 1;
	int wait;
	oper_t **rcvdoper = disp->op;
	n_opers = (disp->instr)->n_src;

	
	for (i = 0; i < n_waits && all_found; i++) {
	  //n_waits will be <1 if their commit needs no waits
		not_found = 1;

		wait = waitoper[i]->value.i;
		//printf("Waiting for %d\n", wait);
		for (j = 0; j < n_opers && not_found; j++) {
			//printf("rcvdoper[%d]->spec = %d\n",j,rcvdoper[j]->spec);
			//if (wait == rcvdoper[j]->spec && rcvdoper[j]->isspeculative) {
			if (wait == rcvdoper[j]->spec) {
				//the non-speculative operands must not be counted, despite having the most recent spectag
				not_found = 0;
				rcvdoper[j]->spec *= -1; //Mark it so this wait is not counted again when doing the search for the next waits. 
				//printf("got wait! %d\n",rcvdoper[j]->spec);
			}
		}
		if (not_found) 
			all_found = 0;
	}

	for (i = 0; i < n_opers; i++)
		//Set the positive value back in the end.
		rcvdoper[i]->spec = rcvdoper[i]->spec * ((rcvdoper[i]->spec > 0) ? 1 : -1);

	return(all_found);
}

void debug_oplists(thread_args *pe_attr) {
	instr_t *instr;
	int i, j;
	oper_t *oper;
	opmatch_t *match;

	fprintf(stderr, "Remaining ops in pe: %d\n", pe_attr->id);
	for (i = 0; i < pe_attr->n_instrs; i++) {
		instr = pe_attr->instrs + i;
		match = instr->opmatch;
		while (match != NULL) {
			if (match->count > 0) {
				for (j = 0; j < instr->n_src; j++) {
					oper = match->op[j];	
					while (oper != NULL) {
					
						fprintf(stderr, "Instr: %d (opcode: %d) Input: %d tag: %d spec: %d valor: %x\n", i, instr->opcode, j, oper->tag, oper->spec, oper->value.i);

						oper = oper->next;
					
					}
				}	
			}
			match = match->next;
		}
	}


}

/*void debug_oplists(thread_args *pe_attr) {
	//Shows all remaining operands in the PE's instructions.
	instr_t *instr;
	int i,j;
	oper_t *oper;

	printf("Remaining ops in pe: %d\n", pe_attr->id);
	for (i=0; i < pe_attr->n_instrs; i++) {
		instr = pe_attr->instrs+i;
		
		for (j = 0; j < instr->n_src; j++) {
			oper = instr->src[j];
			while (oper != NULL) {
				printf("Instr: %d (opcode: %d) Input: %d tag: %d spec: %d valor: %x\n", i, instr->opcode, j, oper->tag, oper->spec, oper->value.i);

				//if (oper->cleanup != NULL)
				//	printf("   dispatch: %lx\n" , (double)((dispandtx_t *)oper->value.p)->disp);
				oper = oper->next;

			}


		}
	}


}
*/

/*
void clean_oplist_old(oper_t **oplist, int tstamp) {
	oper_t **ptr = oplist, *removed;
	int exectag, tag;

	#ifdef DEBUG_GC
//	printf("Clean oplist\n");fflush(stdout);
	#endif
	if (oplist != NULL) {
	
		while (*ptr != NULL && (*ptr)->max_match != tstamp) 
			//pprev = ptr;
			ptr = &((*ptr)->next);
		
		if ((*ptr) != NULL && (*ptr)->max_match == tstamp) {
			//if it has been matched with an operand with timestamp tstamp, we can remove it now.
			exectag = (*ptr)->exec;
			tag = (*ptr)->tag;
			while ((*ptr) != NULL && (*ptr)->exec == exectag && (*ptr)->tag == tag) {
				//we can also remove all the operands from old (re)executions of the same iteration that this one has replaced
				#ifdef DEBUG_GC
				printf("Spec cleaning %d\n", (*ptr)->max_match);
				#endif
				removed = *ptr;
				*ptr = (*ptr)->next;
				
				if (removed->cleanup != NULL) 
					removed->cleanup(removed->value.p);

				
				free(removed);
			}
	
	
	
		}
	
	}


}
*/
void remove_match(opmatch_t **matchptr, int n_src) {
	int i;
	oper_t *oper, *next;
	opmatch_t *match = *matchptr;
	for (i = 0; i < n_src; i++) {
		oper = match->op[i];
		while (oper != NULL) {
			next = oper->next;
			if (oper->cleanup != NULL)
				oper->cleanup(oper->value.p, (next == NULL));
			free(oper);
			oper = next;
		
		}
	
	}
	*matchptr = (*matchptr)->next;
	free(match);

}
void spec_clean(thread_args *pe_attr, int tstamp) {
	int i;
	instr_t *instr;
	opmatch_t **matchptr = NULL, **nextptr;

	for (i = 0; i < pe_attr->n_instrs; i++) {
		instr = pe_attr->instrs + i;
		matchptr = &(instr->opmatch);
		
		while ((*matchptr) != NULL) {
			nextptr = &((*matchptr)->next); 
			if ((*matchptr)->spec == tstamp) {
				#ifdef DEBUG_GC
				printf("Removing match spec: %d\n", (*matchptr)->spec);
				#endif
				remove_match(matchptr, instr->n_src);
				
			} else
				matchptr = nextptr;
		}	
	
	
	}

}

/*
void spec_clean(thread_args *pe_attr, int tstamp) {
	int i, j;
	instr_t *instr;

	for (i = 0; i < pe_attr->n_instrs; i++) {
		instr = pe_attr->instrs + i;
		for (j = 0; j < instr->n_src; j++)
			clean_oplist(instr->src+j, tstamp);	
		

	}
}
*/

void send_dispatch(dispatch_t *disp, int pe_id) {
	dispsnd_t *dispmsg = (dispsnd_t *)malloc(sizeof(dispsnd_t));
//	printf("Sending dispatch to %d\n", pe_id);
	dispmsg->disp = disp;
	dispmsg->type = MSG_DISPSND;
	comm_send(comm_buffer + pe_id, (qelem)dispmsg);

}

void send_gc_markers(int tstamp, int n_threads) {
	int i;
	marker_t *marker;
	for (i=0; i<n_threads; i++) {
		marker = (marker_t *)malloc(sizeof(marker_t));
		marker->tag = tstamp;
		marker->type = MSG_GC;
		comm_send(comm_buffer + i, (qelem)marker);
	}


}


void add_wait_counter(wcounters_list_t *counters, int tstamp, int count, int n_threads) {
	waitcounter_t *wcounter;
	#ifdef DEBUG_GC
	printf("Adding wait counter with timestamp %d and init value %d\n", tstamp, count);
	#endif 
	if (count == 0) {
	
		//ready for GC, don't even need to add a counter
		send_gc_markers(tstamp, n_threads);
		#ifdef DEBUG_GC
		printf("Operands with timestamp %d can be removed by GC. No need for a counter.\n", tstamp);
		#endif

	} else 	{//TODO: adapt to message passing
		wcounter = (waitcounter_t *)malloc(sizeof(waitcounter_t));
		wcounter->tstamp = tstamp;
		wcounter->count = count;
		wcounter->next = NULL;

		if (counters->head == NULL)
			counters->head = counters->tail = wcounter;
		else {
			(counters->tail)->next = wcounter;
			counters->tail = wcounter;
		}
	}


}
void dec_wait_counter(wcounters_list_t *counters, int tstamp, int n_threads) {
	/* Decrement the counter of the tstamp reexecution, indicating that the current commit instruction has committed and has received a wait with timestamp tstamp. If the corresponding counter becomes 0, all speculative operands with timestamp tstamp or less than timestamp, but with the same exectag and tag, can be cleaned. */
	waitcounter_t *ptr, *prev;
	//TODO: adapt to message passing
	#ifdef DEBUG_GC
	printf("Decrementing wait counter for timestamp %d\n", tstamp);
	#endif
	prev = ptr = counters->head;
	while (ptr->tstamp != tstamp) {
		prev = ptr;
		ptr = ptr->next; //can't reach a NULL value because the counter of tstamp must have been added to the list and can't have been removed yet.
	
	}
	//We don't need to use atomic operations to decrement the counter, because this function is only called inside the Commit instructions.
	if (--(ptr->count) == 0) {
		prev->next = ptr->next;
		free(ptr);
		send_gc_markers(tstamp, n_threads);
	//	enqueue((qelem)tstamp, garbage_specs); //no need for a lock on garbage_specs because only one commit executes at once
		#ifdef DEBUG_GC
		printf("Operands with timestamp %d can be removed by GC\n", tstamp);
		#endif
	}
	

}



int get_notnull_spec(oper_t **oper, int len) {
	int i;

	for (i = 0; i < len; i++)
		if (oper[i]->spec != 0)
			return(oper[i]->spec);

	return(0);

}



/*
oper_t * get_oper(oper_t **oplist, int tag) {
	//TODO; remove from list
	oper_t *op_ptr, *op_ret=NULL, **prevptr;
	

	op_ptr = *oplist;
	prevptr = oplist;
	while (op_ptr != NULL && op_ptr->tag <= tag && op_ret == NULL) {
	
		if (op_ptr->tag == tag) {
			op_ret = op_ptr;
			//ptrret prevptr
			
		
		} else {
			//prevptr = &(op_ptr->next);
			op_ptr = op_ptr->next;
				
		}	

	}
	return(op_ret);
} 
*/
/*
oper_t ** get_oper(oper_t **oplist, int tag, int exectag) {
	//returns the address of the pointer to the operand(if found), so the operand can be then removed from the list
	//with just one step
	oper_t **ptr;


	ptr = oplist;

	//The first operand with the desired tag and exectag in the linked list is the most recent one, i.e. the one from the most recent speculative (or not) execution
	while (*ptr != NULL && ((*ptr)->tag < tag || 
			( (*ptr)->tag == tag && (*ptr)->exec != exectag ) ) )
		ptr = &((*ptr)->next);

	if ( *ptr == NULL || ((*ptr)->tag != tag) || ((*ptr)->exec != exectag) ) 
		ptr = NULL;
	
	 
		
	return(ptr);


}*/
/*
void remove_oper(oper_t **ptr) {
	// ptr is the address of the pointer to the oper, so to remove the oper from the linked list we just have
	to change the pointer's value(*ptr) to the address of the next operand in the list 
	*ptr = (*ptr)->next;

}
*/


void propagate_oper(instr_t *instr, oper_t result[], thread_args *pe_attr) {

	int i ,j, inputn;
	dispatch_t *dispatch;
	instr_t *target;
	for (i = 0; i < instr->n_dst; i++)
		if (instr->port_enable[i]) 
			for (j = 0; j < instr->dst_len[i]; j++) {
				target = instr->dst[i][j].instr;
				inputn = instr->dst[i][j].dstn;
		
				#ifdef DEBUG_OP_SEND
				printf("Propagarei para %d (spec %d - value %d) entrada %d -- pe: %d\n", target->opcode,result[i].spec, result[0].value.i, inputn, target->pe_id);
				#endif
				if (target->pe_id == pe_attr->id) {
					//bypass_oper(target->src+inputn, result[i]);	
					bypass_oper(&(target->opmatch), inputn, result[i]);
					if ((dispatch = can_exec(target, result[i].tag, result[i].exec))) {
						enqueue((qelem)dispatch, &(pe_attr->ready_queue));
						}
			
				} else 
					inter_pe_send(target->pe_id, target, inputn, result[i]);
		
			
			}
	

}


dispatch_t * can_exec(instr_t *instr, int tag, int exectag) {
	int i;
	opmatch_t **matchptr = &(instr->opmatch), *match;
	
	dispatch_t *disp = NULL;

	while ( (tag >  (*matchptr)->tag) ||
					((tag == (*matchptr)->tag) && exectag != (*matchptr)->exec) ) {

			matchptr = &((*matchptr)->next);
		
	}
	
	match = *matchptr;
	if ((tag == match->tag) && (exectag == match->exec))  {
		if (match->count == instr->n_src) {
			//printf("Deu match\n");
			disp = (dispatch_t *)malloc(sizeof(dispatch_t));
			disp->instr = instr;
			disp->free_disp = 1;	
			for (i = 0; i < instr->n_src; i++) {
				disp->op[i] = match->op[i];
			
			}
			
			if (match->spec == 0)  {
				disp->speculative = 0;
				*matchptr = (*matchptr)->next;
				free(match);
			} else
				disp->speculative = match->spec;	
		
		} //else
		//	printf("Nao deu match 1 - count = %d n_src = %d\n", match->count, instr->n_src);

		
	}

	return(disp);

}

/*
dispatch_t * can_exec_old(instr_t *instr, int tag, int exectag) {

	oper_t *op, **opptr[MAX_SOURCE]; //TODO: allocate dynamically??
	int i, no_null_found = 1;
	dispatch_t *disp = (dispatch_t *)malloc(sizeof(dispatch_t));
 	disp->instr = instr;
	disp->speculative = 0;
	disp->free_disp = 1; //defaults to freeing the dispatch after execution
	for (i = 0; i<instr->n_src && no_null_found; i++) {
		opptr[i] = get_oper(instr->src + i, tag, exectag);

		if (opptr[i] == NULL) {
			no_null_found = 0;
			free(disp);
			disp = NULL;
		
		} else { 

			op = *(opptr[i]);
			disp->op[i] = op;
			if (op->spec > disp->speculative) //store the largest spec number
				disp->speculative = op->spec;
		}
		
	}
	if (no_null_found) {
		if (disp->speculative) {
			for (i = 0; i < instr->n_src; i++) 
				//if (!disp->op[i]->isspeculative)
				disp->op[i]->max_match = disp->speculative;
					//If the operand is not speculative we set its timestamp to the latest speculation to guarantee it will be removed by the gc. If another match occurs in the future with due to a new reexecution, this number is updated to the new latest. This operand will be removed by gc because the timestamp of the latest reexecution will be queued for cleaning up, since the speculative oper with that timestamp has not been replaced, which makes this timestamp the wait value of the source instruction's commit.
		} else
			for (i = 0; i<instr->n_src; i++)  
				remove_oper(opptr[i]);
		
	}
	return(disp);
		
}
*/
void inter_pe_send(int pe_id, instr_t *target, int dstn, oper_t oper) {
	//TODO: check if placing directly on a queue of tokens(instead of pointers to tokens) is faster

	optoken_t *tk = (optoken_t *)malloc(sizeof(optoken_t));
	
	tk->oper = oper;
	tk->dst = target;
	tk->dstn = dstn;	
	tk->type = MSG_OPER;
/*	pthread_mutex_lock(&(comm_buff[pe_id].mutex));
	
	enqueue((qelem)tk, &(comm_buff[pe_id].operqueue)); 
	
	pthread_mutex_unlock(&(comm_buff[pe_id].mutex));*/
	#ifdef DEBUG_COMMUNICATION
	printf("Enviando para pe: %d ... lado: %d - %s...\n", pe_id, dstn, (comm_buffer+pe_id)->waiting ?  "esperando" : "livre");
	#endif
	comm_send(comm_buffer + pe_id, (qelem)tk);
	#ifdef DEBUG_COMMUNICATION
	printf("Enviado para(pe: %d)\n", pe_id);
	#endif
}

void add_to_match(opmatch_t *match, int inport, oper_t *oper) {
	oper_t *old;
	//if (oper->next != NULL)
	//	printf("Nao eh nulo\n");
	if (match->op[inport] != NULL) {
		old = match->op[inport];
		if (oper->spec > old->spec) {
			oper->next = old;
			match->op[inport] = oper;
			
			if (oper->spec > match->spec)
				match->spec = oper->spec;
		
		} else {
			#ifdef DEBUG_GC
			printf("O novo eh mais velho\n");
			#endif

			if (oper->cleanup != NULL) {
					printf("Cleaning up %d\n", oper->spec);
					oper->cleanup(oper->value.p, 0); 
					//the 0 param indicates that this is not a full cleanup,
					//because we do full cleanups only at garbage collection.
			}

			free(oper);
			
		}

			
	
	
	} else {
		match->op[inport] = oper;
		if (oper->spec > match->spec)
			match->spec = oper->spec;
		(match->count)++;
	}

}
opmatch_t *create_opmatch(int tag, int exec) {
	opmatch_t *match = (opmatch_t *)malloc(sizeof(opmatch_t));
	int i;

	match->tag = tag;
	match->exec = exec;
	match->count = 0;
	match->spec = 0;
	match->next = NULL;
	for (i = 0; i < MAX_SOURCE; i++)
		match->op[i] = NULL;
	return(match);

}

void bypass_oper(opmatch_t **matchptr, int inport, oper_t oper) {
	opmatch_t *match = *matchptr, *prev = NULL, *newmatch;
	oper_t *opcopy = (oper_t *)malloc(sizeof(oper_t));

	*opcopy = oper;

	if (match == NULL) {
	       	*matchptr = create_opmatch(opcopy->tag, opcopy->exec); 	
		//(*matchptr)->op[inport] = opcopy;
		add_to_match(*matchptr, inport, opcopy);
	} else {
		//TODO: Maybe you should do the opposite and put the new one at the head of the list, because the old ones can be kept because of speculation
		while (match != NULL && ( (opcopy->tag >  match->tag) ||
						((opcopy->tag == match->tag) && (opcopy->exec != match->exec) )) ) {

			prev = match;
			match = match->next;
		
		}
	
		if (match != NULL && ( (opcopy->tag == match->tag) && (opcopy->exec == match->exec) ) ) {
			add_to_match(match, inport,  opcopy);	
		
		} else {
			//newmatch =(opmatch_t *)malloc(sizeof(opmatch_t));
			newmatch = create_opmatch(opcopy->tag, opcopy->exec);
			
			add_to_match(newmatch, inport, opcopy);		
			if (prev!=NULL) {
		
				prev->next = newmatch;
				newmatch->next = match;
			} else {
				*matchptr = newmatch;
				newmatch->next = match;
			}


		}
	
	
	
	}



} 

/*
void bypass_oper_old(oper_t **oplist, oper_t oper) {
	
	oper_t *ptr = *oplist, *prev = NULL, *opcopy;
	opcopy = (oper_t *)malloc(sizeof(oper_t));

	*opcopy = oper; //each instruction has its own copy of the operands that are sent to it	
	//printf("bypassando oper com tag: %d e value %d\n", oper.tag, oper.value);


	if (ptr == NULL) 
		*oplist	= opcopy;
	
	else {
		//TODO: return error if two operands with the same tags are received.
		while (ptr != NULL && ( (opcopy->tag > ptr->tag) || 
				((opcopy->tag == ptr->tag) && (opcopy->exec != ptr->exec)) ) ) {
				
			prev = ptr;
			ptr = ptr->next;

		}
		if ((ptr != NULL) && (opcopy->tag == ptr->tag) && (opcopy->exec == ptr->exec)) { //same operand, different executions
			if (opcopy->spec > ptr->spec) { //opcopy is from a more recent execution
				if (prev!=NULL) {
					prev->next = opcopy;
					opcopy->next = ptr;
				}
				else	{
					*oplist = opcopy;
					opcopy->next = ptr;
				}
				//opcopy->next = ptr->next;
				//old = ptr;
			} else {
				printf("O novo eh mais velho\n");
				//oldd = opcopy;
				if (opcopy->cleanup != NULL) {
					printf("Cleaning up %d\n", opcopy->spec);
					opcopy->cleanup(opcopy->value.p);
				}
				free(opcopy);
			}
		
		} else {
			prev->next = opcopy;
			opcopy->next = ptr;
		}		
		
	}

}
*/
void dispandtx_cleanup(void *ptr, int islast) {
	int i;
	oper_t **oper;
	dispandtx_t *disptx = (dispandtx_t *)ptr;
	dispatch_t *disp = disptx->disp;
	#ifdef DEBUG_GC
	//printf("Freeing disp %x tx %x no disptx %x\n", disptx->disp, disptx->tx, disptx); fflush(stdout);
	#endif
	
	if (islast && disp->speculative == 0) { 
	//Is the last one in the opmatch structure, which means we can do a full cleanup. It may not be the last one when the commit receives multiple commit messages for the same instance, due to reexecutions. Also, we have to check if disp->speculative == 0, because otherwise the operands would still be in the instruction's opmatch and, hence, would be removed by garbage collection on their side.
		oper = disp->op;
		for (i =  0; i < disp->instr->n_src; i++) {
			if (oper[i]->cleanup != NULL)
				oper[i]->cleanup(oper[i]->value.p, 1);
			free(oper[i]);	
		}

			
		
	
	
	}


	free(disptx->disp);
	//stm_exit_thread(disptx->tx);
	tm_cleanup_tx(disptx->tx);
	free(disptx);
	
}
//instr_t create_instruction(int opcode, 

void initialize_threads(thread_args *args, int n_threads, FILE *fp, FILE *pla) {
	int i;



	int *placement;
	int pla_inst_count;
	
	int pla_inst;
	
	if (!fscanf(pla, "%d\n", &pla_inst_count)) {
		fprintf(stderr, "Error reading placement file\n");
		exit(1);
	}
	placement = (int *) malloc(pla_inst_count*sizeof(int));

	for (pla_inst=0; pla_inst<pla_inst_count; pla_inst++) {
		if (!fscanf(pla, "%d\n", &placement[pla_inst])) {
			fprintf(stderr, "Error reading placement file\n");
			exit(1);
		}
	}



	
			//TODO: automatize placement

	//args[0].instrs = (instr_t *)malloc(3*sizeof(instr_t))
	
	//args[1].instrs = (instr_t *)malloc(2*sizeof(instr_t))

	/*dispatch_t *disp1, *disp2;

	disp1 = (dispatch_t *)malloc(sizeof(dispatch_t));
	
	disp2 = (dispatch_t *)malloc(sizeof(dispatch_t));
*/
	for (i = 0; i < n_threads; i++) {
		args[i].id = i;
		init_queue(&(args[i].ready_queue));
		init_combuff(comm_buffer + i);	
		args[i].n_edges = n_threads - 1;
		args[i].n_threads = n_threads;
		args[i].n_instrs = 0;
		args[i].global_termination = 0;
		args[i].termination_tag = 0;
		args[i].termination_count = 0;
		args[i].isidle = 0;

	}


	loader(placement, args, fp);



	/*args[0].instrs[0].opcode = OP_CONST;

	args[0].instrs[0].dst[1][0] = args[0].instrs+1;
	args[0].instrs[0].dst_len[0] = 0;
	args[0].instrs[0].dst_len[1] = 1;
	args[0].instrs[0].immed=5;


	args[0].instrs[2].opcode = OP_CONST;
	args[0].instrs[2].dst[0][0] = args[0].instrs+1;;
	args[0].instrs[2].dst_len[0] = 1;
	args[0].instrs[2].dst_len[1] = 0;
	args[0].instrs[2].immed = 4;


	args[0].instrs[1].opcode = OP_ADD;
	args[0].instrs[1].dst_len[0] = 0;
	args[0].instrs[1].dst_len[1] = 0;


	disp1->instr = args[0].instrs;
	disp2->instr = args[0].instrs+2;
	enqueue((qelem)disp1, &(args[0].ready_queue));
	enqueue((qelem)disp2, &(args[0].ready_queue));*/





/*
	args[1].instrs[0].op = OP_CONST;

	args[1].instrs[0].src1 = 7;
	args[1].instrs[0].dst = 3;





	args[1].instrs[1].op = OP_ADD;
	args[1].instrs[1].src1=3;
	args[1].instrs[1].src2=2;

	args[1].instrs[1].dst=4;

*/

}
