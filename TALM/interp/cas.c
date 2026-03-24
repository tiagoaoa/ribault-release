/*
 * TALM/Trebuchet — Architecture and Language for Multi-threading
 *
 * Copyright (C) 2010-2026  Tiago A.O. Alves <tiago@ime.uerj.br>
 *                           Leandro Marzulo <lmarzulo@cos.ufrj.br>
 *
 * This file is part of TALM.
 *
 * TALM is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of
 * the License, or (at your option) any later version.
 *
 * TALM is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with TALM. If not, see <https://www.gnu.org/licenses/>.
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




