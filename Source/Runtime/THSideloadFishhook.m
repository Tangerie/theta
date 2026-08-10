/* Sideload fishhook rebindings (strlen / SecItem*) */
// Keychain hook via fishhook (file scope)
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
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
    const void *svcKey = kSecAttrService;
    CFTypeRef svcValue = CFDictionaryGetValue(query, svcKey);
    if (svcValue && CFGetTypeID(svcValue) == CFStringGetTypeID()) {
        if (CFStringGetCString((CFStringRef)svcValue, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            for (size_t k = 0; k < sizeof(keywords) / sizeof(keywords[0]); k++) {
                if (strstr(buf, keywords[k])) return YES;
            }
        }
    }
    const void *accKey = kSecAttrAccount;
    CFTypeRef accValue = CFDictionaryGetValue(query, accKey);
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
    const void *agKey = kSecAttrAccessGroup;
    CFTypeRef agValue = CFDictionaryGetValue(query, agKey);
    if (agValue && CFGetTypeID(agValue) == CFStringGetTypeID()) {
        CFStringRef agStr = (CFStringRef)agValue;
        char buf[256];
        if (CFStringGetCString(agStr, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            if (strstr(buf, "facebook") || strstr(buf, "Facebook") ||
                strstr(buf, "meta") || strstr(buf, "Meta") ||
                strstr(buf, "fbkeychain") || strstr(buf, "keychainstore")) return YES;
        }
    }
    const void *svcKey = kSecAttrService;
    CFTypeRef svcValue = CFDictionaryGetValue(query, svcKey);
    if (svcValue && CFGetTypeID(svcValue) == CFStringGetTypeID()) {
        CFStringRef svcStr = (CFStringRef)svcValue;
        char buf[256];
        if (CFStringGetCString(svcStr, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            if (strstr(buf, "facebook") || strstr(buf, "Meta") || strstr(buf, "fbkeychain")) return YES;
        }
    }
    return NO;
}

// Real SecItemCopyMatching resolved once before we rebind (dlsym after rebind would return our hook).
static OSStatus (*real_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = NULL;

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
#ifdef SIDELOAD
    // On sideload never block: let real keychain run; strlen guard protects against nil. Blocking any query can crash save-login flow.
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
    return real_SecItemCopyMatching(query, result);
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

// True if attributes dict looks like login/credential/save (for SecItemAdd fake-success on sideload).
static BOOL isLoginOrCredentialKeychainItem(CFDictionaryRef attributes) {
    if (!attributes || CFGetTypeID(attributes) != CFDictionaryGetTypeID()) return NO;
    const char *keywords[] = {
        "login", "password", "credential", "save", "token", "auth", "authentication",
        "user", "session", "device", "identifier"
    };
    char buf[256];
    CFTypeRef v = CFDictionaryGetValue(attributes, kSecAttrService);
    if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)v, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        for (size_t k = 0; k < sizeof(keywords) / sizeof(keywords[0]); k++)
            if (strstr(buf, keywords[k])) return YES;
    }
    v = CFDictionaryGetValue(attributes, kSecAttrAccount);
    if (v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)v, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        for (size_t k = 0; k < sizeof(keywords) / sizeof(keywords[0]); k++)
            if (strstr(buf, keywords[k])) return YES;
    }
    return NO;
}

static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*real_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = NULL;
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!real_SecItemAdd) return -25243; // errSecUnimplemented
    OSStatus status = real_SecItemAdd(attributes, result);
#ifdef SIDELOAD
    // On sideload, adding login/credential often fails (entitlements). Fake success so the app doesn't crash.
    if (status != errSecSuccess && isLoginOrCredentialKeychainItem(attributes)) {
        if (result) *result = NULL;
        return errSecSuccess;
    }
#endif
    return status;
}

static void install_fishhook_rebindings(void) {
#ifdef SIDELOAD
    // Resolve real implementations before rebinding (after rebind, dlsym would return our hooks).
    void *p = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    real_SecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))p;
    p = dlsym(RTLD_DEFAULT, "SecItemAdd");
    real_SecItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))p;

    // Capture real strlen before rebind; only hook one symbol name.
    original_strlen_fn = (size_t (*)(const char *))dlsym(RTLD_DEFAULT, "strlen");

    struct rebinding rebindings[] = {
        { "strlen", (void *)safe_strlen_impl, (void **)&original_strlen_fn },
        { "SecItemCopyMatching", (void *)hooked_SecItemCopyMatching, (void **)&original_SecItemCopyMatching },
        { "SecItemAdd", (void *)hooked_SecItemAdd, (void **)&original_SecItemAdd },
    };
    size_t n = sizeof(rebindings) / sizeof(rebindings[0]);
    if (rebind_symbols(rebindings, n) == 0) {
        NSLog(@"[Theta] strlen/SecItemCopyMatching/SecItemAdd hooks installed (sideload login crash fix)");
    }
#endif
}
