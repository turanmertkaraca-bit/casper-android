package os.casper.desktop;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.util.Log;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Owns the installed-app list and the recent/pinned state.
 *
 * <p>The whole point is that queries happen here and nowhere else. On this
 * device a {@code queryIntentActivities} over a full app set takes long enough
 * to drop frames if done on the UI thread during a draw, so the repository
 * loads once, caches, and is refreshed explicitly (after an install, or from
 * the desktop menu).
 */
final class AppRepository {

    private static final String TAG = "CasperDesktop";
    private static final String PREFS = "casper_desktop";
    private static final String KEY_RECENT = "recent";
    private static final int RECENT_MAX = 8;

    private final Context ctx;
    private final SharedPreferences prefs;

    private List<AppInfo> apps = new ArrayList<>();
    private final List<String> recentKeys = new ArrayList<>();

    AppRepository(Context ctx) {
        this.ctx = ctx.getApplicationContext();
        this.prefs = this.ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        loadRecent();
    }

    List<AppInfo> apps() {
        return apps;
    }

    /** Blocking; call off the main thread on first run. */
    void refresh() {
        long t0 = System.nanoTime();
        apps = AppInfo.loadInstalled(ctx);
        long ms = (System.nanoTime() - t0) / 1_000_000L;
        Log.i(TAG, "app query: " + apps.size() + " apps in " + ms + " ms");
    }

    AppInfo byKey(String key) {
        for (AppInfo a : apps) {
            if (a.key().equals(key)) return a;
        }
        return null;
    }

    /** Recently used apps, most recent first, skipping any no longer installed. */
    List<AppInfo> recent() {
        List<AppInfo> out = new ArrayList<>();
        for (String k : recentKeys) {
            AppInfo a = byKey(k);
            if (a != null) out.add(a);
        }
        return out;
    }

    void noteLaunched(AppInfo app) {
        recentKeys.remove(app.key());
        recentKeys.add(0, app.key());
        while (recentKeys.size() > RECENT_MAX) {
            recentKeys.remove(recentKeys.size() - 1);
        }
        saveRecent();
    }

    private void loadRecent() {
        String raw = prefs.getString(KEY_RECENT, "");
        if (raw == null || raw.isEmpty()) return;
        for (String s : raw.split("\n")) {
            if (!s.isEmpty()) recentKeys.add(s);
        }
    }

    private void saveRecent() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < recentKeys.size(); i++) {
            if (i > 0) sb.append('\n');
            sb.append(recentKeys.get(i));
        }
        // Deliberately not apply(): writes are rare (app launch) and we want
        // the value on disk before the process can be killed mid-session.
        prefs.edit().putString(KEY_RECENT, sb.toString()).commit();
    }

    /** Package name of this desktop, so the grid can exclude itself. */
    String ownPackage() {
        return ctx.getPackageName();
    }

    PackageManager pm() {
        return ctx.getPackageManager();
    }
}
