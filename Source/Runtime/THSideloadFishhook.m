/* Sideload fishhook rebindings (strlen / SecItem*) */
// Keychain hook via fishhook (file scope)
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*original_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*original_SecItemDelete)(CFDictionaryRef query);
#define kErrSecItemNotFoundKeychain ((OSStatus)-25300)

// Don't block keychain reads for device/session/report/login — blocking them can leave nil
// and cause crash (e.g. strlen(0) in device report or unhandled errSecItemNotFound on save-login).
static BOOL isDeviceOrSessionKeychainQuery(CFDictionaryRef query) {
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return NO;
    const char *keywords[] = {
        "device", "report", "essential", "session", "identifier", "DeviceReport",
        "login", "password", "credential", "save", "token", "auth", "authentication", "user"
    };
    char buf[256];
    CFTypeRef svcValue = CFDictionaryGetValue(query, kSecAttrService);
    if (svcValue && CFGetTypeID(svcValue) == CFStringGetTypeID()) {
        if (CFStringGetCString((CFStringRef)svcValue, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            for (size_t k = 0; k < sizeof(keywords) / sizeof(keywords[0]); k++) {
                if (strstr(buf, keywords[k])) return YES;
            }
        }
    }
    CFTypeRef accValue = CFDictionaryGetValue(query, kSecAttrAccount);
    if (accValue && CFGetTypeID(accValue) == CFStringGetTypeID()) {
        if (CFStringGetCString((CFStringRef)accValue, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            for (size_t k = 0; k < sizeof(keywords) / sizeof(keywords[0]); k++) {
                if (strstr(buf, keywords[k])) return YES;
            }
        }
    }
    return NO;
}

static BOOL isMetaKeychainQuery(CFDictionaryRef query) {
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return NO;
    if (isDeviceOrSessionKeychainQuery(query)) return NO;
    CFTypeRef agValue = CFDictionaryGetValue(query, kSecAttrAccessGroup);
    if (agValue && CFGetTypeID(agValue) == CFStringGetTypeID()) {
        CFStringRef agStr = (CFStringRef)agValue;
        char buf[256];
        if (CFStringGetCString(agStr, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            if (strstr(buf, "facebook") || strstr(buf, "Facebook") ||
                strstr(buf, "meta") || strstr(buf, "Meta") ||
                strstr(buf, "fbkeychain") || strstr(buf, "keychainstore")) return YES;
        }
    }
    CFTypeRef svcValue = CFDictionaryGetValue(query, kSecAttrService);
    if (svcValue && CFGetTypeID(svcValue) == CFStringGetTypeID()) {
        CFStringRef svcStr = (CFStringRef)svcValue;
        char buf[256];
        if (CFStringGetCString(svcStr, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            if (strstr(buf, "facebook") || strstr(buf, "Meta") || strstr(buf, "fbkeychain")) return YES;
        }
    }
    return NO;
}

// Real SecItem* resolved once before we rebind (dlsym after rebind would return our hook).
static OSStatus (*real_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = NULL;
static OSStatus (*real_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = NULL;
static OSStatus (*real_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = NULL;
static OSStatus (*real_SecItemDelete)(CFDictionaryRef query) = NULL;

#ifdef SIDELOAD
// Instagram writes tokens with Meta's team-id access group. Sideload signing
// uses a different team, so those writes used to fail; faking success left
// the next cold launch with no session. Rewrite onto the sideload group.
static BOOL SideloadShouldSkipAccessGroup(CFStringRef group) {
    if (!group || CFGetTypeID(group) != CFStringGetTypeID()) return YES;
    if (CFStringHasPrefix(group, CFSTR("com.apple."))) return YES;
    if (keychainAccessGroup.length &&
        CFStringCompare(group, (__bridge CFStringRef)keychainAccessGroup, 0) == kCFCompareEqualTo) {
        return YES;
    }
    return NO;
}

// Returns a +1 copy the caller must CFRelease, or NULL to use `dict` unchanged.
static CFDictionaryRef SideloadSecItemDictCopy(CFDictionaryRef dict, BOOL isQuery) {
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return NULL;
    if (!keychainAccessGroup.length) return NULL;

    CFTypeRef ag = CFDictionaryGetValue(dict, kSecAttrAccessGroup);
    BOOL rewriteGroup = (ag != NULL) && !SideloadShouldSkipAccessGroup((CFStringRef)ag);
    BOOL hasSync = CFDictionaryContainsKey(dict, kSecAttrSynchronizable);
    if (!rewriteGroup && !hasSync) return NULL;

    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
    if (!copy) return NULL;
    if (rewriteGroup) {
        CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)keychainAccessGroup);
    }
    if (hasSync) {
        if (isQuery) {
            CFDictionarySetValue(copy, kSecAttrSynchronizable, kSecAttrSynchronizableAny);
        } else {
            CFDictionarySetValue(copy, kSecAttrSynchronizable, kCFBooleanFalse);
        }
    }
    return copy;
}
#endif

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
#ifdef SIDELOAD
    (void)isMetaKeychainQuery;
#else
    if (isMetaKeychainQuery(query)) {
        if (result) *result = NULL;
        return kErrSecItemNotFoundKeychain;
    }
#endif
    if (!real_SecItemCopyMatching) {
        if (result) *result = NULL;
        return kErrSecItemNotFoundKeychain;
    }
#ifdef SIDELOAD
    CFDictionaryRef rewritten = SideloadSecItemDictCopy(query, YES);
    OSStatus status = real_SecItemCopyMatching(rewritten ? rewritten : query, result);
    if (rewritten) CFRelease(rewritten);
    return status;
#else
    return real_SecItemCopyMatching(query, result);
#endif
}

// Guard strlen(NULL) in IGDeviceReportWithEssentialInfo on sideload.
// Never rebind both strlen and _platform_strlen into the same orig pointer — fishhook
// can overwrite orig with our hook and recurse until the stack blows.
static size_t (*original_strlen_fn)(const char *) = NULL;
static size_t safe_strlen_impl(const char *s) {
    if (!s) return 0;
    size_t (*fn)(const char *) = original_strlen_fn;
    if (fn && fn != safe_strlen_impl) return fn(s);
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!real_SecItemAdd) return -25243; // errSecUnimplemented
#ifdef SIDELOAD
    CFDictionaryRef rewritten = SideloadSecItemDictCopy(attributes, NO);
    OSStatus status = real_SecItemAdd(rewritten ? rewritten : attributes, result);
    if (rewritten) CFRelease(rewritten);
    // Item already in the sideload keychain — that *is* persistence.
    if (status == errSecDuplicateItem) return errSecSuccess;
    if (status != errSecSuccess) {
        fprintf(stderr, "[Theta] SecItemAdd failed status=%d (session may not persist)\n", (int)status);
        fflush(stderr);
    }
    return status;
#else
    return real_SecItemAdd(attributes, result);
#endif
}

static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!real_SecItemUpdate) return -25243;
#ifdef SIDELOAD
    CFDictionaryRef q = SideloadSecItemDictCopy(query, YES);
    CFDictionaryRef a = SideloadSecItemDictCopy(attributesToUpdate, NO);
    OSStatus status = real_SecItemUpdate(q ? q : query, a ? a : attributesToUpdate);
    if (q) CFRelease(q);
    if (a) CFRelease(a);
    return status;
#else
    return real_SecItemUpdate(query, attributesToUpdate);
#endif
}

static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    if (!real_SecItemDelete) return -25243;
#ifdef SIDELOAD
    CFDictionaryRef rewritten = SideloadSecItemDictCopy(query, YES);
    OSStatus status = real_SecItemDelete(rewritten ? rewritten : query);
    if (rewritten) CFRelease(rewritten);
    return status;
#else
    return real_SecItemDelete(query);
#endif
}

