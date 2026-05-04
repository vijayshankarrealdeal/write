// InkSpaceXWidget.swift
//
// WidgetKit extension that paints the InkSpaceX home-screen widget on
// iOS 14+. Data comes from the shared App Group container that
// HomeWidgetService writes from Dart — see
// `lib/services/home_widget_service.dart`.

import WidgetKit
import SwiftUI

// MARK: - Shared payload

private let appGroupId = "group.com.inkspacex.app.widget"
private let userDefaultsPrefix = "" // home_widget plugin writes plain keys

private struct InkPayload {
    let author: String
    let recentTitle: String
    let recentSubtitle: String
    let recentId: String
    let bookCount: Int
    let updatedAt: Date

    static let placeholder = InkPayload(
        author: "Writer",
        recentTitle: "Start a new story",
        recentSubtitle: "Tap to start writing",
        recentId: "",
        bookCount: 0,
        updatedAt: Date()
    )

    static func read() -> InkPayload {
        let defaults = UserDefaults(suiteName: appGroupId)
        let author = defaults?.string(forKey: "author") ?? "Writer"
        let recentTitle = defaults?.string(forKey: "recent_title")
            ?? "Start a new story"
        let recentSubtitle = defaults?.string(forKey: "recent_subtitle")
            ?? "Tap to start writing"
        let recentId = defaults?.string(forKey: "recent_id") ?? ""
        let bookCount = defaults?.integer(forKey: "book_count") ?? 0
        let updatedRaw = defaults?.string(forKey: "updated_at")
        let updatedAt: Date
        if let raw = updatedRaw,
           let parsed = ISO8601DateFormatter().date(from: raw) {
            updatedAt = parsed
        } else {
            updatedAt = Date()
        }
        return InkPayload(
            author: author,
            recentTitle: recentTitle,
            recentSubtitle: recentSubtitle,
            recentId: recentId,
            bookCount: bookCount,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Timeline provider

struct InkProvider: TimelineProvider {
    func placeholder(in context: Context) -> InkEntry {
        InkEntry(date: Date(), payload: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (InkEntry) -> Void) {
        completion(InkEntry(date: Date(), payload: InkPayload.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InkEntry>) -> Void) {
        let entry = InkEntry(date: Date(), payload: InkPayload.read())
        // Refresh every 30 minutes — the Dart side also pushes
        // explicit updates whenever drafts change, so this is just a
        // safety net for stale data.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct InkEntry: TimelineEntry {
    let date: Date
    let payload: InkPayload
}

// MARK: - Views

struct InkWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: InkProvider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            small
        default:
            medium
        }
    }

    private var greetingName: String {
        let first = entry.payload.author.split(separator: " ").first.map(String.init)
        return first?.isEmpty == false ? first! : "Writer"
    }

    private var draftCountText: String {
        let n = entry.payload.bookCount
        if n == 1 { return "1 draft" }
        return "\(n) drafts"
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.04, green: 0.04, blue: 0.04),
                     Color(red: 0.13, green: 0.13, blue: 0.13)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var small: some View {
        ZStack(alignment: .leading) {
            background
            VStack(alignment: .leading, spacing: 4) {
                Text("Hi, \(greetingName)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer(minLength: 0)
                Text(entry.payload.recentTitle)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundColor(.white)
                    .lineLimit(3)
                Spacer(minLength: 0)
                Text(draftCountText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(14)
        }
        .widgetURL(URL(string: deepLinkForRecent()))
    }

    @ViewBuilder
    private var medium: some View {
        ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hi, \(greetingName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Text(draftCountText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                Text(entry.payload.recentTitle)
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(entry.payload.recentSubtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Link(destination: URL(string: "inkspacex://editor?new=1")!) {
                        Text("+ New writing")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(16)
        }
        .widgetURL(URL(string: deepLinkForRecent()))
    }

    private func deepLinkForRecent() -> String {
        if entry.payload.recentId.isEmpty {
            return "inkspacex://home"
        }
        return "inkspacex://editor?id=\(entry.payload.recentId)"
    }
}

// MARK: - Widget configuration

@main
struct InkSpaceXWidgetBundle: WidgetBundle {
    var body: some Widget {
        InkSpaceXWidget()
    }
}

struct InkSpaceXWidget: Widget {
    let kind: String = "InkSpaceXWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkProvider()) { entry in
            if #available(iOS 17.0, macOS 14.0, *) {
                InkWidgetEntryView(entry: entry)
                    .containerBackground(for: .widget) { Color.black }
            } else {
                InkWidgetEntryView(entry: entry)
                    .background(Color.black)
            }
        }
        .configurationDisplayName("InkSpaceX")
        .description("Pick up your latest draft from the home screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
