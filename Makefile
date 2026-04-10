ARCHS = arm64
TARGET := iphone:clang:16.5:15.0

TWEAK_NAME = ExploreFilter
ExploreFilter_FILES = ExploreFilter.m
ExploreFilter_FRAMEWORKS = Foundation UIKit
ExploreFilter_CFLAGS = -fobjc-arc -Wno-unused-function -DEF_LOGGING_ENABLED=1

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tweak.mk
