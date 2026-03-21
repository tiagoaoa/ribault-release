#include <stdio.h>
#include <stdlib.h>

#define VALSET_BLOCK_SIZE 100000
#define HASH_SIZE 32768//16384
#define REALLOC_INCREMENT 100000
#define SHIFT_ALIGN 2
#include "dfmem.h"

int hash(tm_hashkey_t key) {
	unsigned int pos;
	//int keyint = key & 0xffffffff;
	//char *b = (char*)&key;
	

	/*pos = b[0];
	pos = ((pos<<8) + b[1]) % HASH_SIZE;
	pos = ((pos<<8) + b[2]) % HASH_SIZE;
	pos = ((pos<<8) + b[3]) % HASH_SIZE;
*/
	  //register uint32 key;
	   // key = (uint32) addr;
	//pos = (int)key >> 3 * 2654435761;
	//pos = ((unsigned int) key>>2) % HASH_SIZE;
	pos = ((unsigned long int) key>> SHIFT_ALIGN) % HASH_SIZE;
	return(pos);



}
tm_valset_t *tm_create_valset() { 
	int i;
	tm_valset_t *valset = (tm_valset_t *)malloc(sizeof(tm_valset_t));
	
	if ((valset->val = (tm_value_t *)malloc(sizeof(tm_value_t) * VALSET_BLOCK_SIZE)) == NULL) {
		printf("Error allocating new valset\n");
		exit(1);
	
	}
		

	valset->count = 0;
	//valset->allocated = VALSET_BLOCK_SIZE;

	valset->hasht = (tm_value_t **) malloc(sizeof(tm_value_t*)*HASH_SIZE);
	if (valset->hasht == NULL) {
		printf("Error allocating new hash\n");
		exit(1);
	}
	for (i=0; i < HASH_SIZE; i++)
		valset->hasht[i] = NULL;

	valset->gclist = NULL;
	return(valset);
}

void tm_gcvalset(tm_valset_t *valset) {
	tm_gcobj_t *p, *next;
	p = valset->gclist;
	//int i;
	while (p != NULL) {
		next = p->next;
		free((tm_valset_t *)p->addr);
		#ifdef DEBUG_GC
		printf("Freeing valset\n");
		#endif
		free(p);
		p = next;
	
	}
	//int i;	
	//for (i = 0; i < HASH_SIZE; i++)
	//	printf("Posicao %d hash: %s\n", i, (valset->hasht[i] != NULL ? "Cheia" : "Vazia"));
	free(valset->hasht);
	free(valset->val);
}
void tm_cleanup_tx(tm_tx_t *tx) {
	tm_gcvalset(tx->rset);
	tm_gcvalset(tx->wset);

	free(tx->rset);
	free(tx->wset);
	free(tx);

}
tm_tx_t *tm_create_tx() {
	tm_tx_t *tx = (tm_tx_t *)malloc(sizeof(tm_tx_t));

	tx->rset = tm_create_valset();

	tx->wset = tm_create_valset();

	return(tx);

}

tm_value_t *has_written(tm_tx_t *tx, tm_dword *addr) {
	//int i, not_found = 1;
	//tm_value_t *val = NULL;
	

	/*for (i = 0; i < tx->wset->count && not_found; i++)
		if (tx->wset->val[i].addr == addr) {
			val = tx->wset->val + i;
			not_found = 0;

		}*/



	return(hash_find((tm_hashkey_t)addr,  tx->wset->hasht));

}


int has_read(tm_tx_t *tx, tm_dword *addr) {
	//int i, not_found = 1;

	/*for (i = 0; i < tx->rset->count && not_found; i++)
		if (tx->wset->val[i].addr == addr) {
			not_found = 0;

		}

	return(!not_found);*/

	return(hash_find((tm_hashkey_t)addr, tx->rset->hasht) != NULL);


}

