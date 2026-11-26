package __VIBEHELPER_PACKAGE__

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Top punch-hole Dynamic Island overlay with iOS-style centered spring morphing,
 * configurable pixel pet, auto/manual expand, and quick Agent controls.
 */
class DynamicIslandManager(private val context: Context) {
    private val appWindowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
    private var attachedWindowManager: WindowManager? = null
    private var usingAccessibilityLayer: Boolean = false
    private val mainHandler = Handler(Looper.getMainLooper())

    private var containerView: FrameLayout? = null
    private var islandShell: FrameLayout? = null
    private var shellBg: GradientDrawable? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var autoCollapseRunnable: Runnable? = null
    private var activeAnimator: ValueAnimator? = null
    private var isDismissing: Boolean = false
    private var hasPendingUpdate: Boolean = false

    private var currentTitle: String = "VibeHelper"
    private var currentBody: String = ""
    private var currentStatus: String = "idle"
    private var currentShowActions: Boolean = false
    private var currentPetType: String = "shiba"
    private var currentAutoExpand: Boolean = true
    private var currentYOffsetDp: Int = 6
    private var currentWidthDp: Int = 140
    private var isExpanded: Boolean = false
    private var lastAutoExpandedStatus: String = ""
    private var actionCallback: ((String) -> Unit)? = null
    private var activePetView: IslandPetView? = null
    private var petWalkPos: Float = 0.15f
    private var petWalkDir: Int = 1

    fun canDrawOverlays(): Boolean = Settings.canDrawOverlays(context)

    fun canShowIsland(): Boolean =
        VibeIslandAccessibilityService.isEnabled() || canDrawOverlays()

    fun isShowing(): Boolean = containerView != null && !isDismissing

    fun rebindLayerIfShowing() {
        mainHandler.post {
            if (containerView == null || !canShowIsland()) return@post
            val wantA11y = VibeIslandAccessibilityService.isEnabled()
            if (wantA11y == usingAccessibilityLayer) return@post
            removeIslandImmediateLocked()
            createAndAttachWindowLocked(startCollapsedForPopIn = false)
            renderShellContentLocked()
            attachedWindowManager?.let { updateWindowLayoutLocked(it) }
        }
    }

    fun showIsland(
        title: String,
        body: String,
        status: String,
        showActions: Boolean,
        petType: String,
        autoExpand: Boolean,
        yOffsetDp: Int,
        widthDp: Int,
        expanded: Boolean,
        onAction: (String) -> Unit
    ) {
        mainHandler.post {
            if (!canShowIsland()) return@post

            val wasExpanded = isExpanded
            currentTitle = title
            currentBody = body
            currentStatus = status
            currentShowActions = showActions
            currentPetType = petType
            currentAutoExpand = autoExpand
            currentYOffsetDp = yOffsetDp.coerceIn(0, 60)
            currentWidthDp = widthDp.coerceIn(140, 300)
            isExpanded = expanded
            actionCallback = onAction

            val wantA11y = VibeIslandAccessibilityService.isEnabled()
            if (containerView != null && wantA11y != usingAccessibilityLayer) {
                removeIslandImmediateLocked()
            }

            if (containerView == null) {
                createAndAttachWindowLocked(startCollapsedForPopIn = true)
                animatePopInLocked()
            } else if (isDismissing) {
                isDismissing = false
                animatePopInLocked()
            } else if (expanded != wasExpanded) {
                animateExpandCollapseLocked(expand = expanded)
            } else if (activeAnimator?.isRunning == true) {
                hasPendingUpdate = true
                updateShellStrokeLocked()
            } else {
                renderShellContentLocked()
                attachedWindowManager?.let { updateWindowLayoutLocked(it) }
                animatePulseLocked()
            }
        }
    }

