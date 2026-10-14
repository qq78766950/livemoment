#!/usr/bin/env bash
#
# 把 LiveMoment 编译成一个「未签名」的 .ipa。
#
# 为什么是未签名的：编译只需要 SDK，签名需要证书。未签名的 ipa 交给
# Sideloadly / AltStore 用你自己的 Apple ID 现场签名后就能装到手机上，
# 这样就不需要 99 美元/年的开发者账号。
#
# 必须在 macOS 上运行（装好 Xcode 命令行工具即可）。
# 没有 Mac 的话，直接用 GitHub Actions 跑 .github/workflows/build-ios.yml。
#
set -euo pipefail

TARGET="${TARGET:-LiveMoment}"
PROJECT="${PROJECT:-LiveMoment.xcodeproj}"
CONFIG="${CONFIG:-Release}"

SRCROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SRCROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "✗ 找不到 xcodebuild。" >&2
  echo "  iOS 只能在一台装有 Xcode 的 Mac 上编译，Windows / Linux 上没有可行路径。" >&2
  echo "  不想买 Mac 的话，用仓库里的 GitHub Actions 工作流在云端编译：见 安装到手机指南.md" >&2
  exit 1
fi

echo "▸ 工具链"
xcodebuild -version
echo

BUILD_DIR="$SRCROOT/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "▸ 编译（关闭全部签名环节）"
# 用 -target 而不是 -scheme：这样不依赖 .xcscheme 文件，
# 无论工程是仓库里这份、还是 XcodeGen 重新生成的，都能直接编。
xcodebuild build \
  -project "$PROJECT" \
  -target "$TARGET" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  SYMROOT="$BUILD_DIR" \
  OBJROOT="$BUILD_DIR/obj" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  DEVELOPMENT_TEAM="" \
  2>&1 | tee "$BUILD_DIR/xcodebuild.log"

APP="$BUILD_DIR/$CONFIG-iphoneos/$TARGET.app"
if [ ! -d "$APP" ]; then
  echo "✗ 编译没有产出 .app：$APP" >&2
  exit 1
fi

echo
echo "▸ 打包 .ipa"
STAGE="$BUILD_DIR/ipa-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"

# 未签名构建本来就不会生成签名目录，这里再清一次，保证产出的包是干净的
rm -rf "$STAGE/Payload/$TARGET.app/_CodeSignature"
rm -rf "$STAGE/Payload/$TARGET.app/embedded.mobileprovision"

IPA="$BUILD_DIR/$TARGET-unsigned.ipa"
rm -f "$IPA"
( cd "$STAGE" && zip -qry "$IPA" Payload )

echo
echo "✓ 完成：$IPA"
echo "  体积：$(du -h "$IPA" | cut -f1)"
echo "  下一步：用 Sideloadly 把 .ipa 拖进去，填自己的 Apple ID，签名安装。"
