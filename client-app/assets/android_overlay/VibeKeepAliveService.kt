package __VIBEHELPER_PACKAGE__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Lightweight ForegroundService to prevent MIUI / HyperOS from freezing WebSocket sync
 * and background notifications when VibeHelper is in background.
 */
class VibeKeepAliveService : Service() {
    companion object {
        const val CHANNEL_ID = "vibehelper_keepalive"
        const val NOTIF_ID = 2001
        const val ACTION_START = "vibehelper.keepalive.START"
        const val ACTION_STOP = "vibehelper.keepalive.STOP"
        const val EXTRA_SUBTITLE = "subtitle"

        fun start(context: Context, subtitle: String = "正在后台保持宿主机实时连接") {
            val intent = Intent(context, VibeKeepAliveService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_SUBTITLE, subtitle)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
            }
        }

        fun stop(context: Context) {
            try {
                val intent = Intent(context, VibeKeepAliveService::class.java).apply {
                    action = ACTION_STOP
                }
                context.stopService(intent)
            } catch (_: Throwable) {
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()
        val subtitle = intent?.getStringExtra(EXTRA_SUBTITLE)
            ?.takeIf { it.isNotBlank() }
            ?: "正在后台保持宿主机实时连接"
        val notif = buildNotification(subtitle)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIF_ID,
                    notif,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (_: Throwable) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VibeHelper 后台保活",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持与电脑宿主机的长连接与中岛实时状态同步"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(subtitle: String): Notification {
        val iconRes = applicationInfo.icon.let {
            if (it != 0) it else android.R.drawable.stat_notify_sync
        }
        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        val contentPi = if (launchIntent != null) {
            PendingIntent.getActivity(this, 2002, launchIntent, piFlags)
        } else {
            null
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        builder
            .setSmallIcon(iconRes)
            .setContentTitle("VibeHelper 后台连接运行中")
            .setContentText(subtitle)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
        if (contentPi != null) {
            builder.setContentIntent(contentPi)
        }
        return builder.build()
    }
}
