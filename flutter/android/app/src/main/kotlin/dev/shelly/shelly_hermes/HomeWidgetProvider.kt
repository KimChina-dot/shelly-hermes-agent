package dev.shelly.shelly_hermes

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject

/** Cached widget snapshot: last conversation title + conversation count. */
data class WidgetState(val title: String?, val count: Int)

/**
 * Home-screen widget (PHASE 42). Renders the last conversation title and
 * the conversation count from a small JSON snapshot the app persists in
 * SharedPreferences ([STATE_PREFS], key [STATE_KEY]) through the
 * `dev.shelly/hermes_widget` channel (see MainActivity `pushUpdate`).
 * Tapping the widget opens the launcher activity with extra
 * [ACTION_EXTRA]=[ACTION_OPEN]; MainActivity forwards it to Flutter.
 */
class HomeWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        val state = readState(context)
        for (appWidgetId in appWidgetIds) {
            manager.updateAppWidget(appWidgetId, render(context, state))
        }
    }

    companion object {
        /** SharedPreferences file holding the JSON widget snapshot. */
        const val STATE_PREFS = "shelly.widget.state"

        /** Key inside [STATE_PREFS] holding the JSON snapshot. */
        const val STATE_KEY = "payload"

        /** Intent extra MainActivity forwards to Flutter when the widget is tapped. */
        const val ACTION_EXTRA = "shelly_action"

        /** Value of [ACTION_EXTRA]: open the app on the chat tab. */
        const val ACTION_OPEN = "open"

        /** Reads the cached snapshot; missing or corrupt state renders empty defaults. */
        fun readState(context: Context): WidgetState {
            val prefs = context.getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
            val raw = prefs.getString(STATE_KEY, null) ?: return WidgetState(null, 0)
            return try {
                val json = JSONObject(raw)
                WidgetState(
                    title = json.optString("lastConversationTitle", "").ifBlank { null },
                    count = json.optInt("conversationCount", 0),
                )
            } catch (e: Exception) {
                WidgetState(null, 0)
            }
        }

        /** Builds the RemoteViews for one widget instance. */
        fun render(context: Context, state: WidgetState): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_home)
            views.setTextViewText(R.id.widget_title, state.title ?: "还没有对话")
            views.setTextViewText(
                R.id.widget_count,
                if (state.count > 0) "${state.count} 条对话" else "开始新的对话",
            )
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra(ACTION_EXTRA, ACTION_OPEN)
            }
            val pending = PendingIntent.getActivity(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root, pending)
            return views
        }

        /** Repaints every placed widget from the cached snapshot. */
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(context, HomeWidgetProvider::class.java))
            val state = readState(context)
            for (appWidgetId in ids) {
                manager.updateAppWidget(appWidgetId, render(context, state))
            }
        }
    }
}
