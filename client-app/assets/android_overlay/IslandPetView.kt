package __VIBEHELPER_PACKAGE__

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.view.View

/**
 * Lightweight 12x12 pixel-art pet view rendered via native Canvas (~7 FPS when attached).
 * Supports petType: "shiba" | "cat" | "bot"
 * Supports status:  "working" | "waiting_approval" | "question" | "idle" | "done" | "disconnected"
 */
class IslandPetView(context: Context) : View(context) {
    private val paint = Paint().apply {
        isAntiAlias = false
        style = Paint.Style.FILL
    }
    private val handler = Handler(Looper.getMainLooper())
    private var attached = false
    private var frameIndex = 0
    private var pauseTicks = 0

    var walkPos: Float = 0.15f
        private set
    var walkDir: Int = 1
        private set

    var petType: String = "shiba"
        private set
    var petStatus: String = "idle"
        private set

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (!attached) return
            frameIndex = (frameIndex + 1) % 8
            val step = when (petStatus) {
                "working" -> 0.08f
                "waiting_approval", "question" -> 0.06f
                "disconnected" -> 0f
                else -> 0.03f
            }
            if (step > 0f) {
                if (pauseTicks > 0) {
                    pauseTicks--
                } else {
                    walkPos += step * walkDir
                    if (walkPos >= 1f) {
                        walkPos = 1f
                        walkDir = -1
                        if (petStatus in setOf("idle", "done")) {
                            pauseTicks = 3
                        }
                    } else if (walkPos <= 0f) {
                        walkPos = 0f
                        walkDir = 1
                        if (petStatus in setOf("idle", "done")) {
                            pauseTicks = 3
                        }
                    }
                }
            }
            invalidate()
            val delayMs = when (petStatus) {
                "working" -> 130L
                "waiting_approval", "question" -> 170L
                "disconnected" -> 500L
                else -> 260L
            }
            handler.postDelayed(this, delayMs)
        }
    }

    fun restoreWalk(pos: Float, dir: Int) {
        walkPos = pos.coerceIn(0f, 1f)
        walkDir = if (dir < 0) -1 else 1
    }

    fun updateState(pet: String, status: String) {
        val nextPet = if (pet in setOf("shiba", "cat", "bot")) pet else "shiba"
        val changed = nextPet != petType || status != petStatus
        petType = nextPet
        petStatus = status
        if (changed) {
            invalidate()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        attached = true
        handler.removeCallbacks(tickRunnable)
        handler.post(tickRunnable)
    }

    override fun onDetachedFromWindow() {
        attached = false
        handler.removeCallbacks(tickRunnable)
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val petSize = width.coerceAtMost(height).toFloat()
        if (petSize <= 0f) return
        val cell = petSize / 12f
        val travel = (width - petSize).coerceAtLeast(0f)
        val left = walkPos * travel
        val top = (height - petSize) / 2f

        val sprite = when (petType) {
            "cat" -> catRows()
            "bot" -> botRows()
            else -> shibaRows()
        }

        val yShift = when (petStatus) {
            "working" -> if (frameIndex % 2 == 1) -0.5f * cell else 0f
            "waiting_approval", "question" -> if (frameIndex % 4 == 1) -0.7f * cell else 0f
            else -> 0f
        }

        val dim = petStatus == "disconnected"
        canvas.save()
        if (walkDir < 0) {
            canvas.scale(-1f, 1f, left + petSize / 2f, 0f)
        }
        val maxRows = minOf(12, sprite.size)
        for (r in 0 until maxRows) {
            val row = sprite[r]
            val maxCols = minOf(12, row.length)
            for (c in 0 until maxCols) {
                val ch = row[c]
                if (ch == '.') continue
                val color = resolvePixelColor(ch, dim) ?: continue
                paint.color = color
                val x0 = left + c * cell
                val y0 = (top + r * cell + yShift).coerceIn(0f, height.toFloat())
                val y1 = (y0 + cell + 0.4f).coerceAtMost(height.toFloat())
                canvas.drawRect(x0, y0, x0 + cell + 0.4f, y1, paint)
            }
        }
        canvas.restore()

        drawStatusBadge(canvas, left, top, cell)
    }

    private fun drawStatusBadge(canvas: Canvas, left: Float, top: Float, cell: Float) {
        when (petStatus) {
            "working" -> {
                // Animated cyan spark pixel on top-right
                paint.color = if (frameIndex % 2 == 0) {
                    Color.parseColor("#38BDF8")
                } else {
                    Color.parseColor("#60A5FA")
                }
                val sx = if (frameIndex % 2 == 0) 10 else 9
                val sy = if (frameIndex % 4 < 2) 1 else 2
                canvas.drawRect(
                    left + sx * cell,
                    top + sy * cell,
                    left + (sx + 1.5f) * cell,
                    top + (sy + 1.5f) * cell,
                    paint
                )
            }
            "waiting_approval" -> {
                // Blinking amber exclamation badge
                if (frameIndex % 2 == 0) {
                    paint.color = Color.parseColor("#F59E0B")
                    canvas.drawRect(
                        left + 10 * cell,
                        top + 0.5f * cell,
                        left + 11.4f * cell,
                        top + 3.2f * cell,
                        paint
                    )
                    canvas.drawRect(
                        left + 10 * cell,
                        top + 4 * cell,
                        left + 11.4f * cell,
                        top + 5.2f * cell,
                        paint
                    )
                }
            }
            "question" -> {
                // Bobbing amber question mark
                val dy = if (frameIndex % 2 == 0) 0f else -0.4f * cell
                paint.color = Color.parseColor("#FBBF24")
                canvas.drawRect(
                    left + 9.5f * cell,
                    (top + 0.5f * cell + dy).coerceAtLeast(0f),
                    left + 11.5f * cell,
                    top + 2.2f * cell + dy,
                    paint
                )
                canvas.drawRect(
                    left + 10 * cell,
                    top + 3f * cell + dy,
                    left + 11.2f * cell,
                    top + 4.2f * cell + dy,
                    paint
                )
            }
            "idle", "done" -> {
                // Soft sleeping pixel zzz
                if (frameIndex % 4 < 3) {
                    paint.color = Color.parseColor("#34D399")
                    val rise = (frameIndex % 3) * 0.45f * cell
                    canvas.drawRect(
                        left + 9.8f * cell,
                        (top + 2.0f * cell - rise).coerceAtLeast(0f),
                        left + 11.4f * cell,
                        (top + 3.2f * cell - rise).coerceAtLeast(0.4f * cell),
                        paint
                    )
                }
            }
        }
    }

    private fun resolvePixelColor(ch: Char, dim: Boolean): Int? {
        val raw = when (petType) {
            "cat" -> when (ch) {
                'K' -> Color.parseColor("#3B4254") // Charcoal outline/fur visible on #0D0F14
                'D' -> Color.parseColor("#232836") // Dark shade
                'E' -> Color.parseColor("#FACC15") // Golden eye
                'P' -> Color.parseColor("#F472B6") // Pink nose/ear
                'W' -> Color.parseColor("#E2E8F0") // Paw tip / whisker
                else -> return null
            }
            "bot" -> when (ch) {
                'M' -> Color.parseColor("#94A3B8") // Metal body
                'L' -> Color.parseColor("#CBD5E1") // Light highlight
                'S' -> Color.parseColor("#1E293B") // Visor screen
                'C' -> when (petStatus) {
                    "waiting_approval", "question" -> Color.parseColor("#F59E0B")
                    "disconnected" -> Color.parseColor("#64748B")
                    else -> Color.parseColor("#38BDF8")
                }
                'A' -> if (petStatus == "working" && frameIndex % 2 == 0) {
                    Color.parseColor("#22D3EE")
                } else {
                    Color.parseColor("#F59E0B")
                }
                else -> return null
            }
            else -> when (ch) {
                'O' -> Color.parseColor("#E59A3C") // Shiba tan fur
                'B' -> Color.parseColor("#8A4B18") // Dark ear/back shade
                'C' -> Color.parseColor("#FFF3D6") // Cream muzzle/belly
                'E' -> Color.parseColor("#1E1B18") // Eye/nose
                'P' -> Color.parseColor("#F472B6") // Tongue
                else -> return null
            }
        }
        if (!dim) return raw
        val r = (Color.red(raw) * 0.45f).toInt()
        val g = (Color.green(raw) * 0.45f).toInt()
        val b = (Color.blue(raw) * 0.45f).toInt()
        return Color.rgb(r, g, b)
    }

    private fun shibaRows(): Array<String> {
        val blink = petStatus in setOf("idle", "done") && frameIndex % 8 == 7
        val wagLeft = frameIndex % 4 < 2
        val working = petStatus == "working"
        val eye = if (blink) 'B' else 'E'
        val tailRow6 = if (wagLeft) "..BBBBBBBB.." else "...BBBBBBBO."
        val tailRow7 = if (wagLeft) ".BOOOOOOOB.." else "..OOOOOOOOB."
        val pawRow = if (working && frameIndex % 2 == 1) {
            "..C.CCCC.C.."
        } else {
            "..CC....CC.."
        }
        return arrayOf(
            "............",
            "..BB....BB..",
            "..BOOOOOOB..",
            ".BOOOOOOOOB.",
            ".BOO${eye}OO${eye}OOB.",
            ".BOC${'E'}CC${'C'}OOB.",
            tailRow6,
            tailRow7,
            "..OOCCCCOO..",
            "..OOOOOOOO..",
            pawRow,
            "............"
        )
    }

    private fun catRows(): Array<String> {
        val blink = petStatus in setOf("idle", "done") && frameIndex % 8 == 7
        val tailUp = frameIndex % 2 == 0
        val eye = if (blink) 'K' else 'E'
        val tailA = if (tailUp) "KKKKKKKKKK.K" else "KKKKKKKKKK.."
        val tailB = if (tailUp) ".KDDDDDDK.K." else ".KDDDDDDKKK."
        val pawRow = if (petStatus == "working" && frameIndex % 2 == 1) {
            "..W.KKKK.W.."
        } else {
            "..KK....WW.."
        }
        return arrayOf(
            "............",
            "..KP....PK..",
            "..KKKKKKKK..",
            ".KKKKKKKKKK.",
            ".KK${eye}KKKK${eye}KK.",
            ".KKKKPPKKKK.",
            tailA,
            tailB,
            "..KKKKKKKK..",
            "..KKKKKKKK..",
            pawRow,
            "............"
        )
    }

    private fun botRows(): Array<String> {
        val blink = frameIndex % 6 == 5 && petStatus != "working"
        val visorEye = if (blink) 'S' else 'C'
        val antRow = if (frameIndex % 2 == 0) ".....AA....." else ".....MM....."
        val footRow = if (petStatus == "working" && frameIndex % 2 == 1) {
            "..M......M.."
        } else {
            "...MM..MM..."
        }
        return arrayOf(
            antRow,
            ".....MM.....",
            "..LLLLLLLL..",
            ".LMMMMMMMMM.",
            ".LMSSSSSSSM.",
            ".LMS${visorEye}SSS${visorEye}SM.",
            ".LMSSSSSSSM.",
            "..LLLLLLLL..",
            "..MMMMMMMM..",
            "..MMCCCCMM..",
            footRow,
            "............"
        )
    }
}
