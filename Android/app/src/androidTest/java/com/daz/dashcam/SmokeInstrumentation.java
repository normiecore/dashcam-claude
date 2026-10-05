package com.daz.dashcam;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.View;
import java.io.*;
import java.util.UUID;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Dependency-free installed-app smoke runner. Physical camera acceptance is separate. */
public final class SmokeInstrumentation extends Instrumentation {
    private int currentTest;
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle results = new Bundle();
        Activity activity = null;
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
            runTest("deniedCameraStart", this::testDeniedCameraStart);
            runTest("syntheticCameraRecording", this::testSyntheticCameraRecording);
            results.putInt("passed", 5);
            results.putString("stream", "\nPASS: native durable storage, read-only footage provider, activity launch, permission-denied start, synthetic camera segment/incident/tail recording.\nPhysical phone recording and screen-off reliability require separate device tests.\n");
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
        event.putInt("numtests", 5);
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
        try (ParcelFileDescriptor command = getUiAutomation().executeShellCommand("pm grant com.daz.dashcam android.permission.CAMERA");
             InputStream output = new ParcelFileDescriptor.AutoCloseInputStream(command)) {
            byte[] bytes = new byte[1024];
            while (output.read(bytes) != -1) { }
        }
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
            runOnMainSync(() -> context.startForegroundService(new Intent(context, RecordingService.class).setAction(RecordingService.ACTION_START)));
            await(() -> service.isRecording() && service.getStatus().startsWith("Recording"), 20_000, "Synthetic camera must start: " + service.getStatus());
            await(() -> completed(store) >= 1, 20_000, "First segment must finalize");
            service.saveIncident();
            await(() -> store.listIncidents().size() == 1, 5000, "Incident must be persisted");
            RecordingStore.Incident incident = store.listIncidents().get(0);
            await(() -> service.timelineNow() >= incident.endMs + 2000 && completed(store) >= 3, 40_000, "Thirty-second incident tail must finish");
            await(() -> {
                for (RecordingStore.Segment segment : store.listSegments()) {
                    if (!segment.complete && !segment.uncertain) return service.timelineNow() - segment.startMs >= 3000;
                }
                return false;
            }, 15_000, "Final partial segment must contain several seconds of video");
            runOnMainSync(() -> context.startService(new Intent(context, RecordingService.class).setAction(RecordingService.ACTION_STOP)));
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
