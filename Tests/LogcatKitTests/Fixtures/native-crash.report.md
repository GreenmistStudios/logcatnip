### Native crash: `SIGSEGV (SEGV_MAPERR) · libnative.so (crashMe+20)`
| | |
|---|---|
| App | com.example.app 1.2.3 (10203) |
| Target SDK | 34 |
| Installer | com.android.vending |
| Device | Google Pixel 8, Android 14 (API 34) |
| Build | google/shiba/shiba:14/UQ1A.240205.004/11269751:user/release-keys |
| Time | 2025-11-18 10:05:01.118 |

```text
2025-11-18 10:05:01.102 15020-15020 NativeBridge com.example.app D  render: surface 0x7a4c3f2e10 1080x2400
2025-11-18 10:05:01.118 15020-15051 libc com.example.app A  Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 15051 (RenderThread), pid 15020 (com.example.app)
2025-11-18 10:05:01.290 15102-15102 DEBUG com.example.app A  *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
2025-11-18 10:05:01.291 15102-15102 DEBUG com.example.app A  Build fingerprint: 'google/husky/husky:14/UQ1A.240205.004/11269751:user/release-keys'
2025-11-18 10:05:01.292 15102-15102 DEBUG com.example.app A  Revision: 'MP1.0'
2025-11-18 10:05:01.293 15102-15102 DEBUG com.example.app A  ABI: 'arm64'
2025-11-18 10:05:01.294 15102-15102 DEBUG com.example.app A  Timestamp: 2025-11-18 10:05:01.290481232+0000
2025-11-18 10:05:01.295 15102-15102 DEBUG com.example.app A  Process uptime: 12s
2025-11-18 10:05:01.296 15102-15102 DEBUG com.example.app A  Cmdline: com.example.app
2025-11-18 10:05:01.297 15102-15102 DEBUG com.example.app A  pid: 15020, tid: 15051, name: RenderThread  >>> com.example.app <<<
2025-11-18 10:05:01.298 15102-15102 DEBUG com.example.app A  uid: 10234
2025-11-18 10:05:01.299 15102-15102 DEBUG com.example.app A  tagged_addr_ctrl: 0000000000000001 (PR_TAGGED_ADDR_ENABLE)
2025-11-18 10:05:01.300 15102-15102 DEBUG com.example.app A  pac_enabled_keys: 000000000000000f (PR_PAC_APIAKEY, PR_PAC_APIBKEY, PR_PAC_APDAKEY, PR_PAC_APDBKEY)
2025-11-18 10:05:01.301 15102-15102 DEBUG com.example.app A  signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0000000000000000
2025-11-18 10:05:01.302 15102-15102 DEBUG com.example.app A  Cause: null pointer dereference
2025-11-18 10:05:01.303 15102-15102 DEBUG com.example.app A      x0  0000000000000000  x1  0000007a4c3f2e10  x2  0000000000000010  x3  0000000000000000
2025-11-18 10:05:01.304 15102-15102 DEBUG com.example.app A      x4  0000007a4c3f2e20  x5  0000000000000004  x6  0000000000000000  x7  7f7f7f7f7f7f7f7f
2025-11-18 10:05:01.305 15102-15102 DEBUG com.example.app A      lr  0000007b1f6c1b84  sp  0000007a4c3f2d90  pc  0000007b1f6c1a2c  pst 0000000060001000
2025-11-18 10:05:01.306 15102-15102 DEBUG com.example.app A  15 total frames
2025-11-18 10:05:01.307 15102-15102 DEBUG com.example.app A  backtrace:
2025-11-18 10:05:01.308 15102-15102 DEBUG com.example.app A        #00 pc 0000000000001a2c  /data/app/~~Qm8xN3p2T5aLk9VbWc1dEg==/com.example.app-7hJk2LmN4pQ6rS8tU0vWxY==/lib/arm64/libnative.so (crashMe+20) (BuildId: 3e9f1c2a7b4d5e6f8091a2b3c4d5e6f708192a3b)
2025-11-18 10:05:01.309 15102-15102 DEBUG com.example.app A        #01 pc 0000000000001b80  /data/app/~~Qm8xN3p2T5aLk9VbWc1dEg==/com.example.app-7hJk2LmN4pQ6rS8tU0vWxY==/lib/arm64/libnative.so (Java_com_example_app_NativeBridge_render+56) (BuildId: 3e9f1c2a7b4d5e6f8091a2b3c4d5e6f708192a3b)
2025-11-18 10:05:01.310 15102-15102 DEBUG com.example.app A        #02 pc 000000000037a240  /apex/com.android.art/lib64/libart.so (art_quick_generic_jni_trampoline+144) (BuildId: 6a0f7d9d1c2e4a9f8b3e5c7d9a1b2c3d)
2025-11-18 10:05:01.311 15102-15102 DEBUG com.example.app A        #03 pc 0000000000363b74  /apex/com.android.art/lib64/libart.so (art_quick_invoke_static_stub+612) (BuildId: 6a0f7d9d1c2e4a9f8b3e5c7d9a1b2c3d)
2025-11-18 10:05:01.312 15102-15102 DEBUG com.example.app A        #04 pc 00000000002c1f1c  /system/lib64/libhwui.so (android::uirenderer::renderthread::RenderThread::threadLoop()+220) (BuildId: 9c8b7a6f5e4d3c2b1a0f9e8d7c6b5a49)
2025-11-18 10:05:01.313 15102-15102 DEBUG com.example.app A        #05 pc 00000000000c64fc  /apex/com.android.runtime/lib64/bionic/libc.so (__pthread_start(void*)+204) (BuildId: a87908b48b368e6282bcc9f34bcfc28c)
2025-11-18 10:05:01.314 15102-15102 DEBUG com.example.app A        #06 pc 0000000000059210  /apex/com.android.runtime/lib64/bionic/libc.so (__start_thread+64) (BuildId: a87908b48b368e6282bcc9f34bcfc28c)
```
