#TINYSTM_DIR=../tinySTM-0.9.9
ROOT_DIR=.
INCLUDE_DIR=${ROOT_DIR}/include
#LIBS=-L${TINYSTM_DIR}/lib
#LIBFLAGS=-lstm
INCLUDES=-I./include 
FLAGS=-O3 -rdynamic ${INCLUDES} ${LIBS} -g
# -DUSE_STM

DEBUG=
#DEBUG+=-DDEBUG_LOADER
DEBUG+=-DDEBUG_EXECUTION
#DEBUG+=-DDEBUG_TERMINATION
DEBUG+=-DDEBUG_OP_SEND
#DEBUG+=-DDEBUG_COMMUNICATION
#DEBUG+=-DDEBUG_STM
#DEBUG+=-DDEBUG_STM2
DEBUG+=-DDEBUG_GC
#DEBUG+=-DDEBUG_MEMORY
#DEBUG+=-DSTAT_STM

FLAGS+=${DEBUG}
FLAGS+=-DSET_AFFINITY
FLAGS+=-DINITIAL_QUEUE_SIZE=2000

all: interp
clean:
	rm *.o interp
interp: interp.o queue.o cas.o loader.o dfmem.o treb_functions.o
	gcc ${FLAGS} interp.o queue.o cas.o loader.o dfmem.o treb_functions.o -o interp -lpthread -Wall -ldl -lm -lrt
interp.o: interp.c ${INCLUDE_DIR}/interp.h
	gcc ${FLAGS} -c interp.c -o interp.o -Wall 
queue.o: queue.c cas.o ${INCLUDE_DIR}/queue.h
	gcc ${FLAGS} -c queue.c -o queue.o -Wall
loader.o: loader.c ${INCLUDE_DIR}/interp.h
	gcc ${FLAGS} -c loader.c -o loader.o -Wall
treb_functions.o: treb_functions.c ${INCLUDE_DIR}/treb_functions.h
	gcc ${FLAGS} -c treb_functions.c -o treb_functions.o -Wall
#dfstm.o: dfstm.c ${INCLUDE_DIR}/dfstm.h
#	gcc ${FLAGS} -c dfstm.c -o dfstm.o -Wall
#
cas.o:	 cas.c ${INCLUDE_DIR}/cas.h
	 gcc ${FLAGS} -c cas.c -o cas.o -Wall
dfmem.o: dfmem.c ${INCLUDE_DIR}/dfmem.h
	gcc ${FLAGS} -c dfmem.c -o dfmem.o -Wall

testemem: testemem.c dfmem.o ${INCLUDE_DIR}/dfmem.h
	gcc -I${INCLUDE_DIR} testemem.c -o testemem dfmem.o -Wall
