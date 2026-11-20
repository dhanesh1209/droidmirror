package dev.droidmirror.companion

import org.json.JSONObject

/** JSON messages, matching CompanionMessages.swift (one flat envelope with a `type` field). */
object Protocol {
    const val VERSION = 1

    fun hello(name: String): JSONObject = JSONObject().put("type", "hello").put("name", name).put("v", VERSION)

    fun pong(): JSONObject = JSONObject().put("type", "pong")

    fun dismissed(key: String): JSONObject = JSONObject().put("type", "dismissed").put("key", key)

    fun notification(
        key: String, pkg: String, app: String, title: String?, text: String?, postedAt: Double, canReply: Boolean,
    ): JSONObject {
        val n = JSONObject().put("key", key).put("pkg", pkg).put("app", app).put("postedAt", postedAt).put("canReply", canReply)
        if (title != null) n.put("title", title)
        if (text != null) n.put("text", text)
        return JSONObject().put("type", "notification").put("n", n)
    }
}
