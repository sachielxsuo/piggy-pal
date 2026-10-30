package com.piggypal.piggy_pal

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "piggy_pal/installer"
    private val deviceChannelName = "piggy_pal/device"
    private val uiChannelName = "piggy_pal/ui"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerDeviceChannel(flutterEngine)
        registerUiChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val openSettings = call.argument<Boolean>("openSettings") ?: true
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path is empty", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(installApk(path, openSettings))
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 设备标识：ANDROID_ID（SSAID）+ 品牌型号。
     *
     * 为什么不用 IMEI：Android 10 起普通应用完全拿不到 IMEI（需要 READ_PRIVILEGED_PHONE_STATE），
     * 硬拿会抛 SecurityException；而且 Play 政策也禁止用 IMEI 做标识。
     * ANDROID_ID 在同一签名 + 同一用户下卸载重装不变（恢复出厂 / 换签名才会变），
     * 足够当「这台设备」的稳定标识。
     */
    private fun registerDeviceChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceInfo" -> {
                        val androidId = try {
                            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                        } catch (e: Exception) {
                            null
                        }
                        result.success(
                            mapOf(
                                "android_id" to (androidId ?: ""),
                                "manufacturer" to Build.MANUFACTURER,
                                "model" to Build.MODEL,
                                "os_version" to Build.VERSION.RELEASE,
                                "sdk_int" to Build.VERSION.SDK_INT,
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 原生轻提示：用系统 Toast，不占 Flutter 页面、不打断宝宝操作。
     * 目前只用于「发现新版本，请家长手动更新」这类提示。
     */
    private fun registerUiChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, uiChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showToast" -> {
                        val text = call.argument<String>("text")
                        if (text.isNullOrEmpty()) {
                            result.error("bad_args", "text is empty", null)
                            return@setMethodCallHandler
                        }
                        val long = call.argument<Boolean>("long") ?: true
                        Toast.makeText(
                            applicationContext,
                            text,
                            if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT,
                        ).show()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 拉起系统安装器。返回：
     *  started            已打开安装界面
     *  permission_required 还没允许「安装未知应用」（openSettings 为 true 时会顺手打开设置页）
     *  missing            安装包不存在
     */
    private fun installApk(path: String, openSettings: Boolean): String {
        val file = File(path)
        if (!file.exists()) return "missing"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            if (openSettings) openInstallSettings()
            return "permission_required"
        }

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return "started"
    }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            startActivity(intent)
        }
    }
}
