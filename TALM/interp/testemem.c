#include <stdio.h>

#include <stdlib.h>

#include "dfmem.h"


int main(void) {
	int m[20], i;

	for (i=0; i<20; i++)
		m[i] = i;
	tm_tx_t *tx0, *tx1;

	
	
	tx0 = tm_create_tx();
	tx1 = tm_create_tx();

	printf("%d\n", tm_load32(tx0, m+4));
	tm_store32(tx0, m+5, 66);
	printf("tx0 %d\n", tm_load32(tx0, m+5));
	tm_load32(tx1, m+10);
	
	printf("tx1 %d\n", tm_load32(tx1, m+10));

	printf("tx1 %d\n", tm_load32(tx1, m+5));
	tm_commit(tx0);
	if (tm_commit(tx1))
		printf("Tx1 commitou\n");
	else
		printf("Tx1 deu pra tras\n");


	tx1 = tm_create_tx();

	tm_load32(tx1, m+10);
	
	printf("tx1 %d\n", tm_load32(tx1, m+10));

	printf("tx1 %d\n", tm_load32(tx1, m+5));
	if (tm_commit(tx1))
		printf("Tx1 commitou\n");
	else
		printf("Tx1 deu pra tras\n");

	printf("Fim: %d\n", m[5]);

	return(0);



}
