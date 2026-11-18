import Foundation
import Testing
@testable import LogcatKit

/// `adb shell dumpsys package com.example.app` on a Pixel 8 (Android 14), trimmed of permission lists.
private let installedAppOutput = """
    Activity Resolver Table:
      Non-Data Actions:
          android.intent.action.MAIN:
            7c1f2a9 com.example.app/.MainActivity filter 3b8e0d4
              Action: "android.intent.action.MAIN"
              Category: "android.intent.category.LAUNCHER"

    Receiver Resolver Table:
      Non-Data Actions:
          androidx.profileinstaller.action.INSTALL_PROFILE:
            e4a91c0 com.example.app/androidx.profileinstaller.ProfileInstallReceiver filter 52d7b1e
              Action: "androidx.profileinstaller.action.INSTALL_PROFILE"

    Key Set Manager:
      [com.example.app]
          Signing KeySets: 74

    Packages:
      Package [com.example.app] (b2c8e15):
        userId=10234
        pkg=Package{9d04f7a com.example.app}
        codePath=/data/app/~~Wq3nXbV0aHk2LmY8pTz5cQ==/com.example.app-Ke7rJd1sNf4uHq9yGv2bOw==
        resourcePath=/data/app/~~Wq3nXbV0aHk2LmY8pTz5cQ==/com.example.app-Ke7rJd1sNf4uHq9yGv2bOw==
        legacyNativeLibraryDir=/data/app/~~Wq3nXbV0aHk2LmY8pTz5cQ==/com.example.app-Ke7rJd1sNf4uHq9yGv2bOw==/lib
        extractNativeLibs=false
        primaryCpuAbi=arm64-v8a
        secondaryCpuAbi=null
        cpuAbiOverride=null
        versionCode=10203 minSdk=24 targetSdk=34
        minExtensionVersions=[]
        versionName=1.2.3
        hiddenApiEnforcementPolicy=2
        usesNonSdkApi=false
        splits=[base]
        apkSigningVersion=2
        flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]
        privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE_VIA_SDK_VERSION ALLOW_AUDIO_PLAYBACK_CAPTURE PRIVATE_FLAG_ALLOW_NATIVE_HEAP_POINTER_TAGGING ]
        forceQueryable=false
        dataDir=/data/user/0/com.example.app
        supportsScreens=[small, medium, large, xlarge, resizeable, anyDensity]
        timeStamp=2025-11-17 16:03:11
        lastUpdateTime=2025-11-17 16:03:12
        installerPackageName=com.android.vending
        installerPackageUid=10146
        initiatingPackageName=com.android.vending
        originatingPackageName=null
        packageSource=0
        appMetadataFilePath=null
        signatures=PackageSignatures{6a3e0b2 version:2, signatures:[f81c09d4], past signatures:[]}
        installPermissionsFixed=true
        pkgFlags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ALLOW_BACKUP ]
        install permissions:
          android.permission.INTERNET: granted=true
          android.permission.ACCESS_NETWORK_STATE: granted=true
        User 0: ceDataInode=164829 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false quarantined=false
          gids=[3003]
          runtime permissions:
            android.permission.POST_NOTIFICATIONS: granted=true, flags=[ USER_SET|USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]

    Queries:
      system apps queryable: false
      queries via forceQueryable:
      queries via package name:
      queries via component:
      queryable via interaction:
        User 0:
          [com.android.vending]:
            com.example.app

    Dexopt state:
      [com.example.app]
        path: /data/app/~~Wq3nXbV0aHk2LmY8pTz5cQ==/com.example.app-Ke7rJd1sNf4uHq9yGv2bOw==/base.apk
          arm64: [status=speed-profile] [reason=install-dm]

    Compiler stats:
      [com.example.app]
         base.apk - 1874
    """

