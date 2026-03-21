/* Atomic counter */

#include <limits.h>
#if ( __WORDSIZE == 64 )


int atomic_inc(int * operand)
{
	long int incr = 1;
	asm volatile (
	            "lock; xaddq %3, %1\n" // atomically add inc to *operand and store in inc the old val of *operand
	            : "=r" (incr), "=m" (*operand)
		    : "m" (*operand), "0"(incr) //1 is the increment size
		    : "memory"
		);
	return(incr+1); 
}

#else
int atomic_inc(int * operand)
{
	int incr = 1;
	asm volatile (
	            "lock; xaddl %3, %1\n" // atomically add inc to *operand and store in inc the old val of *operand
	            : "=r" (incr), "=m" (*operand)
	            : "m" (*operand), "0" (incr)
		    : "memory"
		);
	return(incr+1);
}


#endif
/*
int atomic_inc(int *addr) {
	int oldval;
	char success; 

//	do {
	oldval = *addr;
	__asm__ __volatile__("loop_atom_inc: 
				movl (%1), %%eax;
			       	leal (%%eax,$1), %%ebx  	
				lock; cmpxchgq %%ebx, (%1); 
				jnz loop_atom_inc" 
				:"=m"(*addr) 
				:"r"(addr)//, "q"(oldval)
				:"memory", "ebx", "eax");
//	} while (!success); 

	return(oldval+1);
}

#else
int atomic_inc(int *addr) {
	int oldval;
	char success; 

	do {
		oldval = *addr;
		__asm__ __volatile__("lock; cmpxchgl %2, %0; setz %1" 
					:"=m"(*addr), "=q"(success) 
					:"r"(oldval+1), "m"(*addr), "a"(oldval)
					:"memory");
	} while (!success); 

	return (oldval+1);
}
#endif

*/


