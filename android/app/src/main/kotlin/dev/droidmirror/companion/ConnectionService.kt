package dev.droidmirror.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom

/** Foreground service that keeps the encrypted link to the Mac alive and reconnects when it drops. */
class ConnectionService : Service() {
    @Volatile private var running = false
    private var thread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundNotification()
        if (!running) {
            running = true
            thread = Thread(::runLoop, "droidmirror-link").also { it.isDaemon = true; it.start() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        Bridge.session?.close()
        thread?.interrupt()
        Bridge.status = "Stopped"
        super.onDestroy()
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Link to your Mac", NotificationManager.IMPORTANCE_MIN))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("DroidMirror")
            .setContentText("Linked to your Mac")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun runLoop() {
        var backoffMs = 1000L
        while (running) {
            val config = Settings(this).load()
            if (config == null) {
                Bridge.status = "Not paired"
                sleepQuietly(2000)
                continue
            }
            try {
                Bridge.status = "Connecting to ${config.macName}…"
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(config.host, config.port), 5000)
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    // The Mac pings every 15 s. If nothing arrives for 45 s the link is dead (a half-open
                    // connection never raises an error on its own), so the read times out and we reconnect.
                    socket.soTimeout = 45_000
                    val input = DataInputStream(socket.getInputStream())
                    val macSalt = ByteArray(CompanionChannel.SALT_LENGTH).also { input.readFully(it) }
                    val phoneSalt = ByteArray(CompanionChannel.SALT_LENGTH).also { SecureRandom().nextBytes(it) }
                    socket.getOutputStream().apply { write(phoneSalt); flush() }
                    val channel = CompanionChannel(config.secret, macSalt, phoneSalt, isPhone = true)
                    val session = Session(socket, channel)
                    Bridge.session = session
                    session.send(Protocol.hello(Build.MODEL))
                    Bridge.status = "Connected to ${config.macName}"
                    backoffMs = 1000L
                    while (running) handle(channel.open(CompanionChannel.readBody(input)))
                }
            } catch (e: Exception) {
                // Never log message contents; the error type is enough to debug the link.
                Log.w(TAG, "link ended: ${e.javaClass.simpleName}")
            } finally {
                Bridge.session = null
                if (running) Bridge.status = "Reconnecting…"
            }
            sleepQuietly(backoffMs)
            backoffMs = minOf(backoffMs * 2, 30_000L)
        }
    }

    private fun handle(payload: ByteArray) {
        val msg = JSONObject(String(payload, Charsets.UTF_8))
        when (msg.optString("type")) {
            "ping" -> Bridge.send(Protocol.pong())
            "action" -> PhoneNotificationListener.instance?.handleAction(
                msg.optString("key"), msg.optString("kind"), if (msg.has("text")) msg.getString("text") else null,
            )
        }
    }

    private fun sleepQuietly(ms: Long) {
        try { Thread.sleep(ms) } catch (_: InterruptedException) { }
    }

    companion object {
        private const val TAG = "DroidMirror"
        private const val CHANNEL_ID = "link"
        private const val NOTIFICATION_ID = 1
    }
}
