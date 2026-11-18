package os.casper.desktop;

import android.app.Activity;
import android.app.ActivityOptions;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.List;

/**
 * The Casper desktop shell.
 *
 * <p>Structure, top to bottom:
 * <ul>
 *   <li><b>Panel</b> — "Activities", running window title, clock, status tray.
 *       GNOME-shaped, but flat: no blur, no shadows, no animation.</li>
 *   <li><b>Desktop</b> — window area. Apps are launched as freeform windows
 *       where the platform supports it, so several apps can share the screen
 *       like a PC rather than one taking everything.</li>
 *   <li><b>Dock</b> — pinned and recent apps, always visible.</li>
 *   <li><b>App grid</b> — all installed apps, an overlay rather than a separate
 *       activity, so switching is a view toggle rather than an activity
 *       transition (transitions are the expensive part on Gen7).</li>
 * </ul>
 *
 * <p>Built entirely in code, with no layout XML: the view tree is small and
 * fixed, and inflating layouts at startup is measurable on a 1.33 GHz Atom.
 */
public class DesktopActivity extends Activity {

    private static final String TAG = "CasperDesktop";

    private int cBg, cPanel, cBorder, cWinTitle, cAccent, cText, cTextDim;

    private AppRepository repo;

    private FrameLayout root;
    private LinearLayout dock;
    private View appGrid;
    private TextView clock;
    private TextView windowTitle;

    /** Bounds of the last window we placed, so cascading looks deliberate. */
    private Rect lastBounds;
    private int cascadeStep;

