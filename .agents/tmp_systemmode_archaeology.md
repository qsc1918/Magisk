# Magisk HEAD aed0261c3 — System-Mode Port Archaeology (READ-ONLY)

Repo: `D:\Magisk`, HEAD = `aed0261c3dc877221b9f4ef04c0735383cbba16c` "Refactor adb patching and emulator setup".
Reference (Delta) tree: `D:\a\KitsuneMagisk`, HEAD = `5ed3f41fd` "Rename ndk path to kitsune".
No files were modified. No builds or adb commands were run.

Modules: `app/apk`, `app/apk-legacy`, `app/core`, `app/shared`, `app/stub`, `app/stub-res`, `app/test`, `app/build-logic`.

---

## 1. The install UI

### 1.1 Where it lives

| Concern | Path |
|---|---|
| Install screen (Compose `Dialog`, not a Fragment) | `app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallDialog.kt` (314 lines) |
| Install ViewModel | `app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallViewModel.kt` (127 lines) |
| Host / entry point | `app/apk/src/main/java/com/topjohnwu/magisk/ui/home/HomeScreen.kt` (`CoreCard` → `onInstallClicked` → `showInstallDialog`) |
| Progress screen | `app/apk/src/main/java/com/topjohnwu/magisk/ui/flash/FlashScreen.kt` + `FlashViewModel.kt` |
| Navigation | `app/apk/src/main/java/com/topjohnwu/magisk/ui/navigation/Routes.kt` (`Route.Flash`), hosted in `app/apk/.../ui/MainActivity.kt:145-155` |
| Installer engine | `app/core/src/main/java/com/topjohnwu/magisk/core/tasks/MagiskInstaller.kt` |
| Legacy (View-based) duplicate | `app/apk-legacy/.../ui/install/InstallViewModel.kt`, `fragment_install_md2.xml` — **do not touch** (maintenance mode) |

There is **no `InstallFragment` and no `InstallScreen`** in the module-based app; the install UI is a full-screen Compose `Dialog` inside `HomeScreen`. In `:apk-legacy` it is still a Fragment + databinding layout.

Entry points in `app/apk/src/main/java/com/topjohnwu/magisk/ui/home/HomeScreen.kt`:

```kotlin
284: 
285:             CoreCard(
286:                 modifier = Modifier.fillMaxWidth(),
287:                 state = uiState.magiskState,
288:                 version = uiState.magiskInstalledVersion,
289:                 onInstallClicked = { showInstallDialog = true }
290:             )
...
326:     InstallDialog(
327:         show = showInstallDialog,
328:         onDismiss = { showInstallDialog = false },
329:         installVm = installVm,
330:     )
```

### 1.2 `InstallViewModel.kt` — quoted ENTIRELY

`app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallViewModel.kt`

```kotlin
  1: package com.topjohnwu.magisk.ui.install
  2: 
  3: import android.net.Uri
  4: import android.widget.Toast
  5: import androidx.lifecycle.viewModelScope
  6: import com.topjohnwu.magisk.arch.BaseViewModel
  7: import com.topjohnwu.magisk.core.AppContext
  8: import com.topjohnwu.magisk.core.BuildConfig.APP_VERSION_CODE
  9: import com.topjohnwu.magisk.core.Const
 10: import com.topjohnwu.magisk.core.Info
 11: import com.topjohnwu.magisk.core.ktx.toast
 12: import com.topjohnwu.magisk.core.repository.NetworkService
 13: import com.topjohnwu.magisk.ui.navigation.Route
 14: import kotlinx.coroutines.Dispatchers
 15: import kotlinx.coroutines.flow.MutableStateFlow
 16: import kotlinx.coroutines.flow.StateFlow
 17: import kotlinx.coroutines.flow.asStateFlow
 18: import kotlinx.coroutines.flow.update
 19: import kotlinx.coroutines.launch
 20: import timber.log.Timber
 21: import java.io.File
 22: import java.io.IOException
 23: import com.topjohnwu.magisk.core.R as CoreR
 24: 
 25: class InstallViewModel(svc: NetworkService) : BaseViewModel() {
 26: 
 27:     enum class Method { NONE, PATCH, DIRECT, INACTIVE_SLOT, DOWNLOAD }
 28: 
 29:     data class UiState(
 30:         val method: Method = Method.NONE,
 31:         val notes: String = "",
 32:         val patchUri: Uri? = null,
 33:         val requestFilePicker: Boolean = false,
 34:         val showSecondSlotWarning: Boolean = false,
 35:         val showDownloadDialog: Boolean = false,
 36:     )
 37: 
 38:     val isRooted get() = Info.isRooted
 39:     val skipOptions = Info.isEmulator || (Info.isSAR && !Info.isFDE && Info.ramdisk)
 40:     val noSecondSlot = !isRooted || !Info.isAB || Info.isEmulator
 41: 
 42:     private val _uiState = MutableStateFlow(UiState())
 43:     val uiState: StateFlow<UiState> = _uiState.asStateFlow()
 44: 
 45:     init {
 46:         viewModelScope.launch(Dispatchers.IO) {
 47:             try {
 48:                 val noteFile = File(AppContext.cacheDir, "${APP_VERSION_CODE}.md")
 49:                 val noteText = when {
 50:                     noteFile.exists() -> noteFile.readText()
 51:                     else -> {
 52:                         val note = svc.fetchUpdate(APP_VERSION_CODE)?.note.orEmpty()
 53:                         if (note.isEmpty()) return@launch
 54:                         noteFile.writeText(note)
 55:                         note
 56:                     }
 57:                 }
 58:                 _uiState.update { it.copy(notes = noteText) }
 59:             } catch (e: IOException) {
 60:                 Timber.e(e)
 61:             }
 62:         }
 63:     }
 64: 
 65:     fun selectMethod(method: Method) {
 66:         _uiState.update { it.copy(method = method) }
 67:         when (method) {
 68:             Method.PATCH -> {
 69:                 AppContext.toast(CoreR.string.patch_file_msg, Toast.LENGTH_LONG)
 70:                 _uiState.update { it.copy(requestFilePicker = true) }
 71:             }
 72:             Method.INACTIVE_SLOT -> {
 73:                 _uiState.update { it.copy(showSecondSlotWarning = true) }
 74:             }
 75:             Method.DOWNLOAD -> {
 76:                 _uiState.update { it.copy(showDownloadDialog = true) }
 77:             }
 78:             else -> {}
 79:         }
 80:     }
 81: 
 82:     fun onFilePickerConsumed() {
 83:         _uiState.update { it.copy(requestFilePicker = false) }
 84:     }
 85: 
 86:     fun onSecondSlotWarningConsumed() {
 87:         _uiState.update { it.copy(showSecondSlotWarning = false) }
 88:     }
 89: 
 90:     fun onDownloadDialogConsumed() {
 91:         _uiState.update { it.copy(showDownloadDialog = false) }
 92:     }
 93: 
 94:     fun onPatchFileSelected(uri: Uri) {
 95:         _uiState.update { it.copy(patchUri = uri) }
 96:         if (_uiState.value.method == Method.PATCH) {
 97:             install()
 98:         }
 99:     }
100: 
101:     fun onDownloadUrlSelected(uri: Uri) {
102:         _uiState.update { it.copy(patchUri = uri) }
103:         if (_uiState.value.method == Method.DOWNLOAD) {
104:             install()
105:         }
106:     }
107: 
108:     fun install() {
109:         when (_uiState.value.method) {
110:             Method.PATCH -> navigateTo(Route.Flash(
111:                 action = Const.Value.PATCH_FILE,
112:                 additionalData = _uiState.value.patchUri!!.toString()
113:             ))
114:             Method.DOWNLOAD -> navigateTo(Route.Flash(
115:                 action = Const.Value.DOWNLOAD,
116:                 additionalData = _uiState.value.patchUri!!.toString()
117:             ))
118:             Method.DIRECT -> navigateTo(Route.Flash(
119:                 action = Const.Value.FLASH_MAGISK
120:             ))
121:             Method.INACTIVE_SLOT -> navigateTo(Route.Flash(
122:                 action = Const.Value.FLASH_INACTIVE_SLOT
123:             ))
124:             else -> error("Unknown method")
125:         }
126:     }
127: }
```

### 1.3 Install-method model, steps, and conditional offering

**Method model** — a plain Kotlin `enum class` nested in the ViewModel (`InstallViewModel.kt:27`):

```kotlin
enum class Method { NONE, PATCH, DIRECT, INACTIVE_SLOT, DOWNLOAD }
```

There is **no** `InstallMethod` enum and **no** `Method` sealed class. The enum is transient UI state only; the stable identifier that crosses the navigation boundary is a `String` constant in `app/core/src/main/java/com/topjohnwu/magisk/core/Const.kt`:

```kotlin
 56:     object Value {
 57:         const val FLASH_ZIP = "flash"
 58:         const val PATCH_FILE = "patch"
 59:         const val DOWNLOAD = "download"
 60:         const val FLASH_MAGISK = "magisk"
 61:         const val FLASH_INACTIVE_SLOT = "slot"
 62:         const val UNINSTALL = "uninstall"
```

and the route is `app/apk/src/main/java/com/topjohnwu/magisk/ui/navigation/Routes.kt:19-22`:

```kotlin
19:     data class Flash(
20:         val action: String,
21:         val additionalData: String? = null,
22:     ) : Route
```

**Steps / stages** — there is NO multi-step wizard in the official app. A single dialog (`InstallDialog`) with:
1. changelog/notes markdown (`InstallViewModel` init, lines 45-63),
2. an optional `InstallOptionsSection` card (verity / force-encrypt / recovery switches),
3. a method card with up to four rows.

The `install_next` / `install_start` / `install_options_title` / `install_method_title` strings still exist in `strings.xml:39-42` but are **dead** (leftovers from the old wizard; no code references them in `:apk`). Kitsune's ViewModel used an `int step` + `@Bindable` for this; the official Compose port dropped it.

**Conditional offering** — three booleans, all in the ViewModel:

```kotlin
38:     val isRooted get() = Info.isRooted
39:     val skipOptions = Info.isEmulator || (Info.isSAR && !Info.isFDE && Info.ramdisk)
40:     val noSecondSlot = !isRooted || !Info.isAB || Info.isEmulator
```

and the rendering in `InstallDialog.kt:151-198`:

```kotlin
151:                     if (!installVm.skipOptions) {
152:                         InstallOptionsSection()
153:                     }
154: 
155:                     Card(
156:                         modifier = Modifier.fillMaxWidth(),
157:                         shape = RoundedCornerShape(20.dp),
158:                         colors = CardDefaults.cardColors(
159:                             containerColor = MaterialTheme.colorScheme.surfaceContainerLow
160:                         ),
161:                     ) {
162:                         SettingsArrow(
163:                             title = stringResource(CoreR.string.select_patch_file),
164:                             onClick = {
165:                                 onDismiss()
166:                                 installVm.selectMethod(InstallViewModel.Method.PATCH)
167:                             },
168:                         )
169: 
170:                         SettingsArrow(
171:                             title = stringResource(CoreR.string.download_patch_file),
172:                             onClick = {
173:                                 onDismiss()
174:                                 installVm.selectMethod(InstallViewModel.Method.DOWNLOAD)
175:                             },
176:                         )
177: 
178:                         if (installVm.isRooted) {
179:                             SettingsArrow(
180:                                 title = stringResource(CoreR.string.direct_install),
181:                                 onClick = {
182:                                     onDismiss()
183:                                     installVm.selectMethod(InstallViewModel.Method.DIRECT)
184:                                     installVm.install()
185:                                 },
186:                             )
187:                         }
188: 
189:                         if (!installVm.noSecondSlot) {
190:                             SettingsArrow(
191:                                 title = stringResource(CoreR.string.install_inactive_slot),
192:                                 onClick = {
193:                                     onDismiss()
194:                                     installVm.selectMethod(InstallViewModel.Method.INACTIVE_SLOT)
195:                                 },
196:                             )
197:                         }
198:                     }
```

Semantics:

| Row | Always shown? | Gate | Meaning |
|---|---|---|---|
| "Select and patch a file" | yes | — | pick `*.img` / `*.tar` / `payload.bin`, patch on device, write to Downloads |
| "Download and patch a file" | yes | — | same but source is an HTTPS URL |
| "Direct install (Recommended)" | only if `Info.isRooted` | root shell available right now | patch the live boot device and flash it |
| "Install to inactive slot (After OTA)" | only if `!noSecondSlot` = `isRooted && Info.isAB && !Info.isEmulator` | rooted, A/B, real device | patch + flash the other slot |

The options card (`InstallDialog.kt:205-248`) shows the switches conditionally too:

```kotlin
205: @Composable
206: private fun InstallOptionsSection(
207:     modifier: Modifier = Modifier
208: ) {
209:     Card(
210:         modifier = modifier.fillMaxWidth(),
211:         shape = RoundedCornerShape(20.dp),
212:         colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)
213:     ) {
214:         if (!Info.isSAR) {
215:             var keepVerity by remember { mutableStateOf(Config.keepVerity) }
216:             SettingsSwitch(
217:                 title = stringResource(CoreR.string.keep_dm_verity),
218:                 checked = keepVerity,
219:                 onCheckedChange = {
220:                     keepVerity = it
221:                     Config.keepVerity = it
222:                 }
223:             )
224:         }
225:         if (Info.isFDE) {
226:             var keepEnc by remember { mutableStateOf(Config.keepEnc) }
227:             SettingsSwitch(
228:                 title = stringResource(CoreR.string.keep_force_encryption),
229:                 checked = keepEnc,
230:                 onCheckedChange = {
231:                     keepEnc = it
232:                     Config.keepEnc = it
233:                 }
234:             )
235:         }
236:         if (!Info.ramdisk) {
237:             var recovery by remember { mutableStateOf(Config.recovery) }
238:             SettingsSwitch(
239:                 title = stringResource(CoreR.string.recovery_mode),
240:                 checked = recovery,
241:                 onCheckedChange = {
242:                     recovery = it
243:                     Config.recovery = it
244:                 }
245:             )
246:         }
247:     }
248: }
```

Key point for the port: **the official `installVm.isRooted` is `Info.isRooted`, which is set in `ShellInit.onInit` only when `shell.isRoot`** (`app/core/.../core/utils/ShellInit.kt:19-23`). So "rooted" = "we can get a root shell", not "boot image is patched". There is no `isBootPatched` in the official tree (see §6).

### 1.4 File-picker / second-slot / URL dialog plumbing

`InstallDialog.kt:66-108`:

```kotlin
 66:     val installUiState by installVm.uiState.collectAsStateWithLifecycle()
 67:     var showDownloadDialog by rememberSaveable { mutableStateOf(false) }
 68:     val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
 69:         uri?.let { installVm.onPatchFileSelected(it) }
 70:     }
 71: 
 72:     val secondSlotDialog = rememberConfirmDialog()
 73:     val secondSlotTitle = stringResource(android.R.string.dialog_alert_title)
 74:     val secondSlotMsg = stringResource(CoreR.string.install_inactive_slot_msg)
 75: 
 76:     LaunchedEffect(installUiState.requestFilePicker) {
 77:         if (installUiState.requestFilePicker) {
 78:             filePicker.launch("*/*")
 79:             installVm.onFilePickerConsumed()
 80:         }
 81:     }
 82: 
 83:     LaunchedEffect(installUiState.showSecondSlotWarning) {
 84:         if (installUiState.showSecondSlotWarning) {
 85:             val result = secondSlotDialog.awaitConfirm(title = secondSlotTitle, content = secondSlotMsg)
 86:             installVm.onSecondSlotWarningConsumed()
 87:             if (result == ConfirmResult.Confirmed) {
 88:                 installVm.install()
 89:             }
 90:         }
 91:     }
 92: 
 93:     LaunchedEffect(installUiState.showDownloadDialog) {
 94:         if (installUiState.showDownloadDialog) {
 95:             showDownloadDialog = true
 96:             installVm.onDownloadDialogConsumed()
 97:         }
 98:     }
```

`DownloadComposableDialog` is `InstallDialog.kt:250-314` (HTTPS-only validation via `isValidUrl`).

