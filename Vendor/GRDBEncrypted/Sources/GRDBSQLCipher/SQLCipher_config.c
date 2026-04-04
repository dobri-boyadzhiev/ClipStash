#include "SQLCipher_config.h"

int grdb_sqlcipher_key(sqlite3 *db, const void *pKey, int nKey) {
    return sqlite3_key(db, pKey, nKey);
}

int grdb_sqlcipher_rekey(sqlite3 *db, const void *pKey, int nKey) {
    return sqlite3_rekey(db, pKey, nKey);
}
