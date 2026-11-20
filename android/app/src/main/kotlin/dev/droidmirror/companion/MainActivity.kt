package dev.droidmirror.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import android.util.TypedValue
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode

/** Pairing and status screen. Plain views on purpose: no UI framework dependency for v1. */
class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val refresher = object : Runnable {
        override fun run() { refresh(); handler.postDelayed(this, 1000) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()
        handleDevPairing(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDevPairing(intent)
    }

    override fun onResume() { super.onResume(); refresher.run() }
    override fun onPause() { super.onPause(); handler.removeCallbacks(refresher) }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()
    private fun color(id: Int) = resources.getColor(id, theme)

    private lateinit var headline: TextView
    private lateinit var checklist: TextView

    private fun rounded(fill: Int, stroke: Int? = null) = android.graphics.drawable.GradientDrawable().apply {
        cornerRadius = dp(12).toFloat()
        setColor(fill)
        if (stroke != null) setStroke(dp(1), stroke)
    }

    private fun buildUi() {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(24), dp(16), dp(24))
        }
        fun text(s: String, sizeSp: Float, bold: Boolean = false, secondary: Boolean = false) = TextView(this).apply {
            this.text = s; textSize = sizeSp
            setTextColor(color(if (secondary) R.color.dm_text_secondary else R.color.dm_text))
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, dp(4), 0, dp(4))
        }
        fun section(s: String) = text(s, 16f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) }
        fun button(label: String, primary: Boolean = false, onClick: () -> Unit) = Button(this).apply {
            text = label; isAllCaps = false; textSize = 15f
            minHeight = dp(48)
            stateListAnimator = null
            setTextColor(if (primary) 0xFFFFFFFF.toInt() else color(R.color.dm_accent))
            background = if (primary) rounded(color(R.color.dm_accent).let { if (resources.configuration.uiMode and 0x30 == 0x20) 0xFF1A73E8.toInt() else it })
                         else rounded(color(R.color.dm_bg), color(R.color.dm_outline))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) }
            setOnClickListener { onClick() }
        }

        column.addView(text("DroidMirror", 28f, bold = true))
        column.addView(text("Sends your phone’s notifications to your Mac over your own Wi-Fi, encrypted. No USB debugging needed.", 14f, secondary = true))

        // Status card first: one headline, then the checklist.
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(color(R.color.dm_surface))
            setPadding(dp(16), dp(12), dp(16), dp(12))
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(16) }
        }
        headline = text("", 18f, bold = true)
        checklist = text("", 14f, secondary = true).apply { setLineSpacing(dp(4).toFloat(), 1f) }
        card.addView(headline)
        card.addView(checklist)
        column.addView(card)

        column.addView(section("1. Pair with your Mac"))
        column.addView(button("Scan QR code from your Mac", primary = true) { scanQr() })
        column.addView(button("Paste pairing code instead") { pasteCode() })

        column.addView(section("2. Allow notification access"))
        column.addView(button("Open notification access settings") { open(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS) })
        column.addView(text("Installed outside the Play Store? Android 13 and later may say “Restricted setting”. Open App info, tap the ⋮ menu and choose “Allow restricted settings”, then try again.", 13f, secondary = true))
        column.addView(button("Open App info") { openAppInfo() })

        column.addView(section("3. Keep it running"))
        column.addView(button("Battery optimization settings") { open(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS) })
        column.addView(button("Start link now") { startLink() })
        column.addView(button("Stop link") { stopService(Intent(this, ConnectionService::class.java)) })

        column.addView(section("Pairing"))
        column.addView(button("Forget this Mac") { forget() })

        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            column.addView(section("Developer (debug build only)"))
            column.addView(button("Post test notification with reply box") { postTestReply() })
        }
        // Edge-to-edge is enforced on Android 15+, so pad by the system bars or the last buttons hide under the gesture bar.
        val scroll = ScrollView(this).apply {
            addView(column)
            setBackgroundColor(color(R.color.dm_bg))
            clipToPadding = false
            setOnApplyWindowInsetsListener { v, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                v.setPadding(0, bars.top, 0, bars.bottom)
                insets
            }
        }
        setContentView(scroll)
    }

    private fun refresh() {
        val cfg = Settings(this).load()
        val access = isListenerEnabled()
        val batteryUnrestricted = getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName)
        val connected = Bridge.status.startsWith("Connected")
        val ready = cfg != null && access && connected
        headline.text = when {
            ready -> "Connected to ${cfg!!.macName}"
            cfg == null -> "Not paired yet"
            else -> "Needs attention"
        }
        headline.setTextColor(color(if (ready) R.color.dm_ok else R.color.dm_attention))
        // A live checklist: everything should show a tick for notifications to flow.
        checklist.text = buildString {
            append(if (cfg != null) "✓ Paired with ${cfg.macName}\n" else "✗ Not paired: scan the QR code from your Mac (step 1)\n")
            append(if (access) "✓ Notification access is on\n" else "✗ Notification access is off (step 2)\n")
            append(if (connected) "✓ Link is up\n" else "• Link: ${Bridge.status}\n")
            append(if (batteryUnrestricted) "✓ Battery: unrestricted" else "• Battery: Android may stop the link (step 3)")
        }
    }

    private fun isListenerEnabled(): Boolean =
        android.provider.Settings.Secure.getString(contentResolver, "enabled_notification_listeners")?.contains(packageName) == true

    private fun open(action: String) {
        try { startActivity(Intent(action)) } catch (e: Exception) { toast("Could not open settings") }
    }

    private fun openAppInfo() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    private fun scanQr() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode -> handlePayload(barcode.rawValue) }
            .addOnFailureListener { toast("Scan failed. Use 'Paste pairing code' instead.") }
    }

    private fun pasteCode() {
        val input = EditText(this).apply { hint = "Pairing code (JSON)"; setSingleLine(false) }
        AlertDialog.Builder(this).setTitle("Paste pairing code").setView(input)
            .setPositiveButton("Pair") { _, _ -> handlePayload(input.text.toString()) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun handlePayload(json: String?) {
        if (json.isNullOrBlank()) { toast("Empty pairing code"); return }
        try {
            val config = dev.droidmirror.companion.Settings.parsePayload(json)
            dev.droidmirror.companion.Settings(this).save(config)
            toast("Paired with ${config.macName}")
            startLink()
        } catch (e: Exception) {
            toast("That is not a valid pairing code")
        }
    }

    private fun startLink() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
        startForegroundService(Intent(this, ConnectionService::class.java))
    }

    private fun postTestReply() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
            toast("Allow notifications, then tap the button again")
            return
        }
        TestReply.post(this)
    }

    private fun forget() {
        stopService(Intent(this, ConnectionService::class.java))
        dev.droidmirror.companion.Settings(this).clear()
        toast("Forgot this Mac")
    }

    /** Debug builds only: adb can deliver a base64 pairing payload, so developers need not scan a QR. */
    private fun handleDevPairing(intent: Intent?) {
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        val b64 = intent?.getStringExtra("pair_payload_b64")
        if (debuggable && b64 != null) {
            handlePayload(String(Base64.decode(b64, Base64.DEFAULT), Charsets.UTF_8))
        }
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()
}
