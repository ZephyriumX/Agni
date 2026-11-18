package com.agnipulse.ppg_camera

import com.agnipulse.ppg_camera.CameraCaps.Cam
import com.agnipulse.ppg_camera.CameraCaps.Sz
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Pure JVM tests of the camera ranking/selection (no Android runtime needed). */
class CameraChoiceTest {
    private fun cam(key: String, fps: Double, flash: Boolean = true, manual: Boolean = true,
                    eq: Double? = 26.0, kind: String = "single", phys: String? = null) = Cam(
        key = key, logicalId = key.substringBefore(':'), physicalId = phys, kind = kind, hasFlash = flash,
        manual = manual, yuv = listOf(Sz(640, 480, fps), Sz(1920, 1080, fps)), surfaceMaxFps = fps,
        highSpeed = emptyList(), aeRanges = emptyList(), hardwareLevel = 1, focalMm = 5.0, equivMm = eq,
        physicalIds = emptyList())

    @Test fun fasterPhysicalLensBeatsSlowLogicalCamera() {
        val cams = listOf(cam("0", 30.0, kind = "logical"), cam("0:2", 60.0, kind = "physical", phys = "2"))
        assertEquals("0:2", CameraCaps.choose(cams, 60, 55)?.cam?.key)
    }

    @Test fun nothingReachesTheMinimumGivesNull() {
        assertNull(CameraCaps.choose(listOf(cam("0", 30.0), cam("0:2", 30.0, phys = "2")), 60, 55))
    }

    @Test fun userChoiceIsHonouredEvenIfAnotherIsFaster() {
        val cams = listOf(cam("0", 60.0), cam("0:2", 58.0, phys = "2"))
        assertEquals("0:2", CameraCaps.choose(cams, 60, 55, "0:2")?.cam?.key)
    }

    @Test fun unsuitableUserChoiceIsNeverSwitchedSilently() {
        val cams = listOf(cam("0", 60.0), cam("0:2", 30.0, phys = "2"))
        assertNull(CameraCaps.choose(cams, 60, 55, "0:2"))
    }

    @Test fun cameraWithoutFlashIsNotUsable() {
        assertNull(CameraCaps.choose(listOf(cam("0", 60.0, flash = false)), 60, 55))
    }

    @Test fun meetingTargetBeatsHigherSlowerNonTargetAndManualBeatsAuto() {
        val cams = listOf(cam("1", 57.0, manual = true), cam("2", 60.0, manual = false), cam("3", 120.0, manual = false))
        // 2 and 3 both meet the target; fps above the target does not help; neither is manual -> main-lens rule, then order
        assertNotNull(CameraCaps.choose(cams, 60, 55))
        assertEquals(true, (CameraCaps.choose(cams, 60, 55)?.maxFps ?: 0.0) >= 59.5)
        val withManual = cams + cam("4", 60.0, manual = true)
        assertEquals("4", CameraCaps.choose(withManual, 60, 55)?.cam?.key)
    }

    @Test fun mainLensPreferredOverUltraWideWhenEqual() {
        val cams = listOf(cam("0:3", 60.0, eq = 14.0, phys = "3"), cam("0:2", 60.0, eq = 26.0, phys = "2"))
        assertEquals("0:2", CameraCaps.choose(cams, 60, 55)?.cam?.key)
    }

    // ---- constrained high-speed (realme P3 5G profile: YUV capped at 30 fps) ----
    private fun hsCam(key: String = "0", vararg modes: CameraCaps.Hs) = Cam(
        key = key, logicalId = key, physicalId = null, kind = "single", hasFlash = true, manual = true,
        yuv = listOf(Sz(640, 480, 30.0), Sz(1920, 1080, 30.0)), surfaceMaxFps = 30.0,
        highSpeed = emptyList(), aeRanges = emptyList(), hardwareLevel = 1, focalMm = 5.0, equivMm = 27.0,
        physicalIds = emptyList(), hs = modes.toList())
    private val p3 = arrayOf(CameraCaps.Hs(120, 120, 1280, 720), CameraCaps.Hs(240, 240, 1280, 720),
        CameraCaps.Hs(30, 240, 1280, 720), CameraCaps.Hs(60, 240, 1280, 720), CameraCaps.Hs(30, 120, 1280, 720),
        CameraCaps.Hs(60, 120, 1280, 720))

    @Test fun yuvCappedAt30UsesHighSpeedWithFixed120() {
        val p = CameraCaps.choose(listOf(hsCam("0", *p3)), 60, 55)
        assertNotNull(p)
        assertEquals("highspeed", p!!.mode)
        assertEquals(120, p.hsCandidates.first().hi); assertEquals(120, p.hsCandidates.first().lo)
        assertEquals("60,120", "${p.hsCandidates[1].lo},${p.hsCandidates[1].hi}")   // fallback range
    }

    @Test fun highSpeedRangeWhoseLowerBoundIsBelowMinimumIsRejected() {
        val c = hsCam("0", CameraCaps.Hs(30, 120, 1280, 720))
        assertNull(CameraCaps.choose(listOf(c), 60, 55))
    }

    @Test fun regularYuvIsPreferredOverHighSpeedAtEqualRate() {
        val cams = listOf(hsCam("0", *p3), cam("1", 60.0))
        assertEquals("1", CameraCaps.choose(cams, 60, 55)?.cam?.key)
        assertEquals("yuv", CameraCaps.choose(cams, 60, 55)?.mode)
    }
}
