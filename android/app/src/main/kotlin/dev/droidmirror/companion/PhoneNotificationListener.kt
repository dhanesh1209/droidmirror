package dev.droidmirror.companion

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/** Forwards phone notifications to the Mac and carries out reply/dismiss/click requests coming back. */
class PhoneNotificationListener : NotificationListenerService() {
    // Keys of notifications we actually sent, so we only report dismissals the Mac knows about.
    private val forwardedKeys = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    override fun onListenerConnected() {
        instance = this
        // After a reboot the system rebinds this service; make sure the link service is running too.
        if (Settings(this).load() != null) {
            try {
                startForegroundService(Intent(this, ConnectionService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "could not start link service: ${e.javaClass.simpleName}")
            }
        }
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val n = sbn.notification
        // Skip our own notifications, except the debug test notification used to verify reply from the Mac.
        if (sbn.packageName == packageName && !n.extras.getBoolean(TEST_EXTRA)) return
        val f = n.flags
        if (f and Notification.FLAG_ONGOING_EVENT != 0 ||
            f and Notification.FLAG_FOREGROUND_SERVICE != 0 ||
            f and Notification.FLAG_GROUP_SUMMARY != 0
        ) return
        if (n.visibility == Notification.VISIBILITY_SECRET) return

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()?.ifEmpty { null }
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString()?.trim()?.ifEmpty { null }
        if (title == null && text == null) return

        forwardedKeys.add(sbn.key)
        Bridge.send(
            Protocol.notification(sbn.key, sbn.packageName, appLabel(sbn), title, text, sbn.postTime / 1000.0, replyAction(n) != null)
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (forwardedKeys.remove(sbn.key)) Bridge.send(Protocol.dismissed(sbn.key))
    }

    /** Called from the connection service when the Mac asks to act on a notification. */
    fun handleAction(key: String, kind: String, text: String?) {
        val sbn = try {
            getActiveNotifications(arrayOf(key)).firstOrNull()
        } catch (e: SecurityException) {
            null
        } ?: return
        when (kind) {
            "dismiss" -> cancelNotification(key)
            "click" -> try { sbn.notification.contentIntent?.send() } catch (_: PendingIntent.CanceledException) { }
            "reply" -> if (text != null) reply(sbn.notification, text)
        }
    }

    private fun replyAction(n: Notification): Notification.Action? =
        n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

    private fun reply(n: Notification, text: String) {
        val action = replyAction(n) ?: return
        val inputs = action.remoteInputs
        val results = Bundle()
        for (input in inputs) results.putCharSequence(input.resultKey, text)
        val intent = Intent()
        RemoteInput.addResultsToIntent(inputs, intent, results)
        try {
            action.actionIntent.send(this, 0, intent)
        } catch (_: PendingIntent.CanceledException) {
        }
    }

    @Suppress("DEPRECATION")
    private fun appLabel(sbn: StatusBarNotification): String {
        val extras = sbn.notification.extras
        val info = if (Build.VERSION.SDK_INT >= 33) {
            extras.getParcelable("android.appInfo", ApplicationInfo::class.java)
        } else {
            extras.getParcelable<ApplicationInfo>("android.appInfo")
        }
        return info?.loadLabel(packageManager)?.toString() ?: sbn.packageName
    }

    companion object {
        private const val TAG = "DroidMirror"
        const val TEST_EXTRA = "dm_test"
        @Volatile var instance: PhoneNotificationListener? = null
    }
}
