/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *    cas.c
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


#include "cas.h"


#if ( __WORDSIZE == 64 )


	/* CAS FOR 64 bits */
	int CAS(void *addr, casword_t oldval, casword_t newval) {
		char success;
		asm volatile (
				"lock; cmpxchgq %2, %0; setz %1"
				:"=m" (*(casword_t *)addr), "=q" (success)
				:"q" (newval), "a" (oldval), "m" (*(casword_t *)addr)
				: "memory");
					
				

		return(success);
	}



#else


	/* CAS FOR 32 bits */


	int CAS(void *addr, casword_t oldval, casword_t newval) {
		char success;
		asm volatile (                                          	
				"lock; cmpxchgl %2, %0; setz %1"
				:"=m" (*(casword_t *)addr), "=q" (success)
				:"q" (newval), "a" (oldval), "m" (*(casword_t *)addr)
				: "memory");
        	        	
        		
       	return(success);

}

#endif




