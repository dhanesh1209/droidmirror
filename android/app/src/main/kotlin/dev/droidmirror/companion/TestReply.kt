package dev.droidmirror.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Bundle
import android.util.Log

/**
 * Debug-only helper: posts a notification with a reply box, so reply-from-Mac can be tested end to end
 * without a chat app or a second person. Replying updates the notification to "Reply received" with the text,
 * which comes back to the Mac as a new notification. Only reachable from debuggable builds (see MainActivity).
 */
object TestReply {
    private const val CHANNEL = "test"
    private const val ID = 99
    const val KEY_REPLY = "reply_text"

    fun post(context: Context) = show(context, "DroidMirror test", "Reply to this from your Mac")

    fun show(context: Context, title: String, text: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Test notifications", NotificationManager.IMPORTANCE_DEFAULT))
        val input = RemoteInput.Builder(KEY_REPLY).setLabel("Reply").build()
        val pending = PendingIntent.getBroadcast(
            context, 0, Intent(context, TestReplyReceiver::class.java),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val action = Notification.Action.Builder(Icon.createWithResource(context, android.R.drawable.ic_menu_send), "Reply", pending)
            .addRemoteInput(input)
            .build()
        val extras = Bundle().apply { putBoolean(PhoneNotificationListener.TEST_EXTRA, true) }
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(text)
            .addAction(action)
            .addExtras(extras)
            .build()
        nm.notify(ID, notification)
    }
}

class TestReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(TestReply.KEY_REPLY)?.toString() ?: return
        Log.i("DroidMirror", "test reply received, length=${reply.length}")
        TestReply.show(context, "Reply received", reply)
    }
}
