#import "Include/THProfileAnalyzerStorage.h"
#import "Include/THProfileAnalyzerTypes.h"
#import <sqlite3.h>
#import <string.h>

static NSString * const kTHProfileAnalyzerDBFile = @"Stats.sqlite";
static const char *kTHProfileAnalyzerTableScans = "scans";
static const char *kTHProfileAnalyzerColAPIFollowers = "api_followers_count";
static const char *kTHProfileAnalyzerColAPIFollowing = "api_following_count";

static void addAPICountColumnsIfNeeded(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA table_info(scans);", -1, &stmt, NULL) != SQLITE_OK) return;
    int hasFollowers = 0, hasFollowing = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *name = (const char *)sqlite3_column_text(stmt, 1);
        if (name && strcmp(name, kTHProfileAnalyzerColAPIFollowers) == 0) hasFollowers = 1;
        if (name && strcmp(name, kTHProfileAnalyzerColAPIFollowing) == 0) hasFollowing = 1;
    }
    sqlite3_finalize(stmt);
    if (!hasFollowers) {
        char *err = NULL;
        sqlite3_exec(db, "ALTER TABLE scans ADD COLUMN api_followers_count INTEGER DEFAULT -1;", NULL, NULL, &err);
        if (err) sqlite3_free(err);
    }
    if (!hasFollowing) {
        char *err = NULL;
        sqlite3_exec(db, "ALTER TABLE scans ADD COLUMN api_following_count INTEGER DEFAULT -1;", NULL, NULL, &err);
        if (err) sqlite3_free(err);
    }
}

@implementation THProfileAnalyzerStorage

+ (NSString *)profileAnalyzerDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"ProfileAnalyzer"];
}

+ (NSString *)profileAnalyzerSQLPathForUserPK:(NSString *)userPK {
    return [[[self profileAnalyzerDirectory] stringByAppendingPathComponent:userPK] stringByAppendingPathComponent:kTHProfileAnalyzerDBFile];
}

- (BOOL)createUserDirectoryIfNeeded:(NSString *)userPK error:(NSError **)outError {
    NSString *userDir = [[THProfileAnalyzerStorage profileAnalyzerDirectory] stringByAppendingPathComponent:userPK];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:userDir]) return YES;
    NSError *err = nil;
    if (![fm createDirectoryAtPath:userDir withIntermediateDirectories:YES attributes:nil error:&err]) {
        if (outError) *outError = err;
        return NO;
    }
    return YES;
}

- (BOOL)saveSnapshot:(THProfileAnalyzerSnapshot *)snapshot error:(NSError **)outError {
    if (![self createUserDirectoryIfNeeded:snapshot.userPK error:outError]) return NO;
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:snapshot.userPK];
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return NO;
    }
    char *errMsg = NULL;
    NSString *createSQL = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %s (id INTEGER PRIMARY KEY AUTOINCREMENT, user_pk TEXT NOT NULL, scanned_at REAL NOT NULL, followers_json TEXT NOT NULL, following_json TEXT NOT NULL, api_followers_count INTEGER DEFAULT -1, api_following_count INTEGER DEFAULT -1);", kTHProfileAnalyzerTableScans];
    if (sqlite3_exec(db, createSQL.UTF8String, NULL, NULL, &errMsg) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:2 userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithUTF8String:errMsg ?: "create failed"] }];
        sqlite3_free(errMsg);
        sqlite3_close(db);
        return NO;
    }
    addAPICountColumnsIfNeeded(db);
    NSInteger apiF = snapshot.apiFollowersCount >= 0 ? snapshot.apiFollowersCount : -1;
    NSInteger apiG = snapshot.apiFollowingCount >= 0 ? snapshot.apiFollowingCount : -1;
    NSMutableArray *fArr = [NSMutableArray array];
    for (THProfileAnalyzerUser *u in snapshot.followers) [fArr addObject:[u toDictionary]];
    NSMutableArray *gArr = [NSMutableArray array];
    for (THProfileAnalyzerUser *u in snapshot.following) [gArr addObject:[u toDictionary]];
    NSData *fData = [NSJSONSerialization dataWithJSONObject:fArr options:0 error:NULL];
    NSData *gData = [NSJSONSerialization dataWithJSONObject:gArr options:0 error:NULL];
    NSString *fJson = fData ? [[NSString alloc] initWithData:fData encoding:NSUTF8StringEncoding] : @"[]";
    NSString *gJson = gData ? [[NSString alloc] initWithData:gData encoding:NSUTF8StringEncoding] : @"[]";
    double scannedAt = snapshot.scannedAt.timeIntervalSince1970;
    sqlite3_stmt *stmt = NULL;
    NSString *insertSQL = [NSString stringWithFormat:@"INSERT INTO %s (user_pk, scanned_at, followers_json, following_json, api_followers_count, api_following_count) VALUES (?, ?, ?, ?, ?, ?);", kTHProfileAnalyzerTableScans];
    if (sqlite3_prepare_v2(db, insertSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:3 userInfo:@{ NSLocalizedDescriptionKey: @"Prepare insert failed" }];
        sqlite3_close(db);
        return NO;
    }
    sqlite3_bind_text(stmt, 1, snapshot.userPK.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_double(stmt, 2, scannedAt);
    sqlite3_bind_text(stmt, 3, fJson.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, gJson.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 5, (int)apiF);
    sqlite3_bind_int(stmt, 6, (int)apiG);
    BOOL ok = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    if (!ok && outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:4 userInfo:@{ NSLocalizedDescriptionKey: @"Insert failed" }];
    return ok;
}

