typedef void * tm_hashkey_t;
typedef void * tm_dword;
typedef double tm_word64;
typedef int tm_word32;

typedef union {
		tm_word64 w64;
		tm_word32 w32;
		tm_dword dw;
		char b;
} tm_generic_value;

typedef union {
		tm_word64 *w64;
		tm_word32 *w32;
		tm_dword *dw;
		char *b;
} tm_generic_pointer;
typedef struct tm_value tm_value_t;
struct tm_value {
	void *addr;
	tm_generic_value value;
	int size;
	//char validate;
	tm_value_t *next;	
};
typedef struct tm_gcobj tm_gcobj_t;
struct tm_gcobj {
	void *addr;
	tm_gcobj_t *next;

};
typedef struct tm_valset {
	tm_value_t *val;
	tm_value_t **hasht;
	int count;
	tm_gcobj_t *gclist;
} tm_valset_t;

typedef struct tm_tx {
	tm_valset_t *rset;
	tm_valset_t *wset;
} tm_tx_t;




char tm_load_char(tm_tx_t *tx, char *addr);
tm_word32 tm_load32(tm_tx_t *tx,  tm_word32 *addr);

double tm_load_double(tm_tx_t *tx, void *addr);

tm_dword tm_load_dword(tm_tx_t *tx, void *addr);


void tm_store32(tm_tx_t *tx, tm_word32 *addr, tm_word32 word);

tm_word64 tm_load64(tm_tx_t *tx, tm_word64 *addr);

void tm_store_dword(tm_tx_t *tx, tm_dword dword);
void tm_store64(tm_tx_t *tx, tm_word64 *addr, tm_word64 value);

tm_tx_t *tm_create_tx();

int tm_validate(tm_tx_t *tx);
int tm_commit(tm_tx_t *tx);
void tm_cleanup_tx(tm_tx_t *tx);
tm_value_t *hash_find(tm_hashkey_t key, tm_value_t **table);
