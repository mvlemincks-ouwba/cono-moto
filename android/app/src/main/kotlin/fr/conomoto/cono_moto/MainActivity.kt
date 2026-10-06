package fr.conomoto.cono_moto

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.telephony.SmsManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val ACTION_INSTALL_STATUS = "fr.conomoto.cono_moto.INSTALL_STATUS"
    }

    /// Canal des mises à jour (voir lib/services/update/app_update.dart).
    private var updaterChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updaterChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fr.conomoto/updater").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank() || !File(path).exists()) {
                            result.error("ARGS", "Fichier de mise à jour introuvable", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            result.success("permission")
                            return@setMethodCallHandler
                        }
                        // Copie de l'APK dans la session : hors du fil principal.
                        Thread {
                            try {
                                installWithSession(File(path))
                                runOnUiThread { result.success("started") }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("INSTALL", e.message, null) }
                            }
                        }.start()
                    }
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                            )
                        }
                        result.success(null)
                    }
                    // Architectures du téléphone (la préférée d'abord) : l'appli télécharge l'APK qui lui va.
                    "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "isNetworkUnmetered" -> result.success(isNetworkUnmetered())
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fr.conomoto/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> {
                        val phone = call.argument<String>("phone")
                        val message = call.argument<String>("message")
                        if (phone.isNullOrBlank() || message.isNullOrBlank()) {
                            result.error("ARGS", "Numéro ou message manquant", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val sms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                getSystemService(SmsManager::class.java)
                            } else {
                                @Suppress("DEPRECATION")
                                SmsManager.getDefault()
                            }
                            val parts = sms.divideMessage(message)
                            sms.sendMultipartTextMessage(phone, null, parts, null, null)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SMS", e.message, null)
                        }
                    }
                    "keepScreenOn" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Connexion sans compteur (Wi-Fi, Ethernet) ? Dans le doute (pas de réseau,
    /// erreur), non : la mise à jour ne se télécharge pas en arrière-plan sur
    /// les données mobiles ni sur un partage de connexion.
    private fun isNetworkUnmetered(): Boolean {
        return try {
            val connectivity = getSystemService(ConnectivityManager::class.java) ?: return false
            val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        } catch (e: Exception) {
            false
        }
    }

    /// Installe la mise à jour avec PackageInstaller. Android demande une
    /// confirmation (STATUS_PENDING_USER_ACTION) sauf, à partir d'Android 12,
    /// quand Cono Moto a lui-même installé la version en place.
    private fun installWithSession(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(packageName)
        params.setSize(apk.length())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("cono-moto.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val intent = Intent(this, MainActivity::class.java)
                .setAction(ACTION_INSTALL_STATUS)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getActivity(this, sessionId, intent, flags)
            session.commit(pending.intentSender)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleInstallStatus(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleInstallStatus(intent)
    }

    /// Résultat renvoyé par PackageInstaller (voir installWithSession).
    private fun handleInstallStatus(intent: Intent?) {
        if (intent?.action != ACTION_INSTALL_STATUS) return
        val extras = intent.extras ?: return
        when (val status = extras.getInt(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    extras.getParcelable(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    extras.getParcelable<Intent>(Intent.EXTRA_INTENT)
                }
                if (confirm != null) startActivity(confirm)
                updaterChannel?.invokeMethod("installStatus", mapOf("status" to "pending"))
            }
            PackageInstaller.STATUS_SUCCESS ->
                updaterChannel?.invokeMethod("installStatus", mapOf("status" to "success"))
            else -> updaterChannel?.invokeMethod(
                "installStatus",
                mapOf(
                    "status" to "failure",
                    "code" to status,
                    "message" to extras.getString(PackageInstaller.EXTRA_STATUS_MESSAGE),
                ),
            )
        }
    }
}