    fun updateIsland(
        title: String,
        body: String,
        status: String,
        showActions: Boolean,
        petType: String,
        autoExpand: Boolean,
        yOffsetDp: Int,
        widthDp: Int
    ) {
        mainHandler.post {
            if (containerView == null || isDismissing || !canShowIsland()) return@post

            val prevStatus = currentStatus
            currentTitle = title
            currentBody = body
            currentStatus = status
            currentShowActions = showActions
            currentPetType = petType
            currentAutoExpand = autoExpand
            currentYOffsetDp = yOffsetDp.coerceIn(0, 60)
            currentWidthDp = widthDp.coerceIn(140, 300)

            var shouldPulse = status != prevStatus
            var triggeredAutoExpand = false

            if (autoExpand &&
                (status == "waiting_approval" || status == "question") &&
                lastAutoExpandedStatus != status
            ) {
                lastAutoExpandedStatus = status
                if (!isExpanded) {
                    triggeredAutoExpand = true
                }
                scheduleAutoCollapseLocked()
            } else if (status != "waiting_approval" && status != "question") {
                lastAutoExpandedStatus = ""
            }

            val wantA11y = VibeIslandAccessibilityService.isEnabled()
            if (wantA11y != usingAccessibilityLayer) {
                if (triggeredAutoExpand) {
                    isExpanded = true
                }
                removeIslandImmediateLocked()
                createAndAttachWindowLocked(startCollapsedForPopIn = true)
                animatePopInLocked()
                return@post
            }

            if (triggeredAutoExpand) {
                animateExpandCollapseLocked(expand = true)
                return@post
            }

            if (activeAnimator?.isRunning == true) {
                hasPendingUpdate = true
                updateShellStrokeLocked()
                return@post
            }

            renderShellContentLocked()
            attachedWindowManager?.let { updateWindowLayoutLocked(it) }
            if (shouldPulse) {
                animatePulseLocked()
            }
        }
    }

    fun hideIsland() {
        mainHandler.post {
            animateHideAndRemoveLocked()
        }
    }

