package com.daz.dashcam;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.*;
import android.graphics.drawable.*;
import android.view.Gravity;
import android.view.View;
import android.widget.*;

/** Small native design system: shared spacing, contrast, touch feedback and icons. */
final class Ui {
    static final int BG = Color.rgb(12, 18, 26);
    static final int SURFACE = Color.rgb(22, 31, 42);
    static final int RAISED = Color.rgb(29, 41, 54);
    static final int LINE = Color.rgb(47, 62, 77);
    static final int TEXT = Color.rgb(242, 247, 250);
    static final int MUTED = Color.rgb(164, 181, 196);
    static final int MINT = Color.rgb(111, 232, 191);
    static final int MINT_DARK = Color.rgb(24, 60, 51);
    static final int AMBER = Color.rgb(255, 200, 119);
    static final int RED = Color.rgb(255, 128, 123);
    private Ui() { }
    static int dp(Context context, float value) { return Math.round(value * context.getResources().getDisplayMetrics().density); }
    static GradientDrawable shape(Context context, int fill, int stroke, int radius) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(fill);
        background.setCornerRadius(dp(context, radius));
        if (stroke != 0) background.setStroke(dp(context, 1), stroke);
        return background;
    }
    static Drawable touch(Context context, int fill, int stroke, int radius) {
        return new RippleDrawable(ColorStateList.valueOf(0x247FE8C3), shape(context, fill, stroke, radius), shape(context, Color.WHITE, 0, radius));
    }
    static TextView text(Context context, String value, int sp, int color, boolean bold) {
        TextView view = new TextView(context);
        view.setText(value); view.setTextSize(sp); view.setTextColor(color);
        view.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
        view.setIncludeFontPadding(false);
        view.setLineSpacing(dp(context, 3), 1);
        return view;
    }
    static Button button(Context context, String label, String icon, boolean primary, Runnable click) {
        Button button = new Button(context);
        button.setText(label); button.setAllCaps(false); button.setTextSize(16);
        button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        button.setMinHeight(dp(context, 56)); button.setMinimumHeight(dp(context, 56));
        button.setPadding(dp(context, 20), dp(context, 12), dp(context, 20), dp(context, 12));
        button.setStateListAnimator(null);
        button.setBackground(touch(context, primary ? MINT : SURFACE, primary ? 0 : LINE, 16));
        button.setTextColor(primary ? BG : TEXT);
        if (icon != null) {
            Glyph glyph = new Glyph(icon, primary ? BG : TEXT, dp(context, 22));
            button.setCompoundDrawablesRelativeWithIntrinsicBounds(glyph, null, null, null);
            button.setCompoundDrawablePadding(dp(context, 12));
        }
        button.setOnClickListener(view -> click.run());
        return button;
    }
    static ImageButton iconButton(Context context, String icon, String description, Runnable click) {
        ImageButton button = new ImageButton(context);
        button.setImageDrawable(new Glyph(icon, TEXT, dp(context, 22)));
        button.setContentDescription(description);
        button.setPadding(dp(context, 12), dp(context, 12), dp(context, 12), dp(context, 12));
        button.setBackground(touch(context, SURFACE, LINE, 16));
        button.setOnClickListener(view -> click.run());
        return button;
    }
    static LinearLayout column(Context context) {
        LinearLayout layout = new LinearLayout(context); layout.setOrientation(LinearLayout.VERTICAL); return layout;
    }
    static LinearLayout row(Context context) {
        LinearLayout layout = new LinearLayout(context); layout.setOrientation(LinearLayout.HORIZONTAL); layout.setGravity(Gravity.CENTER_VERTICAL); return layout;
    }
    static void gap(LinearLayout parent, int height) {
        View space = new View(parent.getContext()); parent.addView(space, new LinearLayout.LayoutParams(1, dp(parent.getContext(), height)));
    }
    static final class Glyph extends Drawable {
        private final String name; private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int size; private int color;
        Glyph(String name, int color, int size) { this.name = name; this.color = color; this.size = size; }
        @Override public int getIntrinsicWidth() { return size; }
        @Override public int getIntrinsicHeight() { return size; }
        @Override public void draw(Canvas canvas) {
            canvas.save(); canvas.translate(getBounds().left, getBounds().top);
            canvas.scale(getBounds().width() / 24f, getBounds().height() / 24f);
            paint.setColor(color); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(1.7f);
            paint.setStrokeCap(Paint.Cap.ROUND); paint.setStrokeJoin(Paint.Join.ROUND);
            Path p = new Path();
            switch (name) {
                case "camera":
                    canvas.drawRoundRect(3, 6, 17, 18, 3, 3, paint);
                    p.moveTo(17, 9); p.lineTo(22, 6); p.lineTo(22, 18); p.lineTo(17, 15); canvas.drawPath(p, paint);
                    canvas.drawCircle(10, 12, 3, paint); break;
                case "library":
                    canvas.drawRoundRect(3, 6, 21, 21, 3, 3, paint); canvas.drawLine(7, 3, 17, 3, paint);
                    p.moveTo(10, 10); p.lineTo(15, 13.5f); p.lineTo(10, 17); p.close(); canvas.drawPath(p, paint); break;
                case "shield":
                    p.moveTo(12, 2); p.lineTo(20, 5); p.lineTo(20, 12); p.quadTo(20, 18, 12, 22);
                    p.quadTo(4, 18, 4, 12); p.lineTo(4, 5); p.close(); canvas.drawPath(p, paint);
                    canvas.drawLine(8, 12, 11, 15, paint); canvas.drawLine(11, 15, 16, 9, paint); break;
                case "play":
                    p.moveTo(8, 4); p.lineTo(21, 12); p.lineTo(8, 20); p.close(); canvas.drawPath(p, paint); break;
                case "stop": canvas.drawRoundRect(5, 5, 19, 19, 3, 3, paint); break;
                case "share":
                    canvas.drawCircle(6, 12, 2.5f, paint); canvas.drawCircle(18, 5, 2.5f, paint); canvas.drawCircle(18, 19, 2.5f, paint);
                    canvas.drawLine(8, 11, 16, 6, paint); canvas.drawLine(8, 13, 16, 18, paint); break;
                case "audio":
                    canvas.drawRoundRect(9, 2, 15, 14, 3, 3, paint); p.moveTo(5, 10); p.lineTo(5, 12);
                    p.cubicTo(5, 21, 19, 21, 19, 12); p.lineTo(19, 10); canvas.drawPath(p, paint);
                    canvas.drawLine(12, 19, 12, 23, paint); break;
                case "settings":
                    for (int i = 0; i < 3; i++) {
                        float y = 5 + i * 7; canvas.drawLine(3, y, 21, y, paint);
                        canvas.drawCircle(i == 1 ? 15 : 8, y, 2.5f, paint);
                    } break;
                case "back": canvas.drawLine(15, 4, 7, 12, paint); canvas.drawLine(7, 12, 15, 20, paint); break;
                case "chevron": canvas.drawLine(9, 6, 15, 12, paint); canvas.drawLine(15, 12, 9, 18, paint); break;
                case "close": canvas.drawLine(6, 6, 18, 18, paint); canvas.drawLine(18, 6, 6, 18, paint); break;
                case "alert":
                    p.moveTo(12, 3); p.lineTo(22, 21); p.lineTo(2, 21); p.close(); canvas.drawPath(p, paint);
                    canvas.drawLine(12, 9, 12, 14, paint); canvas.drawPoint(12, 18, paint); break;
                default: canvas.drawCircle(12, 12, 7, paint);
            }
            canvas.restore();
        }
        @Override public void setAlpha(int alpha) { paint.setAlpha(alpha); invalidateSelf(); }
        @Override public void setColorFilter(ColorFilter filter) { paint.setColorFilter(filter); invalidateSelf(); }
        @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
    }
}