    // Density helpers -------------------------------------------------------

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    private int color(int res) {
        return getResources().getColor(res, getTheme());
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        cBg = color(R.color.desktop_bg);
        cPanel = color(R.color.panel_bg);
        cBorder = color(R.color.panel_border);
        cWinTitle = color(R.color.window_title);
        cAccent = color(R.color.accent);
        cText = color(R.color.text);
        cTextDim = color(R.color.text_dim);

        repo = new AppRepository(this);

        buildUi();

        // App enumeration is the one genuinely slow startup step. Doing it off
        // the main thread means the panel and dock paint immediately, which is
        // the difference between "booted" and "feels booted".
        new Thread(new Runnable() {
            @Override
            public void run() {
                repo.refresh();
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        populateDock();
                        if (appGrid != null) {
                            populateGrid(appGrid);
                        }
                    }
                });
            }
        }, "app-query").start();

        applyLowEndTuning();
    }

    // UI construction -------------------------------------------------------

    private void buildUi() {
        root = new FrameLayout(this);
        root.setBackgroundColor(cBg);

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        root.addView(column, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        column.addView(buildPanel());

        // The desktop area itself is empty by design: apps are separate top-level
        // windows. A click on it closes the app grid, matching PC behaviour.
        FrameLayout deskArea = new FrameLayout(this);
        deskArea.setBackgroundColor(cBg);
        deskArea.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showGrid(false);
            }
        });
        column.addView(deskArea, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        dock = new LinearLayout(this);
        dock.setOrientation(LinearLayout.HORIZONTAL);
        dock.setGravity(Gravity.CENTER_VERTICAL);
        dock.setPadding(dp(8), dp(6), dp(8), dp(6));
        GradientDrawable dockBg = new GradientDrawable();
        dockBg.setColor(cPanel);
        dockBg.setCornerRadius(dp(12));
        dockBg.setStroke(dp(1), cBorder);
        dock.setBackground(dockBg);

        LinearLayout dockWrap = new LinearLayout(this);
        dockWrap.setOrientation(LinearLayout.HORIZONTAL);
        dockWrap.setGravity(Gravity.CENTER);
        dockWrap.setPadding(0, dp(4), 0, dp(8));
        dockWrap.addView(dock, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        column.addView(dockWrap);

        // App grid overlay lives above everything else.
        appGrid = buildGridOverlay();
        appGrid.setVisibility(View.GONE);
        root.addView(appGrid, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        setContentView(root);
    }

    private View buildPanel() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.HORIZONTAL);
        panel.setGravity(Gravity.CENTER_VERTICAL);
        panel.setBackgroundColor(cPanel);
        panel.setPadding(dp(12), 0, dp(12), 0);
        panel.setMinimumHeight(dp(34));

        TextView activities = new TextView(this);
        activities.setText("Etkinlikler");
        activities.setTextColor(cText);
        activities.setTextSize(13);
        activities.setPadding(dp(8), dp(6), dp(8), dp(6));
        activities.setBackground(pressable(cAccent));
        activities.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                toggleGrid();
            }
        });
        panel.addView(activities);

        windowTitle = new TextView(this);
        windowTitle.setText("");
        windowTitle.setTextColor(cTextDim);
        windowTitle.setTextSize(13);
        windowTitle.setSingleLine(true);
        windowTitle.setPadding(dp(12), 0, 0, 0);
        panel.addView(windowTitle, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        clock = new TextView(this);
        clock.setTextColor(cText);
        clock.setTextSize(13);
        clock.setTypeface(Typeface.DEFAULT_BOLD);
        panel.addView(clock);

        return panel;
    }

    private View buildGridOverlay() {
        FrameLayout overlay = new FrameLayout(this);
        // Slightly transparent rather than fully opaque: it reads as a layer
        // over the desktop, and it is one flat quad to composite.
        overlay.setBackgroundColor(0xF210131A);

        ScrollViewSafe scroller = new ScrollViewSafe(this);
        LinearLayout holder = new LinearLayout(this);
        holder.setOrientation(LinearLayout.VERTICAL);
        holder.setPadding(dp(24), dp(48), dp(24), dp(24));
        scroller.addView(holder);

        TextView title = new TextView(this);
        title.setText("Uygulamalar");
        title.setTextColor(cText);
        title.setTextSize(18);
        title.setPadding(0, 0, 0, dp(16));
        holder.addView(title);

        LinearLayout grid = new LinearLayout(this);
        grid.setOrientation(LinearLayout.VERTICAL);
        grid.setTag("grid");
        holder.addView(grid);

        overlay.addView(scroller, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Backdrop tap dismisses, but the scroller swallows clicks first, so
        // only the surrounding frame area is a dismiss target.
        return overlay;
    }

    private void populateGrid(View overlay) {
        LinearLayout holder = findGridHolder(overlay);
        if (holder == null) return;
        holder.removeAllViews();

        List<AppInfo> apps = repo.apps();
        int perRow = 6;

        LinearLayout row = null;
        for (int i = 0; i < apps.size(); i++) {
            if (i % perRow == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setPadding(0, 0, 0, dp(4));
                holder.addView(row);
            }
            row.addView(buildGridTile(apps.get(i)));
        }

        if (apps.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("Yüklü uygulama bulunamadı");
            empty.setTextColor(cTextDim);
            holder.addView(empty);
        }
    }

    private LinearLayout findGridHolder(View overlay) {
        // Small tree, so a targeted search is clearer than caching a field
        // through several construction steps.
        if (!(overlay instanceof FrameLayout)) return null;
        FrameLayout f = (FrameLayout) overlay;
        for (int i = 0; i < f.getChildCount(); i++) {
            View c = f.getChildAt(i);
            if (c instanceof ScrollViewSafe) {
                ViewGroup inner = (ViewGroup) ((ScrollViewSafe) c).getChildAt(0);
                if (inner != null && inner.getChildCount() > 0) {
                    View grid = inner.getChildAt(inner.getChildCount() - 1);
                    if (grid instanceof LinearLayout) return (LinearLayout) grid;
                }
            }
        }
        return null;
    }

    private View buildGridTile(final AppInfo app) {
        LinearLayout tile = new LinearLayout(this);
        tile.setOrientation(LinearLayout.VERTICAL);
        tile.setGravity(Gravity.CENTER_HORIZONTAL);
        tile.setPadding(dp(6), dp(10), dp(6), dp(10));
        tile.setBackground(pressable(cPanel));

        ImageView icon = new ImageView(this);
        if (app.icon != null) {
            icon.setImageDrawable(app.icon);
        } else {
            icon.setImageDrawable(fallbackIcon());
        }
        tile.addView(icon, new LinearLayout.LayoutParams(dp(42), dp(42)));

        TextView label = new TextView(this);
        label.setText(app.label);
        label.setTextColor(cText);
        label.setTextSize(11);
        label.setGravity(Gravity.CENTER_HORIZONTAL);
        label.setMaxLines(2);
        label.setPadding(0, dp(6), 0, 0);
        tile.addView(label);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                dp(96), ViewGroup.LayoutParams.WRAP_CONTENT);
        tile.setLayoutParams(lp);

        tile.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showGrid(false);
                launch(app);
            }
        });
        return tile;
    }

    private void populateDock() {
        if (dock == null) return;
        dock.removeAllViews();

        // Pinned entry: the app grid, always present.
        dock.addView(buildDockButton(null, "Uygulamalar", new Runnable() {
            @Override
            public void run() {
                toggleGrid();
            }
        }));

        List<AppInfo> recents = repo.recent();
        for (final AppInfo app : recents) {
            dock.addView(buildDockButton(app.icon, app.label, new Runnable() {
                @Override
                public void run() {
                    launch(app);
                }
            }));
        }
    }

    private View buildDockButton(Drawable icon, String label, final Runnable action) {
        FrameLayout holder = new FrameLayout(this);
        holder.setBackground(pressable(cPanel));
        holder.setPadding(dp(6), dp(4), dp(6), dp(4));

        if (icon != null) {
            ImageView iv = new ImageView(this);
            iv.setImageDrawable(icon);
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(dp(34), dp(34));
            lp.gravity = Gravity.CENTER;
            holder.addView(iv, lp);
        } else {
            TextView tv = new TextView(this);
            tv.setText(label);
            tv.setTextColor(cText);
            tv.setTextSize(11);
            tv.setGravity(Gravity.CENTER);
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                    dp(64), dp(34));
            lp.gravity = Gravity.CENTER;
            holder.addView(tv, lp);
        }

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(dp(3), 0, dp(3), 0);
        holder.setLayoutParams(lp);

        holder.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                action.run();
            }
        });
        return holder;
    }

    private Drawable fallbackIcon() {
        GradientDrawable d = new GradientDrawable();
        d.setColor(cBorder);
        d.setCornerRadius(dp(8));
        return d;
    }

    private Drawable pressable(int baseColor) {
        // A single-state drawable: we deliberately do not use a ripple, because
        // ripples animate and animation is what this device is short of.
        GradientDrawable d = new GradientDrawable();
        d.setColor(baseColor);
        d.setCornerRadius(dp(6));
        return d;
    }

    // Behaviour -------------------------------------------------------------

    private void toggleGrid() {
        showGrid(appGrid.getVisibility() != View.VISIBLE);
    }

    private void showGrid(boolean show) {
        appGrid.setVisibility(show ? View.VISIBLE : View.GONE);
        if (show) {
            populateGrid(appGrid);
        }
    }

    /**
     * Launch an app, as a window when the platform allows it.
     *
     * <p>This is the mechanism that makes the device feel like a PC instead of
     * a tablet: {@code FLAG_ACTIVITY_MULTIPLE_TASK} plus launch bounds asks the
     * system for a freeform window alongside whatever is already open, rather
     * than replacing the current app full-screen.
     *
     * <p>If freeform is unavailable (it is a developer option on many builds),
     * we fall back to a normal full-screen launch rather than failing. Detecting
     * support is done by catching the failure of the windowed launch, since
     * there is no reliable public "supports freeform" query.
     */
    private void launch(AppInfo app) {
        repo.noteLaunched(app);

        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(Intent.CATEGORY_LAUNCHER);
        intent.setComponent(app.component);
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                      | Intent.FLAG_ACTIVITY_MULTIPLE_TASK
                      | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);

        if (windowTitle != null) {
            windowTitle.setText(app.label);
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && launchWindowed(intent)) {
            populateDock();
            return;
        }

        try {
            startActivity(intent);
        } catch (ActivityNotFoundException e) {
            Log.w(TAG, "no activity for " + app.component, e);
        }
        populateDock();
    }

    /** @return true if the app was launched as a freeform window. */
    private boolean launchWindowed(Intent intent) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false;
        try {
            Rect bounds = nextWindowBounds();
            ActivityOptions opts = ActivityOptions.makeBasic();
            opts.setLaunchBounds(bounds);
            startActivity(intent, opts.toBundle());
            return true;
        } catch (RuntimeException e) {
            // Freeform not enabled, or the system rejected the bounds. Fall
            // through to a fullscreen launch — never let a windowing failure
            // stop the app from opening at all.
            Log.i(TAG, "windowed launch unavailable, using fullscreen: " + e);
            return false;
        }
    }

    /**
     * Cascade new windows so they do not stack exactly on top of each other.
     * Size is a fraction of the screen, leaving the panel and dock visible.
     */
    private Rect nextWindowBounds() {
        int w = getResources().getDisplayMetrics().widthPixels;
        int h = getResources().getDisplayMetrics().heightPixels;

        int winW = Math.round(w * 0.62f);
        int winH = Math.round(h * 0.66f);

        int step = dp(28);
        int maxSteps = 5;
        int idx = cascadeStep % maxSteps;
        cascadeStep++;

        int x = dp(24) + idx * step;
        int y = dp(48) + idx * step;

        // Keep the window fully on-screen regardless of cascade position.
        if (x + winW > w) x = Math.max(0, w - winW);
        if (y + winH > h) y = Math.max(0, h - winH);

        lastBounds = new Rect(x, y, x + winW, y + winH);
        return lastBounds;
    }

    /**
     * Cheap, global reductions that cost nothing to apply and pay off on every
     * frame. These mirror docs/optimizations.md §2.2 and §3.
     *
     * <p>Wrapped in a try/catch: WRITE_SETTINGS is not granted by default, and
     * a desktop that crashes because it could not change an animation scale is
     * worse than one that runs with animations on.
     */
    private void applyLowEndTuning() {
        try {
            android.provider.Settings.Global.putFloat(getContentResolver(),
                    android.provider.Settings.Global.WINDOW_ANIMATION_SCALE, 0f);
            android.provider.Settings.Global.putFloat(getContentResolver(),
                    android.provider.Settings.Global.TRANSITION_ANIMATION_SCALE, 0f);
            android.provider.Settings.Global.putFloat(getContentResolver(),
                    android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f);
            Log.i(TAG, "animation scales set to 0");
        } catch (RuntimeException e) {
            Log.i(TAG, "could not set animation scales (no WRITE_SETTINGS): " + e);
        }
    }

    // Lifecycle -------------------------------------------------------------

    @Override
    protected void onResume() {
        super.onResume();
        updateClock();
        if (clock != null) {
            clock.postDelayed(new Runnable() {
                @Override
                public void run() {
                    updateClock();
                    if (clock != null) clock.postDelayed(this, 10_000L);
                }
            }, 10_000L);
        }
    }

    private void updateClock() {
        if (clock == null) return;
        java.util.Calendar c = java.util.Calendar.getInstance();
        // 24-hour, Turkish locale — matches the device configuration.
        clock.setText(String.format(java.util.Locale.GERMANY, "%02d:%02d",
                c.get(java.util.Calendar.HOUR_OF_DAY),
                c.get(java.util.Calendar.MINUTE)));
    }

    @Override
    public void onBackPressed() {
        if (appGrid != null && appGrid.getVisibility() == View.VISIBLE) {
            showGrid(false);
            return;
        }
        // On the desktop itself, Back does nothing — PC behaviour. Swallowing it
        // prevents the confusing "Back exits the home screen" default.
    }

    /**
     * ScrollView that does not intercept taps meant for its children, and does
     * not show scrollbars (an extra drawn element on a GPU we are trying to
     * keep idle).
     */
    private static final class ScrollViewSafe extends android.widget.ScrollView {
        ScrollViewSafe(Context c) {
            super(c);
            setVerticalScrollBarEnabled(false);
        }
    }
}
