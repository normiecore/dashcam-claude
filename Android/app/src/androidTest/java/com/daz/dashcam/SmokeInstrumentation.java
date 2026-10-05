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
import android.widget.TextView;
import java.io.*;
import java.util.UUID;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Dependency-free installed-app smoke runner. Physical camera acceptance is separate. */
public final class SmokeInstrumentation extends Instrumentation {
    private static final int TEST_COUNT = 8;
    private static final int RECORD_TAB = 1001, LIBRARY_TAB = 1002, PRIMARY_ACTION = 1003,
        STOP_ACTION = 1004, FOOTAGE_LIST = 1005;
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
            results.putInt("passed", TEST_COUNT);
            results.putString("stream", "\nPASS: native durable storage, read-only footage provider, activity launch, recorder/library navigation, permission-denied start, synthetic camera segment/incident/tail recording with activity recreation and UI recording actions, saved footage library, landscape recorder controls.\nUI screenshots: app cache/ui-screenshots. Physical phone recording and screen-off reliability require separate device tests.\n");
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

    private void capture(String name) throws IOException {
        waitForIdleSync();
        Bitmap screenshot = getUiAutomation().takeScreenshot();
        require(screenshot != null, "Capture screenshot " + name);
        File directory = new File(getTargetContext().getCacheDir(), "ui-screenshots");
        require(directory.isDirectory() || directory.mkdirs(), "Create screenshot directory");
        try (FileOutputStream output = new FileOutputStream(new File(directory, name + ".png"))) {
            require(screenshot.compress(Bitmap.CompressFormat.PNG, 100, output), "Write screenshot " + name);
        } finally { screenshot.recycle(); }
        // Gradle's installed-app runner removes the app after testing. Shell-owned
        // screenshot copies survive that cleanup; private recordings never leave the app.
        String export = "sh -c 'mkdir -p /sdcard/Download/dashcam-ui && run-as com.daz.dashcam cat cache/ui-screenshots/"
            + name + ".png > /sdcard/Download/dashcam-ui/" + name + ".png'";
        try (ParcelFileDescriptor command = getUiAutomation().executeShellCommand(export);
             InputStream output = new ParcelFileDescriptor.AutoCloseInputStream(command)) {
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
