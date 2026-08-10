/**
 * Shared preference helpers and cross-module exports.
 */
#ifndef ThetaTweakCommon_h
#define ThetaTweakCommon_h

#import <Foundation/Foundation.h>

#define ENABLED(setting) [[NSUserDefaults standardUserDefaults] boolForKey:[NSString stringWithFormat:@"%@_Enabled", setting]]

/** Implemented in HideFeedFiltering.m; chained from HideAds home feed adapter. */
NSArray *ThetaApplyHideFeedFiltering(NSArray *list, BOOL isMainFeed);

#endif
