package com.daz.dashcam;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.*;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.MediaRecorder;
import android.os.*;
import android.util.Size;
import android.view.Surface;
import java.io.File;
import java.util.*;

/** User-started foreground recorder. All camera and manifest work uses one worker. */
public final class RecordingService extends Service {
    public static final String ACTION_START = "com.daz.dashcam.START";
    public static final String ACTION_STOP = "com.daz.dashcam.STOP";
    public static final String ACTION_SAVE = "com.daz.dashcam.SAVE";
    private static final String CHANNEL = "recording";
    private static final int NOTIFICATION_ID = 10;
    private static final long MIN_FREE_BYTES = 256L * 1024 * 1024;
    private final LocalBinder binder = new LocalBinder();
    private HandlerThread thread;
    private Handler worker;
    private RecordingStore store;
    private CameraDevice camera;
    private CameraCaptureSession session;
    private MediaRecorder recorder;
    private Surface preview;
    private SurfaceTexture previewTexture;
    private RecordingStore.Segment segment;
    private PowerManager.WakeLock wakeLock;
    private volatile boolean recording;
    private volatile boolean startRequested;
    private volatile boolean destroyed;
    private volatile String status = "Ready";
    private boolean microphone;
    private boolean recorderStarted;
    private boolean openingCamera;
    private int sessionGeneration;
    private int displayDegrees;
    private int sensorOrientation;
    private Size videoSize = new Size(1280, 720);
    private final long epochWall = System.currentTimeMillis();
    private final long epochElapsed = SystemClock.elapsedRealtime();
    private PowerManager.OnThermalStatusChangedListener thermalListener;
    private final Runnable checkStorage = new Runnable() {
        @Override public void run() {
            if (!recording) return;
            if (!store.hasEnoughSpace(MIN_FREE_BYTES)) {
                stopRecording("Low storage — stopped safely; footage retained");
                return;
            }
            worker.postDelayed(this, 2000);
        }
    };
    private final Runnable rotate = () -> {
        if (!recording) return;
        finishSegment();
        if (recording) beginSegment();
        else stopRecording(status);
    };

    public final class LocalBinder extends Binder {
        public RecordingService service() { return RecordingService.this; }
    }

