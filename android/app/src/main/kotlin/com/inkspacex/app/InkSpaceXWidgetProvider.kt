package com.inkspacex.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Home-screen widget that shows the user's most recent draft and a
 * "New writing" CTA. Tapping the body opens the draft directly via
 * deep link (`inkspacex://editor?id=<id>`); tapping the new-writing
 * button opens the editor on a blank canvas.
 *
 * Data is written from Dart by HomeWidgetService — see
 * lib/services/home_widget_service.dart.
 */
class InkSpaceXWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = HomeWidgetPlugin.getData(context)
        val author = prefs.getString("author", "Writer") ?: "Writer"
        val recentTitle = prefs.getString("recent_title", "Start a new story")
            ?: "Start a new story"
        val recentSubtitle = prefs.getString("recent_subtitle", "Tap to start writing")
            ?: "Tap to start writing"
        val recentId = prefs.getString("recent_id", "") ?: ""
        val bookCount = prefs.getInt("book_count", 0)

        for (widgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.inkspacex_widget)
            views.setTextViewText(R.id.widget_greeting, "Hi, ${shortName(author)}")
            views.setTextViewText(R.id.widget_title, recentTitle)
            views.setTextViewText(R.id.widget_subtitle, recentSubtitle)
            views.setTextViewText(
                R.id.widget_count,
                if (bookCount == 1) "1 draft" else "$bookCount drafts"
            )

            val openRecentUri = if (recentId.isNotEmpty()) {
                Uri.parse("inkspacex://editor?id=$recentId")
            } else {
                Uri.parse("inkspacex://home")
            }
            val openRecentIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                openRecentUri
            )
            views.setOnClickPendingIntent(R.id.widget_root, openRecentIntent)

            val newWritingIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("inkspacex://editor?new=1")
            )
            views.setOnClickPendingIntent(R.id.widget_new_button, newWritingIntent)

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun shortName(full: String): String {
        val first = full.trim().split(" ").firstOrNull() ?: "Writer"
        return if (first.isEmpty()) "Writer" else first
    }
}