- (THProfileAnalyzerSnapshot *)loadMostRecentSnapshotForUserPK:(NSString *)userPK error:(NSError **)outError {
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:userPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:5 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return nil;
    }
    addAPICountColumnsIfNeeded(db);
    NSString *selectSQL = [NSString stringWithFormat:@"SELECT scanned_at, followers_json, following_json, api_followers_count, api_following_count FROM %s WHERE user_pk = ? ORDER BY id DESC LIMIT 1;", kTHProfileAnalyzerTableScans];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, selectSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
    sqlite3_bind_text(stmt, 1, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    THProfileAnalyzerSnapshot *snapshot = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        double t = sqlite3_column_double(stmt, 0);
        const char *f = (const char *)sqlite3_column_text(stmt, 1);
        const char *g = (const char *)sqlite3_column_text(stmt, 2);
        int apiF = (sqlite3_column_count(stmt) > 3) ? sqlite3_column_int(stmt, 3) : -1;
        int apiG = (sqlite3_column_count(stmt) > 4) ? sqlite3_column_int(stmt, 4) : -1;
        NSString *fStr = f ? [NSString stringWithUTF8String:f] : @"[]";
        NSString *gStr = g ? [NSString stringWithUTF8String:g] : @"[]";
        NSArray *fArr = [NSJSONSerialization JSONObjectWithData:[fStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSArray *gArr = [NSJSONSerialization JSONObjectWithData:[gStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![fArr isKindOfClass:[NSArray class]]) fArr = @[];
        if (![gArr isKindOfClass:[NSArray class]]) gArr = @[];
        NSMutableArray<THProfileAnalyzerUser *> *followers = [NSMutableArray array];
        NSMutableArray<THProfileAnalyzerUser *> *following = [NSMutableArray array];
        for (id d in fArr) if ([d isKindOfClass:[NSDictionary class]]) [followers addObject:[[THProfileAnalyzerUser alloc] initWithDictionary:d]];
        for (id d in gArr) if ([d isKindOfClass:[NSDictionary class]]) [following addObject:[[THProfileAnalyzerUser alloc] initWithDictionary:d]];
        snapshot = [[THProfileAnalyzerSnapshot alloc] initWithUserPK:userPK scannedAt:[NSDate dateWithTimeIntervalSince1970:t] followers:followers following:following];
        snapshot.apiFollowersCount = (NSInteger)apiF;
        snapshot.apiFollowingCount = (NSInteger)apiG;
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return snapshot;
}

- (THProfileAnalyzerSnapshot *)loadSnapshotAtIndex:(NSInteger)index forUserPK:(NSString *)userPK error:(NSError **)outError {
    if (index < 0) return nil;
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:userPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:5 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return nil;
    }
    addAPICountColumnsIfNeeded(db);
    NSString *selectSQL = [NSString stringWithFormat:@"SELECT scanned_at, followers_json, following_json, api_followers_count, api_following_count FROM %s WHERE user_pk = ? ORDER BY id DESC LIMIT 1 OFFSET %ld;", kTHProfileAnalyzerTableScans, (long)index];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, selectSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
    sqlite3_bind_text(stmt, 1, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    THProfileAnalyzerSnapshot *snapshot = nil;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        double t = sqlite3_column_double(stmt, 0);
        const char *f = (const char *)sqlite3_column_text(stmt, 1);
        const char *g = (const char *)sqlite3_column_text(stmt, 2);
        int apiF = (sqlite3_column_count(stmt) > 3) ? sqlite3_column_int(stmt, 3) : -1;
        int apiG = (sqlite3_column_count(stmt) > 4) ? sqlite3_column_int(stmt, 4) : -1;
        NSString *fStr = f ? [NSString stringWithUTF8String:f] : @"[]";
        NSString *gStr = g ? [NSString stringWithUTF8String:g] : @"[]";
        NSArray *fArr = [NSJSONSerialization JSONObjectWithData:[fStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSArray *gArr = [NSJSONSerialization JSONObjectWithData:[gStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![fArr isKindOfClass:[NSArray class]]) fArr = @[];
        if (![gArr isKindOfClass:[NSArray class]]) gArr = @[];
        NSMutableArray<THProfileAnalyzerUser *> *followers = [NSMutableArray array];
        NSMutableArray<THProfileAnalyzerUser *> *following = [NSMutableArray array];
        for (id d in fArr) if ([d isKindOfClass:[NSDictionary class]]) [followers addObject:[[THProfileAnalyzerUser alloc] initWithDictionary:d]];
        for (id d in gArr) if ([d isKindOfClass:[NSDictionary class]]) [following addObject:[[THProfileAnalyzerUser alloc] initWithDictionary:d]];
        snapshot = [[THProfileAnalyzerSnapshot alloc] initWithUserPK:userPK scannedAt:[NSDate dateWithTimeIntervalSince1970:t] followers:followers following:following];
        snapshot.apiFollowersCount = (NSInteger)apiF;
        snapshot.apiFollowingCount = (NSInteger)apiG;
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return snapshot;
}

- (NSInteger)snapshotCountForUserPK:(NSString *)userPK error:(NSError **)outError {
    if (!userPK.length) return 0;
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:userPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return 0;
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:5 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return 0;
    }
    addAPICountColumnsIfNeeded(db);
    NSString *cntSQL = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %s WHERE user_pk = ?;", kTHProfileAnalyzerTableScans];
    sqlite3_stmt *stmt = NULL;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(db, cntSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return 0;
    }
    sqlite3_bind_text(stmt, 1, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return count;
}

- (BOOL)deleteSnapshotAtNewestFirstIndex:(NSInteger)newestFirstIndex forUserPK:(NSString *)userPK error:(NSError **)outError {
    if (!userPK.length || newestFirstIndex < 0) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:10 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid delete parameters." }];
        return NO;
    }
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:userPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:11 userInfo:@{ NSLocalizedDescriptionKey: @"No scan database." }];
        return NO;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:5 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return NO;
    }
    addAPICountColumnsIfNeeded(db);
    NSString *pickSQL = [NSString stringWithFormat:@"SELECT id FROM %s WHERE user_pk = ? ORDER BY id DESC LIMIT 1 OFFSET %ld;", kTHProfileAnalyzerTableScans, (long)newestFirstIndex];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, pickSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:12 userInfo:@{ NSLocalizedDescriptionKey: @"Could not prepare delete." }];
        return NO;
    }
    sqlite3_bind_text(stmt, 1, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_int64 rowId = 0;
    BOOL found = NO;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        rowId = sqlite3_column_int64(stmt, 0);
        found = YES;
    }
    sqlite3_finalize(stmt);
    if (!found) {
        sqlite3_close(db);
        return NO;
    }
    sqlite3_stmt *delStmt = NULL;
    NSString *delSQL = [NSString stringWithFormat:@"DELETE FROM %s WHERE id = ?;", kTHProfileAnalyzerTableScans];
    if (sqlite3_prepare_v2(db, delSQL.UTF8String, -1, &delStmt, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:13 userInfo:@{ NSLocalizedDescriptionKey: @"Could not prepare delete statement." }];
        return NO;
    }
    sqlite3_bind_int64(delStmt, 1, rowId);
    BOOL ok = (sqlite3_step(delStmt) == SQLITE_DONE);
    sqlite3_finalize(delStmt);
    sqlite3_close(db);
    if (!ok && outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:14 userInfo:@{ NSLocalizedDescriptionKey: @"Delete failed." }];
    return ok;
}

- (BOOL)deleteAllSnapshotsForUserPK:(NSString *)userPK error:(NSError **)outError {
    if (!userPK.length) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:10 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid user." }];
        return NO;
    }
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:userPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:5 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return NO;
    }
    addAPICountColumnsIfNeeded(db);
    NSString *delSQL = [NSString stringWithFormat:@"DELETE FROM %s WHERE user_pk = ?;", kTHProfileAnalyzerTableScans];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, delSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:13 userInfo:@{ NSLocalizedDescriptionKey: @"Could not prepare delete all." }];
        return NO;
    }
    sqlite3_bind_text(stmt, 1, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    BOOL ok = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    if (!ok && outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:14 userInfo:@{ NSLocalizedDescriptionKey: @"Delete all failed." }];
    return ok;
}

