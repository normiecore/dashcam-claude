package com.daz.dashcam;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ActivityInfo;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.View;
import android.view.ViewGroup;
import android.view.TextureView;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.TextView;
import java.io.*;
import java.util.UUID;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Dependency-free installed-app smoke runner. Physical camera acceptance is separate. */
public final class SmokeInstrumentation extends Instrumentation {
    private static final int TEST_COUNT = 10;
    private static final int RECORD_TAB = 1001, LIBRARY_TAB = 1002, PRIMARY_ACTION = 1003,
        STOP_ACTION = 1004, FOOTAGE_LIST = 1005, SETTINGS_ACTION = 1006;
    private int currentTest;
    private Activity activity;
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle results = new Bundle();
        int resultCode = Activity.RESULT_OK;
        try {
            runTest("nativeStorage", this::testNativeStorage);
            runTest("readOnlyProvider", this::testReadOnlyProvider);
            Activity[] launch = new Activity[1];
            runTest("activityLaunch", () -> {
                launch[0] = startActivitySync(new Intent(getTargetContext(), MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                waitForIdleSync();
                runOnMainSync(() -> {
                    View root = launch[0].findViewById(android.R.id.content);
                    require(root != null && root.getWidth() > 0, "Activity content must be laid out");
                });
            });
            activity = launch[0];
            runTest("recorderNavigation", this::testRecorderNavigation);
            runTest("deniedCameraStart", this::testDeniedCameraStart);
            runTest("syntheticCameraRecording", this::testSyntheticCameraRecording);
            runTest("savedLibrary", this::testSavedLibrary);
            runTest("responsiveRecorder", this::testResponsiveRecorder);
            runTest("incidentSheet", this::testIncidentSheet);
            runTest("settingsSheet", this::testSettingsSheet);
            results.putInt("passed", TEST_COUNT);
            results.putString("stream", "\nPASS: native durable storage, read-only footage provider, activity launch, recorder/library navigation, permission-denied start, synthetic camera segment/incident/tail recording with activity recreation and UI recording actions, saved footage library, landscape recorder controls, accessible incident sheet, persisted audio setting.\nUI screenshots: app cache/ui-screenshots and emulator Download/dashcam-ui. Physical phone recording and screen-off reliability require separate device tests.\n");
        } catch (Throwable failure) {
            resultCode = Activity.RESULT_CANCELED;
            results.putInt("failed", 1);
            StringWriter trace = new StringWriter();
            failure.printStackTrace(new PrintWriter(trace));
            results.putString("stream", "\nFAIL: " + trace + "\n");
        } finally {
            if (activity != null) {
                final Activity launched = activity;
                runOnMainSync(launched::finish);
            }
        }
        finish(resultCode, results);
    }

    private interface TestBody { void run() throws Exception; }
    private void runTest(String name, TestBody body) throws Exception {
        Bundle event = new Bundle();
        event.putString("id", "InstrumentationTestRunner");
        event.putString("class", getClass().getName());
        event.putString("test", name);
        event.putInt("numtests", TEST_COUNT);
        event.putInt("current", ++currentTest);
        event.putString("stream", "\n" + getClass().getName() + ":");
        sendStatus(1, event);
        try {
            body.run();
            event.putString("stream", ".");
            sendStatus(0, event);
        } catch (Throwable failure) {
            StringWriter trace = new StringWriter();
            failure.printStackTrace(new PrintWriter(trace));
            event.putString("stack", trace.toString());
            event.putString("stream", "\nFailure in " + name + ":\n" + trace);
            sendStatus(-2, event);
            if (failure instanceof Exception) throw (Exception) failure;
            if (failure instanceof Error) throw (Error) failure;
            throw new RuntimeException(failure);
        }
    }

    private void testRecorderNavigation() throws Exception {
        awaitUi(() -> actionEnabled(PRIMARY_ACTION), 5000, "Start action must become available after recorder binds");
        runOnMainSync(() -> {
            View start = requiredView(PRIMARY_ACTION);
            require(start.isClickable() && start.isFocusable(), "Primary recording action must support touch and keyboard accessibility");
            require(start.getHeight() >= Math.round(48 * activity.getResources().getDisplayMetrics().density), "Primary action must have a 48 dp touch target");
            require(accessibleText(start).toLowerCase(java.util.Locale.ROOT).contains("record"), "Idle primary action must explain recording");
            View stop = activity.findViewById(STOP_ACTION);
            require(stop == null || !stop.isShown() || !stop.isEnabled(), "Stop must not be available while idle");
        });
        capture("01-ready");
        click(LIBRARY_TAB);
        runOnMainSync(() -> {
            View library = requiredView(FOOTAGE_LIST);
            require(!accessibleText(library).trim().isEmpty(), "Empty library must explain how to save footage");
        });
        capture("02-library-empty");
        click(RECORD_TAB);
        runOnMainSync(() -> require(actionEnabled(PRIMARY_ACTION), "Returning to Recorder must preserve the ready action"));
    }

    private void testSavedLibrary() throws Exception {
        awaitUi(() -> actionEnabled(PRIMARY_ACTION)
            && accessibleText(requiredView(PRIMARY_ACTION)).toLowerCase(java.util.Locale.ROOT).contains("record"),
            5000, "Stopped recorder must return to its start action");
        click(LIBRARY_TAB);
        runOnMainSync(() -> {
            View library = requiredView(FOOTAGE_LIST);
            require(accessibleText(library).toLowerCase(java.util.Locale.ROOT).contains("incident"), "Library must display the saved incident");
            require(library instanceof ViewGroup && ((ViewGroup) library).getChildCount() > 0, "Saved library must contain a footage row");
            View row = ((ViewGroup) library).getChildAt(0);
            require(row.isClickable() && row.isFocusable() && row.getContentDescription() != null,
                "Saved incident must be accessible and directly openable");
        });
        capture("04-library-saved");
        click(RECORD_TAB);
    }

    private void testResponsiveRecorder() throws Exception {
        orient(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        awaitUi(() -> actionEnabled(PRIMARY_ACTION), 5000, "Landscape recorder must reconnect its primary action");
        runOnMainSync(() -> {
            for (int id : new int[] {PRIMARY_ACTION, RECORD_TAB, LIBRARY_TAB}) {
                View control = requiredView(id);
                Rect visible = new Rect();
                require(control.getGlobalVisibleRect(visible), "Landscape control must be reachable: " + id);
                require(visible.height() >= control.getHeight() - 1 && visible.width() >= control.getWidth() - 1,
                    "Landscape control must fit fully on screen: " + id);
            }
        });
        capture("05-landscape");
        orient(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
    }

    private void testIncidentSheet() throws Exception {
        awaitUi(() -> actionEnabled(PRIMARY_ACTION), 5000, "Portrait recorder must reconnect before opening footage");
        click(LIBRARY_TAB);
        runOnMainSync(() -> {
            ViewGroup list = (ViewGroup) requiredView(FOOTAGE_LIST);
            require(list.getChildCount() > 0 && list.getChildAt(0).performClick(), "Open the saved incident from its library row");
        });
        waitForIdleSync();
        await(() -> windowHasText(R.string.clips_footer) && windowHasText(R.string.protected_label)
            && windowHasText(R.string.clip_ready), 5000,
            "Incident sheet must expose original clips, protected tail status and playable footage");
        capture("06-incident");
        closeAccessibleSheet();
        runOnMainSync(() -> require(requiredView(FOOTAGE_LIST) != null, "Closing the incident must return to the footage library"));
    }

    private void testSettingsSheet() throws Exception {
        click(SETTINGS_ACTION);
        await(() -> audioSwitchChecked(false), 5000, "Audio setting must begin off on a fresh install");
        clickAccessible(R.string.record_audio);
        await(() -> audioSwitchChecked(true), 5000, "Audio switch must respond to its accessible action");
        require(getTargetContext().getSharedPreferences("interface", Context.MODE_PRIVATE).getBoolean("audio", false),
            "Audio preference must be saved when enabled");
        closeAccessibleSheet();
        click(SETTINGS_ACTION);
        await(() -> audioSwitchChecked(true), 5000, "Reopening Settings must restore the enabled audio preference");
        clickAccessible(R.string.record_audio);
        await(() -> audioSwitchChecked(false), 5000, "Audio switch must return to off");
        require(!getTargetContext().getSharedPreferences("interface", Context.MODE_PRIVATE).getBoolean("audio", true),
            "Audio preference must be saved when disabled");
        capture("07-settings");
        closeAccessibleSheet();
        click(RECORD_TAB);
    }

    private boolean windowHasText(int text) {
        AccessibilityNodeInfo window = getUiAutomation().getRootInActiveWindow();
        if (window == null) return false;
        try { return nodeText(window).contains(getTargetContext().getString(text)); }
        finally { window.recycle(); }
    }

    private boolean audioSwitchChecked(boolean expected) {
        AccessibilityNodeInfo window = getUiAutomation().getRootInActiveWindow();
        if (window == null) return false;
        AccessibilityNodeInfo toggle = null;
        try {
            toggle = findAccessible(window, getTargetContext().getString(R.string.record_audio));
            return toggle != null && toggle.isCheckable() && toggle.isEnabled() && toggle.isChecked() == expected;
        } finally { if (toggle != null) toggle.recycle(); window.recycle(); }
    }

    private void clickAccessible(int text) throws Exception {
        String label = getTargetContext().getString(text);
        await(() -> {
            AccessibilityNodeInfo window = getUiAutomation().getRootInActiveWindow();
            if (window == null) return false;
            AccessibilityNodeInfo action = null;
            try {
                action = findAccessible(window, label);
                return action != null && action.isEnabled() && action.isClickable()
                    && action.performAction(AccessibilityNodeInfo.ACTION_CLICK);
            } finally { if (action != null) action.recycle(); window.recycle(); }
        }, 5000, "Accessible action must be available: " + label);
        waitForIdleSync();
    }

    private void closeAccessibleSheet() throws Exception {
        AccessibilityNodeInfo window = getUiAutomation().getRootInActiveWindow();
        require(window != null, "Sheet must be the active accessible window");
        final int sheetWindow = window.getWindowId(); window.recycle();
        clickAccessible(R.string.close);
        await(() -> {
            AccessibilityNodeInfo current = getUiAutomation().getRootInActiveWindow();
            if (current == null) return false;
            try { return current.getWindowId() != sheetWindow; }
            finally { current.recycle(); }
        }, 5000, "Accessible Close must dismiss the sheet");
    }

    /** The returned snapshot is separately owned; callers recycle it after use. */
    private static AccessibilityNodeInfo findAccessible(AccessibilityNodeInfo node, String label) {
        if (label.contentEquals(node.getText() == null ? "" : node.getText())
            || label.contentEquals(node.getContentDescription() == null ? "" : node.getContentDescription()))
            return AccessibilityNodeInfo.obtain(node);
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try {
                AccessibilityNodeInfo found = findAccessible(child, label);
                if (found != null) return found;
            } finally { child.recycle(); }
        }
        return null;
    }

    private static String nodeText(AccessibilityNodeInfo node) {
        StringBuilder text = new StringBuilder();
        if (node.getText() != null) text.append(node.getText()).append(' ');
        if (node.getContentDescription() != null) text.append(node.getContentDescription()).append(' ');
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { text.append(nodeText(child)); }
            finally { child.recycle(); }
        }
        return text.toString();
    }

    private void orient(int requested) {
        ActivityMonitor monitor = addMonitor(MainActivity.class.getName(), null, false);
        try {
            runOnMainSync(() -> activity.setRequestedOrientation(requested));
            Activity replacement = waitForMonitorWithTimeout(monitor, 10_000);
            require(replacement != null, "Orientation change must recreate the recorder");
            activity = replacement;
            waitForIdleSync();
        } finally { removeMonitor(monitor); }
    }

    /** Recreating a recording screen must reconnect without stopping or losing its preview. */
    private void recreateWhileRecording(RecordingService expectedService) throws Exception {
        Activity previous = activity;
        ActivityMonitor monitor = addMonitor(MainActivity.class.getName(), null, false);
        try {
            runOnMainSync(previous::recreate);
            Activity replacement = waitForMonitorWithTimeout(monitor, 10_000);
            require(replacement != null && replacement != previous, "Configuration recreation must create a new recording screen");
            activity = replacement;
            waitForIdleSync();
            awaitUi(() -> {
                TextureView preview = findPreview(activity.findViewById(android.R.id.content));
                return preview != null && preview.isAvailable() && preview.getWidth() > 0
                    && preview.getSurfaceTexture().getTimestamp() > 0 && actionEnabled(PRIMARY_ACTION);
            }, 10_000, "Recreated recorder must receive camera preview frames and restore its primary action");
            require(expectedService.isRecording(), "Activity recreation must keep the foreground recording active");
            CountDownLatch connected = new CountDownLatch(1);
            RecordingService[] rebound = new RecordingService[1];
            ServiceConnection connection = new ServiceConnection() {
                @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                    rebound[0] = ((RecordingService.LocalBinder) binder).service();
                    connected.countDown();
                }
                @Override public void onServiceDisconnected(ComponentName name) { }
            };
            Context context = getTargetContext();
            require(context.bindService(new Intent(context, RecordingService.class), connection, Context.BIND_AUTO_CREATE), "Bind after activity recreation");
            try {
                require(connected.await(5000, TimeUnit.MILLISECONDS), "Recorder must remain bindable after recreation");
                require(rebound[0] == expectedService, "Recreation must retain the same recording service");
            } finally { context.unbindService(connection); }
            runOnMainSync(() -> {
                require(accessibleText(requiredView(PRIMARY_ACTION)).toLowerCase(java.util.Locale.ROOT).contains("incident"), "Active primary action must save an incident");
                require(actionEnabled(STOP_ACTION), "Active recorder must offer Stop");
            });
            capture("03-recording");
        } finally { removeMonitor(monitor); }
    }

