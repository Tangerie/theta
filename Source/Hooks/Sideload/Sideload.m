static void loadKeychainAccessGroup() {
	@try {
		NSDictionary* dummyItem = @{
			(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
			(__bridge id)kSecAttrAccount : @"dummyItem",
			(__bridge id)kSecAttrService : @"dummyService",
			(__bridge id)kSecReturnAttributes : @YES,
		};

		CFTypeRef result;
		OSStatus ret = SecItemCopyMatching((__bridge CFDictionaryRef)dummyItem, &result);
		if (ret == -25300) {
			ret = SecItemAdd((__bridge CFDictionaryRef)dummyItem, &result);
		}

		if (ret == 0 && result) {
			NSDictionary* resultDict = (__bridge id)result;
			keychainAccessGroup = resultDict[(__bridge id)kSecAttrAccessGroup];
			CFRelease(result);
		} else {
			NSLog(@"Failed to get keychain access group: %d", (int)ret);
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