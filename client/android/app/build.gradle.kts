import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置从 android/key.properties 读取（不进 git，含密码）。
// 用的是 2024-01-17 生成的 debug keystore，指纹固定，
// 保证已安装设备能继续覆盖升级；换电脑时把 keystore 一起带过去。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) {
        f.inputStream().use { load(it) }
    }
}

val keystoreFile: java.io.File? =
    keystoreProperties.getProperty("storeFile")?.takeIf { it.isNotBlank() }?.let { file(it) }
val hasReleaseSigning = keystoreFile?.exists() == true

android {
    namespace = "com.piggypal.piggy_pal"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.piggypal.piggy_pal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = keystoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // release 必须用固定 keystore 签名，否则换台电脑就会生成新签名，
            // 已安装的设备会报 INSTALL_FAILED_UPDATE_INCOMPATIBLE，只能卸载重装。
            // 缺配置时下面会直接让 release 构建失败（debug 构建不受影响）。
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// 只在打 release 包时硬性要求签名配置：本地 flutter run（debug）不读 key.properties 也能跑。
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any {
        it.project == project && it.name.contains("Release") &&
            (it.name.startsWith("assemble") || it.name.startsWith("bundle") || it.name.startsWith("package"))
    }
    if (buildingRelease && !hasReleaseSigning) {
        throw GradleException(
            "缺少 release 签名配置：${rootProject.file("key.properties")}\n" +
                "  storeFile 指向的 keystore 不存在：${keystoreFile ?: "(未配置)"}\n" +
                "  请按 docs/故障排查.md 的「签名与换机」一节恢复 keystore，或从备份复制到 ~/keys/piggy-pal-debug.keystore。"
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
