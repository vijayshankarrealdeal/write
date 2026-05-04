# iOS Home-Screen Widget — Xcode setup

Apple's WidgetKit requires a separate target inside the Xcode project, and Xcode's project file format isn't safe to edit by hand. Run through this list **once** in Xcode after pulling the changes; after that, the widget is built every time the iOS app builds.

## 1. Add the Widget Extension target

1. Open `ios/Runner.xcworkspace` in Xcode.
2. **File → New → Target… → Widget Extension**. Configure:
   - **Product Name**: `InkSpaceXWidget`
   - **Bundle Identifier**: `com.inkspacex.app.InkSpaceXWidget`
   - **Include Configuration Intent**: **off**
   - **Embed in Application**: `Runner`
3. When Xcode creates the target it will scaffold a folder with `InkSpaceXWidget.swift` and `Info.plist`. **Replace those scaffolded files with the ones already in this folder** (`InkSpaceXWidget.swift` + `Info.plist`) — keep Xcode's target wiring, just point the file references at the existing files on disk if needed.

## 2. Wire the App Group entitlement

The Dart side writes data into the App Group `group.com.inkspacex.app.widget`; both the Runner app and the widget extension need that group enabled.

1. Select the `Runner` target → **Signing & Capabilities** → **+ Capability** → **App Groups** → tick / add `group.com.inkspacex.app.widget`. Use `Runner.entitlements` (already in this folder).
2. Repeat for the `InkSpaceXWidget` target, pointing it at `InkSpaceXWidget.entitlements` in this folder.

## 3. URL scheme

`Runner/Info.plist` already declares the `inkspacex://` scheme so widget taps re-launch the app. Nothing to do here unless you change the scheme.

## 4. Build and run

`flutter run -d <device>` from the project root. Long-press the home screen → **Add Widget** → search for "InkSpaceX".
