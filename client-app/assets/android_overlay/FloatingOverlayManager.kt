package __VIBEHELPER_PACKAGE__

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

class FloatingOverlayManager(private val context: Context) {
    private val windowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var containerView: FrameLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var currentTitle: String = "VibeHelper"
    private var currentBody: String = ""
    private var currentStatus: String = "idle"
    private var currentShowActions: Boolean = false
    private var currentIsDark: Boolean = false
    private var isExpanded: Boolean = false
    private var actionCallback: ((String) -> Unit)? = null

    fun canDrawOverlays(): Boolean = Settings.canDrawOverlays(context)

    fun isShowing(): Boolean = containerView != null

    fun requestOverlayPermission(activity: Activity) {
        if (canDrawOverlays()) return
        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}")
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
        } catch (_: Throwable) {
            try {
                val fallback = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                activity.startActivity(fallback)
            } catch (_: Throwable) {
            }
        }
    }

    fun showMiniWindow(
        title: String,
        body: String,
        status: String,
        showActions: Boolean,
        isDark: Boolean,
        expanded: Boolean,
        onAction: (String) -> Unit
    ) {
        mainHandler.post {
            if (!canDrawOverlays()) return@post
            val wm = windowManager ?: return@post

            currentTitle = title
            currentBody = body
            currentStatus = status
            currentShowActions = showActions
            currentIsDark = isDark
            isExpanded = expanded
            actionCallback = onAction

            if (containerView == null) {
                createAndAttachWindowLocked(wm)
            } else {
                renderContentLocked()
                updateWindowSizeAndBoundsLocked(wm)
            }
        }
    }

    fun updateMiniWindow(
        title: String,
        body: String,
        status: String,
        showActions: Boolean,
        isDark: Boolean
    ) {
        mainHandler.post {
            val wm = windowManager ?: return@post
            if (containerView == null || !canDrawOverlays()) return@post

            currentTitle = title
            currentBody = body
            currentStatus = status
            currentShowActions = showActions
            currentIsDark = isDark

            renderContentLocked()
            updateWindowSizeAndBoundsLocked(wm)
        }
    }

    fun hideMiniWindow() {
        mainHandler.post {
            removeOverlayLocked()
        }
    }

    private fun createAndAttachWindowLocked(wm: WindowManager) {
        val windowType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val initialWidth = if (isExpanded) dp(256) else WindowManager.LayoutParams.WRAP_CONTENT
        val params = WindowManager.LayoutParams(
            initialWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            windowType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(16)
            y = dp(120)
        }

        val container = FrameLayout(context)
        var startRawX = 0f
        var startRawY = 0f
        var startParamX = 0
        var startParamY = 0
        var moved = false

        container.setOnTouchListener { _, event ->
            val lp = layoutParams ?: return@setOnTouchListener false
            val view = containerView ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startRawX = event.rawX
                    startRawY = event.rawY
                    startParamX = lp.x
                    startParamY = lp.y
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - startRawX).toInt()
                    val dy = (event.rawY - startRawY).toInt()
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) {
                        moved = true
                    }
                    if (moved) {
                        lp.x = startParamX + dx
                        lp.y = startParamY + dy
                        clampLayoutParamsLocked(lp)
                        try {
                            wm.updateViewLayout(view, lp)
                        } catch (_: Throwable) {
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        if (!isExpanded) {
                            isExpanded = true
                            renderContentLocked()
                            updateWindowSizeAndBoundsLocked(wm)
                        } else {
                            openApp()
                        }
                    }
                    true
                }
                else -> false
            }
        }

        containerView = container
        layoutParams = params
        renderContentLocked()
        clampLayoutParamsLocked(params)

        try {
            wm.addView(container, params)
        } catch (_: Throwable) {
            containerView = null
            layoutParams = null
        }
    }

    private fun renderContentLocked() {
        val container = containerView ?: return
        container.removeAllViews()
        val child = if (isExpanded) buildExpandedCard() else buildCollapsedPill()
        container.addView(
            child,
            FrameLayout.LayoutParams(
                if (isExpanded) dp(256) else FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            )
        )
    }

    private fun updateWindowSizeAndBoundsLocked(wm: WindowManager) {
        val container = containerView ?: return
        val lp = layoutParams ?: return
        lp.width = if (isExpanded) dp(256) else WindowManager.LayoutParams.WRAP_CONTENT
        clampLayoutParamsLocked(lp)
        try {
            wm.updateViewLayout(container, lp)
        } catch (_: Throwable) {
        }
    }

    private fun clampLayoutParamsLocked(lp: WindowManager.LayoutParams) {
        val dm = context.resources.displayMetrics
        val approxWidth = if (isExpanded) dp(256) else dp(110)
        val maxX = (dm.widthPixels - approxWidth - dp(8)).coerceAtLeast(dp(8))
        val maxY = (dm.heightPixels - dp(120)).coerceAtLeast(dp(24))
        lp.x = lp.x.coerceIn(dp(8), maxX)
        lp.y = lp.y.coerceIn(dp(24), maxY)
    }

    private fun statusColor(): Int = when (currentStatus) {
        "waiting_approval", "question" -> Color.parseColor("#F59E0B")
        "working" -> Color.parseColor("#3B82F6")
        else -> Color.parseColor("#10B981")
    }

    private fun statusShortLabel(): String = when (currentStatus) {
        "waiting_approval" -> "待审批"
        "question" -> "提问"
        "working" -> "执行中"
        else -> "空闲"
    }

    private fun buildCollapsedPill(): View {
        val bgColor = if (currentIsDark) Color.parseColor("#EB1A1F2E") else Color.parseColor("#F5FFFFFF")
        val borderColor = if (currentIsDark) Color.parseColor("#334155") else Color.parseColor("#CBD5E1")
        val textColor = if (currentIsDark) Color.parseColor("#F8FAFC") else Color.parseColor("#0F172A")

        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(11), dp(7), dp(12), dp(7))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(999f)
                setColor(bgColor)
                setStroke(dp(1), borderColor)
            }
            elevation = dpF(6f)

            addView(
                View(context).apply {
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(statusColor())
                    }
                },
                LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                    marginEnd = dp(6)
                }
            )

            addView(
                TextView(context).apply {
                    text = statusShortLabel()
                    setTextColor(textColor)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    setTypeface(Typeface.DEFAULT_BOLD)
                    maxLines = 1
                }
            )
        }
    }

    private fun buildExpandedCard(): View {
        val wm = windowManager
        val bgColor = if (currentIsDark) Color.parseColor("#F21A1F2E") else Color.parseColor("#FAFFFFFF")
        val borderColor = if (currentIsDark) Color.parseColor("#334155") else Color.parseColor("#E2E8F0")
        val titleColor = if (currentIsDark) Color.parseColor("#F8FAFC") else Color.parseColor("#0F172A")
        val bodyColor = if (currentIsDark) Color.parseColor("#94A3B8") else Color.parseColor("#475569")
        val mutedColor = if (currentIsDark) Color.parseColor("#94A3B8") else Color.parseColor("#64748B")
        val neutralBtnBg = if (currentIsDark) Color.parseColor("#263044") else Color.parseColor("#F1F5F9")

        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(14f)
                setColor(bgColor)
                setStroke(dp(1), borderColor)
            }
            elevation = dpF(8f)
        }

        // Header: dot + title + minimize + close
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        header.addView(
            View(context).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(statusColor())
                }
            },
            LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                marginEnd = dp(7)
            }
        )

        header.addView(
            TextView(context).apply {
                text = currentTitle.ifBlank { "VibeHelper" }
                setTextColor(titleColor)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTypeface(Typeface.DEFAULT_BOLD)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        )

        val collapseBtn = TextView(context).apply {
            text = "—"
            setTextColor(mutedColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(2), dp(6), dp(2))
            isClickable = true
            isFocusable = true
            setOnClickListener {
                isExpanded = false
                renderContentLocked()
                if (wm != null) {
                    updateWindowSizeAndBoundsLocked(wm)
                }
            }
        }
        header.addView(collapseBtn)

        val closeBtn = TextView(context).apply {
            text = "×"
            setTextColor(mutedColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            gravity = Gravity.CENTER
            setPadding(dp(6), 0, dp(2), 0)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                actionCallback?.invoke("overlay_closed")
                hideMiniWindow()
            }
        }
        header.addView(closeBtn)

        card.addView(header)

        // Body preview
        val preview = currentBody.ifBlank { "等待宿主机状态更新..." }
        card.addView(
            TextView(context).apply {
                text = preview
                setTextColor(bodyColor)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                maxLines = 3
                ellipsize = TextUtils.TruncateAt.END
                setPadding(0, dp(6), 0, 0)
            }
        )

        // Footer actions
        val footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            setPadding(0, dp(9), 0, 0)
        }

        if (currentShowActions) {
            footer.addView(
                makeMiniButton(
                    label = "拒绝",
                    bgColor = Color.parseColor("#1FEF4444"),
                    textColor = Color.parseColor("#DC2626"),
                    borderColor = Color.parseColor("#4DEF4444")
                ) {
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
                makeMiniButton(
                    label = "允许",
                    bgColor = Color.parseColor("#1F10B981"),
                    textColor = Color.parseColor("#059669"),
                    borderColor = Color.parseColor("#4D10B981")
                ) {
                    actionCallback?.invoke("accept")
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    marginEnd = dp(6)
                }
            )
        } else if (currentStatus != "working") {
            footer.addView(
                makeMiniButton(
                    label = "继续",
                    bgColor = neutralBtnBg,
                    textColor = titleColor,
                    borderColor = borderColor
                ) {
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
            makeMiniButton(
                label = if (currentShowActions) "进入" else "进入应用",
                bgColor = neutralBtnBg,
                textColor = titleColor,
                borderColor = borderColor
            ) {
                openApp()
            }
        )

        card.addView(footer)
        return card
    }

    private fun removeOverlayLocked() {
        val view = containerView
        containerView = null
        layoutParams = null
        if (view != null) {
            try {
                windowManager?.removeViewImmediate(view)
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

    private fun makeMiniButton(
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
            setPadding(dp(11), dp(5), dp(11), dp(5))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(8f)
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
