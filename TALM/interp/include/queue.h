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



