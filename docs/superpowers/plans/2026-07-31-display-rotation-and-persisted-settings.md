# 修复显示旋转 + 设置持久化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 LCD 默认就正着显示,并让旋转/亮度/刷新间隔三项设置在重启后依然生效。

**Architecture:** 三件事各自独立。一、把 `JPEGEncoder.encode` 里反着写的旋转判断改正,连默认参数一起改,使"开关打开=真的旋转"。二、新增一个可注入存储位置的 `Preferences`,负责三项设置的读写与校验,由 `AppState` 在创建时读、在 `applySettings()` 里写。三、删掉早已无人引用的死代码 `MenuBarView.swift`。同时建起本仓库第一个测试单元,用一张"只有一角是白色"的图来断言旋转真的发生。

**Tech Stack:** Swift 6.1 工具链、SwiftPM、swift-testing(`import Testing`,随工具链自带,无需额外依赖)、CoreGraphics / ImageIO、UserDefaults。

## Global Constraints

- 平台 `macOS 15.0`,`swift-tools-version: 6.1`。不改这两个值。
- **本机构建和跑测试都必须带工具链环境变量**,否则会报 `plugin for module 'SwiftUIMacros' not found` 并连带一串看似代码错误的误导性报错:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  CI 用 GitHub 的 macOS 机器,自带完整 Xcode,不需要这个变量。
- 只持久化三项:`rotateDisplay`、`brightness`、`refreshInterval`。**不要**持久化 `currentSet` —— `DisplaySet` 目前只有 `systemMonitor` 一个选项,存它没有意义。
- 命令行调试模式(`--cli` / `--demo` / `--benchmark` / `--snapshot` / `--gif`)**不读**持久化设置,行为完全由命令行参数决定。本计划不给它们加读取逻辑。
- 不改推流、渲染、指标采集、USB 协议等与本问题无关的逻辑。
- 提交信息用英文,沿用仓库现有的 conventional commits 风格(如 `fix(agents): ...`)。
- 已知会保留的现状:`DisplayEngine.blackFrame(rotate:)` 用 `_blackFrame` 缓存,不随 `rotate` 变化重算。这是刻意不动的 —— 那是一张纯黑图,转与不转视觉上没有区别。

---

### Task 1: 理顺旋转语义,并建起第一个测试单元

把反着写的判断改正,同时把本仓库的测试基础设施搭起来(测试单元 + CI 步骤都折进这个任务,因为它们是这批测试跑起来的前提)。

**Files:**
- Modify: `Package.swift`(在 `targets` 数组末尾追加 testTarget)
- Create: `Tests/MacTRTests/JPEGEncoderRotationTests.swift`
- Modify: `Sources/MacTR/Rendering/FrameRenderer.swift:28` 和 `:35`
- Modify: `.github/workflows/build.yml`(新增跑测试的步骤)

**Interfaces:**
- Consumes: 无(第一个任务)
- Produces: `JPEGEncoder.encode(_ image: CGImage, brightness: Int = 1, rotate: Bool = false, maxBytes: Int = 650_000) -> Data?` —— 注意 `rotate` 默认值由 `true` 改为 `false`,且语义变为"true 才旋转"。后续任务和 `AppState` 都按这个语义传值。

- [ ] **Step 1: 加测试单元到 Package.swift**

在 `Package.swift` 的 `targets:` 数组最后一个元素(`.executableTarget(name: "MacTR", ...)`)之后追加:

```swift
        .testTarget(
            name: "MacTRTests",
            dependencies: ["MacTR"],
            path: "Tests/MacTRTests",
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include/libusb-1.0"]),
            ]
        ),
```

`-I` 那个标志是必需的:测试通过 `@testable import MacTR` 间接加载 `CLibUSB`,而 libusb 的头文件在 Homebrew 目录下。这与 `MacTR` 目标上已有的同名标志一致。

- [ ] **Step 2: 写测试**

创建 `Tests/MacTRTests/JPEGEncoderRotationTests.swift`:

