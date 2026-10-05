package com.daz.dashcam;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.SurfaceTexture;
import android.net.Uri;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.text.DateFormat;
import java.util.*;

/** Deliberately small native interface for the first physical-phone acceptance build. */
public final class MainActivity extends Activity implements TextureView.SurfaceTextureListener {
    private static final int PERMISSION_REQUEST = 1;
    private final Handler main = new Handler(Looper.getMainLooper());
    private RecordingService service;
    private RecordingService previewOwner;
    private boolean bound;
    private boolean visible;
    private boolean startAfterPermission;
    private TextureView preview;
    private TextView status;
    private CheckBox microphone;
    private Button start, stop, save;
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            if (service != null) {
                status.setText(service.getStatus());
                boolean active = service.isRecording();
                start.setEnabled(!active);
                stop.setEnabled(active);
                save.setEnabled(active);
                microphone.setEnabled(!active);
            }
            if (visible) main.postDelayed(this, 1000);
        }
    };
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((RecordingService.LocalBinder) binder).service();
            attachPreview();
            main.removeCallbacks(refresh);
            refresh.run();
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            service = null;
            status.setText("Recorder disconnected — reopen the app to recover footage");
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(18), dp(18), dp(18), dp(18));
        content.setBackgroundColor(Color.rgb(15, 23, 34));
        TextView heading = text("DASHCAM  0.1", 26);
        content.addView(heading);
        content.addView(text("Five-minute rolling buffer · manual incident save", 14));
        preview = new TextureView(this);
        preview.setSurfaceTextureListener(this);
        LinearLayout.LayoutParams previewParams = new LinearLayout.LayoutParams(-1, dp(230));
        previewParams.topMargin = dp(16);
        content.addView(preview, previewParams);
        status = text("Grant camera permission to start", 17);
        status.setPadding(0, dp(14), 0, dp(10));
        content.addView(status);
        microphone = new CheckBox(this);
        microphone.setText("Include microphone audio");
        microphone.setTextColor(Color.WHITE);
        content.addView(microphone);
        start = button("Start recording", this::requestStart);
        stop = button("Stop recording", () -> sendAction(RecordingService.ACTION_STOP));
        save = button("Save incident + 30-second tail", () -> {
            if (service != null) service.saveIncident();
        });
        content.addView(start);
        content.addView(save);
        content.addView(stop);
        content.addView(button("Footage library", this::showLibrary));
        content.addView(text("Phone testing pending · short gaps between clips. Footage stays on this phone; share saved incidents before uninstalling.", 13));
        stop.setEnabled(false);
        save.setEnabled(false);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(content);
        setContentView(scroll);
    }

    @Override protected void onStart() {
        super.onStart();
        visible = true;
        bound = bindService(new Intent(this, RecordingService.class), connection, BIND_AUTO_CREATE);
        main.removeCallbacks(refresh);
        refresh.run();
    }

    @Override protected void onStop() {
        visible = false;
        main.removeCallbacks(refresh);
        if (service != null && preview.isAvailable()) service.detachPreview(preview.getSurfaceTexture(), false);
        if (bound) { unbindService(connection); bound = false; }
        service = null;
        super.onStop();
    }

    private void requestStart() {
        List<String> missing = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.CAMERA);
        if (microphone.isChecked() && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.RECORD_AUDIO);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) missing.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!missing.isEmpty()) {
            startAfterPermission = true;
            requestPermissions(missing.toArray(new String[0]), PERMISSION_REQUEST);
        } else startRecording();
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(requestCode, permissions, grants);
        if (requestCode != PERMISSION_REQUEST || !startAfterPermission) return;
        startAfterPermission = false;
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            status.setText("Camera permission is required. Enable it in Android app settings if previously denied.");
            return;
        }
        if (microphone.isChecked() && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) microphone.setChecked(false);
        attachPreview();
        startRecording(); // Notification permission is optional; the foreground service is still required.
    }

    private void startRecording() {
        if (!visible) return;
        Intent intent = new Intent(this, RecordingService.class).setAction(RecordingService.ACTION_START)
            .putExtra("microphone", microphone.isChecked());
        try { startForegroundService(intent); }
        catch (RuntimeException error) { status.setText("Cannot start recording: " + error.getMessage()); }
    }

    private void sendAction(String action) {
        try { startService(new Intent(this, RecordingService.class).setAction(action)); }
        catch (RuntimeException error) { status.setText("Recorder unavailable: " + error.getMessage()); }
    }

    private void attachPreview() {
        if (visible && service != null && preview.isAvailable()
            && checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            previewOwner = service;
            service.setPreview(preview.getSurfaceTexture(), getWindowManager().getDefaultDisplay().getRotation());
        }
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture texture, int width, int height) { attachPreview(); }
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture texture, int width, int height) { }
    @Override public void onSurfaceTextureUpdated(SurfaceTexture texture) { }
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture texture) {
        RecordingService owner = service == null ? previewOwner : service;
        previewOwner = null;
        if (owner != null && owner.detachPreview(texture, true)) return false;
        return true;
    }

    private void showLibrary() {
        if (service == null || service.getStore() == null) {
            new AlertDialog.Builder(this).setMessage("Recording storage is unavailable. Existing files have been retained.").setPositiveButton("OK", null).show();
            return;
        }
        final RecordingStore store = service.getStore();
        new AlertDialog.Builder(this).setTitle("Footage library")
            .setItems(new String[] {"Saved incidents", "Recent and recovery segments"}, (dialog, which) -> {
                if (which == 0) showIncidents(store); else showSegments("Recent / recovery", store.listSegments());
            }).show();
    }

    private void showIncidents(RecordingStore store) {
        List<RecordingStore.Incident> incidents = store.listIncidents();
        Collections.reverse(incidents);
        if (incidents.isEmpty()) { toast("No incidents saved yet"); return; }
        String[] labels = new String[incidents.size()];
        long now = service == null ? System.currentTimeMillis() : service.timelineNow();
        boolean recording = service != null && service.isRecording();
        for (int i = 0; i < labels.length; i++) {
            RecordingStore.Incident incident = incidents.get(i);
            long coverageEnd = Long.MIN_VALUE;
            for (RecordingStore.Segment segment : store.segmentsForIncident(incident.id)) {
                if (segment.complete && !segment.uncertain) coverageEnd = Math.max(coverageEnd, segment.endMs);
            }
            String tail = "";
            if (coverageEnd < incident.endMs) tail = recording ? (now < incident.endMs ? " · tail recording" : " · finalizing tail") : " · partial tail";
            labels[i] = time(incident.endMs - RetentionPolicy.TAIL_MS) + tail;
        }
        new AlertDialog.Builder(this).setTitle("Saved incidents").setItems(labels, (dialog, which) -> {
            List<RecordingStore.Segment> segments = store.segmentsForIncident(incidents.get(which).id);
            new AlertDialog.Builder(this).setTitle(labels[which])
                .setItems(new String[] {"Browse clips", "Share finalized clips"}, (d, action) -> {
                    if (action == 0) showSegments("Incident clips", segments); else share(segments);
                }).show();
        }).show();
    }

    private void showSegments(String title, List<RecordingStore.Segment> segments) {
        Collections.reverse(segments);
        if (segments.isEmpty()) { toast("No footage available yet"); return; }
        String[] labels = new String[segments.size()];
        for (int i = 0; i < labels.length; i++) {
            RecordingStore.Segment segment = segments.get(i);
            labels[i] = time(segment.startMs) + (segment.uncertain ? " · recovery (may not play)" : segment.complete ? " · finalized" : " · recording");
        }
        new AlertDialog.Builder(this).setTitle(title).setItems(labels, (dialog, which) -> {
            RecordingStore.Segment segment = segments.get(which);
            if (!segment.complete && !segment.uncertain) { toast("Wait for this segment to finalize"); return; }
            new AlertDialog.Builder(this).setTitle(labels[which]).setItems(new String[] {"Play", "Share clip"}, (d, action) -> {
                if (action == 0) play(segment); else share(Collections.singletonList(segment));
            }).show();
        }).show();
    }

    private void play(RecordingStore.Segment segment) {
        VideoView video = new VideoView(this);
        MediaController controls = new MediaController(this);
        controls.setAnchorView(video);
        video.setMediaController(controls);
        video.setVideoURI(RecordingProvider.uriFor(segment.file));
        Dialog player = new Dialog(this);
        player.setContentView(video);
        player.setOnDismissListener(dialog -> video.stopPlayback());
        video.setOnPreparedListener(media -> video.start());
        video.setOnErrorListener((media, what, extra) -> { toast("Clip cannot be played; original file retained"); player.dismiss(); return true; });
        player.show();
        if (player.getWindow() != null) player.getWindow().setLayout(-1, dp(360));
    }

    private void share(List<RecordingStore.Segment> segments) {
        ArrayList<Uri> uris = new ArrayList<>();
        for (RecordingStore.Segment segment : segments) {
            if ((segment.complete || segment.uncertain) && segment.file.isFile() && segment.file.length() > 0) uris.add(RecordingProvider.uriFor(segment.file));
        }
        if (uris.isEmpty()) { toast("No finalized clips available yet"); return; }
        Intent intent = new Intent(uris.size() == 1 ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE).setType("video/mp4");
        if (uris.size() == 1) intent.putExtra(Intent.EXTRA_STREAM, uris.get(0));
        else intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        ClipData data = ClipData.newUri(getContentResolver(), "Dashcam clips", uris.get(0));
        for (int i = 1; i < uris.size(); i++) data.addItem(new ClipData.Item(uris.get(i)));
        intent.setClipData(data);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivity(Intent.createChooser(intent, "Share dashcam footage")); }
        catch (ActivityNotFoundException error) { toast("No sharing app available"); }
    }

    private TextView text(String value, int size) {
        TextView view = new TextView(this);
        view.setText(value); view.setTextColor(Color.WHITE); view.setTextSize(size);
        return view;
    }
    private Button button(String label, Runnable action) {
        Button button = new Button(this);
        button.setText(label);
        button.setOnClickListener(view -> action.run());
        return button;
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private String time(long millis) { return DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.MEDIUM).format(new Date(millis)); }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
}
