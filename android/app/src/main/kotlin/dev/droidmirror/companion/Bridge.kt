package dev.droidmirror.companion

import org.json.JSONObject
import java.io.IOException
import java.net.Socket
import java.util.concurrent.Executors

/** One live, encrypted connection to the Mac. Writes are serialized so sequence numbers stay in order. */
class Session(private val socket: Socket, private val channel: CompanionChannel) {
    private val out = socket.getOutputStream()

    @Synchronized
    fun send(json: JSONObject) {
        out.write(channel.seal(json.toString().toByteArray(Charsets.UTF_8)))
        out.flush()
    }

    fun close() {
        try { socket.close() } catch (_: IOException) { }
    }
}

/** Shared state between the connection service, the notification listener and the UI. */
object Bridge {
    @Volatile var session: Session? = null
    @Volatile var status: String = "Not connected"

    // Network I/O must never run on the main thread, and one thread keeps messages ordered.
    private val executor = Executors.newSingleThreadExecutor()

    fun send(json: JSONObject) {
        executor.execute {
            val s = session ?: return@execute
            try { s.send(json) } catch (e: IOException) { s.close() }
        }
    }
}