/// An updated system app (WebView on Android 13): the Play Store build under `Packages:` and the factory
/// build under `Hidden system packages:`, each with its own `Package [...]` entry. Some builds print the
/// second one under another `Packages:` header, which the parser must also skip.
private let updatedSystemApp = """
    Key Set Manager:
      [com.google.android.webview]
          Signing KeySets: 18

    Packages:
      Package [com.google.android.webview] (5f1c3a8):
        userId=10118
        pkg=Package{e07b2d1 com.google.android.webview}
        codePath=/data/app/~~0bq7RkPw2xL9sJ4hVd1mYg==/com.google.android.webview-3zTn8uQe5KfA6cWiXy0lHg==
        resourcePath=/data/app/~~0bq7RkPw2xL9sJ4hVd1mYg==/com.google.android.webview-3zTn8uQe5KfA6cWiXy0lHg==
        legacyNativeLibraryDir=/data/app/~~0bq7RkPw2xL9sJ4hVd1mYg==/com.google.android.webview-3zTn8uQe5KfA6cWiXy0lHg==/lib
        extractNativeLibs=false
        primaryCpuAbi=arm64-v8a
        secondaryCpuAbi=armeabi-v7a
        cpuAbiOverride=null
        versionCode=671516933 minSdk=29 targetSdk=34
        minExtensionVersions=[]
        versionName=130.0.6723.107
        usesNonSdkApi=false
        splits=[base]
        apkSigningVersion=3
        flags=[ SYSTEM HAS_CODE UPDATED_SYSTEM_APP ALLOW_CLEAR_USER_DATA ]
        timeStamp=2024-11-14 21:40:02
        lastUpdateTime=2024-11-15 03:12:47
        installerPackageName=com.android.vending
        installerPackageUid=10146
        initiatingPackageName=com.android.vending
        installPermissionsFixed=true
        User 0: ceDataInode=0 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false

    Hidden system packages:
      Package [com.google.android.webview] (a49d6e2):
        userId=10118
        pkg=Package{3c58f90 com.google.android.webview}
        codePath=/product/app/WebViewGoogle
        resourcePath=/product/app/WebViewGoogle
        versionCode=599311133 minSdk=29 targetSdk=33
        versionName=114.0.5735.131
        flags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA ]

    Packages:
      Package [com.google.android.webview] (a49d6e2):
        userId=10118
        versionCode=599311133 minSdk=29 targetSdk=33
        versionName=114.0.5735.131
    """

/// `dumpsys package com.android.server.telecom` on an emulator: a system app with no `android:versionName`,
/// which dumpsys prints as `null`, and no installer.
private let systemAppWithoutName = """
    Packages:
      Package [com.android.server.telecom] (8ea2c71):
        userId=1000
        sharedUser=SharedUserSetting{4d0f9b3 android.uid.system/1000}
        pkg=Package{1b7c5e4 com.android.server.telecom}
        codePath=/system/priv-app/Telecom
        resourcePath=/system/priv-app/Telecom
        legacyNativeLibraryDir=/system/priv-app/Telecom/lib
        extractNativeLibs=false
        primaryCpuAbi=null
        secondaryCpuAbi=null
        cpuAbiOverride=null
        versionCode=34 minSdk=34 targetSdk=34
        minExtensionVersions=[]
        versionName=null
        usesNonSdkApi=false
        flags=[ SYSTEM HAS_CODE PERSISTENT ]
        privateFlags=[ PRIVATE_FLAG_ACTIVITIES_RESIZE_MODE_RESIZEABLE PRIVATE_FLAG_DEFAULT_TO_DEVICE_PROTECTED_STORAGE PRIVATE_FLAG_DIRECT_BOOT_AWARE PRIVILEGED ]
        timeStamp=2009-01-01 00:00:00
        lastUpdateTime=2009-01-01 00:00:00
        installerPackageName=null
        installerPackageUid=-1
        signatures=PackageSignatures{9a0e31c version:3, signatures:[7b2f4d1e], past signatures:[]}
        User 0: ceDataInode=0 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false
    """

@Suite struct AppVersionTests {
    @Test func installedApp() throws {
        let version = try #require(AppVersion.parse(dumpsysPackage: installedAppOutput))
        #expect(version == AppVersion(versionName: "1.2.3", versionCode: 10203, targetSdk: 34, installerPackage: "com.android.vending"))
        #expect(version.displayText == "1.2.3 (10203)")
    }

    @Test func updatedSystemAppUsesTheFirstPackage() throws {
        let version = try #require(AppVersion.parse(dumpsysPackage: updatedSystemApp))
        #expect(version.versionName == "130.0.6723.107")
        #expect(version.versionCode == 671516933)
        #expect(version.targetSdk == 34)
        #expect(version.installerPackage == "com.android.vending")
    }

    @Test func nullFieldsAreUnknown() throws {
        let version = try #require(AppVersion.parse(dumpsysPackage: systemAppWithoutName))
        #expect(version.versionName == nil)
        #expect(version.installerPackage == nil)
        #expect(version.versionCode == 34)
        #expect(version.displayText == "(34)")
    }

    @Test func crlfLineEndings() throws {
        // `adb shell` on API 23 and older returns CRLF.
        let output = "Packages:\r\n  Package [com.example.app] (1a2b3c4):\r\n    userId=10234\r\n    versionCode=7 targetSdk=23\r\n    versionName=0.7\r\n"
        let version = try #require(AppVersion.parse(dumpsysPackage: output))
        #expect(version == AppVersion(versionName: "0.7", versionCode: 7, targetSdk: 23))
    }

    @Test func unknownPackage() {
        #expect(AppVersion.parse(dumpsysPackage: "Unable to find package: com.example.missing\n") == nil)
        #expect(AppVersion.parse(dumpsysPackage: "") == nil)
    }
}
