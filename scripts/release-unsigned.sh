#!/usr/bin/env bash
# 本地构建未签名 ipa 并上传 GitHub Release。
#
# 用法:
#   ./scripts/release-unsigned.sh                    # 自动在最新 vX.Y.Z 上 +1 patch
#   ./scripts/release-unsigned.sh --version v1.0.8   # 指定版本
#   ./scripts/release-unsigned.sh --no-upload        # 只构建/打包,不上传
#
# 需要: Xcode(本地 26+ 才能编出 Liquid Glass 分支)、gh 已登录。
# 产物在 build/unsigned-dd/assets/,该目录被 .gitignore 忽略。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION=""
UPLOAD=1

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { echo "error: --version 需要参数" >&2; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --no-upload)
      UPLOAD=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: 未知参数 $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  # 远端 tag 才算数:CI 发版创建的 tag 可能还没 fetch 到本地。
  git fetch --tags --quiet 2>/dev/null || true
  latest="$(git tag --sort=-v:refname | head -1 || true)"
  latest="${latest#v}"
  [[ -z "$latest" ]] && latest="0.0.0"
  VERSION="v$(echo "$latest" | awk -F. '{printf "%d.%d.%d", $1+0, $2+0, $3+1}')"
fi
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"

WORK="$ROOT/build/unsigned-dd"
ASSETS="$WORK/assets"
APP="$WORK/Build/Products/Release-iphoneos/LanjingQuiz.app"
IPA="$ASSETS/LanjingQuiz-unsigned-$VERSION.ipa"
NOTES="$ASSETS/ipa-install-notes.txt"

echo "==> Building LanjingQuiz $VERSION (Release, unsigned)"
rm -rf "$WORK"
xcodebuild build \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$WORK" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

if [[ ! -d "$APP" ]]; then
  echo "error: 未找到构建产物 $APP" >&2
  exit 1
fi

echo "==> Packaging ipa"
mkdir -p "$ASSETS/Payload"
cp -R "$APP" "$ASSETS/Payload/"
(cd "$ASSETS" && zip -r -q "$(basename "$IPA")" Payload)

cat > "$NOTES" <<'EOF'
未签名 ipa(LanjingQuiz-unsigned-*.ipa)不能直接安装。它没有签名,
需要用免费工具 + 你自己的 Apple ID 签名后装到真机(每 7 天重新签名一次):

1. 下载 Sideloadly(https://sideloadly.io,macOS/Windows)或 AltStore;
2. iPhone 连接电脑并解锁;
3. Sideloadly 中选择本 ipa,填入你的 Apple ID 和密码(凭据用于向 Apple
   申请签名证书;Sideloadly 是第三方工具,请自行评估安全性);
4. 点击 Start;完成后到手机:设置 → 通用 → VPN 与设备管理 →
   开发者 App → 信任;
5. 信任后即可使用;7 天后过期需重新签名。

题库包不随本发布分发,请到主仓发布页下载:
https://github.com/youngestdriver/lanjing_test/releases
下载 LanjingQuiz-bank-*.zip 后,在 App 内「我的 > 题库 > 导入题库」导入。
EOF

echo "==> IPA:   $IPA"
echo "==> Notes: $NOTES"

if (( UPLOAD )); then
  command -v gh >/dev/null || { echo "error: 未安装 gh" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "error: gh 未登录,先运行 gh auth login" >&2; exit 1; }

  if gh release view "$VERSION" >/dev/null 2>&1; then
    echo "==> Release $VERSION 已存在,覆盖上传产物"
    gh release upload "$VERSION" "$IPA" "$NOTES" --clobber
  else
    echo "==> 创建 Release $VERSION"
    gh release create "$VERSION" "$IPA" "$NOTES" \
      --title "蓝鲸助手 iOS $VERSION" \
      --generate-notes
  fi
  gh release view "$VERSION" --json url --jq .url
else
  echo "==> --no-upload:跳过 GitHub Release"
fi