```swift
// JPEGEncoderRotationTests.swift — the rotation flag must mean what it says.
//
// Guards the inversion that shipped in v1.2.0: `if !rotate` rotated the frame
// when the flag was false, so every call site read backwards and the LCD came
// up upside down by default.

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import MacTR

// MARK: - Fixtures

private let imageSide = 120
private let patchSide = 24

private struct DecodeFailure: Error {}

private enum Corner {
    case a, b, c, d

    /// The corner diagonally across the frame — where a 180° turn lands.
    var diagonalOpposite: Corner {
        switch self {
        case .a: .d
        case .d: .a
        case .b: .c
        case .c: .b
        }
    }
}

/// A black square with one white patch, so a 180° turn is detectable purely by
/// which corner the patch ends up in.
private func makeCornerMarkedImage() -> CGImage {
    let ctx = CGContext(
        data: nil, width: imageSide, height: imageSide,
        bitsPerComponent: 8, bytesPerRow: imageSide * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: imageSide, height: imageSide))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: patchSide, height: patchSide))
    return ctx.makeImage()!
}

/// Which corner holds the brightest patch.
///
/// The corner labels are deliberately meaningless (a/b/c/d): both the reference
/// image and the round-tripped JPEG go through this same function, so the tests
/// only ever compare *which* corner moved. That keeps them out of the business
/// of deciding whether row 0 of a CoreGraphics bitmap is the top or the bottom.
///
/// Frames are JPEG-compressed, so this averages a patch rather than sampling a
/// single pixel — lossy artefacts move individual pixels around.
private func brightestCorner(of image: CGImage) -> Corner {
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func meanLuma(_ xRange: Range<Int>, _ yRange: Range<Int>) -> Double {
        var total = 0.0
        for y in yRange {
            for x in xRange {
                let i = (y * w + x) * 4
                total += (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
            }
        }
        return total / Double(xRange.count * yRange.count)
    }

    let lowX = 0..<patchSide, highX = (w - patchSide)..<w
    let lowY = 0..<patchSide, highY = (h - patchSide)..<h
    let scores: [(Corner, Double)] = [
        (.a, meanLuma(lowX, lowY)),
        (.b, meanLuma(highX, lowY)),
        (.c, meanLuma(lowX, highY)),
        (.d, meanLuma(highX, highY)),
    ]
    return scores.max(by: { $0.1 < $1.1 })!.0
}

/// Plain `throws` rather than `#require`, so there's no question of whether the
/// macro behaves outside a `@Test` function.
private func decode(_ jpeg: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw DecodeFailure() }
    return image
}

// MARK: - Tests

@Test("rotate: false leaves the frame where it was")
func rotateFalseLeavesFrameAlone() throws {
    let original = makeCornerMarkedImage()
    let jpeg = try #require(JPEGEncoder.encode(original, brightness: 1, rotate: false))
    let decoded = try decode(jpeg)
    #expect(brightestCorner(of: decoded) == brightestCorner(of: original))
}

@Test("rotate: true turns the frame 180 degrees")
func rotateTrueTurnsFrame() throws {
    let original = makeCornerMarkedImage()
    let jpeg = try #require(JPEGEncoder.encode(original, brightness: 1, rotate: true))
    let decoded = try decode(jpeg)
    #expect(brightestCorner(of: decoded) == brightestCorner(of: original).diagonalOpposite)
}

/// `makeTestJPEG` in MacTRApp.swift relies on the default, and the USB test
/// pattern must not silently flip when the flag's meaning is corrected.
@Test("the default is no rotation")
func defaultIsNoRotation() throws {
    let original = makeCornerMarkedImage()
    let jpeg = try #require(JPEGEncoder.encode(original, brightness: 1))
    let decoded = try decode(jpeg)
    #expect(brightestCorner(of: decoded) == brightestCorner(of: original))
}
```

- [ ] **Step 3: 跑测试,确认它按预期失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected:
- `rotateTrueTurnsFrame` **失败** —— 当前代码 `rotate: true` 走的是不旋转的分支,白块没动,所以断言"跑到了对角"不成立。这就是要修的 bug。
- `rotateFalseLeavesFrameAlone` **失败** —— 当前 `rotate: false` 反而会旋转。
- `defaultIsNoRotation` **通过** —— 当前默认值是 `true`,而 `true` 现在表示不旋转,所以本来就不转。这条是回归护栏,不是失败先行的测试,**看到它一开始就绿是正常的**,不要以为哪里搞错了。

如果构建阶段就失败(而不是测试失败),看这个任务末尾的「测试跑不起来时的退路」。

- [ ] **Step 4: 修正旋转判断与默认值**

改 `Sources/MacTR/Rendering/FrameRenderer.swift`。

第 28 行,默认值 `true` → `false`:

```swift
        _ image: CGImage, brightness: Int = 1, rotate: Bool = false, maxBytes: Int = 650_000
