
#define OP_CONST 0
#define OP_FCONST 0 //FCONST and CONST have can have the same opcode, because they're of the same size
#define OP_DCONST 1
#define OP_ADDI 2
#define OP_SUBI 3
#define OP_FMULI 4
#define OP_MULI 5
#define OP_DIVI 6
#define OP_ITAGI 7
#define OP_LTHANI 8
#define OP_GTHANI 9
#define OP_CALLSND 10
#define OP_RETSND 11
#define OP_ITAG 12
#define LAST_WITH_IMMED OP_RETSND
#define LAST_WITH_ONE_OPER OP_ITAG
#define OP_ADD 13
#define OP_SUB 14
#define OP_MUL 15 
#define OP_DIV 16
#define OP_FADD 17
#define OP_DADD 18
#define OP_AND 19

#define OP_STEER 20
#define OP_LTHAN 21
#define OP_GTHAN 22
#define OP_EQUAL 23

#define OP_RET 24

#define OP_COPYHTODEV 25
#define OP_COPYDEVTOH 26

#define OP_COMMIT 27
#define OP_STOPSPC 28 
#define OP_TAGTOVAL 29
#define OP_VALTOTAG 30
#define OP_SUPER1 31