    private fun createAndAttachWindowLocked(startCollapsedForPopIn: Boolean) {
        val a11yService = VibeIslandAccessibilityService.instance
        val useA11y = a11yService != null
        val wm = if (useA11y) {
            (a11yService?.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
                ?: appWindowManager
        } else {
            appWindowManager
        } ?: return

        val windowType = if (useA11y) {
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS

        val initialWinW = fixedWindowWidthPx()

        val params = WindowManager.LayoutParams(
            initialWinW,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            flags,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = dp(currentYOffsetDp)
            windowAnimations = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        val container = FrameLayout(context).apply {
            clipChildren = false
            clipToPadding = false
        }

        val bg = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = if (startCollapsedForPopIn) {
                punchHoleCornerPx()
            } else if (isExpanded) {
                dpF(24f)
            } else {
                dpF(19f)
            }
            setColor(Color.parseColor("#FA0B0D12"))
            setStroke(dp(1), borderStrokeColor())
        }

        val shellInitW = if (startCollapsedForPopIn) punchHoleWidthPx() else targetWidthPx()
        val shellInitH = if (startCollapsedForPopIn) {
            punchHoleHeightPx()
        } else {
            FrameLayout.LayoutParams.WRAP_CONTENT
        }

        val shell = FrameLayout(context).apply {
            background = bg
            elevation = dpF(10f)
            outlineProvider = ViewOutlineProvider.BACKGROUND
            clipToOutline = true
            clipChildren = true
            if (startCollapsedForPopIn) {
                alpha = 0f
            }
        }

        container.addView(
            shell,
            FrameLayout.LayoutParams(
                shellInitW,
                shellInitH,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            )
        )

        container.setOnTouchListener { _, event ->
            if (isExpanded && !isDismissing) {
                val isOutside = when (event.actionMasked) {
                    MotionEvent.ACTION_OUTSIDE -> true
                    MotionEvent.ACTION_DOWN ->
                        event.x < shell.left ||
                            event.x > shell.right ||
                            event.y < shell.top ||
                            event.y > shell.bottom
                    else -> false
                }
                if (isOutside) {
                    cancelAutoCollapseLocked()
                    animateExpandCollapseLocked(expand = false)
                }
            }
            false
        }

        containerView = container
        islandShell = shell
        shellBg = bg
        layoutParams = params
        attachedWindowManager = wm
        usingAccessibilityLayer = useA11y
        isDismissing = false

        try {
            wm.addView(container, params)
        } catch (_: Throwable) {
            containerView = null
            islandShell = null
            shellBg = null
            layoutParams = null
            attachedWindowManager = null
            usingAccessibilityLayer = false
        }
    }

    private fun punchHoleWidthPx(): Int = dp(36)

    private fun punchHoleHeightPx(): Int = dp(34)

    private fun punchHoleCornerPx(): Float = dpF(17f)

    private fun fixedWindowWidthPx(): Int {
        val screenW = context.resources.displayMetrics.widthPixels
        val maxExpandedW = (screenW - dp(24)).coerceIn(dp(240), dp(336))
        val maxCollapsedW = dp(300).coerceAtMost(screenW - dp(16))
        return (maxOf(maxExpandedW, maxCollapsedW) + dp(24))
            .coerceAtMost((screenW - dp(4)).coerceAtLeast(maxExpandedW))
    }

    private fun targetWidthPx(): Int {
        val screenW = context.resources.displayMetrics.widthPixels
        return if (isExpanded) {
            (screenW - dp(24)).coerceIn(dp(240), dp(336))
        } else {
            dp(currentWidthDp).coerceAtMost(screenW - dp(16))
        }
    }

    private fun measureTargetHeightLocked(contentView: View, widthPx: Int): Int {
        contentView.measure(
            View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        return contentView.measuredHeight.coerceAtLeast(dp(38))
    }

    private fun updateWindowLayoutLocked(wm: WindowManager) {
        val container = containerView ?: return
        val lp = layoutParams ?: return
        val targetY = dp(currentYOffsetDp)
        if (lp.y == targetY) return
        lp.y = targetY
        updateWindowLayoutSafe(wm, container, lp)
    }

    private fun updateWindowLayoutSafe(
        wm: WindowManager,
        container: View,
        lp: WindowManager.LayoutParams
    ) {
        try {
            wm.updateViewLayout(container, lp)
        } catch (_: Throwable) {
        }
    }

    private fun updateShellStrokeLocked() {
        shellBg?.setStroke(dp(1), borderStrokeColor())
    }

    private fun scheduleAutoCollapseLocked() {
        cancelAutoCollapseLocked()
        val runnable = Runnable {
            if (containerView == null || !isExpanded || isDismissing) return@Runnable
            animateExpandCollapseLocked(expand = false)
        }
        autoCollapseRunnable = runnable
        mainHandler.postDelayed(runnable, 12000L)
    }

    private fun cancelAutoCollapseLocked() {
        autoCollapseRunnable?.let { mainHandler.removeCallbacks(it) }
        autoCollapseRunnable = null
    }

    private fun cancelActiveAnimatorLocked() {
        val anim = activeAnimator
        activeAnimator = null
        anim?.cancel()
    }

    private fun savePetWalkStateLocked() {
        activePetView?.let {
            petWalkPos = it.walkPos
            petWalkDir = it.walkDir
        }
        activePetView = null
    }

    private fun renderShellContentLocked() {
        val shell = islandShell ?: return
        cancelActiveAnimatorLocked()
        savePetWalkStateLocked()
        shell.removeAllViews()
        val toW = targetWidthPx()
        val child = if (isExpanded) buildExpandedIsland() else buildCollapsedCapsule()
        shell.addView(
            child,
            FrameLayout.LayoutParams(
                toW,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            )
        )
        (shell.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
            lp.width = toW
            lp.height = FrameLayout.LayoutParams.WRAP_CONTENT
            lp.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            shell.layoutParams = lp
        } ?: run {
            shell.layoutParams = FrameLayout.LayoutParams(
                toW,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            )
        }
        shell.alpha = 1f
        shell.scaleX = 1f
        shell.scaleY = 1f
        shellBg?.cornerRadius = if (isExpanded) dpF(24f) else dpF(19f)
        updateShellStrokeLocked()
        shell.invalidateOutline()
    }

    private fun animatePopInLocked() {
        if (containerView == null) return
        val shell = islandShell ?: return
        val bg = shellBg ?: return

        cancelActiveAnimatorLocked()
        savePetWalkStateLocked()

        val fromW = shell.width.takeIf { it > 0 } ?: punchHoleWidthPx()
        val fromH = shell.height.takeIf { it > 0 } ?: punchHoleHeightPx()
        val fromRadius = bg.cornerRadius
        val fromShellAlpha = shell.alpha

        val newContent = if (isExpanded) buildExpandedIsland() else buildCollapsedCapsule()
        val toW = targetWidthPx()
        val toH = measureTargetHeightLocked(newContent, toW)
        val toRadius = if (isExpanded) dpF(24f) else (toH / 2f).coerceAtLeast(dpF(19f))

        attachedWindowManager?.let { updateWindowLayoutLocked(it) }

        shell.removeAllViews()
        newContent.alpha = 0f
        newContent.scaleX = 0.90f
        newContent.scaleY = 0.90f
        shell.addView(
            newContent,
            FrameLayout.LayoutParams(
                toW,
                toH,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            )
        )
        shell.layoutParams = FrameLayout.LayoutParams(
            fromW,
            fromH,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL
        )
        updateShellStrokeLocked()

        val minDimPx = dp(24)
        val maxWinW = fixedWindowWidthPx()
        val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 340L
            interpolator = OvershootInterpolator(1.08f)
            addUpdateListener { va ->
                if (islandShell !== shell) return@addUpdateListener
                val t = va.animatedValue as Float
                val rawP = va.animatedFraction.coerceIn(0f, 1f)

                val curW = lerpInt(fromW, toW, t).coerceIn(minDimPx, maxWinW)
                val curH = lerpInt(fromH, toH, t).coerceAtLeast(minDimPx)
                shell.layoutParams = FrameLayout.LayoutParams(
                    curW,
                    curH,
                    Gravity.TOP or Gravity.CENTER_HORIZONTAL
                )

                val r = lerpFloat(fromRadius, toRadius, t)
                    .coerceAtMost(minOf(curW, curH) / 2f)
                bg.cornerRadius = r
                shell.invalidateOutline()

                shell.alpha = if (fromShellAlpha >= 0.99f) {
                    1f
                } else {
                    val aP = (rawP / 0.22f).coerceIn(0f, 1f)
                    lerpFloat(fromShellAlpha, 1f, aP)
                }

                val cP = ((rawP - 0.28f) / 0.57f).coerceIn(0f, 1f)
                newContent.alpha = cP
                val cScale = 0.90f + 0.10f * cP
                newContent.scaleX = cScale
                newContent.scaleY = cScale
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (cancelled || activeAnimator !== animation) return
                    activeAnimator = null
                    shell.alpha = 1f
                    newContent.alpha = 1f
                    newContent.scaleX = 1f
                    newContent.scaleY = 1f
                    newContent.layoutParams = FrameLayout.LayoutParams(
                        toW,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    )
                    shell.layoutParams = FrameLayout.LayoutParams(
                        toW,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    )
                    bg.cornerRadius = toRadius
                    shell.invalidateOutline()
                    if (hasPendingUpdate) {
                        hasPendingUpdate = false
                        renderShellContentLocked()
                        attachedWindowManager?.let { updateWindowLayoutLocked(it) }
                    }
                }
            })
        }
        activeAnimator = anim
        anim.start()
    }