```

第 35 行,去掉那个取反:

```swift
        if rotate {
```

**两处必须一起改。** 全项目有 7 处调用 `JPEGEncoder.encode`,6 处显式传 `rotate`,只有 `MacTRApp.swift:804`(`makeTestJPEG`)吃默认值。默认值从 `true` 改成 `false` 后,那一处的实际行为完全不变(改前 `true` 表示不转,改后 `false` 表示不转)。若只改判断不改默认值,USB 测试图会意外变成颠倒的。

顺带把第 25 行那句已经不准确的注释改掉 —— 它写的是"Encode CGImage to JPEG Data with 180° rotation and brightness adjustment",听起来像是总会旋转:

```swift
    /// Encode a CGImage to JPEG. Turns the frame 180° when `rotate` is true, for
    /// coolers whose LCD is mounted the other way up. Reduces quality if over 650KB.
```

- [ ] **Step 5: 跑测试,确认全绿**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 3 条全部 PASS。

- [ ] **Step 6: CI 加一步跑测试**

改 `.github/workflows/build.yml`,在 `Show toolchain` 步骤之后、`Build .app` 之前插入:

```yaml
      - name: Run tests
        run: swift test
```

- [ ] **Step 7: 提交**

```bash
git add Package.swift Tests/MacTRTests/JPEGEncoderRotationTests.swift \
        Sources/MacTR/Rendering/FrameRenderer.swift .github/workflows/build.yml
git commit -m "fix(render): make the rotate flag mean what it says

FrameRenderer's encode() read 'if !rotate', so the frame turned 180° when
the flag was false. Every call site therefore read backwards, and since
AppState defaults rotateDisplay to false the LCD came up upside down.

Flip the condition and the default parameter together: makeTestJPEG() rides
the default, and changing only the condition would have flipped the USB test
pattern instead (false now means what true used to).

Adds the repo's first tests, which is what would have caught this."
```

#### 测试跑不起来时的退路

本仓库所有代码都在一个 executable target 里,给 executable target 挂测试在 SwiftPM 上偶尔会别扭(典型症状:`@main` 与可测试性冲突,或 `@testable import MacTR` 找不到模块)。

先按上面的直接做法试。若构建就是过不去,退路是新建一个 library target(例如 `MacTRCore`),把纯计算的文件挪进去 —— 本计划涉及的是 `Sources/MacTR/Rendering/FrameRenderer.swift`,以及 Task 2 要新建的 `Preferences.swift`;`MacTR` 与 `MacTRTests` 都依赖它。这是更标准的做法,代价是要动 target 结构、调整 import。**走退路前先告知,不要自己扩大范围。**

---

### Task 2: 新增 Preferences,负责三项设置的读写

**Files:**
- Create: `Sources/MacTR/App/Preferences.swift`
- Create: `Tests/MacTRTests/ThrowawayStore.swift`
- Create: `Tests/MacTRTests/PreferencesTests.swift`

**Interfaces:**
- Consumes: 无(不依赖 Task 1 的产出)
- Produces:
  - `struct DisplaySettings: Equatable, Sendable` —— 成员 `var rotateDisplay: Bool`、`var brightness: Int`、`var refreshInterval: Double`;静态成员 `DisplaySettings.default`(值为 `false` / `5` / `0.5`)。
  - `struct Preferences` —— `init(store: UserDefaults = .standard)`、`func load() -> DisplaySettings`、`func save(_ settings: DisplaySettings)`、`enum Key`(内部可见,成员 `rotateDisplay` / `brightness` / `refreshInterval`,值为同名字符串)。
  - `func withThrowawayStore(_ body: (UserDefaults) throws -> Void) throws`(测试辅助,Task 3 复用)。

- [ ] **Step 1: 写测试辅助**

创建 `Tests/MacTRTests/ThrowawayStore.swift`:

```swift
// ThrowawayStore.swift — a defaults suite that tests can dirty freely.

import Foundation

/// Runs `body` against a private, empty UserDefaults suite and removes it
/// afterwards, so tests never read or clobber the real user settings.
func withThrowawayStore(_ body: (UserDefaults) throws -> Void) throws {
    let name = "com.m1ngli.MacTRAI.tests.\(UUID().uuidString)"
    guard let store = UserDefaults(suiteName: name) else {
        fatalError("could not open a throwaway defaults suite")
    }
    defer { store.removePersistentDomain(forName: name) }
    try body(store)
}
```

- [ ] **Step 2: 写测试**

创建 `Tests/MacTRTests/PreferencesTests.swift`:

```swift
// PreferencesTests.swift — settings must survive a relaunch, and survive
// nonsense in the store (it's system-wide and writable from outside the app).

import Foundation
import Testing

@testable import MacTR

@Test("an empty store yields the defaults")
func emptyStoreYieldsDefaults() throws {
    try withThrowawayStore { store in
        #expect(Preferences(store: store).load() == DisplaySettings.default)
    }
}

@Test("saved settings come back unchanged")
func savedSettingsRoundTrip() throws {
    try withThrowawayStore { store in
        let prefs = Preferences(store: store)
        let settings = DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 2.0)
        prefs.save(settings)
        #expect(prefs.load() == settings)
    }
}

