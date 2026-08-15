static void loadKeychainAccessGroup() {
	@try {
		NSDictionary* dummyItem = @{
			(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
			(__bridge id)kSecAttrAccount : @"dummyItem",
			(__bridge id)kSecAttrService : @"dummyService",
			(__bridge id)kSecReturnAttributes : @YES,
		};

		CFTypeRef result = NULL;
		OSStatus ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
		if (ret == errSecItemNotFound) {
			ret = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);
		}
		if ((ret == errSecSuccess && !result) || ret == errSecDuplicateItem) {
			if (result) { CFRelease(result); result = NULL; }
			ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
		}

		if (ret == 0 && result) {
			NSDictionary* resultDict = (__bridge id)result;
			keychainAccessGroup = resultDict[(__bridge id)kSecAttrAccessGroup];
			CFRelease(result);
			fprintf(stderr, "[Theta] sideload keychain access group: %s\n",
			        keychainAccessGroup.UTF8String ?: "(null)");
			fflush(stderr);
		} else {
			fprintf(stderr, "[Theta] Failed to get keychain access group: %d\n", (int)ret);
			fflush(stderr);
		}
	} @catch (NSException *exception) {
		NSLog(@"Error loading keychain access group: %@", exception);
	}
}

static NSURL *(*orig_NSFileManager)(id self, SEL _cmd, NSString *groupIdentifier);
static BOOL (*orig_createDirectoryAtPath)(id self, SEL _cmd, NSString *path, BOOL createIntermediates, NSDictionary *attributes, NSError **error);

/** Create dirs via orig IMP only — never NSFileManager APIs that re-enter our hooks. */
static void SideloadEnsureDirectoryPath(id fileManager, NSString *path) {
	if (!path.length || !orig_createDirectoryAtPath || !fileManager) return;
	BOOL isDir = NO;
	if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir) return;
	orig_createDirectoryAtPath(fileManager, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:),
	                           path, YES, nil, NULL);
}

static NSURL *hook_NSFileManager(id self, SEL _cmd, NSString *groupIdentifier) {
	@try {
		if (!groupIdentifier || !fakeGroupContainerURL) {
			return orig_NSFileManager ? orig_NSFileManager(self, _cmd, groupIdentifier) : nil;
		}

		NSURL *fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupIdentifier];
		if (!fakeURL) {
			return orig_NSFileManager ? orig_NSFileManager(self, _cmd, groupIdentifier) : nil;
		}

		SideloadEnsureDirectoryPath(self, fakeURL.path);
		SideloadEnsureDirectoryPath(self, [fakeURL URLByAppendingPathComponent:@"Library"].path);
		SideloadEnsureDirectoryPath(self, [fakeURL URLByAppendingPathComponent:@"Library/Caches"].path);

		return fakeURL;
	} @catch (NSException *exception) {
		NSLog(@"Error in NSFileManager hook: %@", exception);
		return orig_NSFileManager ? orig_NSFileManager(self, _cmd, groupIdentifier) : nil;
	}
}

