package id.finbro.app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Draws the widget's balance line like the Home sparkline (`BalanceSparkline`):
 * accent line, curved without overshoot (monotone cubic), a fading fill
 * underneath and a dot on every third point plus the latest. RemoteViews
 * cannot host a chart view, so the line is rendered into a bitmap sized for
 * each placed widget.
 */
internal object WidgetChart {
    private const val ACCENT = 0xFF5BEB12.toInt()

    fun render(values: LongArray, widthPx: Int, heightPx: Int, density: Float): Bitmap {
        val w = widthPx.coerceIn(1, 1600)
        val h = heightPx.coerceIn(1, 800)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val v = if (values.size == 1) longArrayOf(values[0], values[0]) else values
        if (v.size < 2) return bitmap

        val lo = v.min().toDouble()
        val hi = v.max().toDouble()
        val pad = if (hi == lo) abs(hi) * 0.1 + 1 else (hi - lo) * 0.15
        val minY = lo - pad
        val maxY = hi + pad
        val inset = 4f * density
        val stepX = (w - 2 * inset) / (v.size - 1)
        val xs = FloatArray(v.size) { inset + it * stepX }
        val ys = FloatArray(v.size) { (inset + (maxY - v[it]) / (maxY - minY) * (h - 2 * inset)).toFloat() }

        val line = monotonePath(xs, ys)
        val fill = Path(line).apply {
            lineTo(xs.last(), h.toFloat())
            lineTo(xs.first(), h.toFloat())
            close()
        }

        val canvas = Canvas(bitmap)
        canvas.drawPath(
            fill,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.FILL
                shader = LinearGradient(
                    0f, 0f, 0f, h.toFloat(),
                    withAlpha(0.28f), withAlpha(0f),
                    Shader.TileMode.CLAMP,
                )
            },
        )
        canvas.drawPath(
            line,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                color = ACCENT
                strokeWidth = 2.2f * density
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
            },
        )
        val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ACCENT }
        for (i in v.indices) {
            if (i % 3 == 0 || i == v.size - 1) canvas.drawCircle(xs[i], ys[i], 2.4f * density, dot)
        }
        return bitmap
    }

    private fun withAlpha(alpha: Float): Int =
        Color.argb((alpha * 255).toInt(), Color.red(ACCENT), Color.green(ACCENT), Color.blue(ACCENT))

    /** Fritsch–Carlson monotone cubic through the points: smooth, never overshooting. */
    private fun monotonePath(xs: FloatArray, ys: FloatArray): Path {
        val n = xs.size
        val delta = FloatArray(n - 1) { (ys[it + 1] - ys[it]) / (xs[it + 1] - xs[it]) }
        val m = FloatArray(n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for (k in 1 until n - 1) {
            m[k] = if (delta[k - 1] * delta[k] <= 0f) 0f else (delta[k - 1] + delta[k]) / 2f
        }
        for (k in 0 until n - 1) {
            if (delta[k] == 0f) {
                m[k] = 0f
                m[k + 1] = 0f
                continue
            }
            val a = m[k] / delta[k]
            val b = m[k + 1] / delta[k]
            val s = a * a + b * b
            if (s > 9f) {
                val t = 3f / sqrt(s)
                m[k] = t * a * delta[k]
                m[k + 1] = t * b * delta[k]
            }
        }
        return Path().apply {
            moveTo(xs[0], ys[0])
            for (k in 0 until n - 1) {
                val dx = max(xs[k + 1] - xs[k], 0f) / 3f
                cubicTo(xs[k] + dx, ys[k] + m[k] * dx, xs[k + 1] - dx, ys[k + 1] - m[k + 1] * dx, xs[k + 1], ys[k + 1])
            }
        }
    }
}