@Test("an out-of-range brightness is clamped, not discarded")
func brightnessIsClamped() throws {
    try withThrowawayStore { store in
        store.set(99, forKey: Preferences.Key.brightness)
        #expect(Preferences(store: store).load().brightness == 10)

        store.set(-5, forKey: Preferences.Key.brightness)
        #expect(Preferences(store: store).load().brightness == 1)
    }
}

@Test("a refresh interval the picker doesn't offer falls back to the default")
func unsupportedIntervalFallsBack() throws {
    try withThrowawayStore { store in
        store.set(7.5, forKey: Preferences.Key.refreshInterval)
        #expect(Preferences(store: store).load().refreshInterval
            == DisplaySettings.default.refreshInterval)
    }
}
```

- [ ] **Step 3: 跑测试,确认按预期失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 编译失败,报找不到 `Preferences` / `DisplaySettings`。Task 1 的三条测试仍然是绿的。

- [ ] **Step 4: 实现 Preferences**

创建 `Sources/MacTR/App/Preferences.swift`:

```swift
// Preferences.swift — the display settings that survive a relaunch.
//
// The backing store is injected rather than reached for, so tests get a
// throwaway suite instead of the real user defaults.

import Foundation

/// The user-adjustable display settings, as one value.
struct DisplaySettings: Equatable, Sendable {
    var rotateDisplay: Bool
    var brightness: Int
    var refreshInterval: Double

    static let `default` = DisplaySettings(
        rotateDisplay: false, brightness: 5, refreshInterval: 0.5)
}

struct Preferences {

    /// The intervals the Settings picker offers. Anything else is treated as
    /// corrupt rather than clamped — there's no sensible nearest value.
    static let allowedRefreshIntervals: Set<Double> = [0.5, 1.0, 2.0]
    static let brightnessRange = 1...10

