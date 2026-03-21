/*
 * Trebuchet - A multithreaded implementation of TALM.
 *
 *
 * File:
 *     queue.h
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


//#define MAX_ELEMENTS 200

#ifndef INITIAL_QUEUE_SIZE
#define INITIAL_QUEUE_SIZE 500
#endif

#ifndef REALLOC_INCREMENT
#define REALLOC_INCREMENT 500
#endif
#define HAS_ELEMENTS(q) (q->count > 0)

#define DEQUE_RETURN_EMPTY (qelem) 0
#define DEQUE_RETURN_ABORT (qelem) 1

#include "cas.h"



typedef void * qelem;
//typedef int qelem;
typedef struct {
	int first;
	int last;

	int count;
	int allocsize;	
//	qelem elem[MAX_ELEMENTS];	
	qelem *elem;
} queue_t;



struct anchor_struct {
	cashalfword_t index;
	cashalfword_t tag;


};


typedef union {
	struct anchor_struct st;
	casword_t w;

} deque_anchor_t;


typedef struct {
	int first;
	deque_anchor_t last;

	int allocsize;
	qelem *elem;
} deque_t; 


void enqueue(qelem x, queue_t *q);

void init_queue(queue_t *q);

void init_deque(deque_t *d);

qelem get_first(queue_t *q);

void print_queue(queue_t q);



