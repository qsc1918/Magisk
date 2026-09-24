package com.topjohnwu.magisk.dialog

import com.topjohnwu.magisk.core.R
import com.topjohnwu.magisk.events.DialogBuilder
import com.topjohnwu.magisk.view.MagiskDialog

/**
 * Confirmation warning shown before a System Mode installation.
 *
 * System Mode writes Magisk directly into the /system partition instead of
 * patching the boot image, so a failure halfway through can leave the device
 * unbootable. The user must explicitly confirm.
 */
class SystemModeWarningDialog(
    private val onCancel: (() -> Unit)? = null,
) : DialogBuilder {

    override fun build(dialog: MagiskDialog) {
        var confirmed = false

        dialog.apply {
            setTitle(android.R.string.dialog_alert_title)
            setMessage(R.string.direct_install_system_msg)
            setButton(MagiskDialog.ButtonType.POSITIVE) {
                text = android.R.string.ok
                onClick {
                    confirmed = true
                    doNotDismiss = false
                }
            }
            setButton(MagiskDialog.ButtonType.NEGATIVE) {
                text = android.R.string.cancel
            }
            setCancelable(true)
            setOnDismissListener {
                if (!confirmed) onCancel?.invoke()
            }
        }
    }
}
