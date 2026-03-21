#include <limits.h>

typedef void * casword_t;

#if ( __WORDSIZE == 64 )

typedef int cashalfword_t;

#else

typedef short int cashalfword_t;
#endif


int CAS(void *addr, casword_t oldval, casword_t newval);

