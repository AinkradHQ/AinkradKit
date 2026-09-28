DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# The sideload directory is `<cacheRoot>/DevPlugins`, and cacheRoot is
# `~/Library/Application Support/<bundle-id>/Cache` (AinkradHome.defaultCacheRoot).
# It is deliberately NOT under the user's Ainkrad Home: dev plugin bundles are
# rebuildable machine state, not vault data. Must stay in step with the host's
# own Makefile and AppEnvironment+BootstrapStores' scan list.
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins

generate: ; xcodegen generate
build: generate ; xcodebuild -scheme TemplatePlugin -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/TemplatePlugin.bundle"
	cp -R build/Build/Products/Debug/TemplatePlugin.bundle "$(DEV_PLUGINS)/TemplatePlugin.bundle"
# Publishing goes through `ainkrad publish` and nowhere else.
#
# This target used to call a bundled release script that assembled its own
# ainkrad-plugin.json by hand — hardcoding "apiVersion": 1, which the host
# REJECTS (the supported range starts at the current generation), and omitting
# "author" entirely. It was a second publish path producing manifests the
# host's StorePolicy refuses, sitting right beside the validated one, and it
# was the reason the installer needed an `author == nil` grandfather clause.
# Deleted. `ainkrad publish` runs the same validation the store does.
release: releasebuild ; ainkrad publish build/Build/Products/Release/TemplatePlugin.bundle $(V)
releasebuild: generate ; xcodebuild -scheme TemplatePlugin -configuration Release -derivedDataPath build -destination 'platform=macOS' build