void hash_insert(tm_hashkey_t key, tm_value_t **table, tm_value_t *val) {
	int pos;
	tm_value_t *p;
	pos = hash(key);
	//printf("HASH KEY insert: %d %x %x %x %x\n", pos, b[7], b[6], b[5], b[4]);
	if (table[pos] == NULL) {
		table[pos] = val;
		

	} else {
#ifdef DEBUG_STM2
		printf("Hash insert collision key = %d\n", pos);
#endif
		p = table[pos];
		while (p->next != NULL) {
#ifdef DEBUG_STM2
			printf("pegando next %x\n", p->next);fflush(stdout);
#endif
			p = p->next;
		}
#ifdef DEBUG_STM2
		printf("Inserindo val %x\n", val);
#endif
		p->next = val;

	}


}
void add_to_set(tm_valset_t *valset, tm_dword *addr, tm_generic_value value, int size){ //, char needs_validation) {
	int last;
	tm_gcobj_t *gcobj;

	//if (valset->count == valset->allocated) {
	if (valset->count == VALSET_BLOCK_SIZE) {	
		//valset->val = realloc(valset->val, sizeof(tm_value_t) * (valset->allocated + REALLOC_INCREMENT)); 
		
		gcobj = (tm_gcobj_t *)malloc(sizeof(tm_gcobj_t));
		gcobj->addr = valset->val;
		gcobj->next = valset->gclist;
		valset->count = 0;
		valset->gclist = gcobj;

		valset->val = (tm_value_t *)malloc(sizeof(tm_value_t) * VALSET_BLOCK_SIZE); //set the allocation pointer for a newly allocated area, the old one is maintained in the gclist for collection.
		#ifdef DEBUG_GC
		printf("Reallocating valset\n");
		#endif

	}

	last = valset->count++;
	

	valset->val[last].addr = addr;
	valset->val[last].value = value;
	valset->val[last].size = size;
	//valset->val[last].validate = needs_validation;
	valset->val[last].next = NULL;

	hash_insert(addr, valset->hasht, valset->val + last); 
}

tm_value_t *hash_find(tm_hashkey_t key, tm_value_t **table) {
	int pos;
	tm_value_t *p = NULL;
	pos = hash(key);

	if (table[pos] == NULL)
		return(NULL);
	else {
		p = table[pos];
		while (p != NULL && p->addr != key) {
			p = p->next;
		
		}
				
		
		
	}

	return(p);

}

tm_word32 tm_load32(tm_tx_t *tx, tm_word32 *addr) {
	tm_generic_value value;
	tm_value_t *valueptr;
//	char needs_validation;
	if ((valueptr = has_written(tx, (tm_dword*)addr))) {
		value.w32 = valueptr->value.w32;
	//	needs_validation = 0;
	} else {
		value.w32 = *addr;
		//needs_validation = 1;
	
	
		if (!has_read(tx, (tm_dword *)addr))
			add_to_set(tx->rset, (tm_dword *)addr, value, sizeof(tm_word32));
	}

	#ifdef DEBUG_STM2
	printf("load() = %d\n", (int)value.w32);fflush(stdout);
	#endif
	return(value.w32);	


}
tm_word64 tm_load64(tm_tx_t *tx, tm_word64 *addr) {
	tm_generic_value value;
	tm_value_t *valueptr;
	//char needs_validation;
	
	if ((valueptr = has_written(tx, (tm_dword*)addr))) {
		value.w64 = valueptr->value.w64;
	//	needs_validation = 0;
	} else {
		value.w64 = *addr;
//		needs_validation = 1;
	
	
		if (!has_read(tx, (tm_dword *)addr))
			add_to_set(tx->rset, (tm_dword *)addr, value, sizeof(tm_word64));//, needs_validation);
	}
#ifdef DEBUG_STM2
	//printf("load() addr: %x = %17.9e\n", addr, (double)value.w64);fflush(stdout);
	printf("load()\n");
#endif

	return(value.w64);	

}


