#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$PROJECT_DIR/build" 2>/dev/null || true
BUILD_DIR="$(mktemp -d /tmp/JietuMiaoyi_build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

APP_DISPLAY_NAME="截图秒译"
EXEC_NAME="JietuMiaoyi"
BUNDLE_ID="com.opensource.JietuMiaoyi"
APP_BUNDLE="$BUILD_DIR/${APP_DISPLAY_NAME}.app"
INSTALL_PATH="/Applications/${APP_DISPLAY_NAME}.app"

echo "=== 1. 准备构建目录 ==="
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"

echo "=== 2. 绘制 macOS 玻璃拟态立体应用图标 (AppIcon.icns) ==="
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
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

    // 底部柔和阴影
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

    // 顶部玻璃内高光描边
    let innerStroke = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.007, dy: s * 0.007), xRadius: radius, yRadius: radius)
    innerStroke.lineWidth = max(0.8, s * 0.012)
    NSColor.white.withAlphaComponent(0.38).setStroke()
    innerStroke.stroke()

    // 四角完全围绕几何中心对称的白色圆润取景框
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

    // 正中央严格对称的纯白圆角卡片
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

    // 使用 CoreText 像素墨迹包围盒将「译」字 100% 绝对光学居中绘制
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
rm -rf "$ICONSET_DIR"

echo "=== 3. 写入中文名称本地化与 Info.plist ==="
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
    <string>2.0.0</string>
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

echo "=== 4. 编译 Swift 原生二进制文件 ==="
swiftc \
    -O \
    -swift-version 5 \
    -target arm64-apple-macosx14.0 \
    -framework Cocoa \
    -framework Carbon \
    -framework Vision \
    -framework ScreenCaptureKit \
    -framework ServiceManagement \
    "$PROJECT_DIR"/Sources/*.swift \
    -o "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

echo "=== 5. 执行本地代码签名 ==="
codesign --force --deep --sign - "$APP_BUNDLE"

echo "=== 6. 清理旧英文版并安装至 /Applications/截图秒译.app ==="
pkill -x "InPlaceTranslator" 2>/dev/null || true
pkill -x "$EXEC_NAME" 2>/dev/null || true
tccutil reset ScreenCapture com.opensource.InPlaceTranslator 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
rm -rf "/Applications/InPlaceTranslator.app"
rm -rf "$INSTALL_PATH"
ditto "$APP_BUNDLE" "$INSTALL_PATH"
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
touch "$INSTALL_PATH"

echo "=== 构建与安装成功: $INSTALL_PATH ==="