    /// Internal rather than private so tests can plant values without
    /// duplicating the key strings.
    enum Key {
        static let rotateDisplay = "rotateDisplay"
        static let brightness = "brightness"
        static let refreshInterval = "refreshInterval"
    }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
    }

    func load() -> DisplaySettings {
        DisplaySettings(
            rotateDisplay: store.object(forKey: Key.rotateDisplay) as? Bool
                ?? DisplaySettings.default.rotateDisplay,
            brightness: Self.validBrightness(store.object(forKey: Key.brightness) as? Int),
            refreshInterval: Self.validInterval(
                store.object(forKey: Key.refreshInterval) as? Double))
    }

    func save(_ settings: DisplaySettings) {
        store.set(settings.rotateDisplay, forKey: Key.rotateDisplay)
        store.set(Self.validBrightness(settings.brightness), forKey: Key.brightness)
        store.set(Self.validInterval(settings.refreshInterval), forKey: Key.refreshInterval)
    }

    /// Out of range means the slider's bounds moved or someone used `defaults
    /// write`; the nearest legal level is closer to intent than the default.
    private static func validBrightness(_ raw: Int?) -> Int {
        guard let raw else { return DisplaySettings.default.brightness }
        return min(brightnessRange.upperBound, max(brightnessRange.lowerBound, raw))
    }

    private static func validInterval(_ raw: Double?) -> Double {
        guard let raw, allowedRefreshIntervals.contains(raw) else {
            return DisplaySettings.default.refreshInterval
        }
        return raw
    }
}
```

- [ ] **Step 5: 跑测试,确认全绿**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 7 条全部 PASS(Task 1 的 3 条 + 本任务的 4 条)。

- [ ] **Step 6: 提交**

```bash
git add Sources/MacTR/App/Preferences.swift \
        Tests/MacTRTests/ThrowawayStore.swift Tests/MacTRTests/PreferencesTests.swift
git commit -m "feat(settings): add a Preferences store for the display settings

Nothing was persisted anywhere, so every launch reset rotation, brightness
and refresh interval to their defaults.

The store is injected so tests can use a throwaway suite. Loaded values are
validated: brightness clamps to the slider's range, an unrecognised refresh
interval falls back to the default. The store is system-wide and writable
from outside the app, so what comes back can't be trusted.

Nothing reads this yet; AppState is wired up next."
```

---

### Task 3: 让 AppState 读写 Preferences

**Files:**
- Modify: `Sources/MacTR/App/AppState.swift`(属性区约 46–55 行;`applySettings()` 约 107–110 行)
- Create: `Tests/MacTRTests/AppStateSettingsTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `DisplaySettings`、`Preferences`、`withThrowawayStore`
- Produces: `AppState.init(preferences: Preferences = Preferences())` —— 带默认参数,所以 `MacTRApp.swift:160` 那句 `private let appState = AppState()` 不用改。

- [ ] **Step 1: 写测试**

创建 `Tests/MacTRTests/AppStateSettingsTests.swift`:

```swift
// AppStateSettingsTests.swift — the wiring between AppState and the store.

import Foundation
import Testing

@testable import MacTR

@Test("a fresh AppState picks up what was saved")
@MainActor
func appStateLoadsSavedSettings() throws {
    try withThrowawayStore { store in
        Preferences(store: store).save(
            DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 1.0))

        let state = AppState(preferences: Preferences(store: store))

        #expect(state.rotateDisplay == true)
        #expect(state.brightness == 8)
        #expect(state.refreshInterval == 1.0)
    }
}

@Test("applySettings writes the current values out")
@MainActor
func applySettingsPersists() throws {
    try withThrowawayStore { store in
        let prefs = Preferences(store: store)
        let state = AppState(preferences: prefs)

        state.rotateDisplay = true
        state.brightness = 8
        state.applySettings()

        #expect(prefs.load()
            == DisplaySettings(rotateDisplay: true, brightness: 8, refreshInterval: 0.5))
    }
}
```

`applySettings()` 里那句 `engine?.updateSettings(...)` 在测试里是安全的空操作 —— 没调用过 `start()`,`engine` 是 nil。

- [ ] **Step 2: 跑测试,确认按预期失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 编译失败,报 `AppState` 没有接受 `preferences:` 参数的初始化方法。

- [ ] **Step 3: 加属性和初始化方法**

改 `Sources/MacTR/App/AppState.swift`。把这一段:

```swift
    // Display
    var currentSet: DisplaySet = .systemMonitor
    var brightness: Int = 5
    var refreshInterval: Double = 0.5
    var rotateDisplay: Bool = false
```

改成:

```swift
    // Display — the last three come from Preferences (see init) rather than
    // carrying inline defaults, so there's only one place that says what a
    // fresh install looks like: DisplaySettings.default.
    var currentSet: DisplaySet = .systemMonitor
    var brightness: Int
    var refreshInterval: Double
    var rotateDisplay: Bool
```

