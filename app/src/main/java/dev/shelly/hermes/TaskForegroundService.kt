package dev.shelly.hermes

import android.app.*
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat

class TaskForegroundService : Service() {
    override fun onCreate() { super.onCreate(); val channel = NotificationChannel(CHANNEL, "任务执行", NotificationManager.IMPORTANCE_LOW); getSystemService(NotificationManager::class.java).createNotificationChannel(channel) }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int { val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE); startForeground(7, NotificationCompat.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("Shelly Hermes 正在执行任务").setContentText("可返回应用查看进度或审批").setOngoing(true).setContentIntent(open).build()); FileSessionStore(this).save(Session("active", "前台任务", System.currentTimeMillis())); return START_STICKY }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object { const val CHANNEL = "hermes_tasks" }
}