/*tm_value_t *has_written(tm_tx_t *tx, tm_dword *addr) {
	int i;
	tm_valset_t *wset = tx->wset;
	for (i=0; i < wset->count; i++)
		if (wset->val[i].addr = addr)
			return(wset->val+i);

	return(NULL); //haven't found


}*/
void tm_store32(tm_tx_t *tx, tm_word32 *addr, tm_word32 value) {
	tm_value_t *valueptr;
	tm_generic_value genvalue;
	genvalue.w32 = value;
#ifdef DEBUG_STM2
	printf("write()\n");
#endif

	if ((valueptr = has_written(tx, (tm_dword*)addr))) {
		valueptr->value.w32 = value;
		if (valueptr->size < sizeof(tm_word32))
			valueptr->size = sizeof(tm_word32);
	
	} else
		add_to_set(tx->wset, (tm_dword)addr, genvalue, sizeof(tm_word32));//, 0);
	

}
//TODO: isn't it too ugly to just repeat the code? But wouldn't using a switch be slower? Maybe use function pointers..
void tm_store64(tm_tx_t *tx, tm_word64 *addr, tm_word64 value) {
	tm_value_t *valueptr;
	tm_generic_value genvalue;
	genvalue.w64 = value;
#ifdef DEBUG_STM2
	//printf("write() addr: %x = %17.9e\n", addr, (double)value);
	printf("write()\n");
#endif

	if ((valueptr = has_written(tx, (tm_dword*)addr))) {
		valueptr->value.w64 = value;
		if (valueptr->size < sizeof(tm_word64))
			valueptr->size = sizeof(tm_word64);
	
	} else
		add_to_set(tx->wset, (tm_dword)addr, genvalue, sizeof(tm_word64));//, 0);
	

}

int tm_commit(tm_tx_t *tx) {
	int i, length;
	tm_generic_pointer p;
	tm_gcobj_t *nxtgcobj = tx->wset->gclist;
	tm_value_t *val;
	if (!tm_validate(tx))
		return(0);

	
	length = tx->wset->count;
	val = tx->wset->val; //first go through the most recently allocated vector
	//for (i = 0; i < tx->wset->count; i++) {
	while (val != NULL) {
		for (i = 0; i < length; i++) {
		//val = tx->wset->val+i;
			p.w32 = val[i].addr;
			switch (val[i].size) {
				case sizeof(tm_word32): 
					*(p.w32) = val[i].value.w32;			

					break;

				case sizeof(tm_word64):
					*(p.w64) = val[i].value.w64;
					break;

				
				case sizeof(char):
					*(p.b) = val[i].value.b;
					break;                                                  		
	
			}
		}
		if (nxtgcobj != NULL) {
			val = (tm_value_t *)nxtgcobj->addr;
			length = VALSET_BLOCK_SIZE; 
			nxtgcobj = nxtgcobj->next;
		} else
			val = NULL;

		
	}
	return(1);
}

int tm_validate(tm_tx_t *tx) {
	int i, length;	
	tm_valset_t *rset = tx->rset;
	tm_value_t *val;
	tm_gcobj_t *nxtgcobj = tx->rset->gclist;

	val = rset->val;
	length = rset->count;
	while (val != NULL) {
		for (i = 0; i < length; i++) {	
			//if (val[i].validate) {
			switch (val[i].size){
				case sizeof(tm_word32): 
					if (val[i].value.w32 != *((tm_word32 *)val[i].addr)) {
#ifdef DEBUG_STM
						printf("Diferente %d != %d\n", val[i].value.w32, *((tm_word32 *)val[i].addr));
#endif
						//exit(0);
						return(0);
					}
					break;

				case sizeof(tm_word64):
					if (val[i].value.w64 != *((tm_word64 *)val[i].addr)) {

#ifdef DEBUG_STM
						printf("Diferente %17.9e != %17.9e\n", (double)val[i].value.w64, *((double *)val[i].addr));
#endif
        			          	return(0);
					}
					break;
				
				case sizeof(char):
					if (val[i].value.b != *((char *)val[i].addr))	
        		        	  	return(0);
					break;                                                  		
			}
		}
		
		if (nxtgcobj != NULL) {
			val = (tm_value_t *)nxtgcobj->addr;
			nxtgcobj = nxtgcobj->next;
			length = VALSET_BLOCK_SIZE;
		} else
			val = NULL;


	
	}
	return(1);
}


