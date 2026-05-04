# macOS Home-Screen Widget — Xcode setup

macOS WidgetKit, like iOS, requires a separate target inside the Xcode project. Run through this list **once** in Xcode after pulling the changes; after that, the widget is built every time the macOS app builds.

## 1. Add the Widget Extension target

1. Open `macos/Runner.xcworkspace` in Xcode.
2. **File → New → Target… → macOS Widget Extension**. Configure:
   - **Product Name**: `InkSpaceXWidget`
   - **Bundle Identifier**: `com.inkspacex.app.InkSpaceXWidget`
   - **Include Configuration Intent**: **off**
   - **Embed in Application**: `Runner`
3. Replace Xcode's scaffolded `InkSpaceXWidget.swift` and `Info.plist` with the ones already in this folder.
4. Confirm the deployment target is **macOS 11.0** or later (WidgetKit requirement).

## 2. App Group entitlements

Both targets must be in `group.com.inkspacex.app.widget`.

1. `Runner` target → **Signing & Capabilities** → **+ Capability** → **App Groups** → tick `group.com.inkspacex.app.widget`. The Debug + Release entitlements files (`macos/Runner/DebugProfile.entitlements`, `macos/Runner/Release.entitlements`) already declare the group — Xcode just needs to surface the capability.
2. `InkSpaceXWidget` target → same capability, pointing at `InkSpaceXWidget.entitlements` in this folder.

## 3. URL scheme

`Runner/Info.plist` already declares the `inkspacex://` scheme so widget taps re-launch the app. Nothing to do here unless you change the scheme.

## 4. Build and run

`flutter run -d macos` from the project root. After the app launches, open Notification Centre → **Edit Widgets** → drag in the InkSpaceX widget. On macOS 14+ you can also drop it directly onto the desktop.