static void install_fishhook_rebindings(void) {
#ifdef SIDELOAD
    // Resolve real implementations before rebinding (after rebind, dlsym would return our hooks).
    void *p = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    real_SecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))p;
    p = dlsym(RTLD_DEFAULT, "SecItemAdd");
    real_SecItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))p;
    p = dlsym(RTLD_DEFAULT, "SecItemUpdate");
    real_SecItemUpdate = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))p;
    p = dlsym(RTLD_DEFAULT, "SecItemDelete");
    real_SecItemDelete = (OSStatus (*)(CFDictionaryRef))p;

    // Capture real strlen before rebind; only hook one symbol name.
    original_strlen_fn = (size_t (*)(const char *))dlsym(RTLD_DEFAULT, "strlen");

    struct rebinding rebindings[] = {
        { "strlen", (void *)safe_strlen_impl, (void **)&original_strlen_fn },
        { "SecItemCopyMatching", (void *)hooked_SecItemCopyMatching, (void **)&original_SecItemCopyMatching },
        { "SecItemAdd", (void *)hooked_SecItemAdd, (void **)&original_SecItemAdd },
        { "SecItemUpdate", (void *)hooked_SecItemUpdate, (void **)&original_SecItemUpdate },
        { "SecItemDelete", (void *)hooked_SecItemDelete, (void **)&original_SecItemDelete },
    };
    size_t n = sizeof(rebindings) / sizeof(rebindings[0]);
    if (rebind_symbols(rebindings, n) == 0) {
        NSLog(@"[Theta] strlen/SecItem* hooks installed (sideload session persist)");
    }
#endif
}
