#ifndef THETA_ROOTLESS_H
#define THETA_ROOTLESS_H

#import <Foundation/Foundation.h>

/*
 * Minimal stand-in for Theos rootless path helpers.
 * On rootless jailbreaks, paths are under /var/jb; otherwise use the literal path.
 */
#ifdef ROOTLESS
static inline NSString *ROOT_PATH_NS(NSString *path) {
    if (!path.length) return path;
    if ([path hasPrefix:@"/var/jb"]) return path;
    if ([path hasPrefix:@"/"]) {
        return [@"/var/jb" stringByAppendingString:path];
    }
    return path;
}
#else
static inline NSString *ROOT_PATH_NS(NSString *path) {
    return path;
}
#endif

#endif
