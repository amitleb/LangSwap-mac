#!/bin/zsh
# Build a universal (Apple Silicon + Intel) LangSwap.app and zip it into dist/LangSwap.zip
set -e
cd "$(dirname "$0")"
VERSION="4.0"
OUT=dist; APP=$OUT/LangSwap/LangSwap.app
rm -rf $OUT; mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for a in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $a-apple-macos13.0 main.swift -o $OUT/LS_$a -framework AppKit -framework Carbon -framework ServiceManagement
done
lipo -create $OUT/LS_arm64 $OUT/LS_x86_64 -output $APP/Contents/MacOS/LangSwap && rm $OUT/LS_*
cp resources/en_50k.txt resources/he_50k.txt NOTICE.md $APP/Contents/Resources/
sed -n '/<?xml/,/<\/plist>/p' build.sh | sed "s/\$VERSION/$VERSION/g" > $APP/Contents/Info.plist
codesign --force --sign - $APP
cp HOW-TO-INSTALL.txt $OUT/LangSwap/
xattr -cr $OUT/LangSwap
(cd $OUT && ditto -c -k --norsrc --keepParent LangSwap LangSwap.zip)
codesign --verify --deep --strict $APP && echo "dist/LangSwap.zip ready (version $VERSION)"