// Prevent EXC_BREAKPOINT in StorageKit when createMobileConfigDirectoryIfNeeded runs on
// sideload. Must NOT call ThetaHelper/createDirectoryAtURL — that re-enters this hook
// (createDirectoryAtURL → createDirectoryAtPath) and stack-overflows.
static BOOL hook_createDirectoryAtPath(id self, SEL _cmd, NSString *path, BOOL createIntermediates, NSDictionary *attributes, NSError **error) {
	if (!orig_createDirectoryAtPath) {
		if (error) *error = nil;
		return NO;
	}
	BOOL ok = orig_createDirectoryAtPath(self, _cmd, path, createIntermediates, attributes, error);
	if (ok) return YES;
	if (path && ([path rangeOfString:@"MobileConfig" options:NSCaseInsensitiveSearch].location != NSNotFound ||
	             [path rangeOfString:@"FBMobileConfig" options:NSCaseInsensitiveSearch].location != NSNotFound ||
	             [path rangeOfString:@"mobileconfig" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
		// Fake success so IG doesn't assert/crash when the group path is unusable.
		if (error) *error = nil;
		return YES;
	}
	return NO;
}

// Per-class original pointers to avoid clobbering
NSString *(*orig_accessGroup_FBSDKKeychainStore)(id self, SEL _cmd);
NSString *(*orig_accessGroup_FBKeychainItemController)(id self, SEL _cmd);
NSString *(*orig_accessGroup_UICKeyChainStore)(id self, SEL _cmd);

// Per-class hooks (safer for differing IMP signatures)
NSString *hook_accessGroup_FBSDKKeychainStore(id self, SEL _cmd) {
	@try {
		if (keychainAccessGroup) return keychainAccessGroup;
		return orig_accessGroup_FBSDKKeychainStore ? orig_accessGroup_FBSDKKeychainStore(self, _cmd) : nil;
	} @catch (NSException *exception) {
		NSLog(@"Error in accessGroup hook (FBSDKKeychainStore): %@", exception);
		return orig_accessGroup_FBSDKKeychainStore ? orig_accessGroup_FBSDKKeychainStore(self, _cmd) : nil;
	}
}

NSString *hook_accessGroup_FBKeychainItemController(id self, SEL _cmd) {
	@try {
		if (keychainAccessGroup) return keychainAccessGroup;
		return orig_accessGroup_FBKeychainItemController ? orig_accessGroup_FBKeychainItemController(self, _cmd) : nil;
	} @catch (NSException *exception) {
		NSLog(@"Error in accessGroup hook (FBKeychainItemController): %@", exception);
		return orig_accessGroup_FBKeychainItemController ? orig_accessGroup_FBKeychainItemController(self, _cmd) : nil;
	}
}

NSString *hook_accessGroup_UICKeyChainStore(id self, SEL _cmd) {
	@try {
		if (keychainAccessGroup) return keychainAccessGroup;
		return orig_accessGroup_UICKeyChainStore ? orig_accessGroup_UICKeyChainStore(self, _cmd) : nil;
	} @catch (NSException *exception) {
		NSLog(@"Error in accessGroup hook (UICKeyChainStore): %@", exception);
		return orig_accessGroup_UICKeyChainStore ? orig_accessGroup_UICKeyChainStore(self, _cmd) : nil;
	}
}

static NSString *SideloadRemapAccessGroup(NSString *group) {
	return keychainAccessGroup.length ? keychainAccessGroup : group;
}

id (*orig_LS_initWithServiceIDAccessGroupUserIDSync)(id self, SEL _cmd, id serviceID, id accessGroup, id userID, BOOL sync);
id hook_LS_initWithServiceIDAccessGroupUserIDSync(id self, SEL _cmd, id serviceID, id accessGroup, id userID, BOOL sync) {
	if (!orig_LS_initWithServiceIDAccessGroupUserIDSync) return nil;
	return orig_LS_initWithServiceIDAccessGroupUserIDSync(self, _cmd, serviceID, SideloadRemapAccessGroup(accessGroup), userID, NO);
}

id (*orig_LS_initWithServiceIDAccessGroupUserID)(id self, SEL _cmd, id serviceID, id accessGroup, id userID);
id hook_LS_initWithServiceIDAccessGroupUserID(id self, SEL _cmd, id serviceID, id accessGroup, id userID) {
	if (!orig_LS_initWithServiceIDAccessGroupUserID) return nil;
	return orig_LS_initWithServiceIDAccessGroupUserID(self, _cmd, serviceID, SideloadRemapAccessGroup(accessGroup), userID);
}

id (*orig_LS_initSynchronizableItem)(id self, SEL _cmd, id serviceID, id accessGroup, id userID);
id hook_LS_initSynchronizableItem(id self, SEL _cmd, id serviceID, id accessGroup, id userID) {
	if (!orig_LS_initSynchronizableItem) return nil;
	return orig_LS_initSynchronizableItem(self, _cmd, serviceID, SideloadRemapAccessGroup(accessGroup), userID);
}

id (*orig_UIC_keyChainStoreWithServiceAccessGroup)(id self, SEL _cmd, id service, id accessGroup);
id hook_UIC_keyChainStoreWithServiceAccessGroup(id self, SEL _cmd, id service, id accessGroup) {
	if (!orig_UIC_keyChainStoreWithServiceAccessGroup) return nil;
	return orig_UIC_keyChainStoreWithServiceAccessGroup(self, _cmd, service, SideloadRemapAccessGroup(accessGroup));
}

id (*orig_NSDictionary_queryWithAccessGroupKey)(id self, SEL _cmd, id accessGroup);
id hook_NSDictionary_queryWithAccessGroupKey(id self, SEL _cmd, id accessGroup) {
	if (!orig_NSDictionary_queryWithAccessGroupKey) return nil;
	return orig_NSDictionary_queryWithAccessGroupKey(self, _cmd, SideloadRemapAccessGroup(accessGroup));
}

id (*orig_FWA_keychainSecureStoreByInferring)(id self, SEL _cmd, id accessGroup);
id hook_FWA_keychainSecureStoreByInferring(id self, SEL _cmd, id accessGroup) {
	if (!orig_FWA_keychainSecureStoreByInferring) return nil;
	return orig_FWA_keychainSecureStoreByInferring(self, _cmd, SideloadRemapAccessGroup(accessGroup));
}

id (*orig_IGCloudTrust_initWithAccessGroup)(id self, SEL _cmd, id accessGroup);
id hook_IGCloudTrust_initWithAccessGroup(id self, SEL _cmd, id accessGroup) {
	if (!orig_IGCloudTrust_initWithAccessGroup) return nil;
	return orig_IGCloudTrust_initWithAccessGroup(self, _cmd, SideloadRemapAccessGroup(accessGroup));
}