# shared_preferences_android 2.5.x 通过 JNI 直接调用 Android 侧的 Kotlin suspend 方法，
# 而 R8 默认会改名 / 裁掉只被 JNI 按名字引用的类，release 包会抛：
#   NoSuchMethodError: SharedPreferencesApiRegistrar.getAll(...Lkotlin/coroutines/Continuation;)
#   ClassNotFoundException: kotlin/coroutines/intrinsics/CoroutineSingletons
# 结果所有 SharedPreferences 调用失败（选宝宝页、星星页一直 loading）。
# 这里保留插件类与 JNI 按名字查找的 Kotlin 运行时类。
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }
-keep class kotlin.coroutines.jvm.internal.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