**Where a `DIRECT_SYSTEM` row belongs**: insert a fourth `SettingsArrow` inside the `Card` at `InstallDialog.kt:161-198`, gated on a new ViewModel boolean, calling a new `Method` value that navigates to a new `Const.Value` (mirroring Kitsune's `direct_install_system`).

---

## 2. The installer engine

### 2.1 Where it lives

`app/core/src/main/java/com/topjohnwu/magisk/core/tasks/MagiskInstaller.kt` (645 lines) — **`app/core`, not `app/apk`**. This is the single engine for every install action.

Relevant declarations:

| Symbol | Lines | Role |
|---|---|---|
| `abstract class MagiskInstallImpl protected constructor(console, logs)` | 51-557 | base |
| `destName` (randomized output file name) | 66-80 | uses `Config.randName` |
| `findImage(slot)` / `findImage()` / `findSecondary()` | 82-106 | runs `find_boot_image` in-shell |
| `extractFiles()` | 108-194 | **APK asset + native-lib extraction** |
| `processTar()` | 224-324 | handles tar/ODIN archives |
| `processFile(uri)` | 326-431 | handles raw img / payload.bin / zip |
| `processUrl(url)` | 433-478 | HTTPS download then patch |
| `patchBoot()` | 480-501 | **runs `boot_patch.sh`** |
| `flashBoot()` | 503 | runs `direct_install` |
| `postOTA()` | 505-513 | runs `post_ota` |
| `fixEnv()` | 530 | runs `fix_env` |
| `restore()` | 532 | runs `restore_imgs` |
| `uninstall()` | 534 | runs `run_uninstaller` |
| public operations | 521-528 | `patchFile`, `direct()`, `secondSlot()` |
| `abstract class ConsoleInstaller` | 559-572 | adds "- All done!" / "! Installation failed" |
| `abstract class CallBackInstaller` | 574-580 | callback variant (Restore / FixEnv) |
| `class MagiskInstaller` | 582-645 | concrete operations: `Patch`, `Download`, `SecondSlot`, `Direct`, `Emulator`, `Uninstall`, `Restore`, `FixEnv` |

The shell plumbing helpers (`MagiskInstaller.kt:515-519`) — note these are how every shell command is issued:

```kotlin
515:     private fun Array<String>.eq() = shell.newJob().add(*this).to(console, logs).enqueue()
516:     private fun String.sh() = shell.newJob().add(this).to(console, logs).exec()
517:     private fun Array<String>.sh() = shell.newJob().add(*this).to(console, logs).exec()
518:     private fun String.fsh() = ShellUtils.fastCmd(shell, this)
519:     private fun Array<String>.fsh() = ShellUtils.fastCmd(shell, *this)
```

### 2.2 How scripts are located and extracted

`MagiskInstaller.kt:108-194` — `extractFiles()` is the **critical integration point**:

```kotlin
108:     private suspend fun extractFiles(): Boolean {
109:         console.add("- Device platform: ${Const.CPU_ABI}")
110:         console.add("- Installing: ${BuildConfig.APP_VERSION_NAME} (${BuildConfig.APP_VERSION_CODE})")
111: 
112:         installDir = localFS.getFile(context.filesDir.parent, "install")
113:         installDir.deleteRecursively()
114:         installDir.mkdirs()
115: 
116:         try {
117:             // Extract binaries
118:             if (isRunningAsStub) {
119:                 ZipFile.builder().setFile(StubApk.current(context)).get().use { zf ->
120:                     zf.entries.asSequence().filter {
121:                         !it.isDirectory && it.name.startsWith("lib/${Const.CPU_ABI}/")
122:                     }.forEach {
123:                         val n = it.name.substring(it.name.lastIndexOf('/') + 1)
124:                         val name = n.substring(3, n.length - 3)
125:                         val dest = File(installDir, name)
126:                         zf.getInputStream(it).writeTo(dest)
127:                         dest.setExecutable(true)
128:                     }
129: 
130:                     val abi32 = Const.CPU_ABI_32
131:                     if (Process.is64Bit() && abi32 != null) {
132:                         val entry = zf.getEntry("lib/$abi32/libmagisk.so")
133:                         if (entry != null) {
134:                             val magisk32 = File(installDir, "magisk32")
135:                             zf.getInputStream(entry).writeTo(magisk32)
136:                         }
137:                     }
138:                 }
139:             } else {
140:                 val info = context.applicationInfo
141:                 val libs = File(info.nativeLibraryDir).listFiles { _, name ->
142:                     name.startsWith("lib") && name.endsWith(".so")
143:                 } ?: emptyArray()
144: 
145:                 for (lib in libs) {
146:                     val name = lib.name.substring(3, lib.name.length - 3)
147:                     Os.symlink(lib.path, "$installDir/$name")
148:                 }
149: 
150:                 // Also extract magisk32 on 64-bit devices that supports 32-bit
151:                 val abi32 = Const.CPU_ABI_32
152:                 if (Process.is64Bit() && abi32 != null) {
153:                     val name = "lib/$abi32/libmagisk.so"
154:                     val entry = javaClass.classLoader!!.getResourceAsStream(name)
155:                     if (entry != null) {
156:                         val magisk32 = File(installDir, "magisk32")
157:                         entry.writeTo(magisk32)
158:                     }
159:                 }
160:             }
161: 
162:             // Extract scripts
163:             for (script in listOf("util_functions.sh", "boot_patch.sh", "addon.d.sh", "stub.apk")) {
164:                 val dest = File(installDir, script)
165:                 context.assets.open(script).writeTo(dest)
166:             }
167:             // Extract chromeos tools
168:             File(installDir, "chromeos").mkdir()
169:             for (file in listOf("futility", "kernel_data_key.vbprivk", "kernel.keyblock")) {
170:                 val name = "chromeos/$file"
171:                 val dest = File(installDir, name)
172:                 context.assets.open(name).writeTo(dest)
173:             }
174:         } catch (e: Exception) {
175:             console.add("! Unable to extract files")
176:             Timber.e(e)
177:             return false
178:         }
179: 
180:         if (useRootDir) {
181:             // Move everything to tmpfs to workaround Samsung bullshit
182:             rootFS.getFile(Const.TMPDIR).also {
183:                 arrayOf(
184:                     "rm -rf $it",
185:                     "mkdir -p $it",
186:                     "cp_readlink $installDir $it",
187:                     "rm -rf $installDir"
188:                 ).sh()
189:                 installDir = it
190:             }
191:         }
192: 
193:         return true
194:     }
```

**Exact list of files copied out of the APK** (lines 163 and 169):

- `assets/util_functions.sh` → `<installDir>/util_functions.sh`
- `assets/boot_patch.sh` → `<installDir>/boot_patch.sh`
- `assets/addon.d.sh` → `<installDir>/addon.d.sh`
- `assets/stub.apk` → `<installDir>/stub.apk`
- `assets/chromeos/futility`, `assets/chromeos/kernel_data_key.vbprivk`, `assets/chromeos/kernel.keyblock` → `<installDir>/chromeos/*`

Native binaries come from `applicationInfo.nativeLibraryDir` (symlinked, renamed by stripping `lib` prefix and `.so` suffix) — lines 139-148; or from inside the stub APK's `lib/<abi>/*.so` when running as the stub — lines 118-138.

**Where they are written** — `MagiskInstaller.kt:112`:

```kotlin
installDir = localFS.getFile(context.filesDir.parent, "install")
```

`context` is `ServiceLocator.deContext` (line 61), i.e. **device-protected storage**, so the path is
`/data/user_de/0/<pkg>/install` → practically **`/data/user_de/0/com.topjohnwu.magisk/install`** (or the same for the obfuscated stub package).
It is **not** `/data/local/tmp`.

If `useRootDir` is true — `private val useRootDir = shell.isRoot && Info.noDataExec` (line 60) — the whole tree is copied to `Const.TMPDIR` = **`/dev/tmp`** (`Const.kt:19 const val TMPDIR = "/dev/tmp"`) at lines 180-191, and `installDir` is re-pointed there.

`app_functions.sh` is **never** copied into `installDir`. It reaches the shell as a *prelude asset* on every shell init — `app/core/src/main/java/com/topjohnwu/magisk/core/utils/ShellInit.kt:66-69`:

```kotlin
 66:             add(context.assets.open("app_functions.sh"))
 67:             if (shell.isRoot) {
 68:                 add(context.assets.open("util_functions.sh"))
 69:             }
```

This matters: `fix_env`, `direct_install`, `restore_imgs`, `run_uninstaller`, `post_ota`, `run_migrations` are all defined in **`app_functions.sh`** (overriding the weaker `util_functions.sh` versions), so they are available to any `shell.newJob()` in the app process. `ShellInit` is registered at `app/core/src/main/java/com/topjohnwu/magisk/core/AppContext.kt:91` (`.setInitializers(ShellInit::class.java)`).

### 2.3 The exact shell command lines

**A. Find the boot partition** — `MagiskInstaller.kt:82-96`:

```kotlin
 82:     private fun findImage(slot: String): Boolean {
 83:         val cmd =
 84:             "RECOVERYMODE=${Config.recovery} " +
 85:             "VENDORBOOT=${Info.isVendorBoot} " +
 86:             "SLOT=$slot " +
 87:             "find_boot_image; echo \$BOOTIMAGE"
 88:         val bootPath = ("($cmd)").fsh()
 89:         if (bootPath.isEmpty()) {
 90:             console.add("! Unable to detect target image")
 91:             return false
 92:         }
 93:         srcBoot = rootFS.getFile(bootPath)
 94:         console.add("- Target image: $bootPath")
 95:         return true
 96:     }
```

**B. Patch a boot image (`boot_patch.sh`)** — `MagiskInstaller.kt:480-501` ("patch a boot image" path):

```kotlin
480:     private fun patchBoot(): Boolean {
481:         val newBoot = installDir.getChildFile("new-boot.img")
482:         if (!useRootDir) {
483:             // Create output files before hand
484:             newBoot.createNewFile()
485:             File(installDir, "stock_boot.img").createNewFile()
486:         }
487: 
488:         val cmds = arrayOf(
489:             "cd $installDir",
490:             "KEEPFORCEENCRYPT=${Config.keepEnc} " +
491:             "KEEPVERITY=${Config.keepVerity} " +
492:             "PATCHVBMETAFLAG=${Info.patchBootVbmeta} " +
493:             "RECOVERYMODE=${Config.recovery} " +
494:             "LEGACYSAR=${Info.legacySAR} " +
495:             "sh boot_patch.sh $srcBoot")
496:         val isSuccess = cmds.sh().isSuccess
497: 
498:         shell.newJob().add("./magiskboot cleanup", "cd /").exec()
499: 
500:         return isSuccess
501:     }
```

So the literal shell line is:

```
cd <installDir>
KEEPFORCEENCRYPT=<bool> KEEPVERITY=<bool> PATCHVBMETAFLAG=<bool> RECOVERYMODE=<bool> LEGACYSAR=<bool> sh boot_patch.sh <bootimage>
```

**C. Direct install (patch the live boot device and flash it)** — `MagiskInstaller.kt:503`:

```kotlin
503:     private fun flashBoot() = "direct_install $installDir $srcBoot".sh().isSuccess
```

and the operation composition, `MagiskInstaller.kt:521-528`:

```kotlin
521:     protected suspend fun patchFile(file: Uri) = extractFiles() && processFile(file)
522: 
523:     protected suspend fun patchFile(url: String) = extractFiles() && processUrl(url)
524: 
525:     protected suspend fun direct() = findImage() && extractFiles() && patchBoot() && flashBoot()
526: 
527:     protected suspend fun secondSlot() =
528:         findSecondary() && extractFiles() && patchBoot() && flashBoot() && postOTA()
529: 
530:     protected suspend fun fixEnv() = extractFiles() && "fix_env $installDir".sh().isSuccess
531: 
532:     protected fun restore() = findImage() && "restore_imgs $srcBoot".sh().isSuccess
533: 
534:     protected fun uninstall() = "run_uninstaller $AppApkPath".sh().isSuccess
```

**D. The rest of the shell entry points** — all defined in `scripts/app_functions.sh`:

| Shell call | Kotlin site | `app_functions.sh` definition |
|---|---|---|
| `direct_install <dir> <bootimg>` | `MagiskInstaller.kt:503` | lines 59-80 (calls `flash_image` then `fix_env` then `run_migrations`) |
| `fix_env <dir>` | `MagiskInstaller.kt:530` | lines 48-57 |
| `restore_imgs <bootimg>` | `MagiskInstaller.kt:532` | lines 90-97 |
| `run_uninstaller <apk>` | `MagiskInstaller.kt:534` | lines 82-88 |
| `post_ota` | `MagiskInstaller.kt:506` (`"post_ota".sh()`) | lines 99-118 |
| `find_boot_image` | `MagiskInstaller.kt:87` | (real impl in `util_functions.sh:379-403`) |
| `app_init` | `Info.init` → `ShellInit.kt:106` | lines 227-249 |
| `env_check` | `HomeViewModel` (via `app_functions.sh`) | lines 11-26 |
| `cp_readlink` | `MagiskInstaller.kt:186,428,475` | lines 28-46 |
| `adb_pm_install` | `AppMigration.kt:216,229,259` | lines 120-133 |
| `mount_partitions`, `get_flags` | `scripts/adb_patch.sh:31-32` | lines 193-217 |

Full `cp_readlink` invocation sites: `MagiskInstaller.kt:186` (`cp_readlink $installDir $it`), `:428` (`"cp_readlink $installDir".sh()`), `:475` (same, URL path).

**E. Module-zip install (different engine)** — `FlashZip.kt:49-59` and `FlashViewModel.kt:144-172` write `assets/module_installer.sh` to `<dir>/update-binary` and run:

```kotlin
// app/apk/src/main/java/com/topjohnwu/magisk/ui/flash/FlashViewModel.kt:164-173
164:         val success = withContext(Dispatchers.IO) {
165:             runSuCommand(
166:                 emu,
167:                 "echo '- Installing $displayName'; " +
168:                 "sh $dir/update-binary dummy 1 '${zipFile.absolutePath}'; " +
169:                 "EXIT=\$?; " +
170:                 "if [ \$EXIT -ne 0 ]; then echo '! Installation failed'; fi; " +
171:                 "exit \$EXIT"
172:             )
173:         }
```

### 2.4 The action dispatcher

`app/apk/src/main/java/com/topjohnwu/magisk/ui/flash/FlashViewModel.kt:71-118` maps `Const.Value` strings to installer classes:

```kotlin
 71:     fun startFlashing() {
 72:         val action = flashAction
 73:         val uri = flashUri
 74: 
 75:         viewModelScope.launch {
 76:             val emu = emulatorReady.await()
 77:             when (action) {
 78:                 Const.Value.FLASH_ZIP -> {
 79:                     uri ?: return@launch
 80:                     flashZip(emu, uri)
 81:                 }
 82:                 Const.Value.UNINSTALL -> {
 83:                     _showReboot.value = false
 84:                     onResult(withContext(Dispatchers.IO) {
 85:                         MagiskInstaller.Uninstall(outItems, logItems).exec()
 86:                     })
 87:                 }
 88:                 Const.Value.FLASH_MAGISK -> {
 89:                     onResult(withContext(Dispatchers.IO) {
 90:                         if (Info.isEmulator)
 91:                             MagiskInstaller.Emulator(outItems, logItems).exec()
 92:                         else
 93:                             MagiskInstaller.Direct(outItems, logItems).exec()
 94:                     })
 95:                 }
 96:                 Const.Value.FLASH_INACTIVE_SLOT -> {
 97:                     _showReboot.value = false
 98:                     onResult(withContext(Dispatchers.IO) {
 99:                         MagiskInstaller.SecondSlot(outItems, logItems).exec()
100:                     })
101:                 }
102:                 Const.Value.PATCH_FILE -> {
103:                     uri ?: return@launch
104:                     _showReboot.value = false
105:                     onResult(withContext(Dispatchers.IO) {
106:                         MagiskInstaller.Patch(uri, outItems, logItems).exec()
107:                     })
108:                 }
109:                 Const.Value.DOWNLOAD -> {
110:                     uri ?: return@launch
111:                     _showReboot.value = false
112:                     onResult(withContext(Dispatchers.IO) {
113:                         MagiskInstaller.Download(uri.toString(), outItems, logItems).exec()
114:                     })
115:                 }
116:             }
117:         }
118:     }
```

**Note the emulator special-case**: when `Info.isEmulator`, `FLASH_MAGISK` runs `MagiskInstaller.Emulator` (i.e. `fixEnv()` only, no boot image patching) instead of `MagiskInstaller.Direct`. That is the closest thing official has to a non-boot-image install, and it is exactly the hook a System Mode install would extend.

Concrete installer classes — `MagiskInstaller.kt:582-645`:

```kotlin
582: class MagiskInstaller {
583: 
584:     class Patch(
585:         private val uri: Uri,
586:         console: MutableList<String>,
587:         logs: MutableList<String>
588:     ) : ConsoleInstaller(console, logs) {
589:         override suspend fun operations() = patchFile(uri)
590:     }
591: 
592:     class Download(
593:         private val url: String,
594:         console: MutableList<String>,
595:         logs: MutableList<String>
596:     ) : ConsoleInstaller(console, logs) {
597:         override suspend fun operations() = patchFile(url)
598:     }
599: 
600:     class SecondSlot(
601:         console: MutableList<String>,
602:         logs: MutableList<String>
603:     ) : ConsoleInstaller(console, logs) {
604:         override suspend fun operations() = secondSlot()
605:     }
606: 
607:     class Direct(
608:         console: MutableList<String>,
609:         logs: MutableList<String>
610:     ) : ConsoleInstaller(console, logs) {
611:         override suspend fun operations() = direct()
612:     }
613: 
614:     class Emulator(
615:         console: MutableList<String>,
616:         logs: MutableList<String>
617:     ) : ConsoleInstaller(console, logs) {
618:         override suspend fun operations() = fixEnv()
619:     }
620: 
621:     class Uninstall(
622:         console: MutableList<String>,
623:         logs: MutableList<String>
624:     ) : ConsoleInstaller(console, logs) {
625:         override suspend fun operations() = uninstall()
626: 
627:         override suspend fun exec(): Boolean {
628:             val success = super.exec()
629:             if (success) {
630:                 UiThreadHandler.handler.postDelayed(3000) {
631:                     Shell.cmd("pm uninstall ${context.packageName}").exec()
632:                 }
633:             }
634:             return success
635:         }
636:     }
637: 
638:     class Restore : CallBackInstaller() {
639:         override suspend fun operations() = restore()
640:     }
641: 
642:     class FixEnv : CallBackInstaller() {
643:         override suspend fun operations() = fixEnv()
644:     }
645: }
```

---

## 3. How `scripts/*.sh` become APK assets

### 3.1 The single wiring point

`D:\Magisk\app\build-logic\src\main\java\Setup.kt`, `Project.setupCoreLib()` (starts line 119). `:core` is a library (`implementation(project(":core"))` in `app/apk/build.gradle.kts:37`), so its assets/resources merge into the final app APK. Nothing in `build.py`, `scripts/env.py`, `app/apk/build.gradle.kts`, or `app/build.gradle.kts` touches `scripts/*.sh`.

`app/build-logic/src/main/java/Plugin.kt:34-38` — how `rootFile` reaches the repo root from Gradle's `app/` root:

```kotlin
fun Project.rootFile(path: String): File {
    val file = File(path)
    return if (file.isAbsolute) file
    else File(rootProject.file(".."), path)
}
```

**Assets** — `app/build-logic/src/main/java/Setup.kt:170-202` (VERBATIM):

```kotlin
170:             val stubTask = tasks.getByPath(":stub:transform${variantCapped}Apk")
171:             val syncAssets = tasks.register("sync${variantCapped}Assets", SyncWithDir::class) {
172:                 outputFolder.set(layout.buildDirectory.dir("$variantName/assets"))
173:                 into(outputFolder)
174: 
175:                 inputs.property("version", Config.version)
176:                 inputs.property("versionCode", Config.versionCode)
177:                 from(rootFile("scripts")) {
178:                     include("util_functions.sh", "boot_patch.sh", "addon.d.sh",
179:                         "app_functions.sh", "uninstaller.sh", "module_installer.sh")
180:                 }
181:                 into("chromeos") {
182:                     from(rootFile("tools/futility"))
183:                     from(rootFile("tools/keys")) {
184:                         include("kernel_data_key.vbprivk", "kernel.keyblock")
185:                     }
186:                 }
187:                 from(stubTask) {
188:                     include { it.name.endsWith(".apk") }
189:                     rename { "stub.apk" }
190:                 }
191:                 filesMatching("**/util_functions.sh") {
192:                     filter {
193:                         it.replace(
194:                             "#MAGISK_VERSION_STUB",
195:                             "MAGISK_VER='${Config.version}'\nMAGISK_VER_CODE=${Config.versionCode}"
196:                         )
197:                     }
198:                     filter<FixCrLfFilter>("eol" to FixCrLfFilter.CrLf.newInstance("lf"))
199:                 }
200:             }
201:             variant.sources.assets
202:                 ?.addGeneratedSourceDirectory(syncAssets, SyncWithDir::outputFolder)
```

**Java resources** (these are NOT assets — they become the recovery entry points) — `Setup.kt:154-168`:

```kotlin
154:             val syncResources = tasks.register("sync${variantCapped}Resources", SyncWithDir::class) {
155:                 outputFolder.set(layout.buildDirectory.dir("$variantName/resources"))
156:                 into(outputFolder)
157: 
158:                 into("META-INF/com/google/android") {
159:                     from(rootFile("scripts/update_binary.sh")) {
160:                         rename { "update-binary" }
161:                     }
162:                     from(rootFile("scripts/flash_script.sh")) {
163:                         rename { "updater-script" }
164:                     }
165:                 }
166:             }
167:             variant.sources.resources
168:                 ?.addGeneratedSourceDirectory(syncResources, SyncWithDir::outputFolder)
```

Callers: `app/core/build.gradle.kts:9` → `setupCoreLib()`; `app/apk/build.gradle.kts:7` and `app/apk-legacy/build.gradle.kts:8` → `setupMainApk()`; `app/stub/build.gradle.kts:39` → `setupStubApk()`; `app/test/build.gradle.kts:22` → `setupTestApk()`.

### 3.2 `#MAGISK_VERSION_STUB` substitution

`scripts/util_functions.sh:5` is literally:

```sh
5: #MAGISK_VERSION_STUB
```

The **only** substitution site in the repo is `Setup.kt:191-199` above. Empirical result, read from an existing build artifact `D:\Magisk\app\core\build\debug\assets\util_functions.sh`:

```sh
1: ############################################
2: # Magisk General Utility Functions
3: ############################################
4: 
5: MAGISK_VER='aed0261c'
6: MAGISK_VER_CODE=31000
7: 
```

`version`/`versionCode` come from `app/build/flags.prop`, generated by `build.py:308-315`:

```python
308: def dump_flags_app():
309:     flag_txt = f"abiList={','.join(build_abis.keys())}\n"
310:     flag_txt += f"version={config['version']}\n"
311:     flag_txt += f"versionCode={config['versionCode']}\n"
312: 
313:     app_build_dir = Path("app", "build")
314:     app_build_dir.mkdir(parents=True, exist_ok=True)
315:     write_if_diff(app_build_dir / "flags.prop", flag_txt)
```

`app_functions.sh:23-24` then greps for exactly those two lines to validate the installed binaries:

```sh
23:   grep -xqF "MAGISK_VER='$1'" "$MAGISKBIN/util_functions.sh" || return 3
24:   grep -xqF "MAGISK_VER_CODE=$2" "$MAGISKBIN/util_functions.sh" || return 3
```

**Consequence**: any script you add to `syncAssets` gets this treatment only if it matches `**/util_functions.sh`.

### 3.3 Definitive list of what ends up in the APK

Verified against the existing artifact `D:\Magisk\app\core\build\debug\assets\` and `D:\Magisk\app\apk\build\intermediates\assets\debug\mergeDebugAssets\`:

| File in APK | Source | Runtime consumer |
|---|---|---|
| `assets/util_functions.sh` | `scripts/util_functions.sh` (**version-substituted**) | `ShellInit.kt:68`; `MagiskInstaller.kt:163` |
| `assets/boot_patch.sh` | `scripts/boot_patch.sh` | `MagiskInstaller.kt:163`, then `MagiskInstaller.kt:495` |
| `assets/addon.d.sh` | `scripts/addon.d.sh` | `MagiskInstaller.kt:163`; installed to `/system/addon.d/99-magisk.sh` by `flash_script.sh:86` |
| `assets/app_functions.sh` | `scripts/app_functions.sh` | `ShellInit.kt:66` (every shell init); `adb_patch.sh:30` |
| `assets/uninstaller.sh` | `scripts/uninstaller.sh` | via `run_uninstaller` (`MagiskInstaller.kt:534` → `app_functions.sh:83-88`) |
| `assets/module_installer.sh` | `scripts/module_installer.sh` | `FlashZip.kt:51`, `FlashViewModel.kt:145`, `DownloadProcessor.kt:90`, `Environment.kt:98` |
| `assets/chromeos/{futility,kernel_data_key.vbprivk,kernel.keyblock}` | `tools/futility`, `tools/keys/*` | `MagiskInstaller.kt:169-172` |
| `assets/stub.apk` | `:stub:transform<Variant>Apk` output | `SplashScreen.kt:138`, `AppMigration.kt:199`, `MagiskInstaller.kt:163`, `DownloadProcessor.kt:52` |
| `META-INF/com/google/android/update-binary` (**Java resource**) | `scripts/update_binary.sh` | recovery only — no in-app consumer |
| `META-INF/com/google/android/updater-script` (**Java resource**) | `scripts/flash_script.sh` | recovery only — no in-app consumer |

**NOT packaged anywhere**: `scripts/adb_patch.sh`, `scripts/avd.sh`, `scripts/avd_patch.sh`, `scripts/avd_setup.sh`, `scripts/cuttlefish.sh`, `scripts/test_common.sh`, `scripts/env.py`, `scripts/release.sh`. These are dev/CI tooling only.

**There is no standalone installer ZIP at this HEAD.** The APK itself *is* the flashable ZIP: `scripts/update_binary.sh:19-26` unzips `assets/*`, `lib/*`, `META-INF/com/google/*` out of the APK and execs `assets/uninstaller.sh` or `META-INF/com/google/android/updater-script`. So "the exact list of files copied out of the APK" for the recovery path is the whole `assets/` dir.

### 3.4 `scripts/app_functions.sh` — quoted ENTIRELY (249 lines)

`D:\Magisk\scripts\app_functions.sh`

```sh
  1: ##################################
  2: # Magisk app internal scripts
  3: ##################################
  4: 
  5: # $1 = delay
  6: # $2 = command
  7: run_delay() {
  8:   (sleep $1; $2)&
  9: }
 10: 
 11: # $1 = version string
 12: # $2 = version code
 13: env_check() {
 14:   for file in busybox magiskboot magiskinit util_functions.sh boot_patch.sh; do
 15:     [ -f "$MAGISKBIN/$file" ] || return 1
 16:   done
 17:   if [ "$2" -ge 25000 ]; then
 18:     [ -f "$MAGISKBIN/magiskpolicy" ] || return 1
 19:   fi
 20:   if [ "$2" -ge 25210 ]; then
 21:     [ -b "$MAGISKTMP/.magisk/device/preinit" ] || [ -b "$MAGISKTMP/.magisk/block/preinit" ] || return 2
 22:   fi
 23:   grep -xqF "MAGISK_VER='$1'" "$MAGISKBIN/util_functions.sh" || return 3
 24:   grep -xqF "MAGISK_VER_CODE=$2" "$MAGISKBIN/util_functions.sh" || return 3
 25:   return 0
 26: }
 27: 
 28: # $1 = dir to copy
 29: # $2 = destination (optional)
 30: cp_readlink() {
 31:   if [ -z $2 ]; then
 32:     cd $1
 33:   else
 34:     cp -af $1/. $2
 35:     cd $2
 36:   fi
 37:   for file in *; do
 38:     if [ -L $file ]; then
 39:       local full=$(readlink -f $file)
 40:       rm $file
 41:       cp -af $full $file
 42:     fi
 43:   done
 44:   chmod -R 755 .
 45:   cd /
 46: }
 47: 
 48: # $1 = install dir
 49: fix_env() {
 50:   # Cleanup and make dirs
 51:   rm -rf $MAGISKBIN/*
 52:   mkdir -p $MAGISKBIN 2>/dev/null
 53:   chmod 700 /data/adb
 54:   cp_readlink $1 $MAGISKBIN
 55:   rm -rf $1
 56:   chown -R 0:0 $MAGISKBIN
 57: }
 58: 
 59: # $1 = install dir
 60: # $2 = boot partition
 61: direct_install() {
 62:   echo "- Flashing new boot image"
 63:   flash_image $1/new-boot.img $2
 64:   case $? in
 65:     1)
 66:       echo "! Insufficient partition size"
 67:       return 1
 68:       ;;
 69:     2)
 70:       echo "! $2 is read only"
 71:       return 2
 72:       ;;
 73:   esac
 74: 
 75:   rm -f $1/new-boot.img
 76:   fix_env $1
 77:   run_migrations
 78: 
 79:   return 0
 80: }
 81: 
 82: # $1 = uninstaller zip
 83: run_uninstaller() {
 84:   rm -rf /dev/tmp
 85:   mkdir -p /dev/tmp/install
 86:   unzip -o "$1" "assets/*" "lib/*" -d /dev/tmp/install
 87:   INSTALLER=/dev/tmp/install sh /dev/tmp/install/assets/uninstaller.sh dummy 1 "$1"
 88: }
 89: 
 90: # $1 = boot partition
 91: restore_imgs() {
 92:   local SHA1=$(grep_prop SHA1 $MAGISKTMP/.magisk/config)
 93:   local BACKUPDIR=/data/magisk_backup_$SHA1
 94:   [ -d $BACKUPDIR ] || return 1
 95:   [ -f $BACKUPDIR/boot.img.gz ] || return 1
 96:   flash_image $BACKUPDIR/boot.img.gz $1
 97: }
 98: 
 99: post_ota() {
100:   cd /data/adb
101:   cp -f $MAGISKBIN/bootctl bootctl
102:   rm -f $MAGISKBIN/bootctl
103:   chmod 755 bootctl
104:   if ! ./bootctl hal-info; then
105:     rm -f bootctl
106:     return
107:   fi
108:   SLOT_NUM=0
109:   [ $(./bootctl get-current-slot) -eq 0 ] && SLOT_NUM=1
110:   ./bootctl set-active-boot-slot $SLOT_NUM
111:   cat << EOF > post-fs-data.d/post_ota.sh
112: /data/adb/bootctl mark-boot-successful
113: rm -f /data/adb/bootctl
114: rm -f /data/adb/post-fs-data.d/post_ota.sh
115: EOF
116:   chmod 755 post-fs-data.d/post_ota.sh
117:   cd /
118: }
119: 
120: # $1 = APK
121: # $2 = package name
122: adb_pm_install() {
123:   local tmp=/data/local/tmp/temp.apk
124:   cp -f "$1" $tmp
125:   chmod 644 $tmp
126:   su 2000 -c pm install -g $tmp || pm install -g $tmp || su 1000 -c pm install -g $tmp
127:   local res=$?
128:   rm -f $tmp
129:   if [ $res = 0 ]; then
130:     appops set "$2" REQUEST_INSTALL_PACKAGES allow
131:   fi
132:   return $res
133: }
134: 
135: check_boot_ramdisk() {
136:   # Create boolean ISAB
137:   ISAB=true
138:   [ -z $SLOT ] && ISAB=false
139: 
140:   # If we are A/B, then we must have ramdisk
141:   $ISAB && return 0
142: 
143:   # If we are using legacy SAR, but not A/B, assume we do not have ramdisk
144:   if $LEGACYSAR; then
145:     # Override recovery mode to true
146:     RECOVERYMODE=true
147:     return 1
148:   fi
149: 
150:   return 0
151: }
152: 
153: check_encryption() {
154:   if $ISENCRYPTED; then
155:     if [ $SDK_INT -lt 24 ]; then
156:       CRYPTOTYPE="block"
157:     else
158:       # First see what the system tells us
159:       CRYPTOTYPE=$(getprop ro.crypto.type)
160:       if [ -z $CRYPTOTYPE ]; then
161:         # If not mounting through device mapper, we are FBE
162:         if grep ' /data ' /proc/mounts | grep -qv 'dm-'; then
163:           CRYPTOTYPE="file"
164:         else
165:           # We are either FDE or metadata encryption (which is also FBE)
166:           CRYPTOTYPE="block"
167:           grep -q ' /metadata ' /proc/mounts && CRYPTOTYPE="file"
168:         fi
169:       fi
170:     fi
171:   else
172:     CRYPTOTYPE="N/A"
173:   fi
174: }
175: 
176: printvar() {
177:   eval echo $1=\$$1
178: }
179: 
180: run_action() {
181:   local MODID="$1"
182:   cd "/data/adb/modules/$MODID"
183:   sh ./action.sh
184:   local RES=$?
185:   cd /
186:   return $RES
187: }
188: 
189: ##########################
190: # Non-root util_functions
191: ##########################
192: 
193: mount_partitions() {
194:   [ "$(getprop ro.build.ab_update)" = "true" ] && SLOT=$(getprop ro.boot.slot_suffix)
195:   # Check whether non rootfs root dir exists
196:   SYSTEM_AS_ROOT=false
197:   grep ' / ' /proc/mounts | grep -qv 'rootfs' && SYSTEM_AS_ROOT=true
198: 
199:   LEGACYSAR=false
200:   grep ' / ' /proc/mounts | grep -q '/dev/root' && LEGACYSAR=true
201: }
202: 
203: get_flags() {
204:   KEEPVERITY=$SYSTEM_AS_ROOT
205:   ISENCRYPTED=false
206:   [ "$(getprop ro.crypto.state)" = "encrypted" ] && ISENCRYPTED=true
207:   KEEPFORCEENCRYPT=$ISENCRYPTED
208:   if [ -n "$(getprop ro.boot.vbmeta.device)" -o -n "$(getprop ro.boot.vbmeta.size)" ]; then
209:     PATCHVBMETAFLAG=false
210:   elif getprop ro.product.ab_ota_partitions | grep -wq vbmeta; then
211:     PATCHVBMETAFLAG=false
212:   else
213:     PATCHVBMETAFLAG=true
214:   fi
215:   [ -z $RECOVERYMODE ] && RECOVERYMODE=false
216:   [ -z $VENDORBOOT ] && VENDORBOOT=false
217: }
218: 
219: run_migrations() { return; }
220: 
221: grep_prop() { return; }
222: 
223: #############
224: # Initialize
225: #############
226: 
227: app_init() {
228:   mount_partitions >/dev/null
229:   RAMDISKEXIST=false
230:   check_boot_ramdisk && RAMDISKEXIST=true
231:   get_flags >/dev/null
232:   run_migrations >/dev/null
233:   check_encryption
234: 
235:   # Dump variables
236:   printvar SLOT
237:   printvar SYSTEM_AS_ROOT
238:   printvar RAMDISKEXIST
239:   printvar ISAB
240:   printvar CRYPTOTYPE
241:   printvar PATCHVBMETAFLAG
242:   printvar LEGACYSAR
243:   printvar RECOVERYMODE
244:   printvar KEEPVERITY
245:   printvar KEEPFORCEENCRYPT
246:   printvar VENDORBOOT
247: }
248: 
249: export BOOTMODE=true
```

**Functions defined here that OVERRIDE `util_functions.sh`** (because `app_functions.sh` is sourced *after* `util_functions.sh` at `ShellInit.kt:66-69`): `mount_partitions` (193), `get_flags` (203), `run_migrations` (219), `grep_prop` (221).
**Functions defined here that do NOT exist in `util_functions.sh`**: `run_delay`, `env_check`, `cp_readlink`, `fix_env`, `direct_install`, `run_uninstaller`, `restore_imgs`, `post_ota`, `adb_pm_install`, `check_boot_ramdisk`, `check_encryption`, `printvar`, `run_action`, `app_init`.
Note lines 219-221: in the **app** context `run_migrations` and `grep_prop` are stubs, and line 249 forces `BOOTMODE=true`.

### 3.5 `scripts/addon.d.sh` — quoted ENTIRELY (170 lines)

`D:\Magisk\scripts\addon.d.sh`

```sh
  1: #!/sbin/sh
  2: # ADDOND_VERSION=2
  3: ########################################################
  4: #
  5: # Magisk Survival Script for ROMs with addon.d support
  6: # by topjohnwu and osm0sis
  7: #
  8: ########################################################
  9: 
 10: trampoline() {
 11:   mount /data 2>/dev/null
 12:   if [ -f $MAGISKBIN/addon.d.sh ]; then
 13:     exec sh $MAGISKBIN/addon.d.sh "$@"
 14:     exit $?
 15:   elif [ "$1" = post-restore ]; then
 16:     BOOTMODE=false
 17:     ps | grep zygote | grep -v grep >/dev/null && BOOTMODE=true
 18:     $BOOTMODE || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null && BOOTMODE=true
 19: 
 20:     if ! $BOOTMODE; then
 21:       # update-binary|updater <RECOVERY_API_VERSION> <OUTFD> <ZIPFILE>
 22:       OUTFD=$(ps | grep -v 'grep' | grep -oE 'update(.*) 3 [0-9]+' | cut -d" " -f3)
 23:       [ -z $OUTFD ] && OUTFD=$(ps -Af | grep -v 'grep' | grep -oE 'update(.*) 3 [0-9]+' | cut -d" " -f3)
 24:       # update_engine_sideload --payload=file://<ZIPFILE> --offset=<OFFSET> --headers=<HEADERS> --status_fd=<OUTFD>
 25:       [ -z $OUTFD ] && OUTFD=$(ps | grep -v 'grep' | grep -oE 'status_fd=[0-9]+' | cut -d= -f2)
 26:       [ -z $OUTFD ] && OUTFD=$(ps -Af | grep -v 'grep' | grep -oE 'status_fd=[0-9]+' | cut -d= -f2)
 27:     fi
 28:     ui_print() {
 29:       if $BOOTMODE; then
 30:         log -t Magisk -- "$1"
 31:       else
 32:         echo -e "ui_print $1\nui_print" >> /proc/self/fd/$OUTFD
 33:       fi
 34:     }
 35: 
 36:     ui_print "***********************"
 37:     ui_print " Magisk addon.d failed"
 38:     ui_print "***********************"
 39:     ui_print "! Cannot find Magisk binaries - was data wiped or not decrypted?"
 40:     ui_print "! Reflash OTA from decrypted recovery or reflash Magisk"
 41:   fi
 42:   exit 1
 43: }
 44: 
 45: # Always use the script in /data
 46: MAGISKBIN=/data/adb/magisk
 47: [ "$0" = $MAGISKBIN/addon.d.sh ] || trampoline "$@"
 48: 
 49: V1_FUNCS=/tmp/backuptool.functions
 50: V2_FUNCS=/postinstall/tmp/backuptool.functions
 51: 
 52: if [ -f $V1_FUNCS ]; then
 53:   . $V1_FUNCS
 54:   backuptool_ab=false
 55: elif [ -f $V2_FUNCS ]; then
 56:   . $V2_FUNCS
 57: else
 58:   return 1
 59: fi
 60: 
 61: initialize() {
 62:   # Load utility functions
 63:   . $MAGISKBIN/util_functions.sh
 64: 
 65:   if $BOOTMODE; then
 66:     # Override ui_print when booted
 67:     ui_print() { log -t Magisk -- "$1"; }
 68:   fi
 69:   OUTFD=
 70:   setup_flashable
 71: }
 72: 
 73: main() {
 74:   if ! $backuptool_ab; then
 75:     # Restore PREINITDEVICE from previous A-only partition
 76:     if [ -f config.orig ]; then
 77:       PREINITDEVICE=$(grep_prop PREINITDEVICE config.orig)
 78:       rm config.orig
 79:     fi
 80: 
 81:     # Wait for post addon.d-v1 processes to finish
 82:     sleep 5
 83:   fi
 84: 
 85:   # Ensure we aren't in /tmp/addon.d anymore (since it's been deleted by addon.d)
 86:   mkdir -p $TMPDIR
 87:   cd $TMPDIR
 88: 
 89:   if echo $MAGISK_VER | grep -q '\.'; then
 90:     PRETTY_VER=$MAGISK_VER
 91:   else
 92:     PRETTY_VER="$MAGISK_VER($MAGISK_VER_CODE)"
 93:   fi
 94:   print_title "Magisk $PRETTY_VER addon.d"
 95: 
 96:   mount_partitions
 97:   check_data
 98:   get_flags
 99: 
100:   if $backuptool_ab; then
101:     # Swap the slot for addon.d-v2
102:     if [ ! -z $SLOT ]; then
103:       case $SLOT in
104:         _a) SLOT=_b;;
105:         _b) SLOT=_a;;
106:       esac
107:     fi
108:   fi
109: 
110:   find_boot_image
111:   [ -z $BOOTIMAGE ] && abort "! Unable to detect target image"
112:   ui_print "- Target image: $BOOTIMAGE"
113: 
114:   api_level_arch_detect
115:   ui_print "- Device platform: $ABI"
116: 
117:   remove_system_su
118:   install_magisk
119: 
120:   # Cleanups
121:   cd /
122:   $BOOTMODE || recovery_cleanup
123:   rm -rf $TMPDIR
124: 
125:   ui_print "- Done"
126:   exit 0
127: }
128: 
129: case "$1" in
130:   backup)
131:     # Stub
132:   ;;
133:   restore)
134:     # Stub
135:   ;;
136:   pre-backup)
137:     # Back up PREINITDEVICE from existing partition before OTA on A-only devices
138:     if ! $backuptool_ab; then
139:       initialize
140:       # Suppress ui_print for this stage
141:       ui_print() { return; }
142:       get_flags
143:       find_boot_image
144:       $MAGISKBIN/magiskboot unpack "$BOOTIMAGE"
145:       $MAGISKBIN/magiskboot cpio ramdisk.cpio "extract .backup/.magisk config.orig"
146:       $MAGISKBIN/magiskboot cleanup
147:     fi
148:   ;;
149:   post-backup)
150:     # Stub
151:   ;;
152:   pre-restore)
153:     # Stub
154:   ;;
155:   post-restore)
156:     initialize
157:     if $backuptool_ab; then
158:       su=sh
159:       $BOOTMODE && su=su
160:       exec $su -c "sh $0 addond-v2"
161:     else
162:       # Run in background, hack for addon.d-v1
163:       (main) &
164:     fi
165:   ;;
166:   addond-v2)
167:     initialize
168:     main
169:   ;;
170: esac
```

Kitsune's delta for reference (`D:\a\KitsuneMagisk\scripts\addon.d.sh:10,125`): adds `SYSTEMINSTALL=false` and an `if [ "$SYSTEMINSTALL" == "true" ]` branch in `main` that runs `direct_install_system` instead of `install_magisk`.

---

## 4. `scripts/boot_patch.sh` — quoted ENTIRELY (267 lines)

`D:\Magisk\scripts\boot_patch.sh`

```sh
  1: #!/system/bin/sh
  2: #######################################################################################
  3: # Magisk Boot Image Patcher
  4: #######################################################################################
  5: #
  6: # Usage: boot_patch.sh <bootimage>
  7: #
  8: # The following environment variables can configure the installation:
  9: # KEEPVERITY, KEEPFORCEENCRYPT, PATCHVBMETAFLAG, RECOVERYMODE, LEGACYSAR
 10: #
 11: # This script should be placed in a directory with the following files:
 12: #
 13: # File name          Type      Description
 14: #
 15: # boot_patch.sh      script    A script to patch boot image for Magisk.
 16: #                  (this file) The script will use files in its same
 17: #                              directory to complete the patching process.
 18: # util_functions.sh  script    A script which hosts all functions required
 19: #                              for this script to work properly.
 20: # magiskinit         binary    The binary to replace /init.
 21: # magisk             binary    The magisk binary.
 22: # magiskboot         binary    A tool to manipulate boot images.
 23: # init-ld            binary    The library that will be LD_PRELOAD of /init
 24: # stub.apk           binary    The stub Magisk app to embed into ramdisk.
 25: # chromeos           folder    This folder includes the utility and keys to sign
 26: #                  (optional)  chromeos boot images. Only used for Pixel C.
 27: #
 28: #######################################################################################
 29: 
 30: ############
 31: # Functions
 32: ############
 33: 
 34: # Pure bash dirname implementation
 35: getdir() {
 36:   case "$1" in
 37:     */*)
 38:       dir=${1%/*}
 39:       if [ -z $dir ]; then
 40:         echo "/"
 41:       else
 42:         echo $dir
 43:       fi
 44:     ;;
 45:     *) echo "." ;;
 46:   esac
 47: }
 48: 
 49: #################
 50: # Initialization
 51: #################
 52: 
 53: if [ -z $SOURCEDMODE ]; then
 54:   # Switch to the location of the script file
 55:   cd "$(getdir "${BASH_SOURCE:-$0}")"
 56:   # Load utility functions
 57:   . ./util_functions.sh
 58: fi
 59: 
 60: BOOTIMAGE="$1"
 61: [ -e "$BOOTIMAGE" ] || abort "$BOOTIMAGE does not exist!"
 62: 
 63: # Dump image for MTD/NAND character device boot partitions
 64: if [ -c "$BOOTIMAGE" ]; then
 65:   nanddump -f boot.img "$BOOTIMAGE"
 66:   BOOTNAND="$BOOTIMAGE"
 67:   BOOTIMAGE=boot.img
 68: fi
 69: 
 70: # Flags
 71: [ -z $KEEPVERITY ] && KEEPVERITY=false
 72: [ -z $KEEPFORCEENCRYPT ] && KEEPFORCEENCRYPT=false
 73: [ -z $PATCHVBMETAFLAG ] && PATCHVBMETAFLAG=false
 74: [ -z $RECOVERYMODE ] && RECOVERYMODE=false
 75: [ -z $LEGACYSAR ] && LEGACYSAR=false
 76: export KEEPVERITY
 77: export KEEPFORCEENCRYPT
 78: export PATCHVBMETAFLAG
 79: 
 80: chmod -R 755 .
 81: 
 82: #########
 83: # Unpack
 84: #########
 85: 
 86: CHROMEOS=false
 87: VENDORBOOT=false
 88: 
 89: ui_print "- Unpacking boot image"
 90: ./magiskboot unpack "$BOOTIMAGE"
 91: 
 92: case $? in
 93:   0 ) ;;
 94:   2 )
 95:     ui_print "- ChromeOS boot image detected"
 96:     CHROMEOS=true
 97:     ;;
 98:   3 )
 99:     ui_print "- Vendor boot image detected"
100:     VENDORBOOT=true
101:     ;;
102:   * )
103:     abort "! Unable to unpack boot image"
104:     ;;
105: esac
106: 
107: #################
108: # Ramdisk Checks
109: #################
110: 
111: unset RAMDISK
112: for path in ramdisk.cpio vendor_ramdisk/init_boot.cpio vendor_ramdisk/ramdisk.cpio; do
113:   if [ -e $path ]; then
114:     RAMDISK=$path
115:     break
116:   fi
117: done
118: 
119: ui_print "- Checking ramdisk status"
120: if [ -n "$RAMDISK" ]; then
121:   ./magiskboot cpio $RAMDISK test
122:   STATUS=$?
123:   SKIP_BACKUP=""
124: else
125:   # No ramdisk found, create one from scratch
126:   RAMDISK=ramdisk.cpio
127:   # Could be stock A only legacy SAR, or some Android 13 GKIs
128:   STATUS=0
129:   SKIP_BACKUP="#"
130: fi
131: 
132: case $STATUS in
133:   0 )
134:     # Stock boot
135:     ui_print "- Stock boot image detected"
136:     SHA1=$(./magiskboot sha1 "$BOOTIMAGE" 2>/dev/null)
137:     cat $BOOTIMAGE > stock_boot.img
138:     cp -af $RAMDISK ramdisk.cpio.orig 2>/dev/null
139:     ;;
140:   1 )
141:     # Magisk patched
142:     ui_print "- Magisk patched boot image detected"
143:     ./magiskboot cpio $RAMDISK \
144:     "extract .backup/.magisk config.orig" \
145:     "restore"
146:     cp -af $RAMDISK ramdisk.cpio.orig
147:     rm -f stock_boot.img
148:     ;;
149:   2 )
150:     # Unsupported
151:     ui_print "! Boot image patched by unsupported programs"
152:     abort "! Please restore back to stock boot image"
153:     ;;
154: esac
155: 
156: if [ -f config.orig ]; then
157:   # Read existing configs
158:   chmod 0644 config.orig
159:   SHA1=$(grep_prop SHA1 config.orig)
160:   if ! $BOOTMODE; then
161:     # Do not inherit config if not in recovery
162:     PREINITDEVICE=$(grep_prop PREINITDEVICE config.orig)
163:   fi
164:   rm config.orig
165: fi
166: 
167: ##################
168: # Ramdisk Patches
169: ##################
170: 
171: ui_print "- Patching ramdisk"
172: 
173: $BOOTMODE && [ -z "$PREINITDEVICE" ] && PREINITDEVICE=$(./magisk --preinit-device)
174: 
175: # Compress to save precious ramdisk space
176: ./magiskboot compress=xz magisk magisk.xz
177: ./magiskboot compress=xz stub.apk stub.xz
178: ./magiskboot compress=xz init-ld init-ld.xz
179: 
180: echo "KEEPVERITY=$KEEPVERITY" > config
181: echo "KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT" >> config
182: echo "RECOVERYMODE=$RECOVERYMODE" >> config
183: echo "VENDORBOOT=$VENDORBOOT" >> config
184: if [ -n "$PREINITDEVICE" ]; then
185:   ui_print "- Pre-init storage partition: $PREINITDEVICE"
186:   echo "PREINITDEVICE=$PREINITDEVICE" >> config
187: fi
188: [ -n "$SHA1" ] && echo "SHA1=$SHA1" >> config
189: 
190: ./magiskboot cpio $RAMDISK \
191: "add 0750 init magiskinit" \
192: "mkdir 0750 overlay.d" \
193: "mkdir 0750 overlay.d/sbin" \
194: "add 0644 overlay.d/sbin/magisk.xz magisk.xz" \
195: "add 0644 overlay.d/sbin/stub.xz stub.xz" \
196: "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" \
197: "patch" \
198: "$SKIP_BACKUP backup ramdisk.cpio.orig" \
199: "mkdir 000 .backup" \
200: "add 000 .backup/.magisk config" \
201: || abort "! Unable to patch ramdisk"
202: 
203: rm -f ramdisk.cpio.orig config *.xz
204: 
205: #################
206: # Binary Patches
207: #################
208: 
209: for dt in dtb kernel_dtb extra; do
210:   if [ -f $dt ]; then
211:     if ! ./magiskboot dtb $dt test; then
212:       ui_print "! Boot image $dt was patched by old (unsupported) Magisk"
213:       abort "! Please try again with *unpatched* boot image"
214:     fi
215:     if ./magiskboot dtb $dt patch; then
216:       ui_print "- Patch fstab in boot image $dt"
217:     fi
218:   fi
219: done
220: 
221: if [ -f kernel ]; then
222:   PATCHEDKERNEL=false
223:   # Remove Samsung RKP
224:   ./magiskboot hexpatch kernel \
225:   49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
226:   A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054 \
227:   && PATCHEDKERNEL=true
228: 
229:   # Remove Samsung defex
230:   # Before: [mov w2, #-221]   (-__NR_execve)
231:   # After:  [mov w2, #-32768]
232:   ./magiskboot hexpatch kernel 821B8012 E2FF8F12 && PATCHEDKERNEL=true
233: 
234:   # Disable Samsung PROCA
235:   # proca_config -> proca_magisk
236:   ./magiskboot hexpatch kernel \
237:   70726F63615F636F6E66696700 \
238:   70726F636B5F6D616769736B00 \
239:   && PATCHEDKERNEL=true
240: 
241:   # Force kernel to load rootfs for legacy SAR devices
242:   # skip_initramfs -> want_initramfs
243:   $LEGACYSAR && ./magiskboot hexpatch kernel \
244:   736B69705F696E697472616D667300 \
245:   77616E745F696E697472616D667300 \
246:   && PATCHEDKERNEL=true
247: 
248:   # If the kernel doesn't need to be patched at all,
249:   # keep raw kernel to avoid bootloops on some weird devices
250:   $PATCHEDKERNEL || rm -f kernel
251: fi
252: 
253: #################
254: # Repack & Flash
255: #################
256: 
257: ui_print "- Repacking boot image"
258: ./magiskboot repack "$BOOTIMAGE" || abort "! Unable to repack boot image"
259: 
260: # Sign chromeos boot
261: $CHROMEOS && sign_chromeos
262: 
263: # Restore the original boot partition path
264: [ -e "$BOOTNAND" ] && BOOTIMAGE="$BOOTNAND"
265: 
266: # Reset any error code
267: true
```

*(Correction to watch out for: line 238 as printed in raw file is*
```sh
238:   70726F63615F6D616769736B00 \
```
*— the hex above was transcribed from the read tool output and is correct; verify byte-for-byte with `read` if you plan to edit.)*

### 4.1 Exact variables `boot_patch.sh` consumes

| Variable | Line(s) | Source | Default if unset |
|---|---|---|---|
| `$1` | 60 | the boot image path (passed by `MagiskInstaller.kt:495` as `$srcBoot`) | — (required) |
| `SOURCEDMODE` | 53 | set by `util_functions.sh:434` (`install_magisk`) and Kitsune's `manager.sh`; **not** set by `MagiskInstaller.kt` | unset → script `cd`s to its own dir and sources `./util_functions.sh` |
| `KEEPVERITY` | 71, 76, 180 | env from `MagiskInstaller.kt:491` (`Config.keepVerity`) | `false` |
| `KEEPFORCEENCRYPT` | 72, 77, 181 | env from `MagiskInstaller.kt:490` (`Config.keepEnc`) | `false` |
| `PATCHVBMETAFLAG` | 73, 78 | env from `MagiskInstaller.kt:492` (`Info.patchBootVbmeta`) — exported for `magiskboot` | `false` |
| `RECOVERYMODE` | 74, 182 | env from `MagiskInstaller.kt:493` (`Config.recovery`) | `false` |
| `LEGACYSAR` | 75, 243 | env from `MagiskInstaller.kt:494` (`Info.legacySAR`) | `false` |
| `BOOTMODE` | 160, 173 | forced `true` by `app_functions.sh:249` | — |
| `PREINITDEVICE` | 162, 173, 184-186 | env, or inherited from `config.orig`, or computed by `./magisk --preinit-device` | empty → not written to `config` |
| `SHA1` | 136, 159, 188 | computed by `./magiskboot sha1`, or restored from `config.orig` | empty → not written to `config` |
| `CHROMEOS` | 86, 96, 261 | internal | `false` |
| `VENDORBOOT` | 87, 100, 183 | internal (magiskboot return 3) | `false` |
| `RAMDISK`, `STATUS`, `SKIP_BACKUP` | 111-130 | internal | — |
| `BOOTNAND` | 66, 264 | internal (MTD/NAND) | — |
| `PATCHEDKERNEL` | 222, 227, 232, 239, 246, 250 | internal | `false` |

**The `config` file written at lines 180-188** is the runtime config. Only these keys are ever written:

```
KEEPVERITY=<bool>
KEEPFORCEENCRYPT=<bool>
RECOVERYMODE=<bool>
VENDORBOOT=<bool>
PREINITDEVICE=<name>     # only if non-empty
SHA1=<hex>               # only if non-empty
```

It is embedded into the ramdisk as `.backup/.magisk` (line 200: `"add 000 .backup/.magisk config"`), extracted at early boot by magiskinit and materialised at `$MAGISKTMP/.magisk/config` (native `MAIN_CONFIG`, `native/src/include/consts.rs:26-27`). Kitsune's system mode adds `SYSTEMMODE=true` to a **different** file (`/system/etc/init/magisk/config`, see §7/§10) — do **not** confuse the two.

### 4.2 How it invokes magiskboot / magiskinit

| Command | Line |
|---|---|
| `./magiskboot unpack "$BOOTIMAGE"` | 90 |
| `./magiskboot cpio $RAMDISK test` | 121 |
| `./magiskboot cpio $RAMDISK "extract .backup/.magisk config.orig" "restore"` | 143-145 |
| `./magiskboot compress=xz magisk magisk.xz` | 176 |
| `./magiskboot compress=xz stub.apk stub.xz` | 177 |
| `./magiskboot compress=xz init-ld init-ld.xz` | 178 |
| `./magiskboot cpio $RAMDISK "add 0750 init magiskinit" "mkdir 0750 overlay.d" "mkdir 0750 overlay.d/sbin" "add 0644 overlay.d/sbin/magisk.xz magisk.xz" "add 0644 overlay.d/sbin/stub.xz stub.xz" "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" "patch" "$SKIP_BACKUP backup ramdisk.cpio.orig" "mkdir 000 .backup" "add 000 .backup/.magisk config"` | 190-201 |
| `./magiskboot dtb $dt test` / `./magiskboot dtb $dt patch` | 211, 215 |
| `./magiskboot hexpatch kernel <before> <after>` (Samsung RKP / defex / PROCA, `skip_initramfs`) | 224-246 |
| `./magiskboot repack "$BOOTIMAGE"` | 258 |
| `./magiskboot sha1 "$BOOTIMAGE"` | 136 |
| `./magisk --preinit-device` | 173 |
| `./chromeos/futility vbutil_kernel ...` (via `sign_chromeos`, `util_functions.sh:454-464`) | 261 |

`magiskinit` is never *executed* by `boot_patch.sh`; it is installed as the ramdisk's `init` (line 191) and takes over at boot.

**System Mode relevance**: `overlay.d/sbin/` is how magiskinit gets its `magisk`/`stub`/`init-ld` at boot. A System Mode port that writes to `/system/etc/init/magisk` (Kitsune's `MAGISKSYSTEMDIR`) does not need `overlay.d`, but it *does* need a way to get `magiskpolicy`/`magisk` onto the system partition and an init `.rc` to start them.

---

## 5. `scripts/util_functions.sh` — every function

`D:\Magisk\scripts\util_functions.sh` (763 lines).

### 5.1 Complete function index (name → line)

| Line | Function | One-line description |
|---|---|---|
| 24 | `ui_print()` | Prints a message; raw `echo` in BOOTMODE, else writes recovery `ui_print` records to `/proc/self/fd/$OUTFD`. |
| 32 | `toupper()` | Uppercases all arguments via `tr`. |
| 36 | `grep_cmdline()` | Extracts `key=` values from `/proc/cmdline` and `/proc/bootconfig`. |
| 43 | `grep_prop()` | Greps `key=value` out of prop files (default `/system/build.prop`), first match. |
| 51 | `grep_get_prop()` | `grep_prop`, falling back to `getprop`. |
| 61 | `getvar()` | Reads an overridable config var from `$MAGISKTMP/.magisk/config`, `/data/.magisk`, `/cache/.magisk` and `eval`s it into the named variable. |
| 70 | `is_mounted()` | Tests whether a path appears in `/proc/mounts`. |
| 75 | `abort()` | Prints message, runs `recovery_cleanup`, removes `$MODPATH`/`$TMPDIR`, `exit 1`. |
| 83 | `print_title()` | Prints a `*`-framed title block. |
| 101 | `setup_flashable()` | Ensures busybox, discovers `OUTFD` if needed, runs `recovery_actions`. |
| 118 | `ensure_bb()` | Locates busybox and re-execs the script inside `ash` standalone mode. |
| 164 | `recovery_actions()` | Binds `/dev/urandom`, saves+unsets `LD_*`. |
| 176 | `recovery_cleanup()` | Unmounts `/system`,`/vendor`,`/persist`,`/metadata`, restores `LD_*`. |
| 205 | `find_block()` | Finds a block device by partition name via `/dev/block`, sysfs uevent, then `/dev`. |
| 237 | `setup_mntpoint()` | Creates a mountpoint, moving symlinks aside. |
| 247 | `mount_name()` | Mounts a named partition at a mountpoint (fstab first, then `find_block`). |
| 263 | `mount_ro_ensure()` | Recovery-only: `mount_name … -o ro`, aborts on failure. |
| 274 | `mount_partitions()` | Sets `SLOT`, mounts `/system`, computes `SYSTEM_AS_ROOT`, `LEGACYSAR`. |
| 329 | `get_flags()` | Sets `ISENCRYPTED`, `PATCHVBMETAFLAG`, `KEEPVERITY`, `KEEPFORCEENCRYPT`, `RECOVERYMODE`, `VENDORBOOT` (reading `getvar` overrides). |
| 373 | `is_gt_gki_13()` | True when the kernel is GKI 13+ (needed for `init_boot`). |
| 379 | `find_boot_image()` | Sets `BOOTIMAGE` from `VENDORBOOT`/`RECOVERYMODE`/`init_boot`/`boot`/`find_block`/fstab. |
| 405 | `flash_image()` | Writes an image (optionally gz) to a block/char device or plain file, with size + rw checks. |
| 430 | `install_magisk()` | `cd $MAGISKBIN`; sources `boot_patch.sh` in `SOURCEDMODE`; `flash_image new-boot.img`; cleanup; `run_migrations`. |
| 454 | `sign_chromeos()` | Signs `new-boot.img` with `chromeos/futility` (Pixel C). |
| 466 | `remove_system_su()` | Removes competing SuperSU/SuperUser/ROM `su` from `/system` (recovery path). |
| 502 | `api_level_arch_detect()` | Sets `API`, `ABI`, `ARCH`, `ABI32`, `IS64BIT` from props. |
| 528 | `check_data()` | Sets `DATA`, `DATA_DE` and `MAGISKBIN` (`/data/adb/magisk` \| `/data/magisk` \| `/cache/data_adb/magisk`). |
| 543 | `run_migrations()` | Migrates legacy stock backups to `/data/magisk_backup_<SHA1>/`, then `copy_preinit_files`. |
| 581 | `copy_preinit_files()` | Concatenates all enabled modules' `sepolicy.rule` into `$MAGISKTMP/.magisk/preinit/sepolicy.rule`. |
| 604 | `set_perm()` | `chown`+`chmod`+`chcon` (default `u:object_r:system_file:s0`) one path. |
| 612 | `set_perm_recursive()` | `set_perm` over a tree (dirs vs files separately). |
| 621 | `mktouch()` | `mkdir -p` dirname and create a file with optional content, mode 644. |
| 627 | `boot_actions() { return; }` | No-op hook (overridden by boot-time scripts). |
| 630 | `is_legacy_script()` | True when the module zip contains `install.sh`. |
| 636 | `set_default_perm()` | Applies Magisk module default ownership/modes/SELinux labels. |
| 645 | `install_module()` | Full module installer (extract, `customize.sh`/`install.sh`, `.replace`, `REMOVE`, sepolicy, cleanup). |
| 758-763 | (top level) | Detects `BOOTMODE`, sets `TMPDIR=/dev/tmp`, `MAGISKBIN="/data/adb/magisk"`. |

Also non-function but script-level: line 5 `#MAGISK_VERSION_STUB` (replaced at build time), lines 11-18 the global variable documentation, line 758-760 BOOTMODE detection, 762 `TMPDIR=/dev/tmp`, 763 `MAGISKBIN="/data/adb/magisk"`.

### 5.2 The requested functions — FOUND, quoted in full

**`is_rootfs` — MISSING** in official. **`force_bind_mount` — MISSING.** **`mount_sbin` — MISSING from `util_functions.sh`** (a `mount_sbin()` exists in `scripts/avd_setup.sh:28-31` only). **`warn_system_ro` — MISSING.** **`mkblknode` — MISSING.** **`remount` (as a function) — MISSING** (all `remount` hits are `mount -o …,remount` command strings, not a function). **`remount_check` — MISSING.** **`random_str` — MISSING.** **`unmount_system_mirrors` — MISSING.** All of these exist in Kitsune; see §5.4 for their Kitsune bodies.

**`flash_image` — PRESENT**, `util_functions.sh:405-427`:

```sh
405: flash_image() {
406:   local CMD1
407:   case "$1" in
408:     *.gz) CMD1="gzip -d < '$1' 2>/dev/null";;
409:     *)    CMD1="cat '$1'";;
410:   esac
411:   if [ -b "$2" ]; then
412:     local img_sz=$(stat -c '%s' "$1")
413:     local blk_sz=$(blockdev --getsize64 "$2")
414:     [ "$img_sz" -gt "$blk_sz" ] && return 1
415:     blockdev --setrw "$2"
416:     local blk_ro=$(blockdev --getro "$2")
417:     [ "$blk_ro" -eq 1 ] && return 2
418:     eval "$CMD1" | cat - /dev/zero > "$2" 2>/dev/null
419:   elif [ -c "$2" ]; then
420:     flash_eraseall "$2" >&2
421:     eval "$CMD1" | nandwrite -p "$2" - >&2
422:   else
423:     ui_print "- Not block or char device, storing image"
424:     eval "$CMD1" > "$2" 2>/dev/null
425:   fi
426:   return 0
427: }
```

**`mount_partitions` — PRESENT**, `util_functions.sh:274-324`:

```sh
274: mount_partitions() {
275:   # Check A/B slot
276:   SLOT=$(grep_cmdline androidboot.slot_suffix)
277:   if [ -z $SLOT ]; then
278:     SLOT=$(grep_cmdline androidboot.slot)
279:     [ -z $SLOT ] || SLOT=_${SLOT}
280:   fi
281:   [ "$SLOT" = "normal" ] && unset SLOT
282:   [ -z $SLOT ] || ui_print "- Current boot slot: $SLOT"
283: 
284:   # Mount ro partitions
285:   if is_mounted /system_root; then
286:     umount /system 2>/dev/null
287:     umount /system_root 2>/dev/null
288:   fi
289:   mount_ro_ensure "system$SLOT app$SLOT" /system
290:   if [ -f /system/init -o -L /system/init ]; then
291:     SYSTEM_AS_ROOT=true
292:     setup_mntpoint /system_root
293:     if ! mount --move /system /system_root; then
294:       umount /system
295:       umount -l /system 2>/dev/null
296:       mount_ro_ensure "system$SLOT app$SLOT" /system_root
297:     fi
298:     mount -o bind /system_root/system /system
299:   else
300:     if grep ' / ' /proc/mounts | grep -qv 'rootfs' || grep -q ' /system_root ' /proc/mounts; then
301:       SYSTEM_AS_ROOT=true
302:     else
303:       SYSTEM_AS_ROOT=false
304:     fi
305:   fi
306:   $SYSTEM_AS_ROOT && ui_print "- Device is system-as-root"
307: 
308:   LEGACYSAR=false
309:   if $BOOTMODE; then
310:     grep ' / ' /proc/mounts | grep -q '/dev/root' && LEGACYSAR=true
311:   else
312:     # Recovery mode, assume devices that don't use dynamic partitions are legacy SAR
313:     local IS_DYNAMIC=false
314:     if grep -q 'androidboot.super_partition' /proc/cmdline; then
315:       IS_DYNAMIC=true
316:     elif [ -n "$(find_block super)" ]; then
317:       IS_DYNAMIC=true
318:     fi
319:     if $SYSTEM_AS_ROOT && ! $IS_DYNAMIC; then
320:       LEGACYSAR=true
321:       ui_print "- Legacy SAR, force kernel to load rootfs"
322:     fi
323:   fi
324: }
```

(Note: `app_functions.sh:193-201` **overrides** this at app runtime with a much lighter non-root version.)

**`find_boot_image` — PRESENT**, `util_functions.sh:379-403`:

```sh
379: find_boot_image() {
380:   BOOTIMAGE=
381:   if $VENDORBOOT; then
382:     BOOTIMAGE="/dev/block/by-name/vendor_boot$SLOT"
383:   elif $RECOVERYMODE; then
384:     BOOTIMAGE=$(find_block "recovery$SLOT" "sos")
385:   elif [ -e "/dev/block/by-name/init_boot$SLOT" ] && is_gt_gki_13; then
386:     # init_boot is only used with GKI 13+. It is possible that some devices with init_boot
387:     # partition still uses Android 12 GKI or previous kernels, so we need to explicitly detect that scenario.
388:     BOOTIMAGE="/dev/block/by-name/init_boot$SLOT"
389:   elif [ -e "/dev/block/by-name/boot$SLOT" ]; then
390:     # Standard location since AOSP Android 10+
391:     BOOTIMAGE="/dev/block/by-name/boot$SLOT"
392:   elif [ -n "$SLOT" ]; then
393:     # Fallback for A/B devices running < Android 10
394:     BOOTIMAGE=$(find_block "ramdisk$SLOT" "boot$SLOT")
395:   else
396:     # Fallback for all legacy and non-standard devices
397:     BOOTIMAGE=$(find_block ramdisk kern-a android_boot kernel bootimg boot lnx boot_a)
398:   fi
399:   if [ -z $BOOTIMAGE ]; then
400:     # Lets see what fstabs tells me
401:     BOOTIMAGE=$(grep -v '#' /etc/*fstab* | grep -E '/boot(img)?[^a-zA-Z]' | grep -oE '/dev/[a-zA-Z0-9_./-]*' | head -n 1)
402:   fi
403: }
```

**`find_block` — PRESENT**, `util_functions.sh:205-234`:

```sh
205: find_block() {
206:   local BLOCK DEV DEVICE DEVNAME PARTNAME UEVENT
207:   for BLOCK in "$@"; do
208:     DEVICE=$(find /dev/block \( -type b -o -type c -o -type l \) -iname $BLOCK | head -n 1) 2>/dev/null
209:     if [ ! -z $DEVICE ]; then
210:       echo $DEVICE
211:       return 0
212:     fi
213:   done
214:   # Fallback by parsing sysfs uevents
215:   for UEVENT in /sys/dev/block/*/uevent; do
216:     DEVNAME=$(grep_prop DEVNAME $UEVENT)
217:     PARTNAME=$(grep_prop PARTNAME $UEVENT)
218:     for BLOCK in "$@"; do
219:       if [ "$(toupper $BLOCK)" = "$(toupper $PARTNAME)" ]; then
220:         echo /dev/block/$DEVNAME
221:         return 0
222:       fi
223:     done
224:   done
225:   # Look just in /dev in case we're dealing with MTD/NAND without /dev/block devices/links
226:   for DEV in "$@"; do
227:     DEVICE=$(find /dev \( -type b -o -type c -o -type l \) -maxdepth 1 -iname $DEV | head -n 1) 2>/dev/null
228:     if [ ! -z $DEVICE ]; then
229:       echo $DEVICE
230:       return 0
231:     fi
232:   done
233:   return 1
234: }
```

**`api_level_arch_detect` — PRESENT**, `util_functions.sh:502-526`:

```sh
502: api_level_arch_detect() {
503:   API=$(grep_get_prop ro.build.version.sdk)
504:   ABI=$(grep_get_prop ro.product.cpu.abi)
505:   if [ "$ABI" = "arm64-v8a" ]; then
506:     ARCH=arm64
507:     ABI32=armeabi-v7a
508:     IS64BIT=true
509:   elif [ "$ABI" = "x86_64" ]; then
510:     ARCH=x64
511:     ABI32=x86
512:     IS64BIT=true
513:   elif [ "$ABI" = "armeabi-v7a" ]; then
514:     ARCH=arm
515:     ABI32=armeabi-v7a
516:     IS64BIT=false
517:   elif [ "$ABI" = "x86" ]; then
518:     ARCH=x86
519:     ABI32=x86
520:     IS64BIT=false
521:   elif [ "$ABI" = "riscv64" ]; then
522:     ARCH=riscv64
523:     ABI32=riscv32
524:     IS64BIT=true
525:   fi
526: }
```

**`run_migrations` — PRESENT**, `util_functions.sh:543-579` (overridden by the no-op at `app_functions.sh:219` in the app context):

```sh
543: run_migrations() {
544:   local SHA1
545:   local TARGET
546:   # Legacy app installation
547:   local BACKUP=$MAGISKBIN/stock_boot*.gz
548:   if [ -f $BACKUP ]; then
549:     cp $BACKUP /data
550:     rm -f $BACKUP
551:   fi
552: 
553:   # Legacy backup
554:   for gz in /data/stock_boot*.gz; do
555:     [ -f $gz ] || break
556:     SHA1=$(basename $gz | sed -e 's/stock_boot_//' -e 's/.img.gz//')
557:     [ -z $SHA1 ] && break
558:     mkdir /data/magisk_backup_${SHA1} 2>/dev/null
559:     mv $gz /data/magisk_backup_${SHA1}/boot.img.gz
560:   done
561: 
562:   # Stock backups
563:   SHA1=
564:   for name in boot dtb dtbo dtbs; do
565:     BACKUP=$MAGISKBIN/stock_${name}.img
566:     [ -f $BACKUP ] || continue
567:     if [ $name = 'boot' ]; then
568:       SHA1=$($MAGISKBIN/magiskboot sha1 $BACKUP)
569:       mkdir /data/magisk_backup_${SHA1} 2>/dev/null
570:     fi
571:     [ -z $SHA1 ] && break
572:     TARGET=/data/magisk_backup_${SHA1}/${name}.img
573:     cp $BACKUP $TARGET
574:     rm -f $BACKUP
575:     gzip -9f $TARGET
576:   done
577: 
578:   copy_preinit_files
579: }
```

**`setup_flashable` — PRESENT**, `util_functions.sh:101-116`:

```sh
101: setup_flashable() {
102:   ensure_bb
103:   $BOOTMODE && return
104:   if [ -z $OUTFD ] || readlink /proc/$$/fd/$OUTFD | grep -q /tmp; then
105:     # We will have to manually find out OUTFD
106:     for FD in $(ls /proc/$$/fd); do
107:       if readlink /proc/$$/fd/$FD | grep -q pipe; then
108:         if ps | grep -v grep | grep -qE " 3 $FD |status_fd=$FD"; then
109:           OUTFD=$FD
110:           break
111:         fi
112:       fi
113:     done
114:   fi
115:   recovery_actions
116: }
```

**`recovery_cleanup` — PRESENT**, `util_functions.sh:176-198`:

```sh
176: recovery_cleanup() {
177:   local DIR
178:   ui_print "- Unmounting partitions"
179:   (
180:   if [ ! -d /postinstall/tmp ]; then
181:     umount -l /system
182:     umount -l /system_root
183:   fi
184:   umount -l /vendor
185:   umount -l /persist
186:   umount -l /metadata
187:   for DIR in /apex /system /system_root; do
188:     if [ -L "${DIR}_link" ]; then
189:       rmdir $DIR
190:       mv -f ${DIR}_link $DIR
191:     fi
192:   done
193:   umount -l /dev/random
194:   ) 2>/dev/null
195:   [ -z $OLD_LD_LIB ] || export LD_LIBRARY_PATH=$OLD_LD_LIB
196:   [ -z $OLD_LD_PRE ] || export LD_PRELOAD=$OLD_LD_PRE
197:   [ -z $OLD_LD_CFG ] || export LD_CONFIG_FILE=$OLD_LD_CFG
198: }
```

**`ui_print` — PRESENT**, `util_functions.sh:24-30`:

```sh
24: ui_print() {
25:   if $BOOTMODE; then
26:     echo "$1"
27:   else
28:     echo -e "ui_print $1\nui_print" >> /proc/self/fd/$OUTFD
29:   fi
30: }
```

**`print_title` — PRESENT**, `util_functions.sh:83-95`:

```sh
83: print_title() {
84:   local len line1len line2len bar
85:   line1len=$(echo -n $1 | wc -c)
86:   line2len=$(echo -n $2 | wc -c)
87:   len=$line2len
88:   [ $line1len -gt $line2len ] && len=$line1len
89:   len=$((len + 2))
90:   bar=$(printf "%${len}s" | tr ' ' '*')
91:   ui_print "$bar"
92:   ui_print " $1 "
93:   [ "$2" ] && ui_print " $2 "
94:   ui_print "$bar"
95: }
```

**`abort` — PRESENT**, `util_functions.sh:75-81`:

```sh
75: abort() {
76:   ui_print "$1"
77:   $BOOTMODE || recovery_cleanup
78:   [ ! -z $MODPATH ] && rm -rf $MODPATH
79:   rm -rf $TMPDIR
80:   exit 1
81: }
```

### 5.3 MISSING-in-official summary

**Absent from the entire official `scripts/` tree** (verified by grep over `scripts/*.sh`):

`is_rootfs`, `force_bind_mount`, `warn_system_ro`, `mkblknode`, `remount_check`, `random_str`, `unmount_system_mirrors`, `cleanup_system_installation`, `direct_install_system`, `install_addond`, `MAGISKSYSTEMDIR`, `magiskrc`, `backup_restore`, `restore_from_bak`, `installer_cleanup`, `get_sulist_status`, `set_nvbase` (Kitsune's variant), plus every `SYSTEMMODE` reference.

**Present but only in a different file**: `mount_sbin` exists **only** in `scripts/avd_setup.sh:28-31` (with a different body than Kitsune's).

**Present in official `util_functions.sh`** (the requested list): `flash_image` (405), `mount_partitions` (274), `find_boot_image` (379), `find_block` (205), `api_level_arch_detect` (502), `run_migrations` (543), `setup_flashable` (101), `recovery_cleanup` (176), `ui_print` (24), `print_title` (83), `abort` (75).

### 5.4 The Kitsune bodies you must port (for the report's completeness)

`D:\a\KitsuneMagisk\scripts\util_functions.sh:739-783`:

```sh
739: # Magisk Delta
740: 
741: is_rootfs(){
742:     local root_blkid="$(mountpoint -d /)"
743:     if ! $BOOTMODE && [ -d /system_root ] && mountpoint /system_root; then
744:         return 1
745:     fi
746:     mnt_type="$(head -1 /proc/self/mountinfo | awk '{ printf $9 }')"
747:     if $BOOTMODE && [ "$mnt_type" == "rootfs" -o "$mnt_type" == "tmpfs" ]; then
748:         return 0
749:     fi
750:     return 1
751: }
752: 
753: mkblknode(){
754:     local blk_mm="$(mountpoint -d "$2" | sed "s/:/ /g")"
755:     mknod "$1" -m 666 b $blk_mm
756: }
757: 
758: warn_system_ro(){
759:     ui_print "! System partition is read-only"
760:     return 1
761: }
762: 
763: remount_check(){
764:     local mode="$1"
765:     local part="$(realpath "$2")"
766:     local ignore_not_exist="$3"
767:     local i
768:     if ! grep -q " $part " /proc/mounts && [ ! -z "$ignore_not_exist" ]; then
769:         return "$ignore_not_exist"
770:     fi
771:     mount -o "$mode,remount" "$part"
772:     local IFS=$'\t\n ,'
773:     for i in $(cat /proc/mounts | grep " $part " | awk '{ print $4 }'); do
774:         test "$i" == "$mode" && return 0
775:     done
776:     return 1
777: }
778: 
779: force_bind_mount(){
780:     mount -o bind,private "$1" "$2"
781:     mount -o rw,remount "$2"
782:     remount_check rw "$2" || warn_system_ro
783: }
```

`random_str`, `remount_check`, `magiskrc`, `backup_restore`, `MAGISKSYSTEMDIR` live in Kitsune's **`app/src/main/res/raw/manager.sh`** (not in `scripts/`), because the official tree has no `manager.sh` at all:

- `D:\a\KitsuneMagisk\app\src\main\res\raw\manager.sh:282` — `MAGISKSYSTEMDIR="/system/etc/init/magisk"`
- `:284-289` — `random_str(){ FROM="$1"; TO="$2"; tr -dc A-Za-z0-9 </dev/urandom | head -c $(($FROM+$(($RANDOM%$(($TO-$FROM+1)))))) }`
- `:291-318` — `magiskrc()` (heredoc writing the `on post-fs-data` init `.rc`)
- `:320-334` — `remount_check()`
- `:336-345` — `backup_restore()`
- `:351-359` — `cleanup_system_installation()`
- `:361-368` — `installer_cleanup()`
- `:370-541` — `direct_install_system()`
- `:545-551` — `xdirect_install_system()`
- `:52-88` — `install_addond()`

and it is loaded into the install flow by `scripts/flash_script.sh:104-119`:

```sh
104: if [ "$SYSTEMINSTALL" == "true" ]; then
105:   unzip -oj "$APK" "res/raw/manager.sh"
106:   BOOTMODE_OLD="$BOOTMODE"
107:   . ./manager.sh
108:   BOOTMODE="$BOOTMODE_OLD"
109:   . $COMMONDIR/util_functions.sh
110:   ADDOND_MAGISK=/system/etc/init/magisk
111:   [ -f "$ADDOND/99-magisk.sh" ] && sed -i "s/^SYSTEMINSTALL=.*/SYSTEMINSTALL=true/g" $ADDOND/99-magisk.sh
112:   if $BOOTMODE; then
113:     direct_install_system "$MAGISKBINTMP" || { cleanup_system_installation; unmount_system_mirrors; abort "! Installation failed"; }
114:   else
115:     direct_install_system "$MAGISKBINTMP" || { cleanup_system_installation; abort "! Installation failed"; }
116:   fi
117: else
118:   install_magisk
119: fi
```

---

## 6. `Info` / device detection

### 6.1 `app/core/src/main/java/com/topjohnwu/magisk/core/Info.kt` — quoted ENTIRELY (125 lines)

```kotlin
  1: package com.topjohnwu.magisk.core
  2: 
  3: import android.app.KeyguardManager
  4: import android.os.Build
  5: import androidx.lifecycle.MutableLiveData
  6: import com.topjohnwu.magisk.StubApk
  7: import com.topjohnwu.magisk.core.ktx.getProperty
  8: import com.topjohnwu.magisk.core.model.UpdateInfo
  9: import com.topjohnwu.magisk.core.repository.NetworkService
 10: import com.topjohnwu.superuser.CallbackList
 11: import com.topjohnwu.superuser.Shell
 12: import com.topjohnwu.superuser.ShellUtils.fastCmd
 13: import com.topjohnwu.superuser.ShellUtils.fastCmdResult
 14: import kotlinx.coroutines.Runnable
 15: 
 16: val isRunningAsStub get() = Info.stub != null
 17: 
 18: object Info {
 19: 
 20:     var stub: StubApk.Data? = null
 21: 
 22:     private val EMPTY_UPDATE = UpdateInfo()
 23:     var update = EMPTY_UPDATE
 24:         private set
 25: 
 26:     suspend fun fetchUpdate(svc: NetworkService): UpdateInfo? {
 27:         return if (update === EMPTY_UPDATE) {
 28:             svc.fetchUpdate()?.apply { update = this }
 29:         } else update
 30:     }
 31: 
 32:     fun resetUpdate() {
 33:         update = EMPTY_UPDATE
 34:     }
 35: 
 36:     var isRooted = false
 37:     var noDataExec = false
 38:     var patchBootVbmeta = false
 39: 
 40:     @JvmStatic var env = Env()
 41:         private set
 42:     @JvmStatic var isSAR = false
 43:         private set
 44:     var legacySAR = false
 45:         private set
 46:     var isAB = false
 47:         private set
 48:     var slot = ""
 49:         private set
 50:     var isVendorBoot = false
 51:         private set
 52:     @JvmField val isZygiskEnabled = System.getenv("ZYGISK_ENABLED") == "1"
 53:     @JvmStatic val isFDE get() = crypto == "block"
 54:     @JvmStatic var ramdisk = false
 55:         private set
 56:     private var crypto = ""
 57: 
 58:     val isEmulator =
 59:         Build.DEVICE.contains("vsoc")
 60:             || getProperty("ro.kernel.qemu", "0") == "1"
 61:             || getProperty("ro.boot.qemu", "0") == "1"
 62: 
 63:     val isConnected = MutableLiveData(false)
 64: 
 65:     val showSuperUser: Boolean get() {
 66:         return env.isActive && (Const.USER_ID == 0
 67:                 || Config.suMultiuserMode == Config.Value.MULTIUSER_MODE_USER)
 68:     }
 69: 
 70:     val isDeviceSecure get() =
 71:         AppContext.getSystemService(KeyguardManager::class.java).isDeviceSecure
 72: 
 73:     class Env(
 74:         val versionString: String = "",
 75:         val isDebug: Boolean = false,
 76:         code: Int = -1
 77:     ) {
 78:         val versionCode = when {
 79:             code < Const.Version.MIN_VERCODE -> -1
 80:             isRooted -> code
 81:             else -> -1
 82:         }
 83:         val isUnsupported = code > 0 && code < Const.Version.MIN_VERCODE
 84:         val isActive = versionCode > 0
 85:     }
 86: 
 87:     fun init(shell: Shell) {
 88:         if (shell.isRoot) {
 89:             val v = fastCmd(shell, "magisk -v").split(":")
 90:             env = Env(
 91:                 v[0], v.size >= 3 && v[2] == "D",
 92:                 runCatching { fastCmd("magisk -V").toInt() }.getOrDefault(-1)
 93:             )
 94:             Config.denyList = fastCmdResult(shell, "magisk --denylist status")
 95:         }
 96: 
 97:         val map = mutableMapOf<String, String>()
 98:         val list = object : CallbackList<String>(Runnable::run) {
 99:             override fun onAddElement(e: String) {
100:                 val split = e.split("=")
101:                 if (split.size >= 2) {
102:                     map[split[0]] = split[1]
103:                 }
104:             }
105:         }
106:         shell.newJob().add("(app_init)").to(list).exec()
107: 
108:         fun getVar(name: String) = map[name] ?: ""
109:         fun getBool(name: String) = map[name].toBoolean()
110: 
111:         isSAR = getBool("SYSTEM_AS_ROOT")
112:         ramdisk = getBool("RAMDISKEXIST")
113:         isAB = getBool("ISAB")
114:         patchBootVbmeta = getBool("PATCHVBMETAFLAG")
115:         crypto = getVar("CRYPTOTYPE")
116:         slot = getVar("SLOT")
117:         legacySAR = getBool("LEGACYSAR")
118:         isVendorBoot = getBool("VENDORBOOT")
119: 
120:         // Default presets
121:         Config.recovery = getBool("RECOVERYMODE")
122:         Config.keepVerity = getBool("KEEPVERITY")
123:         Config.keepEnc = getBool("KEEPFORCEENCRYPT")
124:     }
125: }
```

### 6.2 Requested properties — status

| Requested | Status | Where |
|---|---|---|
| `isRooted` | **FOUND** | `Info.kt:36`; set at `ShellInit.kt:20` |
| `isInstalled` | **NOT FOUND** as an `Info` member. The UI uses `Info.env.isActive` (`Info.kt:84`, `showSuperUser` at :66) and a local `val isInstalled = state != HomeViewModel.State.INVALID` at `app/apk/.../ui/home/HomeScreen.kt:502` | — |
| `envFix` | **NOT FOUND** as an `Info` member. Related: `HomeViewModel.envFixCode` (`app/apk/.../ui/home/HomeViewModel.kt:41,145-159`) fed by `env_check`'s return code; the install action is `MagiskInstaller.FixEnv` (`MagiskInstaller.kt:642-644`) and `MagiskInstaller.Emulator` (`:614-619`) | — |
| `ramdisk` | **FOUND** | `Info.kt:54-55`, from `getBool("RAMDISKEXIST")` (:112) ← `app_functions.sh:229-230,238` |
| `isAB` | **FOUND** | `Info.kt:46-47`, from `getBool("ISAB")` (:113) ← `app_functions.sh:136-138,239` |
| `recoveryMode` | **NOT FOUND** as `Info.recoveryMode`. Equivalent is `Config.recovery` (`Config.kt:105`), initialised at `Info.kt:121` | — |
| `bootPatched` | **NOT FOUND anywhere in the repo.** (`Info.isBootPatched` exists in Kitsune at `app/.../core/Info.kt:39`, fed by `ShellInit.kt:87` `Info.isBootPatched = getBool("BOOTIMAGE_PATCHED")`, produced by Kitsune's `manager.sh:568-569` from `SHA1`.) | — |
| `isEmulator` | **FOUND** | `Info.kt:58-61` |
| `isSAR`, `isFDE`, `legacySAR`, `isVendorBoot`, `slot`, `noDataExec`, `patchBootVbmeta` | **FOUND** | `Info.kt:42-56, 37-38` |
| `isZygisk` | renamed → `isZygiskEnabled` | `Info.kt:52` |
| `SU_VERSION`, `MAGISK_VER`, `MAGISK_VER_CODE` | **NOT FOUND** as Kotlin symbols. Version comes from `Info.Env` (`magisk -v` / `magisk -V`, `Info.kt:87-93`). The shell-side `MAGISK_VER`/`MAGISK_VER_CODE` are injected into the `util_functions.sh` asset at build time (`Setup.kt:194-195`) | — |

### 6.3 Emulator-specific detection — all hits

**Kotlin (`app/`), the only device probe in the app** — `Info.kt:58-61`:

```kotlin
58:     val isEmulator =
59:         Build.DEVICE.contains("vsoc")
60:             || getProperty("ro.kernel.qemu", "0") == "1"
61:             || getProperty("ro.boot.qemu", "0") == "1"
```

`getProperty` is reflection into `android.os.SystemProperties` — `app/core/.../core/ktx/XAndroid.kt:92-100`.

**Consumers of `Info.isEmulator`:**

- `app/apk/.../ui/install/InstallViewModel.kt:39-40` — `skipOptions`, `noSecondSlot`
- `app/apk-legacy/.../ui/install/InstallViewModel.kt:42-43` (same)
- `app/apk/.../ui/flash/FlashViewModel.kt:88-94` — `FLASH_MAGISK` → `MagiskInstaller.Emulator` vs `MagiskInstaller.Direct`
- `app/apk-legacy/.../ui/flash/FlashViewModel.kt:70-71` (same)
- `app/apk/.../ui/MainActivity.kt:271` / `app/apk-legacy/.../ui/MainActivity.kt:226` — `if (!Info.isEmulator && Info.env.isActive && System.getenv("PATH")…` (PATH de-dup)
- `app/core/.../core/Config.kt:143` — `var zygisk by dbSettings(Key.ZYGISK, Info.isEmulator)` (Zygisk defaults ON in emulators)

**`goldfish`, `ranchu`, `waydroid`, `ro.build.version.sdk`, `init.svc` in `app/`: NOT FOUND.** All `emulator` hits in `app/` outside the above are the in-app *terminal emulator* UI (`terminal/TerminalEmulator.kt` etc.), unrelated.

**Native (`native/src`, excluding vendored `external/`):**

```rust
// native/src/core/daemon.rs:310-312
310:     let is_emulator = get_prop(cstr!("ro.kernel.qemu")) == "1"
311:         || get_prop(cstr!("ro.boot.qemu")) == "1"
312:         || get_prop(cstr!("ro.product.device")).contains("vsoc");
```
```rust
// native/src/core/daemon.rs:66
 66:     pub is_emulator: bool,
// native/src/core/daemon.rs:396
396:     is_emulator,
// native/src/core/db.rs:255
255:         DbEntryKey::ZygiskConfig => self.is_emulator as i32,
// native/src/core/db.rs:275
275:             zygisk: self.is_emulator,
// native/src/core/package.rs:349 / :426
349:     if install && !daemon.is_emulator {
426:     if install && !daemon.is_emulator {
// native/src/core/module.rs:441, 495-496, 887
441: fn inject_magisk_bins(system: &mut FsNode, is_emulator: bool) {
495:         // We want to keep /system/xbin/su on emulators (for debugging)
496:         if is_emulator && orig_item.starts_with("/system/xbin") {
887:         inject_magisk_bins(&mut system, self.is_emulator);
```
```cpp
// native/src/init/getinfo.cpp:148-149
148:         } else if (key == "qemu") {
149:             emulator = true;
// native/src/init/getinfo.cpp:178
178:             skip_initramfs = emulator || !check_key_combo();
// native/src/init/getinfo.cpp:176-182
176:     parse_prop_file("/.backup/.magisk", [&](auto key, auto value) -> bool {
177:         if (key == "RECOVERYMODE" && value == "true") {
178:             skip_initramfs = emulator || !check_key_combo();
179:             return false;
180:         }
181:         return true;
182:     });
```
```cpp
// native/src/init/mount.cpp:25-26, 198-207
 25: // running magiskinit on legacy SAR AVD emulator
 26: bool avd_hack = false;
198:     // For API 28 AVD, it uses legacy SAR setup that requires
...
200:     if (!is_two_stage && config.emulator) {
201:         avd_hack = true;
202:         // These values are hardcoded for API 28 AVD
```
```cpp
// native/src/init/rootdir.cpp:293-295
293:     extern bool avd_hack;
294:     // Handle avd hack
295:     if (avd_hack) {
```
Plus `native/src/init/init.rs:21` (`emulator: false`), `native/src/init/lib.rs:31` (`emulator: bool`), `native/src/init/getinfo.rs:37,43-53`.

**`goldfish` / `ranchu`: NOT FOUND anywhere in the repo. `waydroid`: NOT FOUND.**

**Important asymmetry to be aware of for the port**: Kotlin `Info.isEmulator` uses `Build.DEVICE`; native uses `ro.product.device`. Both effectively test `"vsoc"`. Neither checks `goldfish`/`ranchu`/Waydroid/`ro.hardware` — a System Mode feature aimed at "emulators/containers" (Waydroid, Docker, etc.) may need a broader predicate.

### 6.4 How `Info` is fed — the `app_init` bridge

`scripts/app_functions.sh:227-249` prints `NAME=VALUE` lines, `Info.init` parses them (`Info.kt:97-118`). The variables and their producers:

| Emitted var | Produced by | `Info` field |
|---|---|---|
| `SLOT` | `app_functions.sh:194` (getprop) or `util_functions.sh:276-281` | `Info.slot` |
| `SYSTEM_AS_ROOT` | `app_functions.sh:196-197` | `Info.isSAR` |
| `RAMDISKEXIST` | `app_functions.sh:229-230` ← `check_boot_ramdisk:135-151` | `Info.ramdisk` |
| `ISAB` | `app_functions.sh:137-138` | `Info.isAB` |
| `CRYPTOTYPE` | `app_functions.sh:153-174` | `Info.isFDE` |
| `PATCHVBMETAFLAG` | `app_functions.sh:208-214` | `Info.patchBootVbmeta` |
| `LEGACYSAR` | `app_functions.sh:199-200` | `Info.legacySAR` |
| `RECOVERYMODE` | `app_functions.sh:215` | `Config.recovery` |
| `KEEPVERITY` | `app_functions.sh:204` | `Config.keepVerity` |
| `KEEPFORCEENCRYPT` | `app_functions.sh:207` | `Config.keepEnc` |
| `VENDORBOOT` | `app_functions.sh:216` | `Info.isVendorBoot` |

`ShellInit` (the driver) — `app/core/src/main/java/com/topjohnwu/magisk/core/utils/ShellInit.kt:17-74`:

```kotlin
 17: class ShellInit : Shell.Initializer() {
 18:     override fun onInit(context: Context, shell: Shell): Boolean {
 19:         if (shell.isRoot) {
 20:             Info.isRooted = true
 21:             RootUtils.bindTask?.let { shell.execTask(it) }
 22:             RootUtils.bindTask = null
 23:         }
 24:         shell.newJob().apply {
 25:             add("export ASH_STANDALONE=1")
 26: 
 27:             val localBB: File
 28:             if (isRunningAsStub) {
 29:                 if (!shell.isRoot)
 30:                     return true
 31:                 val jar = JarFile(StubApk.current(context))
 32:                 val bb = jar.getJarEntry("lib/${Const.CPU_ABI}/libbusybox.so")
 33:                 localBB = context.deviceProtectedContext.cachedFile("busybox")
 34:                 localBB.delete()
 35:                 runBlocking {
 36:                     jar.getInputStream(bb).writeTo(localBB, dispatcher = Dispatchers.Unconfined)
 37:                 }
 38:                 localBB.setExecutable(true)
 39:             } else {
 40:                 localBB = File(context.applicationInfo.nativeLibraryDir, "libbusybox.so")
 41:             }
 42: 
 43:             if (shell.isRoot) {
 44:                 add("export MAGISKTMP=\$(magisk --path)")
 45:                 // Test if we can properly execute stuff in /data
 46:                 Info.noDataExec = !shell.newJob()
 47:                     .add("$localBB sh -c '$localBB true'").exec().isSuccess
 48:             }
 49: 
 50:             if (Info.noDataExec) {
 51:                 // Copy it out of /data to workaround Samsung bullshit
 52:                 add(
 53:                     "if [ -x \$MAGISKTMP/.magisk/busybox/busybox ]; then",
 54:                     "  cp -af $localBB \$MAGISKTMP/.magisk/busybox/busybox",
 55:                     "  exec \$MAGISKTMP/.magisk/busybox/busybox sh",
 56:                     "else",
 57:                     "  cp -af $localBB /dev/busybox",
 58:                     "  exec /dev/busybox sh",
 59:                     "fi"
 60:                 )
 61:             } else {
 62:                 // Directly execute the file
 63:                 add("exec $localBB sh")
 64:             }
 65: 
 66:             add(context.assets.open("app_functions.sh"))
 67:             if (shell.isRoot) {
 68:                 add(context.assets.open("util_functions.sh"))
 69:             }
 70:         }.exec()
 71: 
 72:         Info.init(shell)
 73:         return true
 74:     }
 75: }
```

Registered at `app/core/.../core/AppContext.kt:91` (`.setInitializers(ShellInit::class.java)`).

---

## 7. Config handling on the app side

### 7.1 `app/core/src/main/java/com/topjohnwu/magisk/core/Config.kt` — quoted ENTIRELY (219 lines)

```kotlin
  1: package com.topjohnwu.magisk.core
  2: 
  3: import android.os.Bundle
  4: import androidx.core.content.edit
  5: import com.topjohnwu.magisk.core.di.ServiceLocator
  6: import com.topjohnwu.magisk.core.model.ColorMode
  7: import com.topjohnwu.magisk.core.repository.DBConfig
  8: import com.topjohnwu.magisk.core.repository.PreferenceConfig
  9: import com.topjohnwu.magisk.core.utils.LocaleSetting
 10: import kotlinx.coroutines.GlobalScope
 11: 
 12: object Config : PreferenceConfig, DBConfig {
 13: 
 14:     override val stringDB get() = ServiceLocator.stringDB
 15:     override val settingsDB get() = ServiceLocator.settingsDB
 16:     override val context get() = ServiceLocator.deContext
 17:     @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
 18:     override val coroutineScope get() = GlobalScope
 19: 
 20:     object Key {
 21:         // db configs
 22:         const val ROOT_ACCESS = "root_access"
 23:         const val SU_MULTIUSER_MODE = "multiuser_mode"
 24:         const val SU_MNT_NS = "mnt_ns"
 25:         const val SU_BIOMETRIC = "su_biometric"
 26:         const val ZYGISK = "zygisk"
 27:         const val BOOTLOOP = "bootloop"
 28:         const val SU_MANAGER = "requester"
 29:         const val KEYSTORE = "keystore"
 30: 
 31:         // prefs
 32:         const val SU_REQUEST_TIMEOUT = "su_request_timeout"
 33:         const val SU_AUTO_RESPONSE = "su_auto_response"
 34:         const val SU_NOTIFICATION = "su_notification"
 35:         const val SU_REAUTH = "su_reauth"
 36:         const val SU_TAPJACK = "su_tapjack"
 37:         const val SU_RESTRICT = "su_restrict"
 38:         const val CHECK_UPDATES = "check_update"
 39:         const val RELEASE_CHANNEL = "release_channel"
 40:         const val CUSTOM_CHANNEL = "custom_channel"
 41:         const val LOCALE = "locale"
 42:         const val DARK_THEME = "dark_theme_extended"
 43:         const val COLOR_MODE = "color_mode"
 44:         const val DOWNLOAD_DIR = "download_dir"
 45:         const val SAFETY = "safety_notice"
 46:         const val THEME_ORDINAL = "theme_ordinal"
 47:         const val ASKED_HOME = "asked_home"
 48:         const val DOH = "doh"
 49:         const val RAND_NAME = "rand_name"
 50: 
 51:         val NO_MIGRATION = setOf(ASKED_HOME, SU_REQUEST_TIMEOUT,
 52:             SU_AUTO_RESPONSE, SU_REAUTH, SU_TAPJACK)
 53:     }
 54: 
 55:     object OldValue {
 56:         // Update channels
 57:         const val DEFAULT_CHANNEL = -1
 58:         const val STABLE_CHANNEL = 0
 59:         const val BETA_CHANNEL = 1
 60:         const val CUSTOM_CHANNEL = 2
 61:         const val CANARY_CHANNEL = 3
 62:         const val DEBUG_CHANNEL = 4
 63:     }
 64: 
 65:     object Value {
 66:         // Update channels
 67:         const val DEFAULT_CHANNEL = -1
 68:         const val STABLE_CHANNEL = 0
 69:         const val BETA_CHANNEL = 1
 70:         const val DEBUG_CHANNEL = 2
 71:         const val CUSTOM_CHANNEL = 3
 72: 
 73:         // root access mode
 74:         const val ROOT_ACCESS_DISABLED = 0
 75:         const val ROOT_ACCESS_APPS_ONLY = 1
 76:         const val ROOT_ACCESS_ADB_ONLY = 2
 77:         const val ROOT_ACCESS_APPS_AND_ADB = 3
 78: 
 79:         // su multiuser
 80:         const val MULTIUSER_MODE_OWNER_ONLY = 0
 81:         const val MULTIUSER_MODE_OWNER_MANAGED = 1
 82:         const val MULTIUSER_MODE_OWNER_MANAGED = 1
 83:         const val MULTIUSER_MODE_USER = 2
 84: 
 85:         // su mnt ns
 86:         const val NAMESPACE_MODE_GLOBAL = 0
 87:         const val NAMESPACE_MODE_REQUESTER = 1
 88:         const val NAMESPACE_MODE_ISOLATE = 2
 89: 
 90:         // su notification
 91:         const val NO_NOTIFICATION = 0
 92:         const val NOTIFICATION_TOAST = 1
 93:         const val NOTIFICATION_STATUS_BAR = 2
 94: 
 95:         // su auto response
 96:         const val SU_PROMPT = 0
 97:         const val SU_AUTO_DENY = 1
 98:         const val SU_AUTO_ALLOW = 2
 99: 
100:         // su timeout
101:         val TIMEOUT_LIST = longArrayOf(0, -1, 10, 20, 30, 60)
102:     }
103: 
104:     @JvmField var keepVerity = false
105:     @JvmField var keepEnc = false
106:     @JvmField var recovery = false
107:     var denyList = false
108: 
109:     var askedHome by preference(Key.ASKED_HOME, false)
110:     var bootloop by dbSettings(Key.BOOTLOOP, 0)
111: 
112:     var safetyNotice by preference(Key.SAFETY, true)
113:     var darkTheme by preference(Key.DARK_THEME, -1)
114:     var themeOrdinal by preference(Key.THEME_ORDINAL, 0)
115:     var colorMode by preference(Key.COLOR_MODE, ColorMode.MONET_SYSTEM.value)
116: 
117:     private var checkUpdatePrefs by preference(Key.CHECK_UPDATES, true)
118:     private var localePrefs by preference(Key.LOCALE, "")
119:     var doh by preference(Key.DOH, false)
120:     var updateChannel by preference(Key.RELEASE_CHANNEL, Value.DEFAULT_CHANNEL)
121:     val updateChannelIndex get() = when (updateChannel) {
122:         Value.DEFAULT_CHANNEL ->
123:             if (BuildConfig.DEBUG) Value.DEBUG_CHANNEL else Value.STABLE_CHANNEL
124:         else -> updateChannel
125:     }
126:     var customChannelUrl by preference(Key.CUSTOM_CHANNEL, "")
127:     var downloadDir by preference(Key.DOWNLOAD_DIR, "")
128:     var randName by preference(Key.RAND_NAME, true)
129:     var checkUpdate
130:         get() = checkUpdatePrefs
131:         set(value) {
132:             if (checkUpdatePrefs != value) {
133:                 checkUpdatePrefs = value
134:                 JobService.schedule(AppContext)
135:             }
136:         }
137:     var locale
138:         get() = localePrefs
139:         set(value) {
140:             localePrefs = value
141:             LocaleSetting.instance.setLocale(value)
142:         }
143: 
144:     var zygisk by dbSettings(Key.ZYGISK, Info.isEmulator)
145:     var suManager by dbStrings(Key.SU_MANAGER, "", true)
146:     var keyStoreRaw by dbStrings(Key.KEYSTORE, "", true)
147: 
148:     var suDefaultTimeout by preferenceStrInt(Key.SU_REQUEST_TIMEOUT, 10)
149:     var suAutoResponse by preferenceStrInt(Key.SU_AUTO_RESPONSE, Value.SU_PROMPT)
150:     var suNotification by preferenceStrInt(Key.SU_NOTIFICATION, Value.NOTIFICATION_TOAST)
151:     var rootMode by dbSettings(Key.ROOT_ACCESS, Value.ROOT_ACCESS_APPS_AND_ADB)
152:     var suMntNamespaceMode by dbSettings(Key.SU_MNT_NS, Value.NAMESPACE_MODE_REQUESTER)
153:     var suMultiuserMode by dbSettings(Key.SU_MULTIUSER_MODE, Value.MULTIUSER_MODE_OWNER_ONLY)
154:     private var suBiometric by dbSettings(Key.SU_BIOMETRIC, false)
155:     var suAuth
156:         get() = Info.isDeviceSecure && suBiometric
157:         set(value) {
158:             suBiometric = value
159:         }
160:     var suReAuth by preference(Key.SU_REAUTH, false)
161:     var suTapjack by preference(Key.SU_TAPJACK, true)
162:     var suRestrict by preference(Key.SU_RESTRICT, false)
163: 
164:     private const val SU_FINGERPRINT = "su_fingerprint"
165:     private const val UPDATE_CHANNEL = "update_channel"
166: 
167:     // (toBundle / fromBundle / init migrations follow at 166-218)
```

*(Lines 65-102 `Value`, 104-162 properties, 166-218 `toBundle`/`fromBundle`/`init` — reproduced in full in the raw file; only line numbers shifted by the transcription above. Re-read the file before editing.)*

### 7.2 What the app WRITES and READS, and WHERE

**Storage mechanisms — two of them:**

**(a) SharedPreferences** — `app/core/.../core/repository/PreferenceConfig.kt:13-17`:

```kotlin
 13:     val fileName: String
 14:         get() = "${context.packageName}_preferences"
 15: 
 16:     val prefs: SharedPreferences
 17:         get() = context.getSharedPreferences(fileName, Context.MODE_PRIVATE)
```

`context` = `ServiceLocator.deContext` (`Config.kt:16`) = device-protected storage. So the file is
`/data/user_de/0/<pkg>/shared_prefs/<pkg>_preferences.xml`, e.g. `/data/user_de/0/com.topjohnwu.magisk/shared_prefs/com.topjohnwu.magisk_preferences.xml`.

**(b) SQLite via the native daemon** — `app/core/.../core/repository/DBConfig.kt:11-19` and `app/core/.../core/data/magiskdb/MagiskDB.kt:19,32`:

```kotlin
// DBConfig.kt
 16:     fun dbSettings(name: String, default: Int) = IntDBProperty(name, default)
 17:     fun dbSettings(name: String, default: Boolean) = BoolDBProperty(name, default)
 18:     fun dbStrings(name: String, default: String, sync: Boolean = false) = StringDBProperty(name, default, sync)
```
```kotlin
// MagiskDB.kt
 19:             val out = Shell.cmd("magisk --sqlite '$query'").await().out
 ...
 32:             Shell.cmd("magisk --sqlite '$query'").await()
```

DB path: `native/src/include/consts.rs:23` → **`/data/adb/magisk.db`** (tables `policies`, `settings`, `strings`).

**Critical finding: `Config.kt` contains NO filesystem path at all.** It never touches `/data/adb/magisk/config`, `.magisk/config`, `MAGISKTMP`, `/data/adb`, or `MAGISKBIN`.

**Grep results for the requested tokens in `D:\Magisk\app`:**

| Token | Result |
|---|---|
| `/data/adb/magisk/config` | **NOT FOUND** anywhere in the repo |
| `MAGISK_CONFIG` | **NOT FOUND** anywhere in the repo |
| `SYSTEMMODE` | **NOT FOUND** anywhere in `D:\Magisk` |
| `magisk --config` / `magisk -c` | **NOT FOUND** |
| `PREINITDEVICE` | **NOT FOUND** in `app/` (scripts + native only) |
| `SHA1` | Only APK-signing code (`signing/SignApk.java:62,75,80,81,99,126,127,173,207,214,228`; `utils/Keygen.kt:67`). The boot-image `SHA1` config key is scripts-only. |
| `MAGISKTMP` | `ShellInit.kt:44,53,54,55` (see §6.4); `test/Environment.kt:45` |
| `RECOVERYMODE` | `Info.kt:121`, `MagiskInstaller.kt:84,493` |
| `KEEPVERITY` / `KEEPFORCEENCRYPT` | `Info.kt:122,123`, `MagiskInstaller.kt:490,491` |
| `PATCHVBMETAFLAG` / `LEGACYSAR` | `Info.kt:114,117`, `MagiskInstaller.kt:492,494` |
| `keepVerity` / `keepEnc` / `recovery` / `randName` | `Config.kt:104-106,128`; `MagiskInstaller.kt:67,84,249,490,491,493`; `InstallDialog.kt:215-243`; `SettingsScreen.kt:300-307`; `ktx/XSU.kt:8` |
| `getvar` | **NOT FOUND** in `app/` (shell function only) |

### 7.3 The critical conclusion for the port

**The app never writes a runtime config file into `/data/adb`.** The only config it passes to the shell is **environment variables on the `boot_patch.sh` command line** (`MagiskInstaller.kt:488-498`, §2.3-B) and on the `find_boot_image` line (`MagiskInstaller.kt:83-87`, §2.3-A).

The runtime config file is generated **entirely by the scripts** into the ramdisk and materialised on-device:
`config` (`.backup/.magisk`) → written by `boot_patch.sh:180-188` into the cpio (`:200`) → moved by magiskinit (`native/src/init/mount.cpp:212-223`, `cp_afc(".backup/.magisk", MAIN_CONFIG)`) to `$MAGISKTMP/.magisk/config` (`MAIN_CONFIG = ".magisk/config"`, `native/src/include/consts.rs:26-27`).

Who reads it:

```rust
// native/src/core/daemon.rs:314-328  — the ONLY native runtime reader; ONLY RECOVERYMODE
314:     // Load config status
315:     let magisk_tmp = get_magisk_tmp();
316:     let mut tmp_path = cstr::buf::new::<64>()
317:         .join_path(magisk_tmp)
318:         .join_path(MAIN_CONFIG);
319:     let mut is_recovery = false;
320:     if let Ok(main_config) = tmp_path.open(OFlag::O_RDONLY | OFlag::O_CLOEXEC) {
321:         BufReader::new(main_config).for_each_prop(|key, val| {
322:             if key == "RECOVERYMODE" {
323:                 is_recovery = val == "true";
324:                 return false;
325:             }
326:             true
327:         });
328:     }
```
```rust
// native/src/init/rootdir.rs:43-54 — magiskinit reads ONLY PREINITDEVICE from /.backup/.magisk
 43:     pub(crate) fn parse_config_file(&mut self) {
 44:         if let Ok(fd) = cstr!("/data/.backup/.magisk").open(OFlag::O_RDONLY) {
 45:             let mut reader = BufReader::new(fd);
 46:             reader.for_each_prop(|key, val| {
 47:                 if key == "PREINITDEVICE" {
 48:                     self.preinit_dev = val.to_string();
 49:                     return false;
 50:                 }
 51:                 true
 52:             })
 53:         }
 54:     }
```
```sh
# scripts/util_functions.sh:61-68 — shell side, probes three paths
 61: getvar() {
 62:   local VARNAME=$1
 63:   local VALUE
 64:   local PROPPATH='/data/.magisk /cache/.magisk'
 65:   [ ! -z $MAGISKTMP ] && PROPPATH="$MAGISKTMP/.magisk/config $PROPPATH"
 66:   VALUE=$(grep_prop $VARNAME $PROPPATH)
 67:   [ ! -z $VALUE ] && eval $VARNAME=\$VALUE
 68: }
```

**So `SYSTEMMODE` is a brand-new key with no existing reader.** Kitsune put it in a **different file** (`/system/etc/init/magisk/config`, written by `manager.sh:479`) and consumed by: `scripts/flash_script.sh:29` (`getvar SYSTEMMODE`), `scripts/uninstaller.sh:62`, and Kitsune's own `app_init`-adjacent code. A port must decide whether to (a) add `SYSTEMMODE` to the ramdisk `config` (requires a native reader in `daemon.rs`/`rootdir.rs` if the daemon needs it), or (b) mirror Kitsune and use `/system/etc/init/magisk/config` read by shell only.

---

## 8. Strings / resources

### 8.1 Where install strings live

**Module: `:core`.** `app/core/src/main/res/values/strings.xml` is the single default-locale file (273 lines).

Other `values/strings.xml` in the tree: `app/stub-res/src/main/res/values/strings.xml` (6 lines, stub app label only). There is **no** `strings.xml` in `:apk` — the Compose UI reads `:core` resources via `import com.topjohnwu.magisk.core.R as CoreR`.

### 8.2 Localization mechanism

Normal Android resource translations: **`values` + 51 `values-<lang>/strings.xml` directories** under `app/core/src/main/res/` (53 `values*` dirs total; `values-night`, `values-v31`, `values-v34` exist but hold no strings):

`values-ar`, `values-ast`, `values-az`, `values-b+sr+Latn`, `values-be`, `values-bg`, `values-bn`, `values-ca`, `values-cs`, `values-de`, `values-el`, `values-es`, `values-et`, `values-fa`, `values-fr`, `values-hi`, `values-hn`, `values-hr`, `values-hu`, `values-in`, `values-it`, `values-iw`, `values-ja`, `values-ka`, `values-kk`, `values-ko`, `values-ku`, `values-lt`, `values-mk`, `values-ml`, `values-nb`, `values-nl`, `values-pa`, `values-pl`, `values-pt-rBR`, `values-pt-rPT`, `values-ro`, `values-ru`, `values-sk`, `values-sq`, `values-sr`, `values-sv`, `values-sw`, `values-ta`, `values-th`, `values-tr`, `values-uk`, `values-ur`, `values-vi`, `values-zh-rCN`, `values-zh-rTW`

`app/stub-res/src/main/res/` has `values` + 49 language dirs (no `values-bn`, no `values-ur`). `app/apk-legacy` has only `values`, `values-night`, `values-v27` — no `strings.xml`. `app/apk` has only `values/` (themes.xml).

There is also **`app/core/src/main/res/xml/locale_config.xml`** (51 lines) which declares the same 51 locales for the API 33+ per-app language picker — if you add a locale you must touch both.

Locales with an install section that were checked: `values-in/strings.xml` (273 lines, same size as default), `values-zh-rCN/strings.xml` (273), `values-it` (267), `values-b+sr+Latn`/`values-sr` (265), `values-ar`/`values-uk` (264). The shortest are `values-th` (139) and `values-mk` (150).

**No Crowdin/Weblate/gettext tooling exists**; `.github/workflows/` contains only `build.yml` (196 lines, no localization step), and there is no `translate`/`crowdin`/`localiz` string anywhere in `build.py`, `.github/**`, or `scripts/**`. `app/dict.txt` (203 162 lines) is a dictionary word list, not a translation catalogue. Only "translation" references are changelog prose in `docs/app_changes.md` (lines 49, 214, 241, 320, 348, 357, 370, 414).

**Gotcha**: several translation files pack multiple `<string>` elements on a single line (e.g. `values-ar:39`, `values-b+sr+Latn:40`); a naive line-based edit tool will clobber them.

Example translations of `direct_install`: `values-fr:43 "Installation directe (recommandée)"`, `values-hi:43 "प्रत्यक्ष इंस्टॉल (अनुशंसित)"`, `values-bg:43 "Директно инсталиране (препоръчително)"`, `values-az:43 "Birbaşa Quraşdır (Tövsiyyə olunur)"`, `values-et:42 "Otsene install (soovitatud)"`, `values-ar:39 "التثبيت المباشر (موصى به)"`.

`lint { disable += "MissingTranslation" }` (`app/build-logic/src/main/java/Setup.kt:240`) means **missing translations are tolerated** — you can add a new English string without touching the 50 locale files.

### 8.3 Example install-related keys

`app/core/src/main/res/values/strings.xml`, lines 32-54 (the `<!--Install-->` section is 35-54):

```xml
 32:     <string name="uninstall_magisk_title">Uninstall Magisk</string>
 33:     <string name="uninstall_magisk_msg">All modules will be disabled/removed!\nRoot will be removed!\nAny internal storage unencrypted through the use of Magisk will be re-encrypted!</string>
...
 35:     <!--Install-->
 36:     <string name="keep_force_encryption">Preserve force encryption</string>
 37:     <string name="keep_dm_verity">Preserve AVB 2.0/dm-verity</string>
 38:     <string name="recovery_mode">Recovery mode</string>
 39:     <string name="install_options_title">Options</string>
 40:     <string name="install_method_title">Method</string>
 41:     <string name="install_next">Next</string>
 42:     <string name="install_start">Let\'s go</string>
 43:     <string name="manager_download_install">Press to download and install</string>
 44:     <string name="direct_install">Direct install (Recommended)</string>
 45:     <string name="install_inactive_slot">Install to inactive slot (After OTA)</string>
 46:     <string name="install_inactive_slot_msg">Your device will be FORCED to boot to the current inactive slot after a reboot!\nOnly use this option after OTA is done.\nContinue?</string>
 47:     <string name="setup_title">Additional setup</string>
 48:     <string name="select_patch_file">Select and patch a file</string>
 49:     <string name="patch_file_msg">Select a raw image (*.img) or an ODIN tarfile (*.tar) or a payload.bin (*.bin)</string>
 50:     <string name="download_patch_file">Download and patch a file</string>
 51:     <string name="download_dialog_title">Enter image URL</string>
 52:     <string name="download_dialog_msg">Full OTA image or factory image</string>
 53:     <string name="reboot_delay_toast">Rebooting in 5 seconds…</string>
 54:     <string name="flash_screen_title">Installation</string>
```

Other relevant keys:

```xml
  8:     <string name="install">Install</string>
 19:     <string name="not_installed">Not Installed</string>
 23:     <string name="reinstall">Reinstall</string>
 29:     <string name="home_installed_version">Installed</string>
132:     <string name="confirm_install">Install module %1$s?</string>
133:     <string name="confirm_install_title">Install confirmation</string>
242:     <string name="flashing">Flashing…</string>    <string name="done">Done!</string>
244:     <string name="failure">Failed!</string>
247:     <string name="complete_uninstall">Complete uninstall</string>
248:     <string name="restore_img">Restore images</string>
249:     <string name="restore_img_msg">Restoring…</string>
250:     <string name="restore_done">Restoration done!</string>
251:     <string name="restore_fail">Stock backup doesn\'t exist!</string>
252:     <string name="setup_fail">Setup failed</string>
253:     <string name="env_fix_title">Requires additional setup</string>
254:     <string name="env_fix_msg">Your device needs additional setup for Magisk to work properly. Do you want to proceed and reboot?</string>
255:     <string name="env_full_fix_msg">Your device needs reflash Magisk to work properly. Please reinstall Magisk within app, Recovery mode cannot get correct device info.</string>
256:     <string name="setup_msg">Running environment setup…</string>
260:     <string name="unsupport_system_app_msg">Running this app as a system app isn\'t supported. Please revert the app to a user app.</string>
262:     <string name="unsupport_external_storage_msg">Magisk is installed to external storage. Please move the app to internal storage.</string>
267:     <string name="install_unknown_denied">Allow \"Install unknown apps\" to enable this functionality</string>
271:     <string name="reboot_apply_change">Reboot to apply changes</string>
```

**Dead keys to be aware of**: `install_options_title` (39), `install_method_title` (40), `install_next` (41), `install_start` (42) are referenced **only** by the legacy layout `app/apk-legacy/src/main/res/layout/fragment_install_md2.xml:66,76,157,168` — they are unused in the current Compose UI. `setup_title` (47), `setup_msg` (256), `setup_fail` (252), `reboot_delay_toast` (53) are the env-fix / live-setup strings, used at `app/apk-legacy/.../dialog/EnvFixDialog.kt:29,30,38,55` and `app/apk/.../ui/home/HomeScreen.kt:206,943`.

**Line 242 is malformed** in the current tree — it packs two `<string>` elements (`flashing`, `done`) onto one line. Be careful with line-oriented edits there.

**Kitsune's equivalent System Mode string** (for reference) — `D:\a\KitsuneMagisk\app\src\main\res\values\strings.xml:256`:

```xml
256:     <string name="direct_install_system">Direct Install (modify /system directly)</string>
```

Kitsune also gated its XML row with databinding at `D:\a\KitsuneMagisk\app\src\main\res\layout\fragment_install_md2.xml:204` (`gone="@{!viewModel.allowSystemInstall}"`). In Compose the equivalent is an `if (…) { SettingsArrow(...) }` block.

---

## 9. The new "adb patching and emulator setup" tooling

### 9.1 `build.py` subcommands

`D:\Magisk\build.py` (925 lines). `parse_args()` at lines 803-912 (VERBATIM):

```python
803: def parse_args():
804:     parser = argparse.ArgumentParser(description="Magisk build script")
805:     parser.set_defaults(func=lambda: (parser.print_help(), sys.exit(1)))
806:     parser.add_argument(
807:         "-r", "--release", action="store_true", help="compile in release mode"
808:     )
809:     parser.add_argument(
810:         "-v", "--verbose", action="count", default=0, help="verbose output"
811:     )
812:     parser.add_argument(
813:         "-c",
814:         "--config",
815:         default="config.prop",
816:         help="custom config file (default: config.prop)",
817:     )
818:     subparsers = parser.add_subparsers(title="actions")
819: 
820:     all_parser = subparsers.add_parser("all", help="build everything")
821: 
822:     native_parser = subparsers.add_parser("native", help="build native binaries")
823:     native_parser.add_argument(
824:         "targets",
825:         nargs="*",
826:         help=f"{', '.join(support_targets)}, \
827:         or empty for defaults ({', '.join(default_targets)})",
828:     )
829: 
830:     app_parser = subparsers.add_parser("app", help="build the Magisk app")
831: 
832:     app_legacy_parser = subparsers.add_parser(
833:         "app-legacy", help="build the legacy Magisk app"
834:     )
835: 
836:     stub_parser = subparsers.add_parser("stub", help="build the stub app")
837: 
838:     test_parser = subparsers.add_parser("test", help="build the test app")
839: 
840:     clean_parser = subparsers.add_parser("clean", help="cleanup")
841:     clean_parser.add_argument(
842:         "targets",
843:         nargs="*",
844:         help="native, cpp, rust, app, or empty to clean all",
845:     )
846: 
847:     ndk_parser = subparsers.add_parser("ndk", help="setup Magisk NDK")
848: 
849:     emu_parser = subparsers.add_parser("emulator", help="setup AVD for development")
850:     emu_parser.add_argument("apk", help="a Magisk APK to use", nargs="?")
851:     emu_parser.add_argument(
852:         "-b", "--build", action="store_true", help="build before patching"
853:     )
854: 
855:     patch_parser = subparsers.add_parser(
856:         "patch", help="patch boot image or AVD ramdisk.img via ADB"
857:     )
858:     patch_parser.add_argument("image", help="path to image to patch")
859:     patch_parser.add_argument("output", help="output file name")
860:     patch_parser.add_argument("--apk", help="a Magisk APK to use")
861:     patch_parser.add_argument(
862:         "--avd", action="store_true", help="the input file is an AVD ramdisk.img"
863:     )
864:     patch_parser.add_argument(
865:         "-b", "--build", action="store_true", help="build before patching"
866:     )
867: 
868:     cargo_parser = subparsers.add_parser(
869:         "cargo", help="call 'cargo' commands against the project"
870:     )
871:     cargo_parser.add_argument("commands", nargs=argparse.REMAINDER)
872: 
873:     clippy_parser = subparsers.add_parser("clippy", help="run clippy on Rust sources")
874:     clippy_parser.add_argument(
875:         "--abi", action="append", help="target ABI(s) to run clippy"
876:     )
877:     clippy_parser.add_argument(
878:         "-r", "--release", action="store_true", help="run clippy as release"
879:     )
880:     clippy_parser.add_argument(
881:         "-d", "--debug", action="store_true", help="run clippy as debug"
882:     )
883: 
884:     rustup_parser = subparsers.add_parser("rustup", help="setup rustup wrapper")
885:     rustup_parser.add_argument(
886:         "wrapper_dir", help="path to setup rustup wrapper binaries"
887:     )
888: 
889:     gen_parser = subparsers.add_parser("gen", help="generate files for IDE")
890:     gen_parser.add_argument("--abi", help="target ABI to generate")
891: 
892:     # Set callbacks
893:     all_parser.set_defaults(func=build_all)
894:     native_parser.set_defaults(func=build_native)
895:     cargo_parser.set_defaults(func=cargo_cli)
896:     clippy_parser.set_defaults(func=clippy_cli)
897:     rustup_parser.set_defaults(func=setup_rustup)
898:     gen_parser.set_defaults(func=gen_ide)
899:     app_parser.set_defaults(func=build_app)
900:     app_legacy_parser.set_defaults(func=build_app_legacy)
901:     stub_parser.set_defaults(func=build_stub)
902:     test_parser.set_defaults(func=build_test)
903:     emu_parser.set_defaults(func=setup_avd)
904:     patch_parser.set_defaults(func=patch)
905:     clean_parser.set_defaults(func=cleanup)
906:     ndk_parser.set_defaults(func=setup_ndk)
907: 
908:     if len(sys.argv) == 1:
909:         parser.print_help()
910:         sys.exit(1)
911: 
912:     return parser.parse_args()
```

`main()` at lines 915-925 (VERBATIM):

```python
915: def main():
916:     global args
917:     args = parse_args()
918:     args.config = Path(args.config).resolve()
919:     os.chdir(Path(__file__).resolve().parent)
920:     load_config()
921:     args.func()
922: 
923: 
924: if __name__ == "__main__":
925:     main()
```

**Flag inventory**: global `-r/--release`, `-v/--verbose` (count), `-c/--config` (default `config.prop`). `--cuttlefish` **does NOT exist** (cuttlefish reuses `patch`). `--avd` exists **only** on `patch`. `--abi` exists only on `clippy` and `gen`; there is **no** `--abi` for `emulator`/`patch`.

**High-level behaviour:**

- **`build.py emulator [APK] [-b]`** → `setup_avd()`. Requires an **already-booted** AVD reachable through adb; build.py never launches an emulator. Pushes `scripts/avd_setup.sh` + the APK's assets/libs + `magisk.apk` to `/data/local/tmp`, then runs `avd_setup.sh` on device. That script installs the APK, stops zygote, mounts a **tmpfs `/sbin`** (or `/debug_ramdisk` on Q+), lays down `/data/adb/magisk`, `magiskpolicy --live`, `--post-fs-data`, `start`, `--service`, `--boot-complete`. Non-persistent (lost on reboot: `docs/faq.md:35`). **This is the closest official analogue to Kitsune's `avd_magisk.sh`.**
- **`build.py patch [--avd] [--apk APK] [-b] IMAGE OUTPUT`** → `patch()`. Same push prelude (without `magisk.apk`), then runs `scripts/adb_patch.sh` (default) or `scripts/avd_patch.sh` (`--avd`) on device against the pushed image, and pulls `<image>.magisk` back. `adb_patch.sh` patches a boot image via `boot_patch.sh`; `avd_patch.sh` patches an AVD `ramdisk.img` (magiskinit integration test).
- `scripts/avd.sh` (346 lines) owns emulator lifecycle (`avdmanager create`, `$ANDROID_HOME/emulator/emulator`, `adb wait`, `adb emu kill`) and calls `./build.py -v patch --avd --apk "$apk" "$ramdisk" "${images[-1]}"` (line 252) or `./build.py -v emulator $apk` (lines 305, 311).
- `scripts/cuttlefish.sh` (124 lines) has **no build.py subcommand**; it calls `./build.py -v patch --apk "$apk" "$CF_HOME/init_boot.img" "${images[-1]}"` (line 90) and feeds the result to `launch_cvd -init_boot_image=`. CI job is disabled (`if: false`, `.github/workflows/build.yml:157`).
- `scripts/test_common.sh` (102 lines) is the shared harness sourced by both.

**The functions that push files to a device via adb** (VERBATIM):

```python
629: def push_files(files: list[Path], push_apk: bool = False):
630:     if args.build:
631:         build_all()
632: 
633:     abi = cmd_out([adb_path(), "shell", "getprop", "ro.product.cpu.abi"])
634:     if not abi:
635:         error("Cannot detect emulator ABI")
636: 
637:     if args.apk:
638:         apk = Path(args.apk)
639:     else:
640:         name = "app-release.apk" if args.release else "app-debug.apk"
641:         apk = Path(config["outdir"], name)
642: 
643:     if not apk.is_file():
644:         error(f"Cannot find {apk}")
645: 
646:     with tempfile.TemporaryDirectory() as tmp_dir:
647:         tmp = Path(tmp_dir)
648:         to_push = list(files)
649: 
650:         with ZipFile(apk) as zf:
651:             # Extract stub.apk
652:             stub = tmp / "stub.apk"
653:             stub.write_bytes(zf.read("assets/stub.apk"))
654:             to_push.append(stub)
655: 
656:             # Extract assets/*.sh
657:             for name in zf.namelist():
658:                 if name.startswith("assets/") and name.endswith(".sh") and name.count("/") == 1:
659:                     dest = tmp / Path(name).name
660:                     dest.write_bytes(zf.read(name))
661:                     to_push.append(dest)
662: 
663:             # Extract native libs for target ABI
664:             prefix = f"lib/{abi}/"
665:             for name in zf.namelist():
666:                 if name.startswith(prefix):
667:                     base_name = Path(name).name
668:                     if base_name.startswith("lib") and base_name.endswith(".so"):
669:                         dest = tmp / base_name[3:-3]
670:                         dest.write_bytes(zf.read(name))
671:                         to_push.append(dest)
672: 
673:             # Extract 32-bit magisk if exist in the APK
674:             abi32 = abi32_map.get(abi)
675:             if abi32:
676:                 magisk32_entry = f"lib/{abi32}/libmagisk.so"
677:                 if magisk32_entry in zf.namelist():
678:                     dest = tmp / "magisk32"
679:                     dest.write_bytes(zf.read(magisk32_entry))
680:                     to_push.append(dest)
681: 
682:         execv([adb_path(), "shell", "rm", "-rf", "/data/local/tmp/*"])
683:         proc = execv([adb_path(), "push", *to_push, "/data/local/tmp"])
684:         if proc.returncode != 0:
685:             error("adb push failed!")
686: 
687:         if push_apk:
688:             proc = execv([adb_path(), "push", apk, "/data/local/tmp/magisk.apk"])
689:             if proc.returncode != 0:
690:                 error("adb push failed!")
691: 
692: 
693: def setup_avd():
694:     header("* Setting up emulator")
695: 
696:     push_files([Path("scripts", "avd_setup.sh")], push_apk=True)
697: 
698:     proc = execv([adb_path(), "shell", "sh", "/data/local/tmp/avd_setup.sh"])
699:     if proc.returncode != 0:
700:         error("avd_setup.sh failed!")
701: 
702: 
703: def patch():
704:     input_file = Path(args.image)
705:     output = Path(args.output)
706: 
707:     header(f"* Patching {input_file.name}")
708: 
709:     script = "avd_patch.sh" if args.avd else "adb_patch.sh"
710:     push_files([Path("scripts", script), input_file])
711: 
712:     src_file = f"/data/local/tmp/{input_file.name}"
713:     out_file = f"{src_file}.magisk"
714: 
715:     proc = execv([adb_path(), "shell", "sh", f"/data/local/tmp/{script}", src_file])
716:     if proc.returncode != 0:
717:         error(f"{script} failed!")
718: 
719:     proc = execv([adb_path(), "pull", out_file, output])
720:     if proc.returncode != 0:
721:         error("adb pull failed!")
722: 
723:     header(f"Output: {output}")
```

and the adb resolver:

```python
731: # We allow using several functionality without requirement to set ANDROID_HOME
732: @functools.cache
733: def adb_path() -> Path:
734:     if "ANDROID_HOME" in os.environ or "ANDROID_SDK_ROOT" in os.environ:
735:         if paths().adb.exists():
736:             return paths().adb
737:     if adb := shutil.which("adb"):
738:         return Path(adb)
739:     error("Command 'adb' cannot be found in PATH")
```

`paths().adb` is `$ANDROID_HOME/platform-tools/adb` (`scripts/env.py:66`).

**Complete PC-side adb surface of `build.py`** (5 shapes, 7 construction sites):
```
633: adb shell getprop ro.product.cpu.abi
682: adb shell rm -rf /data/local/tmp/*
683: adb push <files...> /data/local/tmp
688: adb push <apk> /data/local/tmp/magisk.apk
698: adb shell sh /data/local/tmp/avd_setup.sh
715: adb shell sh /data/local/tmp/<script> <image>
719: adb pull <image>.magisk <output>
```
All via `subprocess.run(list_argv)` — `execv` (116-119) or `cmd_out` (122-132). Shell scripts call bare `adb` from `PATH` (`test_common.sh:9` prepends `$ANDROID_HOME/platform-tools`).

**System Mode relevance**: `build.py emulator` + `avd_setup.sh` already implement a **live tmpfs `/sbin` overlay install on an emulator** — see §10. Kitsune's `avd_magisk.sh` is the direct ancestor of `avd_setup.sh`; Kitsune's *System Mode* is a different, persistent feature that writes to `/system/etc/init/magisk`.

---

## 10. What official already has that a system-mode install could reuse

### 10.1 `scripts/` hits

`tmpfs` / `/sbin` / `debug_ramdisk` / `mount -t tmpfs` / `chcon u:object_r:` / `blockdev` / `restorecon`:

| File:line | Line |
|---|---|
| `scripts/avd_setup.sh:21` | `mount_tmpfs() {` |
| `scripts/avd_setup.sh:24` | `  mount -t tmpfs -o 'mode=0755' magisk $1` |
| `scripts/avd_setup.sh:28` | `mount_sbin() {` |
| `scripts/avd_setup.sh:29` | `  mount_tmpfs /sbin` |
| `scripts/avd_setup.sh:30` | `  chcon u:object_r:rootfs:s0 /sbin` |
| `scripts/avd_setup.sh:59-61` | `if [ -d /debug_ramdisk ]; then` / `umount -l /debug_ramdisk 2>/dev/null` / `fi` |
| `scripts/avd_setup.sh:68` | `  mount -t tmpfs -o 'mode=0755' tmpfs /cache` |
| `scripts/avd_setup.sh:71` | `MAGISKTMP=/sbin` |
| `scripts/avd_setup.sh:74-83` | legacy-rootfs branch: `mount -o rw,remount /`, `mkdir /root /sbin`, `ln /sbin/* /root`, `mount -o ro,remount /`, `mount_sbin`, `ln -s /root/* /sbin` |
| `scripts/avd_setup.sh:84-102` | legacy-SAR branch: `mount_sbin`, `mount -o ro $block /dev/sysroot`, per-file `cp -af` / `mount -o bind` into `/sbin` |
| `scripts/avd_setup.sh:105-106` | `MAGISKTMP=/debug_ramdisk` / `mount_tmpfs /debug_ramdisk` |
| `scripts/avd_setup.sh:124,131-133` | `cp -af ./$file $MAGISKTMP/$file`; `ln -s ./magisk $MAGISKTMP/su` etc. |
| `scripts/avd_setup.sh:135-141` | `mkdir -p $MAGISKTMP/.magisk/device`; `mkdir -p $MAGISKTMP/.magisk/worker`; `mount_tmpfs $MAGISKTMP/.magisk/worker`; `mount --make-private …`; `touch $MAGISKTMP/.magisk/config`; **`touch $MAGISKTMP/.magisk/live`** |
| `scripts/avd_setup.sh:162-167` | `$MAGISKTMP/magisk --post-fs-data` / `start` / `--service` / `--boot-complete` |
| `scripts/app_functions.sh:21` | `[ -b "$MAGISKTMP/.magisk/device/preinit" ] \|\| [ -b "$MAGISKTMP/.magisk/block/preinit" ] \|\| return 2` |
| `scripts/app_functions.sh:92` | `local SHA1=$(grep_prop SHA1 $MAGISKTMP/.magisk/config)` |
| `scripts/boot_patch.sh:192-196` | `"mkdir 0750 overlay.d"` … `"add 0644 overlay.d/sbin/*.xz"` |
| `scripts/avd_patch.sh:64-68` | same `overlay.d/sbin` cpio adds |
| `scripts/util_functions.sh:65` | `[ ! -z $MAGISKTMP ] && PROPPATH="$MAGISKTMP/.magisk/config $PROPPATH"` |
| `scripts/util_functions.sh:413-416` | `blockdev --getsize64` / `--setrw` / `--getro` (in `flash_image`) |
| `scripts/util_functions.sh:471` | `blockdev --setrw /dev/block/mapper/system$SLOT 2>/dev/null` |
| `scripts/util_functions.sh:531` | `if grep ' /data ' /proc/mounts \| grep -vq 'tmpfs'; then` |
| `scripts/util_functions.sh:582` | `local PREINITDIR=$MAGISKTMP/.magisk/preinit` |
| `scripts/util_functions.sh:648, 677` | `chcon u:object_r:system_file:s0 $TMPDIR` / `$MODPATH` |
| `scripts/flash_script.sh:83` | `blockdev --setrw /dev/block/mapper/system$SLOT 2>/dev/null` |
| `scripts/uninstaller.sh:158` | same `blockdev --setrw` |
| `scripts/addon.d.sh:1`, `scripts/module_installer.sh:1`, `scripts/update_binary.sh:1` | `#!/sbin/sh` (shebang only) |
| `scripts/test_common.sh:60` | `adb shell 'PATH=$PATH:/debug_ramdisk magisk -v'` |

**`restorecon`: NOT FOUND in `scripts/`** (or anywhere in the repo).

### 10.2 `app/` hits

| File:line | Line |
|---|---|
| `app/core/.../core/AppContext.kt:52` | `Os.setenv("PATH", "${Os.getenv("PATH")}:/debug_ramdisk:/sbin", true)` |
| `app/core/.../core/utils/ShellInit.kt:44` | `add("export MAGISKTMP=\$(magisk --path)")` |
| `app/core/.../core/utils/ShellInit.kt:53-55` | `"if [ -x \$MAGISKTMP/.magisk/busybox/busybox ]; then"` / `"  cp -af $localBB \$MAGISKTMP/.magisk/busybox/busybox"` / `"  exec \$MAGISKTMP/.magisk/busybox/busybox sh"` |
| `app/core/.../core/tasks/MagiskInstaller.kt:181` | `// Move everything to tmpfs to workaround Samsung bullshit` (with lines 182-190 using `Const.TMPDIR` = `/dev/tmp`) |
| `app/core/.../test/Environment.kt:45` | `val liveMarker = ShellUtils.fastCmd("echo \$MAGISKTMP/.magisk/live")` — **the app already knows the `.magisk/live` marker** |

`restorecon`, `chcon`, `mount -t tmpfs`, `/sbin` (as a path literal), `debug_ramdisk` beyond the PATH line: no further hits in `app/`.

### 10.3 `native/` hits (non-vendored)

| File:line | Line |
|---|---|
| `native/src/include/consts.rs:19-27` | `SECURE_DIR="/data/adb"`, `DATABIN="/data/adb/magisk"`, `MAGISKDB="/data/adb/magisk.db"`, `INTERNAL_DIR=".magisk"`, `MAIN_CONFIG=".magisk/config"` |
| `native/src/include/consts.rs:36-37` | `ROOTOVL = .magisk/rootdir`, `ROOTMNT` |
| `native/src/include/consts.hpp:9-20` | tmpfs path constants; `:17 ROOTOVL ".magisk/rootdir"` |
| `native/src/core/utils.cpp:33-45` | **`get_magisk_tmp()`** — the canonical tmpfs probe: `/debug_ramdisk` → `/sbin` → `""` |
| `native/src/core/utils.cpp:36-39` | `if (access("/debug_ramdisk/" INTLROOT, F_OK) == 0) path="/debug_ramdisk"; else if (access("/sbin/" INTLROOT, F_OK)==0) path="/sbin";` |
| `native/src/core/selinux.rs:54-73` | `restorecon()` — sets `/data/adb` → `u:object_r:adb_data_file:s0`, `/data/adb/magisk` tree → `u:object_r:system_file:s0`, `magisk.db` mode 000 |
| `native/src/core/selinux.rs:75-97` | `restore_tmpcon()` — **`if tmp == "/sbin" { set u:object_r:rootfs:s0 } else { chmod 0711 }`** |
| `native/src/core/bootstages.rs:32-107` | `setup_magisk_env()` — alt bin dirs `/cache/data_adb/magisk`, `/data/magisk`, `<app_data>/0/<pkg>/install` → `/data/adb/magisk`; calls `restorecon()`; **requires `/data/adb/magisk/busybox` else abort**; copies busybox into `$MAGISKTMP/.magisk/busybox`, plus `magisk32`, `magiskpolicy` |
| `native/src/core/bootstages.rs:11, 68` | `use crate::selinux::restorecon;` / `restorecon();` |
| `native/src/core/bootstages.rs:230` | `if line.contains(" /data ") && !line.contains("tmpfs") {` |
| `native/src/core/magisk.rs:35, 140, 245` | `--restorecon  restore selinux context on Magisk files` (CLI helper) |
| `native/src/core/magisk.rs:39` | `--path  print Magisk tmpfs mount path` (the `magisk --path` contract) |
| `native/src/core/mount.rs:194, 238` | `std::env::var("MAGISKTMP")`; `// Unmount Magisk tmpfs and mounts from module files` |
| `native/src/core/daemon.rs:461` | `log_err!("Start daemon on magisk tmpfs")` |
| `native/src/core/scripting.cpp:222` | `setenv("MAGISKTMP", get_magisk_tmp(), 0);` |
| `native/src/core/module.rs:886, 930` | tmpfs-parent magic-mount logic; `:886` checks `get_magisk_tmp()=="/sbin"` |
| `native/src/init/rootdir.rs:1, 80, 93, 100-105` | rootfs overlay engine (`mount_impl`, `mount_overlay`, `restore_overlay_contexts`) |
| `native/src/init/rootdir.rs:40-106` | `mount_impl()` (56-89) recursive bind-mount overlay, recording `OverlayAttr`; `mount_overlay(dest)` (91-98) writes `ROOTMNT`; `restore_overlay_contexts()` (100-105) |
| `native/src/init/selinux.rs:45, 79, 86, 239, 283` | `restorecon` comments + `restore_overlay_contexts` calls |
| `native/src/init/init.rs:33-169` | root-mode dispatch: `first_stage` (35), `second_stage` (47), `legacy_system_as_root` (73), `rootfs` (84), `start` (114); `:162 } else if cstr!("/sbin/recovery").exists()` |
| `native/src/init/init.hpp:4` | `#define REDIR_PATH "/data/magiskinit"` |
| `native/src/init/mount.rs:66-93` | `is_rootfs()` (`RAMFS_MAGIC`/`TMPFS_MAGIC`, :70); legacy-SAR `/data` staging: `mount("magisk","/data","tmpfs","mode=755")` (:83,:87), copy `/init`→`/data/magiskinit` (:90), `/.backup` (:91), `/.overlay.d`→`/data/overlay.d` (:92) |
| `native/src/init/twostage.rs:18-101` | magiskinit hijack of the 2nd-stage init |
| `native/src/init/rootdir.cpp:54, 98, 106, 133, 150-153, 167, 170, 205-232, 234-260, 262-291, 296-313, 317-323, 326-347, 350-360, 366, 374, 384-399, 408, 412-415` | the whole tmpfs/`/sbin`/`overlay.d` engine (details below) |
| `native/src/init/rootdir.cpp:98, 104` | `replace_all(script, "${MAGISKTMP}", tmp_path)` + `rust::inject_magisk_rc(fd, tmp_path)` |
| `native/src/init/rootdir.rs:21-31` | the injected `.rc` template (`--post-fs-data` on post-fs-data, `--service` on vold.decrypt/nonencrypted, `--boot-complete` on sys.boot_completed, domain `u:r:magisk:s0`) |
| `native/src/init/mount.cpp:192, 212-249` | `xmount("tmpfs","/dev","tmpfs",0,"mode=755")`; `setup_tmp()` (see below) |
| `native/src/init/mount.cpp:200-207` | AVD hack (`is_two_stage == false && config.emulator`) |
| `native/src/boot/cpio.rs:512-544` | fstab keep-verity handling; `:544` legacy `boot/sbin/launch_daemonsu.sh` removal |
| `native/src/boot/dtb.rs` (17 hits) | fstab-in-DTB find/patch |
| `native/src/init/getinfo.cpp:144-145, 148-149, 176-182, 188` | `androidboot.fstab_suffix`; `qemu` → `emulator`; `RECOVERYMODE` handling |
| `native/src/sepolicy/rules.rs:105-119` | `allow(… ["tmpfs"] …)` ×6 (init/zygote/shell file; kernel chr_file; kernel fifo_file; rootfs filesystem; kernel relabelfrom) |
| `native/src/sepolicy/rules.rs:106` | `// For tmpfs overlay on 2SI, Zygisk on lower Android versions and AVD scripts` |
| `native/src/init/rootdir.cpp:205-232` | `recreate_sbin(const char *mirror, bool use_bind_mount)` — rebuilds `/sbin` entries by symlink or bind-mount |
| `native/src/init/rootdir.cpp:234-260` | `extract_files(bool sbin)` — unxz `/sbin/magisk.xz`, `/sbin/stub.xz`, `/sbin/init-ld.xz` into cwd (the tmpfs) |
| `native/src/init/rootdir.cpp:268-289` | `tmp_dir = "/sbin"` if it exists, else `/debug_ramdisk` (+ move-mount `/data/debug_ramdisk`); `setup_tmp(tmp_dir)`; `recreate_sbin(MIRRDIR "/sbin", true)` |
| `native/src/init/rootdir.cpp:291` | `xrename("overlay.d", ROOTOVL);` |
| `native/src/init/rootdir.cpp:309-313` | `load_overlay_rc(ROOTOVL);` then `if (access(ROOTOVL "/sbin", F_OK) == 0) mv_path(ROOTOVL "/sbin", ".");` |
| `native/src/init/rootdir.cpp:332` | `mount_overlay("/");` |
| `native/src/init/rootdir.cpp:344-347` | `// Create hardlink mirror of /sbin to /root` / `clone_attr("/sbin", "/root")` / `link_path("/sbin", "/root")` |
| `native/src/init/rootdir.cpp:350-352` | `load_overlay_rc("/overlay.d")`, `mv_path("/overlay.d", "/")`, `rm_rf("/data/overlay.d")` |
| `native/src/init/rootdir.cpp:356-357` | `patch_rc_scripts("/", "/sbin", true)` / `patch_fissiond("/sbin")` |
| `native/src/init/rootdir.cpp:360` | `xmount("tmpfs", PRE_TMPSRC /* "/magisk" */, "tmpfs", 0, "mode=755");` |
| `native/src/init/rootdir.cpp:374, 384, 386-389` | `cp_afc(REDIR_PATH, "/sbin/magisk");` / `unlink("/sbin/magisk");` / `// Move tmpfs to /sbin` / `xmount(PRE_TMPDIR, "/sbin", nullptr, MS_MOVE, nullptr);` |
| `native/src/init/rootdir.cpp:395, 398-399` | `recreate_sbin("/root", false);` / `setenv("REMOUNT_ROOT","1",1); execve("/sbin/magisk", argv, environ);` |
| `native/src/init/mount.cpp:212-241` | `setup_tmp()` — `mkdir INTLROOT/DEVICEDIR/WORKERDIR`, `mount_preinit_dir()`, `cp_afc(".backup/.magisk", MAIN_CONFIG)`, `rm_rf(".backup")`, applet symlinks, `xmount(".", path, nullptr, MS_BIND, nullptr)` (**note: does NOT `mount -t tmpfs` on `path` itself** — the tmpfs comes from a pre-existing `/sbin`, the moved `/debug_ramdisk`, or the `/magisk` tmpfs), then `xmount("magisk", WORKERDIR, "tmpfs", 0, "mode=755")` + devpts |
| `native/src/core/daemon.rs:365-386` | magiskd consumes/cleans the overlay mount list, `REMOUNT_ROOT` → remount `/` RO, `rm -rf ROOTOVL` |

**The `/sbin` assumptions a system-mode port must extend** (all hard-coded):
`native/src/core/utils.cpp:36-42`, `native/src/core/selinux.rs:77`, `native/src/core/module.rs:886`, `native/src/init/rootdir.cpp:268-289`, `app/core/src/main/java/com/topjohnwu/magisk/core/AppContext.kt:52`.
Plus the `magisk --path` output contract (`native/src/core/magisk.rs:39`, consumed at `ShellInit.kt:44`) and the `.magisk/live` marker (`scripts/avd_setup.sh:141`, `app/core/.../test/Environment.kt:44-47`).

### 10.4 Does official have any notion of system-mode install?

**No.** Official Magisk at this HEAD is **boot-image-patching only**. Specifically:

- There is **no** `SYSTEMMODE`, `systemmode`, `system_mode`, `/system/etc/init/magisk`, `MAGISKSYSTEMDIR`, `direct_install_system`, `setup-sbin`, or `auto-selinux` anywhere in `D:\Magisk` (`grep` over the whole tree: **NOT FOUND**).
- The closest existing capability is `scripts/avd_setup.sh` — a **non-persistent, runtime-only** tmpfs `/sbin` (or `/debug_ramdisk`) overlay on an emulator, driven by `./build.py emulator`. It creates the `.magisk/live` marker (`avd_setup.sh:141`) which the app already probes (`app/core/.../test/Environment.kt:45`).
- `native/src/init/rootdir.cpp` already knows how to **recreate `/sbin`** (`recreate_sbin`, lines 205-232), move a tmpfs onto `/sbin` (lines 386-389), hardlink `/sbin` ↔ `/root` (344-347), and consume `overlay.d` (291, 309-313, 350-352). That is the machinery a system-mode port would reuse for the tmpfs-mounted `/sbin` half.
- `magisk --setup-sbin` and `magisk --auto-selinux` **do not exist** in `native/src/core/magisk.rs` (its subcommand list is at line 33: `post-fs-data, service, boot-complete, zygote-restart`; `--zygote-restart` exists at line 132). Kitsune's `magiskrc()` calls them (`manager.sh:302-303`), so a straight port requires adding those native subcommands **or** replacing them with the existing `magiskpolicy --live` / `magisk --post-fs-data` calls that `avd_setup.sh:153-164` already uses.

### 10.5 Kitsune's System Mode reference implementation (the port source)

Persistent install = **`/system/etc/init/magisk/`** (`MAGISKSYSTEMDIR`, `manager.sh:282`) containing `magisk32`/`magisk64`, `magiskpolicy`, `magiskinit`, `stub.apk` (`manager.sh:475-481`) plus `config` with `SYSTEMMODE=true` (`manager.sh:479`), and an init `.rc` hooked onto `bootanim.rc` (`manager.sh:525-533`, `magiskrc()` at `:291-318`) that runs:

```
on post-fs-data
    exec u:r:su:s0 root root -- /system/etc/init/magisk/magiskpolicy --live --magisk
    exec u:r:su:s0 root root -- /system/etc/init/magisk/$magisk_name --auto-selinux --setup-sbin /system/etc/init/magisk /sbin
    exec u:r:su:s0 root root -- /sbin/magisk --auto-selinux --post-fs-data
```

Boot-image-independent entry point: `scripts/flash_script.sh:29` `getvar SYSTEMMODE` → `SYSTEMINSTALL` → `manager.sh`'s `direct_install_system` (`:370-541`) instead of `install_magisk`. App-side gate: `app/src/main/java/com/topjohnwu/magisk/ui/install/InstallViewModel.kt:42` `val allowSystemInstall = isRooted && !Info.isBootPatched`, and `FlashFragment.flash(2)` → `Const.Value.FLASH_MAGISK_SYSTEM` → `MagiskInstaller.Direct_system` → `"xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\""` (`MagiskInstaller.kt:540, 603-607`).

---

## Where to integrate the System Mode feature

Concrete file-by-file list. Nothing below exists in `D:\Magisk` at `aed0261c3`.

### Layer 0 — Asset script (the installer body)

| File | Action |
|---|---|
| **`D:\Magisk\scripts\app_functions.sh`** (NEW functions) | Port `random_str`, `is_rootfs`, `mkblknode`, `warn_system_ro`, `remount_check`, `force_bind_mount`, `unmount_system_mirrors`, `backup_restore`, `restore_from_bak`, `cleanup_system_installation`, `installer_cleanup`, `MAGISKSYSTEMDIR`, and `direct_install_system` / `xdirect_install_system` from `D:\a\KitsuneMagisk\app\src\main\res\raw\manager.sh:282-551`. This is the file that becomes `assets/app_functions.sh` and is **already sourced into every app shell** (`ShellInit.kt:66`) — putting them here means they are available without any new extraction step. |
| **`D:\Magisk\scripts\boot_patch.sh`** (optional) | Only if you want a `SYSTEMMODE`-aware `install_magisk` path; otherwise leave it alone (Kitsune left it alone too — it routed around it in `flash_script.sh`). |
| **`D:\Magisk\scripts\flash_script.sh`** (recovery path) | Add the `SYSTEMINSTALL` branch after `boot_patch.sh:56`. Kitsune's version is `D:\a\KitsuneMagisk\scripts\flash_script.sh:29-35` and `:104-119`. Official `flash_script.sh` is a different shape (101 lines, uses `install_magisk` at line 94) so adapt, don't copy. |
| **`D:\Magisk\scripts\addon.d.sh`** | Add `SYSTEMINSTALL=false` near the top and a branch in `main()` (Kitsune `addon.d.sh:10,125`). Needed so an OTA survives a system-mode install. |
| **`D:\Magisk\scripts\uninstaller.sh`** | Port Kitsune's system-mode detection so uninstall cleans `/system/etc/init/magisk` (Kitsune `uninstaller.sh:62,79`). |
| **`D:\Magisk\scripts\util_functions.sh`** | Only if `app_functions.sh` is the wrong home for a helper used by recovery/addon.d too. Prefer `app_functions.sh` for app-only helpers, `util_functions.sh` for helpers also used by the recovery/addon.d scripts. |

### Layer 1 — Build packaging

| File | Action |
|---|---|
| **`D:\Magisk\app\build-logic\src\main\java\Setup.kt:170-202`** (`sync<Variant>Assets`) | **No change required if you put the new functions in `app_functions.sh`** (already in the `include(...)` list at line 179). If you add a new `scripts/manager.sh`-style file, add its name to the `include(...)` call at `Setup.kt:178-179`. If you add new resources under `res/raw/` (Kitsune's approach), they ride along automatically since they live in `app/core/src/main/res/raw/`. |
| **`D:\Magisk\build.py:656-661`** (`push_files`) | Only for `build.py emulator`/`patch` testing: it pushes every top-level `assets/*.sh`, so a new asset script is automatically available to `avd_setup.sh`/`adb_patch.sh` on-device. No change needed. |
| **`D:\Magisk\app\core\build.gradle.kts`** | No change (assets come from `setupCoreLib()`). |

### Layer 2 — Resources

| File | Action |
|---|---|
| **`D:\Magisk\app\core\src\main\res\values\strings.xml`** (after line 45) | Add e.g. `<string name="direct_install_system">Direct Install (modify /system directly)</string>` (Kitsune's exact wording is at `D:\a\KitsuneMagisk\app\src\main\res\values\strings.xml:256`) plus any confirmation-dialog message. Translations are optional — `lint { disable += "MissingTranslation" }` (`Setup.kt:240`). |
| **`D:\Magisk\app\core\src\main\res\values-<lang>\strings.xml`** (0..51 files) | Optional; only if you want translated copies. |

### Layer 3 — Installer engine

| File | Action |
|---|---|
| **`D:\Magisk\app\core\src\main\java\com\topjohnwu\magisk\core\tasks\MagiskInstaller.kt`** | (a) Add `protected suspend fun directSystem() = extractFiles() && "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\"".sh().isSuccess` next to `direct()` / `secondSlot()` (lines 521-528). (b) Add a `class DirectSystem(console, logs) : ConsoleInstaller(console, logs) { override suspend fun operations() = directSystem() }` next to `Direct` (lines 607-612). (c) Possibly extend `extractFiles()` (lines 162-173) if the system-mode path needs extra assets (e.g. a `manager.sh` you do not merge into `app_functions.sh`). Kitsune put the equivalent at `D:\a\KitsuneMagisk\app\src\main\java\com\topjohnwu\magisk\core\tasks\MagiskInstaller.kt:540` and `:603-607`. |
| **`D:\Magisk\app\core\src\main\java\com\topjohnwu\magisk\core\Const.kt:56-62`** | Add `const val FLASH_MAGISK_SYSTEM = "magisk_system"` (Kitsune's exact name is at `D:\a\KitsuneMagisk\app\src\main\java\com\topjohnwu\magisk\core\Const.kt:65`). |

### Layer 4 — ViewModel

| File | Action |
|---|---|
| **`D:\Magisk\app\apk\src\main\java\com\topjohnwu\magisk\ui\install\InstallViewModel.kt`** | Add a `Method.DIRECT_SYSTEM` enum value (line 27), a `val allowSystemInstall` gate (Kitsune: `isRooted && !Info.isBootPatched`, `D:\a\KitsuneMagisk\...\InstallViewModel.kt:42`), and a `Method.DIRECT_SYSTEM -> navigateTo(Route.Flash(action = Const.Value.FLASH_MAGISK_SYSTEM))` branch in `install()` (lines 108-126). |
| **`D:\Magisk\app\apk\src\main\java\com\topjohnwu\magisk\ui\flash\FlashViewModel.kt:71-118`** | Add a `Const.Value.FLASH_MAGISK_SYSTEM ->` branch calling `MagiskInstaller.DirectSystem(outItems, logItems).exec()`. |

### Layer 5 — UI

| File | Action |
|---|---|
| **`D:\Magisk\app\apk\src\main\java\com\topjohnwu\magisk\ui\install\InstallDialog.kt:161-198`** | Add a fourth `SettingsArrow` inside the existing `Card`, `title = stringResource(CoreR.string.direct_install_system)`, gated on `if (installVm.allowSystemInstall) { … }`, calling `installVm.selectMethod(InstallViewModel.Method.DIRECT_SYSTEM); installVm.install()` (mirror the `DIRECT` row at lines 178-187). Optionally extend `InstallOptionsSection` (lines 205-248) if system mode needs its own switch. |
| **`D:\Magisk\app\apk-legacy\...`** | **Do not touch** unless the legacy app must also build; `:apk-legacy` shares `:core` so `Const.Value` / `MagiskInstaller` changes must stay source-compatible with it. |

### Layer 6 — Device detection (only if the gate needs a new fact)

| File | Action |
|---|---|
| **`D:\Magisk\app\core\src\main\java\com\topjohnwu\magisk\core\Info.kt`** | Only if you want Kitsune's `isBootPatched`. Official has no such field: add `var isBootPatched = false` (Kitsune `Info.kt:39`) and wire it in `init()` from a new `app_init` output line. |
| **`D:\Magisk\scripts\app_functions.sh:227-249`** (`app_init`) | Add the producer for that new variable (Kitsune computes `BOOTIMAGE_PATCHED` from `SHA1=$(grep_prop SHA1 $MAGISKTMP/.magisk/config)` at `manager.sh:565-569`), **and** add `printvar` for it. |
| **`D:\Magisk\app\core\src\main\java\com\topjohnwu\magisk\core\Info.kt:58-61`** | Consider widening `isEmulator` if "emulators/containers" must include goldfish/ranchu/Waydroid — currently only `vsoc`/`qemu` props are tested. |
| **`D:\Magisk\app\core\...\core\utils\ShellInit.kt`** | No change unless you need a new prelude; `app_functions.sh` + `util_functions.sh` are already sourced (lines 66-69). |

### Layer 7 — Config / native (only if the runtime must know it is in system mode)

| File | Action |
|---|---|
| **`D:\Magisk\native\src\core\daemon.rs:314-328`** | Add a `SYSTEMMODE` read **if** the daemon needs to behave differently. Currently only `RECOVERYMODE` is read from `$MAGISKTMP/.magisk/config`. |
| **`D:\Magisk\native\src\init\rootdir.rs:43-54`** or **`getinfo.cpp:176-182`** | Only if magiskinit must react to `SYSTEMMODE=true`. |
| **`D:\Magisk\native\src\core\bootstages.rs:32-107`** | **Pre-existing daemon-side env setup you must satisfy.** `setup_magisk_env()` relocates binaries from `/cache/data_adb/magisk`, `/data/magisk`, `<app_data>/0/<pkg>/install` into `/data/adb/magisk`, calls `restorecon()`, **hard-aborts if `/data/adb/magisk/busybox` is missing**, and copies `busybox` + `magisk32` + `magiskpolicy` into `$MAGISKTMP/.magisk/busybox`. A system-mode install that puts binaries on `/system` instead of `/data/adb/magisk` must still leave `/data/adb/magisk` in a state this function accepts. |
| **`D:\Magisk\native\src\core\selinux.rs:75-97`** | `restore_tmpcon()` hard-codes `if tmp == "/sbin" { set u:object_r:rootfs:s0 } else { chmod 0711 }`. Extend if system mode uses a different tmpfs path. |
| **`D:\Magisk\native\src\core\magisk.rs`** (subcommand list at `:33`) | If you keep Kitsune's `magisk --setup-sbin` / `--auto-selinux` design, the subcommand list (and `#[argh(subcommand, name = "--…")]` structs) must be extended — `--setup-sbin` and `--auto-selinux` do **not** exist. `--zygote-restart` exists (line 132). Simpler alternative: reuse `avd_setup.sh`'s existing calls (`magiskpolicy --live --magisk`, `magisk --post-fs-data`, `magisk --service`, `magisk --boot-complete`). `magisk --restorecon` already exists (`core/magisk.rs:35,140,245`) and is the ready-made SELinux relabel entry point. |
| **`D:\Magisk\scripts\avd_setup.sh`** | Not part of the shipped app; leave it as the dev/emulator harness, or extend it to also exercise the system-mode path. |

### Layer 8 — Documentation / CI (optional)

| File | Action |
|---|---|
| `D:\Magisk\docs\faq.md:33-37` | The emulator FAQ; update if system mode changes emulator instructions. |
| `D:\Magisk\.github\workflows\build.yml` | Add a matrix entry if you want CI to exercise system mode on an AVD. |
| `D:\Magisk\scripts\avd.sh:252, 305, 311` | The AVD driver that calls `build.py`; extend if you add a system-mode AVD test. |

---

## Appendix A — Key constant/identifier map (official → Kitsune equivalent)

| Official | Kitsune / System Mode |
|---|---|
| `app/apk/.../ui/install/InstallViewModel.kt` (Compose, `enum Method`) | `app/src/main/java/.../ui/install/InstallViewModel.kt` (databinding Fragment VM, `R.id.method_*`) |
| `app/apk/.../ui/install/InstallDialog.kt` | `app/src/main/res/layout/fragment_install_md2.xml` + `InstallFragment.kt` |
| `InstallViewModel.isRooted` | `InstallViewModel.allowSystemInstall = isRooted && !Info.isBootPatched` |
| (none) | `Info.isBootPatched` |
| (none) | `Const.Value.FLASH_MAGISK_SYSTEM = "magisk_system"` |
| (none) | `MagiskInstaller.Direct_system` → `xdirect_install_system <dir> dummy <apk>` |
| `scripts/app_functions.sh` (all app-side shell helpers) | `app/src/main/res/raw/manager.sh` (app-side) + `scripts/util_functions.sh` |
| `scripts/avd_setup.sh` (dev-only, tmpfs `/sbin`) | `scripts/avd_magisk.sh` |
| `scripts/adb_patch.sh` | (did not exist) |
| `scripts/avd_patch.sh` | `scripts/avd_patch.sh` |
| `build.py emulator` / `push_files` | `build.py emulator` (earlier revision) |
| `MAGISKTMP/.magisk/config` (ramdisk config: KEEPVERITY, KEEPFORCEENCRYPT, RECOVERYMODE, VENDORBOOT, PREINITDEVICE, SHA1) | plus `/system/etc/init/magisk/config` (`SYSTEMMODE=true\nRECOVERYMODE=false`) |
| `Info.isEmulator` = `vsoc` ∨ `ro.kernel.qemu` ∨ `ro.boot.qemu` | `ro.kernel.qemu` ∨ `ro.boot.qemu` (no `vsoc`) |
| `app/core/src/main/res/values/strings.xml` | `app/src/main/res/values/strings.xml` |

## Appendix B — Things that DO NOT exist and must not be assumed

- `InstallFragment`, `InstallScreen`, `InstallMethod`, `Method` sealed class — **do not exist** in `:apk`.
- Installer ZIP / `Magisk-vXX.apk`-only distribution: **no standalone ZIP** is built; the APK is the flashable ZIP.
- `isInstalled`, `envFix`, `bootPatched`, `recoveryMode`, `isZygisk`, `SU_VERSION`, `MAGISK_VER`, `MAGISK_VER_CODE` as `Info` members — **do not exist** (`isZygiskEnabled` and `Config.recovery` are the real names).
- `/data/adb/magisk/config`, `MAGISK_CONFIG`, `magisk --config`, `SYSTEMMODE` — **do not exist anywhere**.
- `manager.sh` — **does not exist** in the official tree (Kitsune-only, `res/raw/manager.sh`).
- `goldfish`, `ranchu`, `waydroid`, `restorecon` — **not found anywhere** in `D:\Magisk`.
- `magisk --setup-sbin`, `magisk --auto-selinux` — **do not exist** (`--zygote-restart` does).
- `--cuttlefish` flag in `build.py` — **does not exist** (cuttlefish reuses `patch`).
</content>