    @Override public void onCreate() {
        super.onCreate();
        thread = new HandlerThread("dashcam-recorder");
        thread.start();
        worker = new Handler(thread.getLooper());
        try { store = AndroidStorage.open(new File(getFilesDir(), "recordings")); }
        catch (Exception error) { status = "Storage unavailable: " + message(error); }
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, "Dashcam recording", NotificationManager.IMPORTANCE_LOW));
        wakeLock = getSystemService(PowerManager.class).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dashcam:recording");
        if (Build.VERSION.SDK_INT >= 29) {
            thermalListener = level -> {
                if (recording && level >= PowerManager.THERMAL_STATUS_SEVERE) stopRecording("Phone too hot — recording stopped; footage retained");
            };
            getSystemService(PowerManager.class).addThermalStatusListener(command -> worker.post(command), thermalListener);
        }
    }

    @Override public IBinder onBind(Intent intent) { return binder; }
    public RecordingStore getStore() { return store; }
    public boolean isRecording() { return recording; }
    public String getStatus() { return status; }
    public long timelineNow() { return epochWall + SystemClock.elapsedRealtime() - epochElapsed; }

    /** The activity retains ownership of the texture; release happens after this worker detaches it. */
    public void setPreview(SurfaceTexture texture, int rotation) {
        worker.post(() -> {
            displayDegrees = rotation * 90;
            closeSession();
            if (preview != null) { preview.release(); preview = null; }
            previewTexture = texture;
            if (texture != null) {
                texture.setDefaultBufferSize(videoSize.getWidth(), videoSize.getHeight());
                preview = new Surface(texture);
            }
            if (camera != null) configureSession();
            else if (texture != null || recording) openCamera();
            if (texture == null && !recording) closeCamera();
        });
    }

    public boolean detachPreview(SurfaceTexture texture, boolean release) {
        return worker.post(() -> {
            if (previewTexture == texture) {
                closeSession();
                if (preview != null) preview.release();
                preview = null;
                previewTexture = null;
                if (recording && camera != null) configureSession();
                else if (!recording) closeCamera();
            }
            if (release) texture.release();
        });
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) return START_NOT_STICKY; // Never restart camera access after process death.
        String action = intent.getAction();
        if (ACTION_START.equals(action)) {
            if (recording || startRequested) return START_NOT_STICKY;
            if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                status = "Camera permission required";
                stopSelf();
                return START_NOT_STICKY;
            }
            boolean audio = intent.getBooleanExtra("microphone", false)
                && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
            try {
                startRequested = true;
                int types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA;
                if (audio) types |= ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE;
                if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification("Starting camera"), types);
                else startForeground(NOTIFICATION_ID, notification("Starting camera"));
                worker.post(() -> startRecording(audio));
            } catch (RuntimeException error) {
                startRequested = false;
                status = "Could not start recording: " + message(error);
                stopSelf();
            }
        } else if (ACTION_STOP.equals(action)) worker.post(() -> stopRecording("Stopped — finalized footage retained"));
        else if (ACTION_SAVE.equals(action)) saveIncident();
        return START_NOT_STICKY;
    }

    public void saveIncident() {
        worker.post(() -> {
            if (!recording || store == null) { status = "Start recording before saving an incident"; return; }
            try {
                store.saveIncident(timelineNow());
                status = "Incident saved — recording 30-second tail";
                updateNotification();
            } catch (Exception error) { stopRecording("Cannot preserve incident: " + message(error)); }
        });
    }

    private void startRecording(boolean audio) {
        if (recording) return;
        if (store == null) { stopRecording("Storage unavailable"); return; }
        if (Build.VERSION.SDK_INT >= 29 && getSystemService(PowerManager.class).getCurrentThermalStatus() >= PowerManager.THERMAL_STATUS_SEVERE) {
            stopRecording("Phone too hot — wait for it to cool before recording");
            return;
        }
        microphone = audio;
        recording = true;
        wakeLock.acquire();
        worker.post(checkStorage);
        status = "Starting rear camera";
        if (camera == null) openCamera();
        else beginSegment();
    }

    private void openCamera() {
        if (openingCamera || destroyed || camera != null) return;
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            if (recording) stopRecording("Camera permission required");
            else status = "Grant camera permission to preview";
            return;
        }
        try {
            CameraManager manager = getSystemService(CameraManager.class);
            String selected = null;
            for (String id : manager.getCameraIdList()) {
                CameraCharacteristics characteristics = manager.getCameraCharacteristics(id);
                Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING);
                if (facing != null && facing == CameraCharacteristics.LENS_FACING_BACK) {
                    selected = id;
                    Integer orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
                    sensorOrientation = orientation == null ? 0 : orientation;
                    StreamConfigurationMap map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                    if (map == null) throw new IllegalStateException("No supported camera outputs");
                    Size[] sizes = map.getOutputSizes(MediaRecorder.class);
                    if (sizes == null || sizes.length == 0) throw new IllegalStateException("Camera does not support video recording");
                    videoSize = chooseSize(sizes);
                    if (previewTexture != null) previewTexture.setDefaultBufferSize(videoSize.getWidth(), videoSize.getHeight());
                    break;
                }
            }
            if (selected == null) throw new IllegalStateException("No rear camera available");
            openingCamera = true;
            manager.openCamera(selected, new CameraDevice.StateCallback() {
                @Override public void onOpened(CameraDevice device) {
                    openingCamera = false;
                    if (destroyed || (!recording && preview == null)) { device.close(); return; }
                    camera = device;
                    if (recording) beginSegment(); else configureSession();
                }
                @Override public void onDisconnected(CameraDevice device) { cameraFailed(device, "Camera disconnected; footage retained"); }
                @Override public void onError(CameraDevice device, int error) { cameraFailed(device, "Camera interrupted (" + error + "); footage retained"); }
            }, worker);
        } catch (Exception error) {
            openingCamera = false;
            stopRecording("Camera unavailable: " + message(error));
        }
    }

    private void cameraFailed(CameraDevice device, String reason) {
        openingCamera = false;
        if (camera == device) camera = null;
        stopRecording(reason);
        device.close();
    }

    private static Size chooseSize(Size[] sizes) {
        Size chosen = null;
        for (Size size : sizes) {
            if (size.getWidth() == 1280 && size.getHeight() == 720) return size;
            if (size.getWidth() <= 1280 && size.getHeight() <= 720 &&
                (chosen == null || (long) size.getWidth() * size.getHeight() > (long) chosen.getWidth() * chosen.getHeight())) chosen = size;
        }
        if (chosen != null) return chosen;
        return Collections.min(Arrays.asList(sizes), Comparator.comparingLong(size -> (long) size.getWidth() * size.getHeight()));
    }

    private void beginSegment() {
        if (!recording || camera == null || destroyed) return;
        try {
            store.prune(timelineNow());
            if (!store.hasEnoughSpace(MIN_FREE_BYTES)) {
                stopRecording("Low storage — stopped safely; incident footage retained");
                return;
            }
            closeSession();
            segment = store.beginSegment(timelineNow());
            recorder = new MediaRecorder();
            if (microphone) recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            recorder.setOutputFile(segment.file.getAbsolutePath());
            recorder.setVideoEncodingBitRate(4_000_000);
            recorder.setVideoFrameRate(30);
            recorder.setVideoSize(videoSize.getWidth(), videoSize.getHeight());
            recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
            recorder.setOrientationHint((sensorOrientation - displayDegrees + 360) % 360);
            if (microphone) {
                recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
                recorder.setAudioEncodingBitRate(96_000);
                recorder.setAudioSamplingRate(44_100);
            }
            recorder.setOnErrorListener((source, what, extra) -> worker.post(() -> {
                if (recorder == source) stopRecording("Recorder error (" + what + "); footage retained");
            }));
            recorder.prepare();
            configureSession();
        } catch (Exception error) { stopRecording("Cannot record: " + message(error)); }
    }

    private void configureSession() {
        if (camera == null || destroyed) return;
        ArrayList<Surface> outputs = new ArrayList<>();
        if (preview != null) outputs.add(preview);
        final MediaRecorder configuringRecorder = recorder;
        final Surface videoSurface = configuringRecorder == null ? null : configuringRecorder.getSurface();
        if (videoSurface != null) outputs.add(videoSurface);
        if (outputs.isEmpty()) return;
        final int generation = ++sessionGeneration;
        try {
            camera.createCaptureSession(outputs, new CameraCaptureSession.StateCallback() {
                @Override public void onConfigured(CameraCaptureSession configured) {
                    if (generation != sessionGeneration || camera == null || destroyed) { configured.close(); return; }
                    session = configured;
                    try {
                        CaptureRequest.Builder request = camera.createCaptureRequest(videoSurface == null ? CameraDevice.TEMPLATE_PREVIEW : CameraDevice.TEMPLATE_RECORD);
                        for (Surface output : outputs) request.addTarget(output);
                        request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
                        configured.setRepeatingRequest(request.build(), null, worker);
                        if (configuringRecorder != null && !recorderStarted) {
                            configuringRecorder.start();
                            recorderStarted = true;
                            status = microphone ? "Recording · microphone on" : "Recording · microphone off";
                            worker.postDelayed(rotate, RetentionPolicy.SEGMENT_MS);
                            updateNotification();
                        }
                    } catch (Exception error) { stopRecording("Capture interrupted: " + message(error)); }
                }
                @Override public void onConfigureFailed(CameraCaptureSession failed) {
                    failed.close();
                    if (generation == sessionGeneration) stopRecording("Camera configuration failed; footage retained");
                }
            }, worker);
        } catch (Exception error) { stopRecording("Camera configuration failed: " + message(error)); }
    }

    private void finishSegment() {
        worker.removeCallbacks(rotate);
        closeSession();
        boolean successful = false;
        if (recorder != null) {
            try { if (recorderStarted) { recorder.stop(); successful = true; } }
            catch (RuntimeException error) {
                recording = false;
                status = "Interrupted segment retained for recovery — recording stopped";
            }
            finally { recorder.release(); recorder = null; recorderStarted = false; }
        }
        if (segment != null) {
            try { store.completeSegment(segment.id, timelineNow(), successful); }
            catch (Exception error) {
                recording = false;
                status = "Manifest write failed — stopped; files retained: " + message(error);
            }
            segment = null;
        }
    }

    private void stopRecording(String reason) {
        recording = false;
        startRequested = false;
        worker.removeCallbacks(checkStorage);
        finishSegment();
        status = reason;
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
        // Leave a fresh preview while the visible activity remains bound.
        if (preview != null && camera != null && !destroyed) configureSession();
        else closeCamera();
    }

    private void closeSession() {
        sessionGeneration++;
        if (session != null) {
            try { session.stopRepeating(); } catch (Exception ignored) { }
            session.close();
            session = null;
        }
    }

    private void closeCamera() {
        closeSession();
        if (camera != null) { camera.close(); camera = null; }
    }

    private Notification notification(String text) {
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), flags);
        PendingIntent save = PendingIntent.getService(this, 1, new Intent(this, RecordingService.class).setAction(ACTION_SAVE), flags);
        PendingIntent stop = PendingIntent.getService(this, 2, new Intent(this, RecordingService.class).setAction(ACTION_STOP), flags);
        return new Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("Dashcam is recording")
            .setContentText(text).setContentIntent(open).setOngoing(true)
            .addAction(new Notification.Action.Builder(null, "Save incident", save).build())
            .addAction(new Notification.Action.Builder(null, "Stop", stop).build()).build();
    }

    private void updateNotification() {
        if (recording) getSystemService(NotificationManager.class).notify(NOTIFICATION_ID, notification(status));
    }

    private static String message(Throwable error) {
        return error.getMessage() == null ? error.getClass().getSimpleName() : error.getMessage();
    }

    @Override public void onDestroy() {
        destroyed = true;
        if (Build.VERSION.SDK_INT >= 29 && thermalListener != null) getSystemService(PowerManager.class).removeThermalStatusListener(thermalListener);
        worker.post(() -> {
            stopRecording("Stopped");
            closeCamera();
            if (preview != null) { preview.release(); preview = null; }
            thread.quitSafely();
        });
        super.onDestroy();
    }
}
