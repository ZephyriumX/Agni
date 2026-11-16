package com.agnipulse.ppg_camera

/** What the plugin needs from any capture backend (regular YUV or constrained high-speed). */
interface CaptureSession {
    fun setLocked(l: Boolean)
    fun stop()
    /** Human-readable step log for support / the "Copy diagnostics" button. */
    fun diag(): List<String>
}
