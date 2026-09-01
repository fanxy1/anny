.PHONY: build open

build:
	xcodebuild -project anny.xcodeproj -scheme anny -configuration Debug \
		-derivedDataPath DerivedData build

open:
	open anny.xcodeproj
