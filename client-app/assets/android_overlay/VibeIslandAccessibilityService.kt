package __VIBEHELPER_PACKAGE__

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.content.Intent
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent

/**
 * AccessibilityService providing TYPE_ACCESSIBILITY_OVERLAY window layer (same mechanism used
 * by GitHub Dynamic Island apps like dynamicSpot) so the pill sits cleanly over the punch-hole
 * status bar and receives taps without SystemUI stealing them.
 */
class VibeIslandAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: VibeIslandAccessibilityService? = null
            private set

        var onConnectionChanged: ((Boolean) -> Unit)? = null

        fun isEnabled(): Boolean = instance != null

        fun openAccessibilitySettings(activity: Activity) {
            try {
                val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                activity.startActivity(intent)
            } catch (_: Throwable) {
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        onConnectionChanged?.invoke(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Not used; this service only supplies the TYPE_ACCESSIBILITY_OVERLAY layer.
    }

    override fun onInterrupt() {
        // No-op
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (instance === this) {
            instance = null
            onConnectionChanged?.invoke(false)
        }
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
            onConnectionChanged?.invoke(false)
        }
        super.onDestroy()
    }
}
