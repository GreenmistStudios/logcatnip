### Crash: `IllegalStateException · ProfileRepository.requireProfile (ProfileRepository.kt:58)`
| | |
|---|---|
| App | com.example.app 1.2.3 (10203) |
| Target SDK | 34 |
| Installer | com.android.vending |
| Device | Google Pixel 8, Android 14 (API 34) |
| Build | google/shiba/shiba:14/UQ1A.240205.004/11269751:user/release-keys |
| Time | 2025-11-18 10:02:01.405 |

```text
2025-11-18 10:01:58.552 14211-14211 com.example.app com.example.app I  Late-enabling -Xcheck:jni
2025-11-18 10:01:58.951 14211-14211 ProfileInstaller com.example.app D  Installing profile for com.example.app
2025-11-18 10:02:01.398 14211-14211 AndroidRuntime com.example.app E  Unable to report crash to Firebase: no default app
2025-11-18 10:02:01.402 14211-14211 AndroidRuntime com.example.app D  Shutting down VM
2025-11-18 10:02:01.405 14211-14211 AndroidRuntime com.example.app E  FATAL EXCEPTION: main
Process: com.example.app, PID: 14211
java.lang.RuntimeException: Unable to start activity ComponentInfo{com.example.app/com.example.app.MainActivity}: java.lang.IllegalStateException: Profile must be loaded before rendering
	at android.app.ActivityThread.performLaunchActivity(ActivityThread.java:3782)
	at android.app.ActivityThread.handleLaunchActivity(ActivityThread.java:3922)
	at android.app.servertransaction.LaunchActivityItem.execute(LaunchActivityItem.java:103)
	at android.app.servertransaction.TransactionExecutor.executeCallbacks(TransactionExecutor.java:139)
	at android.app.servertransaction.TransactionExecutor.execute(TransactionExecutor.java:96)
	at android.app.ActivityThread$H.handleMessage(ActivityThread.java:2443)
	at android.os.Handler.dispatchMessage(Handler.java:106)
	at android.os.Looper.loopOnce(Looper.java:205)
	at android.os.Looper.loop(Looper.java:294)
	at android.app.ActivityThread.main(ActivityThread.java:8177)
	at java.lang.reflect.Method.invoke(Native Method)
	at com.android.internal.os.RuntimeInit$MethodAndArgsCaller.run(RuntimeInit.java:552)
	at com.android.internal.os.ZygoteInit.main(ZygoteInit.java:971)
Caused by: java.lang.IllegalStateException: Profile must be loaded before rendering
	at com.example.app.profile.ProfileRepository.requireProfile(ProfileRepository.kt:58)
	at com.example.app.MainActivity.onCreate(MainActivity.kt:42)
	at android.app.Activity.performCreate(Activity.java:8595)
	at android.app.Activity.performCreate(Activity.java:8573)
	at android.app.Instrumentation.callActivityOnCreate(Instrumentation.java:1456)
	at android.app.ActivityThread.performLaunchActivity(ActivityThread.java:3764)
	... 12 more
```
