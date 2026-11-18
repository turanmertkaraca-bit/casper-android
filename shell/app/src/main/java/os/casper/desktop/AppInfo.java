package os.casper.desktop;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;

import java.text.Collator;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * An installed application the desktop can launch.
 *
 * <p>Deliberately a plain immutable holder rather than something backed by a
 * live PackageManager query: the app list changes rarely, and re-querying on
 * every frame would be a disaster on this hardware. {@link AppRepository}
 * refreshes these explicitly.
 */
final class AppInfo {

    final String label;
    final String packageName;
    final ComponentName component;
    final Drawable icon;
    /** True for the few entries that are really desktop actions, not apps. */
    final boolean isDesktopAction;

    AppInfo(String label, String packageName, ComponentName component,
            Drawable icon, boolean isDesktopAction) {
        this.label = label;
        this.packageName = packageName;
        this.component = component;
        this.icon = icon;
        this.isDesktopAction = isDesktopAction;
    }

    /** Cheap, stable key for dedupe and for "recently used" bookkeeping. */
    String key() {
        return component.flattenToString();
    }

    /**
     * Query every launchable activity.
     *
     * <p>Sorted with a {@link Collator} so Turkish dotted/dotless i sorts
     * correctly — this tablet runs tr_TR, where a naive String comparison puts
     * "İ" and "I" in the wrong place and looks broken to the user. That
     * detail is not cosmetic for this project; the device is set to Turkish
     * locale throughout.
     */
    static List<AppInfo> loadInstalled(Context ctx) {
        PackageManager pm = ctx.getPackageManager();
        Intent main = new Intent(Intent.ACTION_MAIN, null);
        main.addCategory(Intent.CATEGORY_LAUNCHER);

        List<ResolveInfo> resolved;
        try {
            resolved = pm.queryIntentActivities(main, 0);
        } catch (RuntimeException e) {
            // A malformed package on the device must not take the desktop down.
            return new ArrayList<>();
        }

        List<AppInfo> out = new ArrayList<>(resolved.size());
        for (ResolveInfo ri : resolved) {
            if (ri.activityInfo == null) continue;
            // The desktop is a HOME activity and is not itself launchable from
            // its own app grid.
            if (ctx.getPackageName().equals(ri.activityInfo.packageName)) continue;

            CharSequence labelCs = ri.loadLabel(pm);
            String label = labelCs == null ? ri.activityInfo.packageName : labelCs.toString();
            Drawable icon;
            try {
                icon = ri.loadIcon(pm);
            } catch (RuntimeException e) {
                icon = null;
            }
            ComponentName cn = new ComponentName(ri.activityInfo.packageName,
                                                 ri.activityInfo.name);
            out.add(new AppInfo(label, ri.activityInfo.packageName, cn, icon, false));
        }

        final Collator collator = Collator.getInstance(new Locale("tr", "TR"));
        collator.setStrength(Collator.PRIMARY);
        Collections.sort(out, new Comparator<AppInfo>() {
            @Override
            public int compare(AppInfo a, AppInfo b) {
                return collator.compare(a.label, b.label);
            }
        });
        return out;
    }
}
