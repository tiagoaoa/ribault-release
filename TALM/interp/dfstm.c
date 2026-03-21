/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *     dfstm.c
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


#include <stdio.h>
#include <stdlib.h>
#include <string.h> 
#include "dfstm.h"

stm_tx_t *create_tx() {
	stm_tx_t *tx;//, *copytx = stm_current_tx();

	//tx =  (stm_tx_t *)malloc(sizeof(*copytx)); 
	tx = stm_init_thread();	
	
	//memcpy(tx, copytx, sizeof(*copytx));
	return(tx);
}
