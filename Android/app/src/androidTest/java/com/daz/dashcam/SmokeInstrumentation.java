package com.daz.dashcam;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.view.View;
import java.io.*;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Dependency-free installed-app smoke runner. Physical camera acceptance is separate. */
public final class SmokeInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle results = new Bundle();
        Activity activity = null;
        try {
            testNativeStorage();
            testReadOnlyProvider();
            activity = startActivitySync(new Intent(getTargetContext(), MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            final Activity launched = activity;
            runOnMainSync(() -> {
                View root = launched.findViewById(android.R.id.content);
                require(root != null && root.getWidth() > 0, "Activity content must be laid out");
            });
            testDeniedCameraStart();
            results.putInt("passed", 4);
            results.putString("stream", "\nPASS: native durable storage, read-only footage provider, activity launch, permission-denied start.\nCamera recording and screen-off reliability require separate device tests.\n");
            finish(Activity.RESULT_OK, results);
        } catch (Throwable failure) {
            results.putInt("failed", 1);
            results.putString("stream", "\nFAIL: " + failure + "\n");
            finish(Activity.RESULT_CANCELED, results);
        } finally {
            if (activity != null) {
                final Activity launched = activity;
                runOnMainSync(launched::finish);
            }
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

    private static void require(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void remove(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) remove(child);
        if (file.exists() && !file.delete()) throw new AssertionError("Cannot remove test fixture " + file);
    }
}
