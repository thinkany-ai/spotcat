#!/bin/bash
# 把 dist/ 里已签名公证的产物发布到 Cloudflare R2（spotcat 桶，https://cdn.spotcat.ai）。
#
# 先上传带版本号的 ZIP / DMG（永久缓存），再上传 Spotcat.dmg（官网固定下载地址），
# 最后才替换 latest.json（不缓存）——客户端读到新清单时，它引用的安装包一定已经存在。
# 预发布版本（版本号带 "-"）只上传安装包，不更新 latest.json 和 Spotcat.dmg。
#
#   ./scripts/publish-cdn.sh                 发布 Info.plist 中的版本
#   ./scripts/publish-cdn.sh 0.3.0           发布指定版本（dist/ 中需要有对应产物）
#
# 凭据：设置了 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY（R2 的 S3 密钥）和 CLOUDFLARE_ACCOUNT_ID 时
# 用 aws CLI（CI）；否则用本机已登录的 wrangler。
set -euo pipefail
cd "$(dirname "$0")/.."

BUCKET=spotcat
CDN=https://cdn.spotcat.ai
REPO=thinkany-ai/spotcat
DIST=dist
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null)}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>" >&2; exit 1; }

ZIP="$DIST/Spotcat-$VERSION.zip"
DMG="$DIST/Spotcat-$VERSION.dmg"
for f in "$ZIP" "$DMG"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done

if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  : "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"
  upload() { # <file> <key> <content-type> <cache-control>
    echo "==> $2"
    AWS_EC2_METADATA_DISABLED=true aws s3 cp "$1" "s3://$BUCKET/$2" \
      --endpoint-url "https://$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com" --region auto \
      --content-type "$3" --cache-control "$4" --no-progress --only-show-errors
  }
else
  upload() {
    echo "==> $2"
    npx -y wrangler@latest r2 object put "$BUCKET/$2" --file "$1" --content-type "$3" \
      --cache-control "$4" --remote >/dev/null
  }
fi

IMMUTABLE="public, max-age=31536000, immutable"
upload "$ZIP" "Spotcat-$VERSION.zip" application/zip "$IMMUTABLE"
upload "$DMG" "Spotcat-$VERSION.dmg" application/x-apple-diskimage "$IMMUTABLE"

if [[ "$VERSION" == *-* ]]; then
  echo "Prerelease $VERSION uploaded; latest.json unchanged."
  exit 0
fi

upload "$DMG" "Spotcat.dmg" application/x-apple-diskimage "public, max-age=300"

# 更新说明取 GitHub Release 正文（没有时留空）
NOTES=$(gh release view "v$VERSION" -R "$REPO" --json body -q .body 2>/dev/null || true)
MANIFEST=$(mktemp)
VERSION="$VERSION" NOTES="$NOTES" CDN="$CDN" REPO="$REPO" \
SHA256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1) \
python3 - > "$MANIFEST" <<'EOF'
import json, os, datetime
v, cdn = os.environ["VERSION"], os.environ["CDN"]
print(json.dumps({
    "version": v,
    "notes": os.environ["NOTES"],
    "url": f"{cdn}/Spotcat-{v}.zip",
    "sha256": os.environ["SHA256"],
    "dmg": f"{cdn}/Spotcat-{v}.dmg",
    "page": f"https://github.com/{os.environ['REPO']}/releases/tag/v{v}",
    "published": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, ensure_ascii=False, indent=2))
EOF
upload "$MANIFEST" latest.json "application/json; charset=utf-8" "no-store, max-age=0"
rm -f "$MANIFEST"

echo "Published $VERSION → $CDN/latest.json"
