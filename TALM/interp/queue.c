/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *     queue.c
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
#include "queue.h"


void expand_queue(queue_t *q);

void enqueue(qelem x, queue_t *q) {
	
	if (q->count == q->allocsize) {
		printf("Queue is full. Reallocating\n");
		//q->elem = realloc(q->elem, (q->allocsize + REALLOC_INCREMENT)*sizeof(qelem)); 
		expand_queue(q);
	}


	
	q->last = (q->last + 1) % q->allocsize;
	q->elem[q->last] = x;
	(q->count)++; 


}
void init_queue(queue_t *q) {
	q->first = 0;
	q->last = -1;
	q->count = 0;
	q->elem = (qelem *)malloc(sizeof(qelem) * INITIAL_QUEUE_SIZE);
	q->allocsize = INITIAL_QUEUE_SIZE;
}

void init_deque(deque_t *d) {
	d->first = 0;
	d->last.st.index = -1;
	d->last.st.tag = 0;
	d->elem = (qelem *)malloc(sizeof(qelem) * INITIAL_QUEUE_SIZE);
	d->allocsize = INITIAL_QUEUE_SIZE;

}


//int has_elements(queue_t *q) {
//	return (q->count > 0);
	
//}


qelem get_first(queue_t *q) {
	qelem first;
	if (q->count > 0) {
		(q->count)--;
		first = q->elem[q->first];
		q->first = (q->first + 1) % q->allocsize;

		
	} else
		first = NULL;	
	
	return(first);

}
void expand_queue(queue_t *q) {
	int i, count_old = q->count;
	qelem *elem_old = q->elem;
	qelem *elem_new = (qelem *)malloc(sizeof(qelem) * (REALLOC_INCREMENT + q->allocsize));
	
	if (elem_new == NULL) {
		printf("Error expanding queue memory\n");
		exit(0);
	}
	//printf("Tamanho %d ", q->count);
	for (i=0; i<count_old; i++) {
		elem_new[i] = get_first(q);
	//	printf("%d, ", (int)elem_new[i]);
	}
	printf("\n");
	q->first = 0;
	q->last = count_old-1;
	q->count = count_old;
	q->allocsize += REALLOC_INCREMENT;

	free(elem_old);

	q->elem = elem_new;
	

}



void push_last(qelem x, deque_t *d) {
	int pos, count, output;
	deque_anchor_t last = d->last, last_new; 
	/* Notice that deque_anchor_t is a union where deque.st is its interpretation as a struct anchor_struct
	 * and deque.w is its interpretion as a casword_t, to be used with CAS() */ 
	
	count = last.st.index - d->first;


	if (count == d->allocsize) {
		printf("Deque is full. Reallocating\n");
		//q->elem = realloc(q->elem, (q->allocsize + REALLOC_INCREMENT)*sizeof(qelem)); 
		//expand_queue(q);
		exit(1);
	}
	


	pos = last_new.st.index = (last.st.index+1) % d->allocsize;
	last_new.st.tag = last.st.tag + 1;

	d->elem[pos] = x;
	
	output = CAS(&(d->last), last.w, last_new.w);
	
}


qelem pop_first(deque_t *d) {
	int count, first;
	deque_anchor_t last, newlast;

	qelem *output = NULL;
	
	first = d->first;
	d->first++;
	
	last = d->last;

	count = last.st.index - first;
 
	if (count < 0) {
		output = DEQUE_RETURN_EMPTY;
	
	} else {

		if (count > 0) {
			output = d->elem[first];
		
		
		} else {
			newlast.st.index = last.st.index;
			newlast.st.tag = last.st.tag+1;
			if (CAS(&(d->last), last.w, newlast.w))
				
				output = d->elem[first];
			else
				output = DEQUE_RETURN_ABORT;



			//d->first = d->last + 1;
		
		
		}
	
	

	}

	return(output);

}



qelem pop_last(deque_t *d) {
	int first, count;
	deque_anchor_t last, newlast;
	qelem *output;

	first = d->first;

	last = d->last;

	count = last.st.index - first;

	if (count < 0)
		output = DEQUE_RETURN_EMPTY;
	else {
		newlast.st.index = last.st.index - 1;
		newlast.st.tag = last.st.tag;
			
		if (CAS(&(d->last), last.w, newlast.w))
			output = d->elem[last.st.index];
		else
			output = DEQUE_RETURN_ABORT;	
	
	
	
	}

	return(output);
	

}






/*
void print_queue(queue_t q) {
	int k = q.first;

	printf("first: %d last: %d\n", q.first, q.last);	
	printf("k: %d ", q.elem[k]);	
	while (k != q.last) {
		//printf("first: %d\n", k);
		
		k = (k + 1) % MAX_ELEMENTS;
			
		printf("k: %d ", q.elem[k]);fflush(stdout);

	} 

	printf("\n");
}
*/
/*
int main(void) {
	queue_t q;


	init_queue(&q);

	enqueue(&q, 2);
	printf("aaa\n");
	print_queue(q);
	
	printf("Uia\n");
	enqueue(&q, 3);
	print_queue(q);

	enqueue(&q,4);
	
	enqueue(&q,6);
	enqueue(&q,7);
	enqueue(&q,10);

	print_queue(q);


	return(0);

}

 */
