package __VIBEHELPER_PACKAGE__

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings

class SystemNotificationManager(private val context: Context) {
    companion object {
        const val CHANNEL_ID = "vibehelper_agent_alerts"
        private const val CHANNEL_NAME = "VibeHelper Agent 消息通知"
        private const val CHANNEL_DESC = "Agent 回复完成、授权审批请求与交互提问提醒"
        private const val REQ_CODE_POST_NOTIF = 10086
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    init {
        ensureChannel()
    }

    fun actionBroadcastName(): String = "${context.packageName}.VIBEHELPER_NOTIF_ACTION"

    fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = notificationManager ?: return
            val existing = nm.getNotificationChannel(CHANNEL_ID)
            if (existing != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = CHANNEL_DESC
                enableVibration(true)
                vibrationPattern = longArrayOf(0L, 180L, 100L, 180L)
                enableLights(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setShowBadge(true)
            }
            nm.createNotificationChannel(channel)
        }
    }

    fun canPostNotifications(): Boolean {
        val nm = notificationManager ?: return false
        val enabled = nm.areNotificationsEnabled()
        if (!enabled) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    fun requestNotificationPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                activity.requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQ_CODE_POST_NOTIF
                )
                return
            }
        }
        if (notificationManager?.areNotificationsEnabled() != true) {
            openNotificationSettings(activity)
        }
    }

    fun openNotificationSettings(activity: Activity) {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                }
            } else {
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${context.packageName}")
                )
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
        } catch (_: Throwable) {
            try {
                val fallback = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:${context.packageName}")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                activity.startActivity(fallback)
            } catch (_: Throwable) {
            }
        }
    }

    fun showNotification(
        id: Int,
        title: String,
        body: String,
        showActions: Boolean
    ) {
        if (!canPostNotifications()) return
        val nm = notificationManager ?: return
        ensureChannel()

        val iconRes = context.applicationInfo.icon.let {
            if (it != 0) it else android.R.drawable.stat_notify_chat
        }

        val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        val contentPi = if (launchIntent != null) {
            PendingIntent.getActivity(context, 2001, launchIntent, piFlags)
        } else {
            null
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_ALL)
        }

        builder
            .setSmallIcon(iconRes)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)

        if (contentPi != null) {
            builder.setContentIntent(contentPi)
        }

        if (showActions) {
            builder.addAction(makeBroadcastAction(id, "accept", "允许", 3001, piFlags))
            builder.addAction(makeBroadcastAction(id, "reject", "拒绝", 3002, piFlags))
        }

        try {
            nm.notify(id, builder.build())
        } catch (_: Throwable) {
        }
    }

    fun cancelNotification(id: Int) {
        try {
            notificationManager?.cancel(id)
        } catch (_: Throwable) {
        }
    }

    private fun makeBroadcastAction(
        notifId: Int,
        actionKey: String,
        label: String,
        reqCode: Int,
        piFlags: Int
    ): Notification.Action {
        val intent = Intent(actionBroadcastName()).apply {
            setPackage(context.packageName)
            putExtra("action", actionKey)
            putExtra("notif_id", notifId)
        }
        val pi = PendingIntent.getBroadcast(context, reqCode, intent, piFlags)
        return Notification.Action.Builder(null, label, pi).build()
    }
}
