package com.fiwichat.fiwichat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Service de premier plan : garde FIWICHAT en vie quand l'écran est éteint,
 * pour recevoir ses messages et relayer ceux des autres.
 */
class KeepAliveService : Service() {
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel("fiwichat_actif", "FIWICHAT actif", NotificationManager.IMPORTANCE_MIN)
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = Notification.Builder(this, "fiwichat_actif")
            .setContentTitle("FIWICHAT est actif")
            .setContentText("Prêt à recevoir et relayer les messages")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(1, notification)
            }
        } catch (e: Exception) {
            // Permissions refusées : l'appli marche quand même tant qu'elle est ouverte.
            stopSelf()
            return START_NOT_STICKY
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "fiwichat:wifi").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fiwichat:cpu").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wifiLock?.release()
        wakeLock?.release()
        super.onDestroy()
    }
}