去掉那三个内联默认值是刻意的:留着的话,"新装是什么样"这件事就有两个说法(这里和 `DisplaySettings.default`),迟早会对不上。`currentSet` 不持久化,保留它的默认值。

然后在 `// MARK: - Internal` 下面那句 `private var engine: DisplayEngine?` 之后加上:

```swift
    private let preferences: Preferences

    // MARK: - Init

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        let saved = preferences.load()
        self.rotateDisplay = saved.rotateDisplay
        self.brightness = saved.brightness
        self.refreshInterval = saved.refreshInterval
    }
```

- [ ] **Step 4: 让 applySettings 存一次**

把 `applySettings()` 整个方法(约 107–110 行)改成:

```swift
    /// Called when the user changes display set, brightness, rotation, or
    /// interval. Every Settings control routes through here, so this is the one
    /// place that needs to persist.
    func applySettings() {
        preferences.save(DisplaySettings(
            rotateDisplay: rotateDisplay,
            brightness: brightness,
            refreshInterval: refreshInterval))
        engine?.updateSettings(set: currentSet, brightness: brightness,
                               interval: refreshInterval, rotate: rotateDisplay)
    }
```

- [ ] **Step 5: 跑测试,确认全绿**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 9 条全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/MacTR/App/AppState.swift Tests/MacTRTests/AppStateSettingsTests.swift
git commit -m "feat(settings): restore and persist the display settings

AppState now loads rotation, brightness and refresh interval on init and
writes them back from applySettings() — already the single funnel every
Settings control routes through.

