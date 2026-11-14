#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="2.0.0"
APP_DISPLAY_NAME="截图秒译"
EXEC_NAME="JietuMiaoyi"
BUNDLE_ID="com.opensource.JietuMiaoyi"
OUTPUT_DMG="${1:-$PROJECT_DIR/${APP_DISPLAY_NAME}-v${VERSION}-macOS.dmg}"

WORK_DIR="$(mktemp -d /tmp/JietuMiaoyi_dmg.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

APP_BUNDLE="$WORK_DIR/stage/${APP_DISPLAY_NAME}.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"
mkdir -p "$WORK_DIR/bin"

echo "=== 1. 生成 macOS 玻璃拟态立体应用图标 (AppIcon.icns) ==="
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

swift -e '
import Cocoa
import CoreText

let iconsetPath = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, name) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let cgCtx = nsCtx.cgContext

    let s = CGFloat(px)
    let inset = s * 0.085
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.225

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.018)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.24, blue: 0.94, alpha: 1.0),
        NSColor(calibratedRed: 0.07, green: 0.56, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.14, green: 0.82, blue: 0.88, alpha: 1.0)
    ])!
    grad.draw(in: bgPath, angle: 55)
    NSGraphicsContext.restoreGraphicsState()

    let innerStroke = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.007, dy: s * 0.007), xRadius: radius, yRadius: radius)
    innerStroke.lineWidth = max(0.8, s * 0.012)
    NSColor.white.withAlphaComponent(0.38).setStroke()
    innerStroke.stroke()

    let bMargin = s * 0.195
    let bLen = s * 0.085
    let bRadius = s * 0.032
    let bWidth = max(1.2, s * 0.028)
    NSColor.white.withAlphaComponent(0.90).setStroke()

    func drawCorner(cx: CGFloat, cy: CGFloat, dx: CGFloat, dy: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = bWidth
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: cx, y: cy + dy * bLen))
        p.appendArc(from: NSPoint(x: cx, y: cy), to: NSPoint(x: cx + dx * bLen, y: cy), radius: bRadius)
        p.line(to: NSPoint(x: cx + dx * bLen, y: cy))
        p.stroke()
    }
    drawCorner(cx: bMargin, cy: bMargin, dx: 1, dy: 1)
    drawCorner(cx: s - bMargin, cy: bMargin, dx: -1, dy: 1)
    drawCorner(cx: bMargin, cy: s - bMargin, dx: 1, dy: -1)
    drawCorner(cx: s - bMargin, cy: s - bMargin, dx: -1, dy: -1)

    let cardSize = s * 0.46
    let cardRect = NSRect(x: (s - cardSize) / 2.0, y: (s - cardSize) / 2.0, width: cardSize, height: cardSize)

    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor(calibratedRed: 0.04, green: 0.15, blue: 0.48, alpha: 0.26)
    cardShadow.shadowBlurRadius = s * 0.035
    cardShadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    cardShadow.set()
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: s * 0.105, yRadius: s * 0.105)
    NSColor.white.withAlphaComponent(0.96).setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let font = NSFont(name: "PingFangSC-Semibold", size: s * 0.285) ?? NSFont.boldSystemFont(ofSize: s * 0.285)
    let textColor = NSColor(calibratedRed: 0.09, green: 0.38, blue: 0.94, alpha: 1.0)
    let attrStr = NSAttributedString(string: "译", attributes: [
        .font: font,
        .foregroundColor: textColor
    ])
    let line = CTLineCreateWithAttributedString(attrStr)
    cgCtx.saveGState()
    cgCtx.textMatrix = .identity
    cgCtx.textPosition = .zero
    let inkBounds = CTLineGetImageBounds(line, cgCtx)
    let drawX = cardRect.midX - inkBounds.midX
    let drawY = cardRect.midY - inkBounds.midY
    cgCtx.textPosition = CGPoint(x: drawX, y: drawY)
    CTLineDraw(line, cgCtx)
    cgCtx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        try pngData.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }
}
' "$ICONSET_DIR"

iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "=== 2. 写入本地化配置与 Info.plist ==="
cat > "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'EOF'
"CFBundleName" = "截图秒译";
"CFBundleDisplayName" = "截图秒译";
EOF

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>截图秒译</string>
    <key>CFBundleName</key>
    <string>截图秒译</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>截图秒译需要屏幕录制权限以截取您框选的区域并在原位置覆盖替换中文。</string>
</dict>
</plist>
EOF

echo "=== 3. 编译 Apple Silicon (arm64) 与 Intel (x86_64) 通用二进制 ==="
COMMON_FLAGS=(
    -O
    -swift-version 5
    -framework Cocoa
    -framework Carbon
    -framework Vision
    -framework ScreenCaptureKit
    -framework ServiceManagement
)

swiftc "${COMMON_FLAGS[@]}" -target arm64-apple-macosx14.0 \
    "$PROJECT_DIR"/Sources/*.swift \
    -o "$WORK_DIR/bin/${EXEC_NAME}_arm64"

if swiftc "${COMMON_FLAGS[@]}" -target x86_64-apple-macosx14.0 \
    "$PROJECT_DIR"/Sources/*.swift \
    -o "$WORK_DIR/bin/${EXEC_NAME}_x86_64" 2>/dev/null; then
    lipo -create -output "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME" \
        "$WORK_DIR/bin/${EXEC_NAME}_arm64" "$WORK_DIR/bin/${EXEC_NAME}_x86_64"
    echo "已生成通用二进制 (arm64 + x86_64)"
else
    cp "$WORK_DIR/bin/${EXEC_NAME}_arm64" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
    echo "已生成 Apple Silicon 二进制 (arm64)"
fi

echo "=== 4. 对应用包执行签名 ==="
codesign --force --deep --sign - "$APP_BUNDLE"

echo "=== 5. 组装标准拖拽式 DMG 镜像 ==="
ln -s /Applications "$WORK_DIR/stage/Applications"

cat > "$WORK_DIR/stage/安装与首次打开说明.txt" <<'EOF'
【截图秒译 v2.0.0 安装说明】

1. 将「截图秒译.app」拖拽到旁边的「Applications」文件夹即可完成安装。

2. 若在新电脑首次打开时遇到 macOS 提示「无法打开 / 未验证开发者」：
   • 方法一（最快）：打开「终端」，粘贴执行以下命令回车即可：
     xattr -cr /Applications/截图秒译.app
   • 方法二：打开「系统设置 → 隐私与安全性」，拉到底部点击「仍要打开」。

3. 首次按下快捷键 Option + S 框选时，按提示在「系统设置 → 隐私与安全性 → 录屏与系统录音」中勾选开启「截图秒译」即可正常使用。
EOF

TMP_DMG="$WORK_DIR/output.dmg"
hdiutil create -volname "${APP_DISPLAY_NAME}" \
    -srcfolder "$WORK_DIR/stage" \
    -ov -format UDZO "$TMP_DMG"

cp -f "$TMP_DMG" "$OUTPUT_DMG"
echo "=== DMG 安装包构建完成: $OUTPUT_DMG ==="
