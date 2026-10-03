TARGET := iphone:clang:latest:14.0
ARCHS := arm64
export TARGET_CODESIGN = true

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MangaGlass
MangaGlass_FILES = Tweak.x MGSettings.m MGGlass.m MGCloudClient.m MGPageProvider.m MangaViewController.m MGReaderGeometry.c
MangaGlass_CFLAGS = -Wall -Wextra
MangaGlass_OBJCFLAGS = -fobjc-arc
MangaGlass_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore PDFKit ImageIO CoreImage
MangaGlass_LDFLAGS = -Wl,-headerpad_max_install_names

include $(THEOS_MAKE_PATH)/tweak.mk