- (BOOL)updateAPICountsForMostRecentScanWithUserPK:(NSString *)userPK followers:(NSInteger)followers following:(NSInteger)following error:(NSError **)outError {
    if (!userPK.length) return NO;
    NSString *path = [THProfileAnalyzerStorage profileAnalyzerSQLPathForUserPK:userPK];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    sqlite3 *db = NULL;
    if (sqlite3_open(path.UTF8String, &db) != SQLITE_OK) {
        if (outError) *outError = [NSError errorWithDomain:@"THProfileAnalyzer" code:5 userInfo:@{ NSLocalizedDescriptionKey: @"Could not open database" }];
        return NO;
    }
    addAPICountColumnsIfNeeded(db);
    NSString *updateSQL = [NSString stringWithFormat:@"UPDATE %s SET api_followers_count = ?, api_following_count = ? WHERE user_pk = ? AND id = (SELECT MAX(id) FROM %s WHERE user_pk = ?);", kTHProfileAnalyzerTableScans, kTHProfileAnalyzerTableScans];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, updateSQL.UTF8String, -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return NO;
    }
    sqlite3_bind_int(stmt, 1, (int)followers);
    sqlite3_bind_int(stmt, 2, (int)following);
    sqlite3_bind_text(stmt, 3, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, userPK.UTF8String, -1, SQLITE_TRANSIENT);
    BOOL ok = (sqlite3_step(stmt) == SQLITE_DONE);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return ok;
}

@end