    private fun animateExpandCollapseLocked(expand: Boolean) {
        if (containerView == null) return
        val shell = islandShell ?: return
        val bg = shellBg ?: return

        cancelActiveAnimatorLocked()
        savePetWalkStateLocked()
        isExpanded = expand

        val fromW = shell.width.takeIf { it > 0 } ?: targetWidthPx()
        val fromH = shell.height.takeIf { it > 0 } ?: dp(38)
        val fromRadius = bg.cornerRadius

        val staleViews = (0 until shell.childCount).map { shell.getChildAt(it) }
        val staleInitialAlphas = staleViews.map { it.alpha }

        val newContent = if (expand) buildExpandedIsland() else buildCollapsedCapsule()
        val toW = targetWidthPx()
        val toH = measureTargetHeightLocked(newContent, toW)
        val toRadius = if (expand) dpF(24f) else (toH / 2f).coerceAtLeast(dpF(19f))

        attachedWindowManager?.let { updateWindowLayoutLocked(it) }

        newContent.alpha = 0f
        newContent.scaleX = if (expand) 0.95f else 0.94f
        newContent.scaleY = if (expand) 0.95f else 0.94f
        shell.addView(
            newContent,
            FrameLayout.LayoutParams(
                toW,
                toH,
                Gravity.TOP or Gravity.CENTER_HORIZONTAL
            )
        )
        shell.layoutParams = FrameLayout.LayoutParams(
            fromW,
            fromH,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL
        )
        shell.alpha = 1f
        shell.scaleX = 1f
        shell.scaleY = 1f
        updateShellStrokeLocked()

        val minDimPx = dp(24)
        val maxWinW = fixedWindowWidthPx()
        val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = if (expand) 340L else 280L
            interpolator = if (expand) {
                OvershootInterpolator(0.92f)
            } else {
                PathInterpolator(0.22f, 1f, 0.36f, 1f)
            }
            addUpdateListener { va ->
                if (islandShell !== shell) return@addUpdateListener
                val t = va.animatedValue as Float
                val rawP = va.animatedFraction.coerceIn(0f, 1f)

                val curW = lerpInt(fromW, toW, t).coerceIn(minDimPx, maxWinW)
                val curH = lerpInt(fromH, toH, t).coerceAtLeast(minDimPx)
                shell.layoutParams = FrameLayout.LayoutParams(
                    curW,
                    curH,
                    Gravity.TOP or Gravity.CENTER_HORIZONTAL
                )

                val r = lerpFloat(fromRadius, toRadius, t)
                    .coerceAtMost(minOf(curW, curH) / 2f)
                bg.cornerRadius = r
                shell.invalidateOutline()

                val outEnd = if (expand) 0.38f else 0.34f
                val outFrac = (1f - rawP / outEnd).coerceIn(0f, 1f)
                for (i in staleViews.indices) {
                    staleViews[i].alpha = staleInitialAlphas[i] * outFrac
                }

                val inStart = if (expand) 0.22f else 0.28f
                val inEnd = if (expand) 0.78f else 0.85f
                val inFrac = ((rawP - inStart) / (inEnd - inStart)).coerceIn(0f, 1f)
                newContent.alpha = inFrac
                val cScale = if (expand) (0.95f + 0.05f * inFrac) else (0.94f + 0.06f * inFrac)
                newContent.scaleX = cScale
                newContent.scaleY = cScale
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (cancelled || activeAnimator !== animation) return
                    activeAnimator = null
                    for (v in staleViews) {
                        shell.removeView(v)
                    }
                    newContent.alpha = 1f
                    newContent.scaleX = 1f
                    newContent.scaleY = 1f
                    newContent.layoutParams = FrameLayout.LayoutParams(
                        toW,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    )
                    shell.layoutParams = FrameLayout.LayoutParams(
                        toW,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    )
                    bg.cornerRadius = toRadius
                    shell.invalidateOutline()
                    if (hasPendingUpdate) {
                        hasPendingUpdate = false
                        renderShellContentLocked()
                        attachedWindowManager?.let { updateWindowLayoutLocked(it) }
                    }
                }
            })
        }
        activeAnimator = anim
        anim.start()
    }

    private fun animateHideAndRemoveLocked() {
        if (containerView == null || isDismissing) return
        val shell = islandShell
        val bg = shellBg
        if (shell == null || bg == null) {
            removeIslandImmediateLocked()
            return
        }

        isDismissing = true
        cancelAutoCollapseLocked()
        cancelActiveAnimatorLocked()
        savePetWalkStateLocked()

        val fromW = shell.width.takeIf { it > 0 } ?: targetWidthPx()
        val fromH = shell.height.takeIf { it > 0 } ?: dp(38)
        val fromRadius = bg.cornerRadius
        val toW = punchHoleWidthPx()
        val toH = punchHoleHeightPx()
        val toRadius = punchHoleCornerPx()

        val children = (0 until shell.childCount).map { shell.getChildAt(it) }
        val initialChildAlphas = children.map { it.alpha }
        val initialShellAlpha = shell.alpha

        val minDimPx = dp(24)
        val maxWinW = fixedWindowWidthPx()
        val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 240L
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener { va ->
                if (islandShell !== shell) return@addUpdateListener
                val t = va.animatedFraction.coerceIn(0f, 1f)

                val curW = lerpInt(fromW, toW, t).coerceIn(minDimPx, maxWinW)
                val curH = lerpInt(fromH, toH, t).coerceAtLeast(minDimPx)
                shell.layoutParams = FrameLayout.LayoutParams(
                    curW,
                    curH,
                    Gravity.TOP or Gravity.CENTER_HORIZONTAL
                )

                val r = lerpFloat(fromRadius, toRadius, t)
                    .coerceAtMost(minOf(curW, curH) / 2f)
                bg.cornerRadius = r
                shell.invalidateOutline()

                val childOutFrac = (1f - t / 0.42f).coerceIn(0f, 1f)
                val childScale = 1f - 0.12f * (t / 0.42f).coerceIn(0f, 1f)
                for (i in children.indices) {
                    children[i].alpha = initialChildAlphas[i] * childOutFrac
                    children[i].scaleX = childScale
                    children[i].scaleY = childScale
                }

                shell.alpha = if (t < 0.72f) {
                    initialShellAlpha
                } else {
                    initialShellAlpha * (1f - (t - 0.72f) / 0.28f).coerceIn(0f, 1f)
                }
            }
            addListener(object : AnimatorListenerAdapter() {
                private var cancelled = false

                override fun onAnimationCancel(animation: Animator) {
                    cancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    if (cancelled || activeAnimator !== animation) return
                    activeAnimator = null
                    if (isDismissing) {
                        removeIslandImmediateLocked()
                    }
                }
            })
        }
        activeAnimator = anim
        anim.start()
    }

    private fun animatePulseLocked() {
        val shell = islandShell ?: return
        if (activeAnimator?.isRunning == true || isDismissing) return
        shell.animate().cancel()
        if (shell.width > 0) {
            shell.pivotX = shell.width / 2f
            shell.pivotY = 0f
        }
        shell.scaleX = 0.96f
        shell.scaleY = 0.96f
        shell.animate()
            .scaleX(1.0f)
            .scaleY(1.0f)
            .setDuration(200L)
            .setInterpolator(OvershootInterpolator(1.6f))
            .start()
    }

    private fun lerpInt(start: Int, end: Int, fraction: Float): Int =
        (start + (end - start) * fraction).roundToInt()

    private fun lerpFloat(start: Float, end: Float, fraction: Float): Float =
        start + (end - start) * fraction

    private fun statusColor(): Int = when (currentStatus) {
        "waiting_approval", "question" -> Color.parseColor("#F59E0B")
        "working" -> Color.parseColor("#38BDF8")
        "disconnected" -> Color.parseColor("#64748B")
        else -> Color.parseColor("#10B981")
    }

    private fun statusShortLabel(): String = when (currentStatus) {
        "waiting_approval" -> "待审批"
        "question" -> "提问中"
        "working" -> "干活中"
        "disconnected" -> "离线"
        else -> "空闲"
    }

    private fun borderStrokeColor(): Int = when (currentStatus) {
        "waiting_approval", "question" -> Color.parseColor("#88F59E0B")
        "working" -> Color.parseColor("#6638BDF8")
        else -> Color.parseColor("#FF262B38")
    }

    private fun buildCollapsedCapsule(): View {
        var downX = 0f
        var downY = 0f
        val pill = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(38)
            setPadding(dp(11), dp(6), dp(12), dp(6))
            isClickable = true
            isFocusable = true
            setOnTouchListener { v, event ->
                val target = islandShell ?: v
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = event.rawX
                        downY = event.rawY
                        if (target.width > 0) {
                            target.pivotX = target.width / 2f
                            target.pivotY = target.height / 2f
                        }
                        target.animate().scaleX(0.96f).scaleY(0.96f).setDuration(70L).start()
                        true
                    }
                    MotionEvent.ACTION_MOVE -> true
                    MotionEvent.ACTION_UP -> {
                        target.animate().cancel()
                        val dx = abs(event.rawX - downX)
                        val dy = abs(event.rawY - downY)
                        if (dx < dp(14) && dy < dp(14)) {
                            target.scaleX = 1f
                            target.scaleY = 1f
                            cancelAutoCollapseLocked()
                            animateExpandCollapseLocked(expand = true)
                        } else {
                            target.animate().scaleX(1f).scaleY(1f).setDuration(90L).start()
                        }
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        target.animate().scaleX(1f).scaleY(1f).setDuration(90L).start()
                        false
                    }
                    else -> false
                }
            }
        }

        val runwayDp = ((currentWidthDp - 120) / 2 + 26).coerceIn(28, 92)
        val petView = IslandPetView(context).apply {
            restoreWalk(petWalkPos, petWalkDir)
            updateState(currentPetType, currentStatus)
        }
        activePetView = petView
        pill.addView(petView, LinearLayout.LayoutParams(dp(runwayDp), dp(24)))

        // Center spacer clears the top-center punch-hole camera
        pill.addView(
            View(context),
            LinearLayout.LayoutParams(0, dp(24), 1f)
        )

        pill.addView(
            View(context).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(statusColor())
                }
            },
            LinearLayout.LayoutParams(dp(7), dp(7)).apply {
                marginEnd = dp(5)
            }
        )

        pill.addView(
            TextView(context).apply {
                text = statusShortLabel()
                setTextColor(Color.parseColor("#F8FAFC"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                setTypeface(Typeface.DEFAULT_BOLD)
                maxLines = 1
            }
        )

        return pill
    }

    private fun buildExpandedIsland(): View {
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }

        // Header: Pet + Title + Status badge + Minimize + Close
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        val petView = IslandPetView(context).apply {
            restoreWalk(petWalkPos, petWalkDir)
            updateState(currentPetType, currentStatus)
        }
        activePetView = petView
        header.addView(
            petView,
            LinearLayout.LayoutParams(dp(58), dp(30)).apply {
                marginEnd = dp(9)
            }
        )

        val titleCol = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        titleCol.addView(
            TextView(context).apply {
                text = currentTitle.ifBlank { "VibeHelper" }
                setTextColor(Color.parseColor("#F8FAFC"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
                setTypeface(Typeface.DEFAULT_BOLD)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
        )
        titleCol.addView(
            TextView(context).apply {
                text = statusShortLabel()
                setTextColor(statusColor())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTypeface(Typeface.DEFAULT_BOLD)
                maxLines = 1
            }
        )
        header.addView(
            titleCol,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        )

        header.addView(
            TextView(context).apply {
                text = "—"
                setTextColor(Color.parseColor("#94A3B8"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.CENTER
                setPadding(dp(8), dp(2), dp(6), dp(2))
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    cancelAutoCollapseLocked()
                    animateExpandCollapseLocked(expand = false)
                }
            }
        )

        header.addView(
            TextView(context).apply {
                text = "×"
                setTextColor(Color.parseColor("#94A3B8"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                gravity = Gravity.CENTER
                setPadding(dp(6), 0, dp(2), 0)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    actionCallback?.invoke("overlay_closed")
                    hideIsland()
                }
            }
        )

        card.addView(header)

        // Message preview body
        val preview = currentBody.ifBlank {
            if (currentStatus == "disconnected") "与宿主机连接已断开，点击进入检查" else "正在监听宿主机状态..."
        }
        card.addView(
            TextView(context).apply {
                text = preview
                setTextColor(Color.parseColor("#CBD5E1"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                maxLines = 3
                ellipsize = TextUtils.TruncateAt.END
                setPadding(0, dp(8), 0, 0)
                isClickable = true
                setOnClickListener { openApp() }
            }
        )

        // Footer actions
        val footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            setPadding(0, dp(10), 0, 0)
        }

        if (currentShowActions) {
            footer.addView(
                makeIslandButton(
                    label = "拒绝",
                    bgColor = Color.parseColor("#2EEF4444"),
                    textColor = Color.parseColor("#FCA5A5"),
                    borderColor = Color.parseColor("#66EF4444")
                ) {
                    cancelAutoCollapseLocked()
                    actionCallback?.invoke("reject")
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    marginEnd = dp(6)
                }
            )
            footer.addView(
                makeIslandButton(
                    label = "允许",
                    bgColor = Color.parseColor("#2E10B981"),
                    textColor = Color.parseColor("#6EE7B7"),
                    borderColor = Color.parseColor("#6610B981")
                ) {
                    cancelAutoCollapseLocked()
                    actionCallback?.invoke("accept")
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    marginEnd = dp(6)
                }
            )
        } else if (currentStatus == "working") {
            footer.addView(
                makeIslandButton(
                    label = "打断",
                    bgColor = Color.parseColor("#2EF59E0B"),
                    textColor = Color.parseColor("#FCD34D"),
                    borderColor = Color.parseColor("#66F59E0B")
                ) {
                    cancelAutoCollapseLocked()
                    actionCallback?.invoke("interrupt")
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    marginEnd = dp(6)
                }
            )
        } else if (currentStatus != "disconnected") {
            footer.addView(
                makeIslandButton(
                    label = "继续",
                    bgColor = Color.parseColor("#FF1E293B"),
                    textColor = Color.parseColor("#F8FAFC"),
                    borderColor = Color.parseColor("#FF334155")
                ) {
                    cancelAutoCollapseLocked()
                    actionCallback?.invoke("continue")
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    marginEnd = dp(6)
                }
            )
        }

        footer.addView(
            makeIslandButton(
                label = if (currentShowActions) "进入" else "进入应用",
                bgColor = Color.parseColor("#FF1E293B"),
                textColor = Color.parseColor("#F8FAFC"),
                borderColor = Color.parseColor("#FF334155")
            ) {
                openApp()
            }
        )

        card.addView(footer)
        return card
    }

    private fun removeIslandImmediateLocked() {
        isDismissing = false
        hasPendingUpdate = false
        cancelAutoCollapseLocked()
        cancelActiveAnimatorLocked()
        activePetView = null
        val view = containerView
        val wm = attachedWindowManager
        containerView = null
        islandShell = null
        shellBg = null
        layoutParams = null
        attachedWindowManager = null
        usingAccessibilityLayer = false
        lastAutoExpandedStatus = ""
        if (view != null) {
            view.animate().cancel()
            try {
                wm?.removeViewImmediate(view)
            } catch (_: Throwable) {
            }
        }
    }

    private fun openApp() {
        try {
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                launchIntent.addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
                context.startActivity(launchIntent)
            }
        } catch (_: Throwable) {
        }
    }

    private fun makeIslandButton(
        label: String,
        bgColor: Int,
        textColor: Int,
        borderColor: Int,
        onClick: () -> Unit
    ): TextView {
        return TextView(context).apply {
            text = label
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setTypeface(Typeface.DEFAULT_BOLD)
            setPadding(dp(12), dp(5), dp(12), dp(5))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(999f)
                setColor(bgColor)
                setStroke(dp(1), borderColor)
            }
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
        }
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            context.resources.displayMetrics
        ).toInt()

    private fun dpF(value: Float): Float =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value,
            context.resources.displayMetrics
        )
}
