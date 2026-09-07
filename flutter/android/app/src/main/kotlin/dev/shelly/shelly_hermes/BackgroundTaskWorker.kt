package dev.shelly.shelly_hermes

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray

/**
 * Periodic check for due scheduled agent tasks (PHASE 45).
 *
 * Native code cannot reach the Dart runtime, so this worker does not run
 * the model — its only job is to make the user aware: when entries in the
 * `shelly.sched.bgstate` SharedPreferences (written by Dart) are overdue,
 * it posts a notification whose tap launches the app with the
 * [ACTION_BG_CATCHUP] extra (routed to Flutter over `dev.shelly/bg_tasks`),
 * and stamps the `shelly.sched.bgseen` marker.
 */
class BackgroundTaskWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val prefs = applicationContext
            .getSharedPreferences(STATE_PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(BG_STATE_KEY, null) ?: return@withContext Result.success()
        val now = System.currentTimeMillis()
        val due = try {
            countDue(raw, now)
        } catch (e: Exception) {
            // Corrupt state is Dart's problem to fix; never crash the worker.
            0
        }
        if (due > 0) {
            prefs.edit().putLong(BG_SEEN_KEY, now).apply()
            notifyDue(due)
        }
        Result.success()
    }

    /** Counts entries whose `at` is in the past (any repeat mode qualifies). */
    private fun countDue(raw: String, now: Long): Int {
        val array = JSONArray(raw)
        var due = 0
        for (i in 0 until array.length()) {
            val entry = array.optJSONObject(i) ?: continue
            if (entry.optLong("at") <= now) due++
        }
        return due
    }

    private fun notifyDue(count: Int) {
        val context = applicationContext
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "定时任务提醒",
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            // The user declined notifications; the in-app catch-up tick
            // still runs on next open, nothing else we can do from here.
            return
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return
        launch.putExtra(ACTION_BG_CATCHUP, true)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(
            context,
            REQUEST_CODE,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Shelly 定时任务")
            .setContentText("$count 个定时任务待执行,点击打开")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    companion object {
        const val STATE_PREFS = "shelly_native"
        const val BG_STATE_KEY = "shelly.sched.bgstate"
        const val BG_SEEN_KEY = "shelly.sched.bgseen"
        const val ACTION_BG_CATCHUP = "shelly_bg_catchup"
        const val CHANNEL_ID = "shelly_bg"
        const val UNIQUE_WORK_NAME = "shelly-bg-checks"
        private const val NOTIFICATION_ID = 4602
        private const val REQUEST_CODE = 4603

        /** Enqueues (or re-arms) the periodic due-task check. */
        fun schedule(context: Context, intervalMinutes: Int) {
            val request = PeriodicWorkRequestBuilder<BackgroundTaskWorker>(
                intervalMinutes.toLong().coerceAtLeast(15), TimeUnit.MINUTES,
            ).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                UNIQUE_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request,
            )
        }

        /** Removes the periodic check. */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK_NAME)
        }
    }
}
