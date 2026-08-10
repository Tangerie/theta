/* Runtime Substrate (MSHookFunction) loader — jailbreak libsubstrate + sideload CydiaSubstrate.framework */
#import "Include/ThetaSubstrate.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>

static void (*g_MSHookFunction)(void *, void *, void **) = NULL;
static bool g_substrateLoadAttempted = false;
static bool g_substrateAvailable = false;

static void *theta_dlopen_substrate(void) {
    void *handle = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (handle) return handle;

    /* Sideload / cyan: CydiaSubstrate.framework at app bundle root */
    handle = dlopen("@executable_path/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
    if (handle) return handle;

    /* Fallback: some IPAs still place it under Frameworks/ */
    handle = dlopen("@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", RTLD_NOW);
    if (handle) return handle;

    handle = dlopen("CydiaSubstrate", RTLD_NOW);
    if (handle) return handle;

    return NULL;
}

bool ThetaSubstrateLoad(void) {
    if (g_substrateLoadAttempted) return g_substrateAvailable;
    g_substrateLoadAttempted = true;

    g_MSHookFunction = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (g_MSHookFunction) {
        g_substrateAvailable = true;
        return true;
    }

    void *sub = theta_dlopen_substrate();
    if (sub) {
        g_MSHookFunction = (void (*)(void *, void *, void **))dlsym(sub, "MSHookFunction");
        if (g_MSHookFunction) {
            g_substrateAvailable = true;
            return true;
        }
    }

    return false;
}

void ThetaMSHookFunction(void *symbol, void *replace, void **result) {
    if (!symbol || !replace) return;
    if (!ThetaSubstrateLoad() || !g_MSHookFunction) return;
    g_MSHookFunction(symbol, replace, result);
}

static bool theta_path_is_main_instagram_executable(const char *path) {
    if (!path) return false;
    const char *needle = strstr(path, "Instagram.app/Instagram");
    if (!needle) return false;
    return strstr(needle, ".framework") == NULL;
}

static void *theta_dlsym_in_loaded_image(const char *imagePath, const char *name) {
    void *handle = dlopen(imagePath, RTLD_NOW | RTLD_NOLOAD);
    if (!handle) handle = dlopen(imagePath, RTLD_NOW);
    if (!handle) return NULL;
    void *sym = dlsym(handle, name);
    dlclose(handle);
    return sym;
}

static void *theta_resolve_symbol_in_dyld_image_matching(const char *name, bool (*path_match)(const char *)) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!path_match(imageName)) continue;
        void *sym = theta_dlsym_in_loaded_image(imageName, name);
        if (sym) return sym;
    }
    return NULL;
}

static bool theta_path_is_fb_shared_framework(const char *path) {
    return path && strstr(path, "FBSharedFramework.framework/FBSharedFramework") != NULL;
}

void *ThetaResolveInstagramExecutableSymbol(const char *name) {
    if (!name || !name[0]) return NULL;

    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym) {
        Dl_info info;
        if (dladdr(sym, &info) && info.dli_fname) {
            if (theta_path_is_main_instagram_executable(info.dli_fname) ||
                theta_path_is_fb_shared_framework(info.dli_fname))
                return sym;
        }
    }

    sym = theta_resolve_symbol_in_dyld_image_matching(name, theta_path_is_main_instagram_executable);
    if (sym) return sym;

    return theta_resolve_symbol_in_dyld_image_matching(name, theta_path_is_fb_shared_framework);
}
