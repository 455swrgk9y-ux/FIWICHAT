package com.fiwichat.fiwichat

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import java.security.SecureRandom
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        // Android impose que le nom d'un réseau Wi-Fi Direct commence par "DIRECT-xy-".
        const val GUEST_SSID = "DIRECT-FC-FIWICHAT"
        const val GROUP_OWNER_IP = "192.168.49.1"
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var p2pManager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fiwichat/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        acquireMulticastLock()
                        result.success(true)
                    }
                    "startGuestHotspot" -> startGuestHotspot(result)
                    "getApkPath" -> result.success(applicationInfo.sourceDir)
                    "shareApk" -> shareApk(call.argument<String>("via"), result)
                    "startKeepAlive" -> {
                        try {
                            startForegroundService(Intent(this, KeepAliveService::class.java))
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopGuestHotspot" -> {
                        stopGuestHotspot()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun acquireMulticastLock() {
        // Sans ce verrou, certains Android ignorent les signaux des autres téléphones.
        if (multicastLock != null) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("fiwichat").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun ensureP2p(): Pair<WifiP2pManager, WifiP2pManager.Channel>? {
        val manager = p2pManager
            ?: (applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager)
            ?: return null
        p2pManager = manager
        val channel = p2pChannel ?: manager.initialize(this, mainLooper, null)
        p2pChannel = channel
        return Pair(manager, channel)
    }

    /** Ouvre le réseau Wi-Fi invité (un groupe Wi-Fi Direct visible comme un Wi-Fi normal). */
    @SuppressLint("MissingPermission")
    private fun startGuestHotspot(result: MethodChannel.Result) {
        val p2p = ensureP2p()
        if (p2p == null) {
            result.error("NO_P2P", "Ce téléphone ne permet pas de créer le réseau invité.", null)
            return
        }
        val (manager, channel) = p2p
        // Nouveau mot de passe à chaque ouverture : seuls ceux qui le voient (ou scannent
        // le QR code) peuvent entrer, et un ancien invité ne peut pas revenir plus tard.
        val alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
        val rng = SecureRandom()
        val password = (1..10).map { alphabet[rng.nextInt(alphabet.length)] }.joinToString("")
        val config = WifiP2pConfig.Builder()
            .setNetworkName(GUEST_SSID)
            .setPassphrase(password)
            .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_2GHZ)
            .enablePersistentMode(false)
            .build()
        var answered = false
        val create = {
            manager.createGroup(channel, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    if (answered) return
                    answered = true
                    result.success(
                        mapOf("ssid" to GUEST_SSID, "password" to password, "ip" to GROUP_OWNER_IP)
                    )
                }

                override fun onFailure(reason: Int) {
                    if (answered) return
                    answered = true
                    val msg = when (reason) {
                        WifiP2pManager.P2P_UNSUPPORTED -> "Wi-Fi Direct n'est pas pris en charge."
                        WifiP2pManager.BUSY -> "Le Wi-Fi est occupé. Réessaie dans quelques secondes."
                        else -> "Impossible d'ouvrir le réseau (code $reason). Vérifie que le Wi-Fi et la localisation sont activés."
                    }
                    result.error("P2P_FAILED", msg, null)
                }
            })
        }
        // On ferme un éventuel ancien groupe avant d'en créer un nouveau.
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { create() }
            override fun onFailure(reason: Int) { create() }
        })
    }

    /** Envoie l'appli elle-même (son APK) via Quick Share, Bluetooth, etc. */
    // Applis de partage connues : on les ouvre directement, sans passer par la liste.
    private val quickSharePackages = listOf(
        "com.google.android.gms",            // Quick Share (Google)
        "com.samsung.android.app.sharelive", // Quick Share (Samsung)
    )
    private val bluetoothPackages = listOf("com.android.bluetooth", "com.google.android.bluetooth")

    private fun shareApk(via: String?, result: MethodChannel.Result) {
        Thread {
            try {
                val dir = File(cacheDir, "share").apply { mkdirs() }
                val apk = File(dir, "fiwichat.apk")
                File(applicationInfo.sourceDir).copyTo(apk, overwrite = true)
                val uri = FileProvider.getUriForFile(this, "$packageName.files", apk)
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "application/vnd.android.package-archive"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = ClipData.newRawUri("fiwichat.apk", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                val wanted = when (via) {
                    "quickshare" -> quickSharePackages
                    "bluetooth" -> bluetoothPackages
                    else -> emptyList()
                }
                val target = findTarget(send, wanted)
                runOnUiThread {
                    try {
                        if (target != null) {
                            startActivity(Intent(send).setComponent(target))
                            result.success("direct")
                        } else {
                            startActivity(Intent.createChooser(send, "Envoyer FIWICHAT avec…"))
                            result.success("liste")
                        }
                    } catch (e: Exception) {
                        // L'appli visée a refusé : on montre la liste complète.
                        startActivity(Intent.createChooser(send, "Envoyer FIWICHAT avec…"))
                        result.success("liste")
                    }
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("SHARE", e.message, null) }
            }
        }.start()
    }

    private fun findTarget(send: Intent, packages: List<String>): ComponentName? {
        if (packages.isEmpty()) return null
        @Suppress("DEPRECATION")
        val all = packageManager.queryIntentActivities(send, 0)
        for (pkg in packages) {
            val matches = all.filter { it.activityInfo.packageName == pkg && it.activityInfo.exported }
            if (matches.isEmpty()) continue
            // Dans Google Play Services, plusieurs écrans reçoivent les fichiers : on prend celui de Quick Share.
            val best = matches.firstOrNull {
                val n = it.activityInfo.name.lowercase()
                n.contains("nearby") || n.contains("sharing") || n.contains("share")
            } ?: if (pkg == "com.google.android.gms") null else matches.first()
            if (best != null) return ComponentName(best.activityInfo.packageName, best.activityInfo.name)
        }
        return null
    }

    private fun stopGuestHotspot() {
        val p2p = ensureP2p() ?: return
        p2p.first.removeGroup(p2p.second, null)
    }

    override fun onDestroy() {
        // L'appli est fermée : on arrête tout (réseau invité, service d'arrière-plan).
        stopService(Intent(this, KeepAliveService::class.java))
        stopGuestHotspot()
        multicastLock?.release()
        super.onDestroy()
    }
}
