#ifndef grdb_config_h
#define grdb_config_h

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sqlite3 sqlite3;
typedef void(*_errorLogCallback)(void *pArg, int iErrCode, const char *zMsg);

#define SQLITE_CONFIG_LOG 16
#define SQLITE_DBCONFIG_DQS_DML 1013
#define SQLITE_DBCONFIG_DQS_DDL 1014

int sqlite3_key(sqlite3 *db, const void *pKey, int nKey);
int sqlite3_rekey(sqlite3 *db, const void *pKey, int nKey);
int sqlite3_config(int, ...);
int sqlite3_db_config(sqlite3 *db, int op, ...);

int grdb_sqlcipher_key(sqlite3 *db, const void *pKey, int nKey);
int grdb_sqlcipher_rekey(sqlite3 *db, const void *pKey, int nKey);

/// Wrapper around sqlite3_config(SQLITE_CONFIG_LOG, ...) which is a variadic
/// function that can't be used from Swift.
static inline void _registerErrorLogCallback(_errorLogCallback callback) {
    sqlite3_config(SQLITE_CONFIG_LOG, callback, 0);
}

/// Wrapper around sqlite3_db_config() which is a variadic function that can't
/// be used from Swift.
static inline void _disableDoubleQuotedStringLiterals(sqlite3 *db) {
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DDL, 0, (void *)0);
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DML, 0, (void *)0);
}

/// Wrapper around sqlite3_db_config() which is a variadic function that can't
/// be used from Swift.
static inline void _enableDoubleQuotedStringLiterals(sqlite3 *db) {
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DDL, 1, (void *)0);
    sqlite3_db_config(db, SQLITE_DBCONFIG_DQS_DML, 1, (void *)0);
}

#ifdef __cplusplus
}
#endif

#endif /* grdb_config_h */
