
#include "queue.h"
#include "interp.h"


#define LEFTMOST_BIT_SET (1 << (sizeof(int)*8 -1))
//#define NUM_SOURCES(opmask,i) ( (opmask >> (sizeof(int)*8 -1*(i+1)*SIZE_OF_SRC_LEN) ) & ((1<<SIZE_OF_SRC_LEN) -1) ) //TODO: Document this

#define OPER_LIST_LEN(opmask,i) ( (opmask >> (sizeof(int)*8 -1*(i+1)*SIZE_OF_OPERLIST_LEN) ) & ((1<<SIZE_OF_OPERLIST_LEN) -1) ) //TODO: Document this
/* Adds to the target destination list */

void add_dst(instr_t **addrs, unsigned int index, int n, instr_t *dst) {
	instr_t *src = addrs[index >> SIZE_OF_SRC_OFFSET]; 
	int output = index & ((1 << SIZE_OF_SRC_OFFSET) - 1);

	int last = src->dst_len[output]++;
	#ifdef DEBUG_LOADER
	printf("output = %d\n", output);
	#endif
	src->dst[output][last].dstn = n;
	src->dst[output][last].instr = dst;
//	src->dst[2*output + bool_port][last].dstn = n;
//	src->dst[2*output + bool_port][last].instr = dst;
	
}

void loadsources(instr_t **instaddrs, instr_t *instr, int k, int n, FILE *fp) {
	int i, src;
	
	for (i = 0; i < n; i++) {
		if (!fread(&src, sizeof(int), 1, fp)) {
			fprintf(stderr, "Error reading binary file\n");
			exit(1);
		}
		#ifdef DEBUG_LOADER
		printf("src = %d\n", (src & 0x7ffffff) >> SIZE_OF_SRC_OFFSET);
		#endif
		add_dst(instaddrs, src, k, instr);
	}

}
void placeinsts(FILE *fp, int n, instr_t **instaddrs, int placement[], thread_args *args) {
	int i, k;
	instr_t *instr;
//	fread(&n, sizeof(int), 1, fp); //the number of instructions is in the header of the binary file
	for (i=0; i < n; i++) {
		#ifdef DEBUG_LOADER
		printf("Placing inst number: %d\n", i);
		#endif
		k = args[placement[i]].n_instrs++;
		instr = instaddrs[i] = args[placement[i]].instrs + k; //save the address of the placed instruction	
		#ifdef DEBUG_LOADER
		printf("Placed\n");	
		#endif
		/* attribute initializations */
		for (k = 0; k < MAX_DEST; k++)
			instr->dst_len[k]=0;
		instr->pe_id = placement[i];
	//	instr->bool_input = 0;	
		/* ------------------------*/
	}
}
void loader(int placement[], thread_args *args, FILE *fp) {

	int i, j, n_src, n_dst, srclen, opcode;
	dispatch_t *disp;
	//int n=100; //Only 20 instructions -- JUST FOR TESTING
		//TODO: now the number of instructions is in the header of the binary file, use it.
		//
	int n;

	instr_t *instr;

	if (!fread(&n, sizeof(int), 1, fp)) { //the number of instructions is in the header of the binary file
		fprintf(stderr, "Error reading binary file.\n");
		exit(1);
	}
	instr_t **instaddrs = (instr_t **)malloc(sizeof(instr_t *) * n);
#ifdef DEBUG_LOADER
	printf("Starting placement..\n");
	#endif
	placeinsts(fp, n, instaddrs, placement, args); //Execute the placement		
	#ifdef DEBUG_LOADER
	printf("done\n");
	#endif	
	for (i=0; fread(&opcode, sizeof(int), 1, fp); i++) {
		instr = instaddrs[i];
	
		n_dst = OPER_LIST_LEN(opcode, 0);
		n_src = OPER_LIST_LEN(opcode, 1);
		instr->opcode = opcode & ((1<<OPCODE_SIZE)-1);

		
		instr->speculative = (instr->opcode & ( 1 << (OPCODE_SIZE -1))) != 0;
		if (instr->speculative) {
			#ifdef DEBUG_LOADER
			printf("Speculative instruction.\n");
			#endif
			instr->opcode &= ~( 1 << (OPCODE_SIZE -1));
		}
		
		instr->n_src = n_src;	
		instr->n_dst = n_dst;
		#ifdef DEBUG_LOADER
		printf("Opcode found: %d, placing at pe %d\n", instr->opcode, placement[i]);
		printf("n_dst = %d\n", n_dst);	
		printf("n_src = %d\n", n_src);
		#endif
		if (instr->opcode <= LAST_WITH_IMMED ||	instr->opcode >= OP_SUPER1) { //Instruction has immed.
			if (!fread(&(instr->immed.i), sizeof(int), 1, fp)) {
				fprintf(stderr, "Error reading binary file.\n");
				exit(1);
			}
			#ifdef DEBUG_LOADER
			printf("Immed: i: %d f: %f\n", instr->immed.i, instr->immed.d);
			#endif


		}
		instr->opmatch = NULL;
		for (j=0; j < n_src; j++) {
			//*(instr->src+j) = NULL;
			if (!fread(&srclen, sizeof(int), 1, fp)) { //read the length of the j_th operand sources list. That means we have srclen instructions that can send the j_th operand to this one.
				fprintf(stderr, "Error reading binary file.\n");
				exit(1);
			}

			#ifdef DEBUG_LOADER
			printf("src_len = %d\n", srclen);
			#endif
			loadsources(instaddrs, instr, j, srclen, fp);
		}
	
		if (instr->n_src == 0) { //Instruction needs no inputs
      			#ifdef DEBUG_LOADER
			printf("Constant found: %d\n", (int)(instr->immed.i));
			#endif
       			disp = (dispatch_t *)malloc(sizeof(dispatch_t));
        		disp->instr = instr;
			//disp->op[0] = NULL; //signalling that it has no operands
       			enqueue((qelem)disp, &(args[placement[i]].ready_queue)); //TODO: do this as a general rule(n_src == 0)
			#ifdef DEUG_LOADER
			printf("Tamanho da fila de ready: %d\n", args[placement[i]].ready_queue.allocsize);
			#endif
       		}





		instr->call_count = 0; //used only by callsnd and retsnd instructions
		
		for (j=0; j < n_dst; j++)
			instr->port_enable[j] = 1; //by default enable sending all produced operands throught their ports


	}
	
	#ifdef DEBUG_LOADER
	printf("----- END OF LOADER ----\n");
	#endif

} 
/*

int main(int argc, char *argv[]) {
	
	int placement[] = {0,0,0,1,1,1};

	FILE *fp = fopen(argv[1], "rb");

	thread_args *t_args = (thread_args *)malloc(sizeof(thread_args)*2);

	loader(placement, t_args, fp);




	return(0);
}*/
