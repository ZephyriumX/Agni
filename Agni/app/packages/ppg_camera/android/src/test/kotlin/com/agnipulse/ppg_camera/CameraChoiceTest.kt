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
}