The preferences store is an init parameter with a default, so the call in
StatusBarController is unchanged."
```

---

### Task 4: 删掉死代码 MenuBarView.swift

**Files:**
- Delete: `Sources/MacTR/UI/MenuBarView.swift`

**Interfaces:**
- Consumes: 无
- Produces: 无

- [ ] **Step 1: 确认它真的没人用**

Run: `grep -rn "MenuBarView" Sources/ packaging/ .github/ Package.swift`
Expected: 只有 `Sources/MacTR/UI/MenuBarView.swift` 自己那两行(第 1 行注释、第 7 行 `struct MenuBarView: View {`)。若别处出现引用,**停下来汇报**,不要删。

- [ ] **Step 2: 删除文件**

```bash
git rm Sources/MacTR/UI/MenuBarView.swift
```

- [ ] **Step 3: 确认构建和测试仍然通过**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: 构建成功,9 条测试全部 PASS。

- [ ] **Step 4: 提交**

```bash
git commit -m "refactor: drop the dead MenuBarView

Left over from the SwiftUI MenuBarExtra approach; the app has used
StatusBarController with a plain NSStatusItem since v1.1.0 and nothing
references this view. It still compiled, though: half the errors from the
SwiftUIMacros toolchain problem that started this branch came out of a file
that never runs."
```

---

### Task 5: 真机验证

改动全部完成后,在接着 LCD 的机器上确认它真的好了。这一步需要人眼看屏幕,没法自动化。

**Files:** 无(纯验证)

**Interfaces:**
- Consumes: Task 1–4 的全部产出
- Produces: 无

- [ ] **Step 1: 清掉可能残留的旧设置**

之前从未持久化过任何东西,但如果开发过程中跑过带 `applySettings()` 的版本,存储里可能已经有值,会掩盖"默认就是正的"这个结论。先清空:

```bash
defaults delete com.m1ngli.MacTRAI 2>/dev/null; echo "已清空(本来没有也正常)"
```

`com.m1ngli.MacTRAI` 取自 `Sources/MacTR/Resources/Info.plist` 的 `CFBundleIdentifier`,已核对。

**本任务必须用打好包的 .app 验证,不要用 `.build/release/MacTR` 裸二进制。** 裸二进制没有 bundle,设置存到哪个域名不确定,"重启后还在不在"这条验收会不可靠。打包后的 App 才有确定的标识符,也才是用户真正运行的东西。

- [ ] **Step 2: 确认设备在线,并停掉可能占着 USB 的旧进程**

```bash
pkill -f 'MacTR'   # 裸二进制和打包后的 App 都能覆盖到
ioreg -p IOUSB -l -w 0 | grep -q '"idProduct" = 21512' && echo "设备在线" || echo "设备不在线"
```

`21512` 是十进制的 `0x5408`,也就是这块屏的产品号(README 里写的 `0416:5408`)。

设备不在线就先接好线再继续。

- [ ] **Step 3: 打包并启动**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./packaging/build-app.sh
open "dist/MacTR AI.app"
```

打包脚本内部用的是 `command -v swift`,所以带上 `DEVELOPER_DIR` 就够了,不需要再传脚本自己的 `SWIFT=` 变量。

启动后应当能在菜单栏看到显示器形状的图标。图标带红色感叹号说明没连上 LCD,回到 Step 2 检查。

- [ ] **Step 4: 验收第一条 —— 默认就是正的**

不要动任何设置。看屏幕:仪表盘应当**正着显示**。若仍然颠倒,说明 Task 1 的方向反了,回去检查。

- [ ] **Step 5: 验收第二条 —— 开关方向正确,且设置存得住**

从菜单栏图标进 Settings → Display:

1. 把亮度调到 8。
2. 打开「Rotate 180°」。屏幕应当**变成颠倒的** —— 这证明开关名字和行为终于一致了。
3. 从菜单栏 Quit,然后重新 `open "dist/MacTR AI.app"`。
4. 屏幕应当**仍然是颠倒的**,Settings 里亮度**仍然是 8**。这证明设置存住了。
5. 把「Rotate 180°」关掉,屏幕恢复正常。

任何一条不符就停下汇报,不要绕过。

- [ ] **Step 6: 更新 README 里的旋转说明(如有需要)**

Run: `grep -rn "rotate\|旋转\|Rotate" README.md README.en.md`

如果文档里描述了旋转开关或 `--rotate` 参数的行为,按新语义更正(`--rotate` 现在是真的旋转;不带它是不旋转)。若两个 README 都没提,跳过这步,不要为此新增章节。

- [ ] **Step 7: 提交并汇总**

如有 README 改动:

```bash
git add README.md README.en.md
git commit -m "docs: correct the rotation flag's described behavior"
```

然后汇报:测试条数与结果、真机三条验收的实际观察、以及 README 是否需要改。

---

## 自查记录

- **规格覆盖:** 设计文档的四节改动分别落在 Task 1(旋转语义)、Task 2 + 3(持久化)、Task 4(删死代码);测试两组落在 Task 1 和 Task 2;三条验收标准落在 Task 5。设计文档里「不做的事」三条已写进 Global Constraints。
- **命名一致性:** `DisplaySettings` / `Preferences` / `load()` / `save(_:)` / `Preferences.Key` / `withThrowawayStore` 在 Task 2 定义,Task 3 沿用同名;`JPEGEncoder.encode` 的新签名在 Task 1 的 Interfaces 里写明,Task 3 通过 `AppState` 间接使用。
- **`SettingsView` 无需改动:** 那句提示「Enable if display appears upside down」在新语义下依然正确 —— 默认不旋转,谁的散热器装反了就打开开关。已核对,不列为任务。

自查时改掉的四处:

1. **Task 3 的改动原本是空的。** 属性块改前改后只差一句注释,等于让人白改一遍。改成真正去掉那三个内联默认值 —— 否则"新装是什么样"有两个说法(属性内联值和 `DisplaySettings.default`),迟早对不上。
2. **测试里 `try` 塞在 `#expect` 里面。** `#expect(try f(x) == y)` 依赖宏怎么处理 `try`,没必要冒这个险。改成先 `let decoded = try decode(jpeg)` 再断言。`decode` 内部也从 `#require` 换成普通抛错,免去"宏能不能在非测试函数里用"的疑问。
3. **Task 5 原本用裸二进制验证持久化,这条验收会不可靠。** 裸二进制没有 bundle,设置存到哪个域名不确定。改成用 `packaging/build-app.sh` 打包后的 .app —— 标识符确定(`com.m1ngli.MacTRAI`,已核对 Info.plist),而且那才是用户真正跑的东西。
4. **`Corner` 挂了个用不上的 `CaseIterable`。** 去掉。