    private View requiredView(int id) {
        View view = activity.findViewById(id);
        require(view != null && view.isShown(), "Expected visible UI control " + id);
        return view;
    }

    private boolean actionEnabled(int id) {
        View view = activity.findViewById(id);
        return view != null && view.isShown() && view.isEnabled();
    }

    private void click(int id) {
        runOnMainSync(() -> require(requiredView(id).performClick(), "UI action must handle click " + id));
        waitForIdleSync();
    }

    private void awaitUi(Check check, long timeout, String message) throws Exception {
        await(() -> {
            boolean[] result = new boolean[1];
            Exception[] failure = new Exception[1];
            runOnMainSync(() -> {
                try { result[0] = check.get(); }
                catch (Exception error) { failure[0] = error; }
            });
            if (failure[0] != null) throw failure[0];
            return result[0];
        }, timeout, message);
    }

    private static TextureView findPreview(View view) {
        if (view instanceof TextureView) return (TextureView) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                TextureView preview = findPreview(group.getChildAt(i));
                if (preview != null) return preview;
            }
        }
        return null;
    }

    private static String accessibleText(View view) {
        StringBuilder result = new StringBuilder();
        if (view.getContentDescription() != null) result.append(view.getContentDescription()).append(' ');
        if (view instanceof TextView) result.append(((TextView) view).getText()).append(' ');
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) result.append(accessibleText(group.getChildAt(i)));
        }
        return result.toString();
    }

    private void capture(String name) throws Exception {
        waitForIdleSync();
        await(() -> {
            AccessibilityNodeInfo active = getUiAutomation().getRootInActiveWindow();
            if (active == null) return false;
            try {
                if (getTargetContext().getPackageName().contentEquals(active.getPackageName())) return true;
                // AOSP Quickstep can ANR during headless emulator boot. Close only
                // that known launcher error; an app error must still fail the suite.
                String systemText = nodeText(active);
                if (systemText.contains("Quickstep") && systemText.contains("responding")) {
                    AccessibilityNodeInfo close = findAccessible(active, "Close app");
                    if (close != null) {
                        try { close.performAction(AccessibilityNodeInfo.ACTION_CLICK); }
                        finally { close.recycle(); }
                    }
                }
                return false;
            } finally { active.recycle(); }
        }, 10_000, "Dashcam must be the active window for screenshot " + name);
        // Wait for accessibility/layout events to settle so the capture includes
        // the newly selected tab or sheet rather than the preceding rendered frame.
        getUiAutomation().waitForIdle(150, 3000);
        android.view.accessibility.AccessibilityNodeInfo window = getUiAutomation().getRootInActiveWindow();
        try {
            require(window != null && getTargetContext().getPackageName().contentEquals(window.getPackageName()),
                "Screenshot must show Dashcam, without a system error or permission overlay: " + name
                    + "; active package=" + (window == null ? "none" : window.getPackageName()));
        } finally { if (window != null) window.recycle(); }
        Bitmap screenshot = getUiAutomation().takeScreenshot();
        require(screenshot != null, "Capture screenshot " + name);
        File directory = new File(getTargetContext().getCacheDir(), "ui-screenshots");
        require(directory.isDirectory() || directory.mkdirs(), "Create screenshot directory");
        try (FileOutputStream output = new FileOutputStream(new File(directory, name + ".png"))) {
            require(screenshot.compress(Bitmap.CompressFormat.PNG, 100, output), "Write screenshot " + name);
        } finally { screenshot.recycle(); }
        // Gradle's installed-app runner removes the app after testing. Shell-owned
        // screenshot copies survive that cleanup; private recordings never leave the app.
        try (ParcelFileDescriptor command = getUiAutomation().executeShellCommand("mkdir -p /sdcard/Download/dashcam-ui");
             InputStream output = new ParcelFileDescriptor.AutoCloseInputStream(command)) {
            byte[] bytes = new byte[1024];
            while (output.read(bytes) != -1) { }
        }
        if (Build.VERSION.SDK_INT < 31) throw new IOException("UI screenshot export requires an API 31+ test emulator");
        ParcelFileDescriptor[] pipes = getUiAutomation().executeShellCommandRw("dd of=/sdcard/Download/dashcam-ui/" + name + ".png");
        try (OutputStream input = new ParcelFileDescriptor.AutoCloseOutputStream(pipes[1]);
             InputStream original = new FileInputStream(new File(directory, name + ".png"))) {
            byte[] bytes = new byte[8192]; int count;
            while ((count = original.read(bytes)) != -1) input.write(bytes, 0, count);
        }
        try (InputStream output = new ParcelFileDescriptor.AutoCloseInputStream(pipes[0])) {
            byte[] bytes = new byte[1024];
            while (output.read(bytes) != -1) { }
        }
    }

    private void testNativeStorage() throws Exception {
        File directory = new File(getTargetContext().getCacheDir(), "storage-test-" + UUID.randomUUID());
        try {
            RecordingStore store = AndroidStorage.open(directory);
            long now = System.currentTimeMillis();
            RecordingStore.Segment segment = store.beginSegment(now);
            try (FileOutputStream output = new FileOutputStream(segment.file)) {
                output.write(new byte[] {1, 2, 3});
                output.getFD().sync();
            }
            store.completeSegment(segment.id, now + 10_000, true);
            store.saveIncident(now + 5_000);
            RecordingStore reopened = AndroidStorage.open(directory);
            require(reopened.listSegments().size() == 1, "Native fsync manifest must survive reopen");
            require(reopened.isProtected(segment.id), "Incident protection must survive reopen");
            reopened.prune(now + 1_000_000);
            require(segment.file.isFile(), "Pinned media must survive cleanup");
        } finally { remove(directory); }
    }

    private void testReadOnlyProvider() throws Exception {
        Context context = getTargetContext();
        File root = new File(context.getFilesDir(), "recordings");
        require(root.isDirectory() || root.mkdirs(), "Create footage directory");
        File fixture = new File(root, "provider-smoke-" + UUID.randomUUID() + ".mp4");
        try {
            try (FileOutputStream output = new FileOutputStream(fixture)) { output.write(new byte[] {1, 2, 3}); }
            Uri uri = RecordingProvider.uriFor(fixture);
            try (ParcelFileDescriptor descriptor = context.getContentResolver().openFileDescriptor(uri, "r")) {
                require(descriptor != null && descriptor.getStatSize() == 3, "Provider must read granted footage");
            }
            try (Cursor cursor = context.getContentResolver().query(uri, null, null, null, null)) {
                require(cursor != null && cursor.moveToFirst(), "Provider supplies file metadata");
                require(fixture.getName().equals(cursor.getString(cursor.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))), "Provider preserves export name");
            }
            boolean rejected = false;
            try (ParcelFileDescriptor ignored = context.getContentResolver().openFileDescriptor(uri, "w")) { }
            catch (FileNotFoundException expected) { rejected = true; }
            require(rejected, "Provider must reject writes");
            Uri unsafe = new Uri.Builder().scheme("content").authority(RecordingProvider.AUTHORITY).appendPath("file").appendPath("../manifest.properties").build();
            rejected = false;
            try (ParcelFileDescriptor ignored = context.getContentResolver().openFileDescriptor(unsafe, "r")) { }
            catch (FileNotFoundException expected) { rejected = true; }
            require(rejected, "Provider must reject traversal and manifest access");
        } finally { require(!fixture.exists() || fixture.delete(), "Remove smoke fixture"); }
    }

    private void testDeniedCameraStart() throws Exception {
        Context context = getTargetContext();
        require(context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED,
            "Run this smoke suite after a fresh install without granting runtime camera permission");
        CountDownLatch connected = new CountDownLatch(1);
        RecordingService[] service = new RecordingService[1];
        ServiceConnection connection = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                service[0] = ((RecordingService.LocalBinder) binder).service();
                connected.countDown();
            }
            @Override public void onServiceDisconnected(ComponentName name) { }
        };
        require(context.bindService(new Intent(context, RecordingService.class), connection, Context.BIND_AUTO_CREATE), "Bind recorder for denial test");
        try {
            require(connected.await(10, TimeUnit.SECONDS), "Recorder must bind");
            runOnMainSync(() -> context.startService(new Intent(context, RecordingService.class).setAction(RecordingService.ACTION_START)));
            long deadline = SystemClock.elapsedRealtime() + 5000;
            while (!service[0].getStatus().contains("permission") && SystemClock.elapsedRealtime() < deadline) Thread.sleep(25);
            require(!service[0].isRecording(), "Denied permission must never start recording");
            require(service[0].getStatus().contains("permission"), "Denied permission must report a clear status");
        } finally { context.unbindService(connection); }
    }

    private void testSyntheticCameraRecording() throws Exception {
        Context context = getTargetContext();
        // Grant, rather than revoke, while instrumenting: revocation terminates the target process.
        grant(Manifest.permission.CAMERA);
        if (Build.VERSION.SDK_INT >= 33) grant(Manifest.permission.POST_NOTIFICATIONS);
        require(context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED, "Grant synthetic camera permission");
        CountDownLatch connected = new CountDownLatch(1);
        RecordingService[] recorder = new RecordingService[1];
        ServiceConnection connection = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                recorder[0] = ((RecordingService.LocalBinder) binder).service();
                connected.countDown();
            }
            @Override public void onServiceDisconnected(ComponentName name) { }
        };
        require(context.bindService(new Intent(context, RecordingService.class), connection, Context.BIND_AUTO_CREATE), "Bind synthetic recorder");
        try {
            require(connected.await(10, TimeUnit.SECONDS), "Synthetic recorder binds");
            RecordingService service = recorder[0];
            RecordingStore store = service.getStore();
            require(store != null && store.listSegments().isEmpty() && store.listIncidents().isEmpty(), "Use a fresh emulator install with no user footage");
            click(PRIMARY_ACTION);
            await(() -> service.isRecording() && service.getStatus().startsWith("Recording"), 20_000, "Synthetic camera must start: " + service.getStatus());
            await(() -> completed(store) >= 1, 20_000, "First segment must finalize");
            awaitUi(() -> actionEnabled(PRIMARY_ACTION)
                && accessibleText(requiredView(PRIMARY_ACTION)).toLowerCase(java.util.Locale.ROOT).contains("incident"),
                5000, "Recording primary action must switch to Save incident");
            click(PRIMARY_ACTION);
            await(() -> store.listIncidents().size() == 1, 5000, "Incident must be persisted");
            RecordingStore.Incident incident = store.listIncidents().get(0);
            click(LIBRARY_TAB);
            runOnMainSync(() -> require(requiredView(FOOTAGE_LIST) != null, "Saved library must be usable during recording"));
            require(service.isRecording(), "Opening the library must preserve active recording");
            click(RECORD_TAB);
            recreateWhileRecording(service);
            await(() -> service.timelineNow() >= incident.endMs + 2000 && completed(store) >= 3, 40_000, "Thirty-second incident tail must finish");
            await(() -> {
                for (RecordingStore.Segment segment : store.listSegments()) {
                    if (!segment.complete && !segment.uncertain) return service.timelineNow() - segment.startMs >= 3000;
                }
                return false;
            }, 15_000, "Final partial segment must contain several seconds of video");
            click(STOP_ACTION);
            await(() -> !service.isRecording() && service.getStatus().startsWith("Stopped"), 10_000, "Recorder must finalize on stop: " + service.getStatus());
            List<RecordingStore.Segment> segments = store.listSegments();
            require(segments.size() >= 4, "Multiple ten-second segments must exist");
            long finalEnd = 0;
            for (RecordingStore.Segment segment : segments) {
                require(segment.complete && !segment.uncertain, "Normal stop must leave only finalized media");
                validateVideo(segment.file);
                finalEnd = Math.max(finalEnd, segment.endMs);
            }
            require(finalEnd >= incident.endMs, "Recorded coverage reaches incident tail");
            RecordingStore reopened = AndroidStorage.open(new File(context.getFilesDir(), "recordings"));
            require(reopened.segmentsForIncident(incident.id).size() >= 4, "Pin membership survives native manifest reopen");
            reopened.prune(service.timelineNow() + 600_000);
            for (RecordingStore.Segment protectedSegment : reopened.segmentsForIncident(incident.id)) require(protectedSegment.file.isFile(), "Incident footage survives cleanup");
        } finally {
            runOnMainSync(() -> context.startService(new Intent(context, RecordingService.class).setAction(RecordingService.ACTION_STOP)));
            context.unbindService(connection);
        }
    }

    private void grant(String permission) throws IOException {
        try (ParcelFileDescriptor command = getUiAutomation().executeShellCommand("pm grant com.daz.dashcam " + permission);
             InputStream output = new ParcelFileDescriptor.AutoCloseInputStream(command)) {
            byte[] bytes = new byte[1024];
            while (output.read(bytes) != -1) { }
        }
    }

    private static int completed(RecordingStore store) {
        int count = 0;
        for (RecordingStore.Segment segment : store.listSegments()) if (segment.complete) count++;
        return count;
    }

    private static void validateVideo(File file) throws Exception {
        require(file.length() > 1024, "Video output must contain media");
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(file.getAbsolutePath());
            int video = -1;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat format = extractor.getTrackFormat(i);
                String mime = format.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("video/")) { video = i; break; }
            }
            require(video >= 0, "Finalized MP4 must have a readable video track");
            extractor.selectTrack(video);
            int samples = 0;
            long first = -1, last = -1;
            while (extractor.getSampleTime() >= 0) {
                if (first < 0) first = extractor.getSampleTime();
                last = extractor.getSampleTime();
                samples++;
                if (!extractor.advance()) break;
            }
            require(samples >= 15 && last - first >= 500_000, "Finalized clip must contain sustained video frames");
        } finally { extractor.release(); }
    }

    private interface Check { boolean get() throws Exception; }
    private static void await(Check check, long timeout, String message) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + timeout;
        while (!check.get() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(25);
        require(check.get(), message);
    }

    private static void require(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void remove(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) remove(child);
        if (file.exists() && !file.delete()) throw new AssertionError("Cannot remove test fixture " + file);
    }
}
