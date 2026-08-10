export ARCHS = arm64
export SDKVERSION = 14.5
INSTALL_TARGET_PROCESSES = Instagram

GO_EASY_ON_ME = 1
FINALPACKAGE = 1

# Non-obfuscating toolchain (no Hikari)
export PREFIX = $(THEOS)/toolchain/Xcode14.xctoolchain/usr/bin/

ifeq ($(filter 1,$(SIDELOAD) $(ROOTLESS)), 1 1)
$(error "SIDELOAD and ROOTLESS cannot both be set")
endif

ifeq ($(ROOTLESS), 1)
	THEOS_PACKAGE_SCHEME = rootless
	Theta_CFLAGS += -DROOTLESS=1
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

TWEAK_NAME = Theta

Theta_FILES = TweakCOMPILE.xm fishhook.c \
	$(wildcard Source/UI/*.m) \
	$(wildcard Source/Media/*.m) \
	$(wildcard Source/ProfileAnalyzer/*.m)

Theta_FRAMEWORKS = UIKit Foundation CoreGraphics Photos CoreServices SystemConfiguration SafariServices Security QuartzCore AuthenticationServices WebKit UserNotifications AVFoundation
Theta_LDFLAGS = -lsqlite3
Theta_PRIVATE_FRAMEWORKS = Preferences

ifneq ($(SIDELOAD),1)
Theta_LIBRARIES += substrate
else
	Theta_CFLAGS += -I$(THEOS)/vendor/lib/CydiaSubstrate.framework/Headers
	Theta_LDFLAGS += -F$(THEOS)/vendor/lib -weak_framework CydiaSubstrate
	Theta_CFLAGS += -DSIDELOAD=1
endif

Theta_CFLAGS += -fobjc-arc \
	-Wno-unused-variable -Wno-unused-value -Wno-deprecated-declarations \
	-Wno-nullability-completeness -Wno-unused-function -Wno-incompatible-pointer-types \
	-I$(THEOS_PROJECT_DIR) \
	-DTHETA_VERSION='"v$(THEOS_PACKAGE_BASE_VERSION)"'

# FFmpeg headers (runtime loaded via dlopen)
Theta_CFLAGS += -I"$(THEOS_PROJECT_DIR)/layout/Library/Application Support/ffmpeg.framework"

ifeq ($(SIDELOAD), 1)
	Theta_CFLAGS += -DTHETA_PROJECT='"theta Jailed v$(THEOS_PACKAGE_BASE_VERSION)"'
	CODESIGN_IPA = 0
	TARGET_CODESIGN =
	LDID_FLAGS =
else
	Theta_CFLAGS += -DTHETA_PROJECT='"theta v$(THEOS_PACKAGE_BASE_VERSION)"'
endif

include $(THEOS_MAKE_PATH)/tweak.mk

before-all::
	@rm -f TweakCOMPILE.xm
	@python3 scripts/assemble.py
	@mkdir -p "ThetaResources.bundle"
	@mkdir -p "layout/Library/Application Support/ThetaResources.bundle"

after-all::
	@rm -f TweakCOMPILE.xm

after-install::
	install.exec "uiopen --bundleid com.burbn.instagram"
