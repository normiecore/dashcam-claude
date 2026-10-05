package com.daz.dashcam;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.*;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.*;
import android.util.LruCache;
import android.util.Size;
import android.view.*;
import android.widget.*;
import java.text.DateFormat;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.concurrent.*;

/** Native recorder and library. UI lifecycle never owns the recording lifecycle. */
public final class MainActivity extends Activity implements TextureView.SurfaceTextureListener {
    public static final int RECORD_TAB = 1001, LIBRARY_TAB = 1002, PRIMARY_ACTION = 1003,
        STOP_ACTION = 1004, FOOTAGE_LIST = 1005, SETTINGS_ACTION = 1006, PREVIEW = 1007;
    private static final int START_PERMISSION = 1, PREVIEW_PERMISSION = 2;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService thumbnails = Executors.newSingleThreadExecutor();
    private final LruCache<String, Bitmap> thumbnailCache = new LruCache<String, Bitmap>(4 * 1024 * 1024) {
        @Override protected int sizeOf(String key, Bitmap value) { return value.getByteCount(); }
    };
    private final Map<String, List<ImageView>> thumbnailPending = new HashMap<>();
    private final List<Dialog> dialogs = new ArrayList<>();
    private RecordingService service, previewOwner;
    private boolean bound, visible, startAfterPermission, library, starting, landscape;
    private int filter;
    private SharedPreferences preferences;
    private LinearLayout root, recorderPage, libraryPage, footageList, actionPanel;
    private TextureView preview;
    private FrameLayout hero;
    private LinearLayout permissionCard;
    private TextView title, subtitle, status, live, clock, audio, buffer, saved, actionHint;
    private Button primary, stop, recordTab, libraryTab, recordingStrip, cameraButton;
    private String libraryStamp = "";
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            renderState();
            if (visible) main.postDelayed(this, 1000);
        }
    };
    private final ServiceConnection connection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((RecordingService.LocalBinder) binder).service();
            attachPreview();
            main.removeCallbacks(refresh); refresh.run();
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            service = null; starting = false; renderState();
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        landscape = getResources().getConfiguration().orientation == 2;
        preferences = getSharedPreferences("interface", MODE_PRIVATE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        root = Ui.column(this); root.setBackgroundColor(Ui.BG);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets.consumeSystemWindowInsets();
        });
        buildHeader();
        FrameLayout pages = new FrameLayout(this);
        root.addView(pages, new LinearLayout.LayoutParams(-1, 0, 1));
        recorderPage = Ui.column(this);
        recorderPage.setPadding(dp(20), dp(landscape ? 8 : 12), dp(20), dp(landscape ? 8 : 12));
        ScrollView recorderScroll = scroll(recorderPage);
        pages.addView(recorderScroll, new FrameLayout.LayoutParams(-1, -1));
        buildRecorder();
        libraryPage = Ui.column(this); padding(libraryPage, 20);
        ScrollView libraryScroll = scroll(libraryPage);
        libraryScroll.setTag("library-scroll");
        pages.addView(libraryScroll, new FrameLayout.LayoutParams(-1, -1));
        buildLibrary();
        actionPanel = Ui.column(this);
        actionPanel.setPadding(dp(20), dp(landscape ? 8 : 12), dp(20), dp(landscape ? 8 : 12));
        LinearLayout actionRow = Ui.row(this);
        primary = Ui.button(this, s(R.string.start_recording), "camera", true, () -> {
            if (service != null && service.isRecording()) {
                service.saveIncident();
                primary.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY);
                toast(s(R.string.saving));
            } else requestStart();
        });
        primary.setId(PRIMARY_ACTION);
        actionRow.addView(primary, new LinearLayout.LayoutParams(0, -2, 1));
        stop = Ui.button(this, s(R.string.stop_short), "stop", false, this::requestStop);
        stop.setContentDescription(s(R.string.stop_recording));
        stop.setPadding(dp(12), dp(12), dp(12), dp(12));
        stop.setId(STOP_ACTION);
        LinearLayout.LayoutParams stopParams = lp(dp(112), -2); stopParams.leftMargin = dp(8);
        actionRow.addView(stop, stopParams); actionPanel.addView(actionRow);
        actionHint = label("", 12, Ui.MUTED, false);
        actionHint.setGravity(Gravity.CENTER); actionHint.setPadding(dp(6), dp(10), dp(6), 0);
        actionPanel.addView(actionHint);
        if (landscape) actionHint.setVisibility(View.GONE);
        root.addView(actionPanel);
        buildNavigation();
        setContentView(root);
        library = state != null && state.getBoolean("library");
        startAfterPermission = state != null && state.getBoolean("startAfterPermission");
        filter = state == null ? 0 : state.getInt("filter");
        selectTab(library);
    }

    private void buildHeader() {
        LinearLayout header = Ui.row(this); header.setPadding(dp(20), dp(landscape ? 4 : 8), dp(20), dp(4));
        ImageView mark = new ImageView(this);
        mark.setImageDrawable(new Ui.Glyph("camera", Ui.MINT, dp(24)));
        mark.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        header.addView(mark, lp(dp(28), dp(28)));
        TextView name = label(s(R.string.app_title), 20, Ui.TEXT, true);
        name.setPadding(dp(10), 0, 0, 0);
        header.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
        ImageButton settings = Ui.iconButton(this, "settings", s(R.string.settings), this::showSettings);
        settings.setId(SETTINGS_ACTION); header.addView(settings, lp(dp(48), dp(48)));
        root.addView(header);
    }

    private void buildRecorder() {
        title = label("", 28, Ui.TEXT, true); recorderPage.addView(title);
        subtitle = label("", 14, Ui.MUTED, false);
        subtitle.setPadding(0, dp(8), 0, dp(20)); recorderPage.addView(subtitle);
        if (landscape) { title.setVisibility(View.GONE); subtitle.setVisibility(View.GONE); }
        hero = new FrameLayout(this);
        hero.setBackground(Ui.shape(this, Color.BLACK, Ui.LINE, 24)); hero.setClipToOutline(true);
        int height = previewHeight();
        recorderPage.addView(hero, lp(-1, dp(height)));
        preview = new TextureView(this); preview.setId(PREVIEW);
        preview.setSurfaceTextureListener(this);
        preview.setContentDescription(s(R.string.preview_description));
        hero.addView(preview, new FrameLayout.LayoutParams(-1, -1));
        LinearLayout overlay = Ui.column(this);
        overlay.setPadding(dp(16), dp(16), dp(16), dp(16));
        FrameLayout.LayoutParams overlayParams = new FrameLayout.LayoutParams(-1, -2, Gravity.TOP);
        hero.addView(overlay, overlayParams);
        LinearLayout cameraRow = Ui.row(this);
        TextView rear = label(s(R.string.preview_label), 11, Ui.TEXT, true);
        rear.setShadowLayer(4, 0, 1, Color.BLACK);
        cameraRow.addView(rear, new LinearLayout.LayoutParams(0, -2, 1));
        live = label("", 11, Ui.BG, true); live.setPadding(dp(10), dp(6), dp(10), dp(6));
        cameraRow.addView(live); overlay.addView(cameraRow);
        LinearLayout bottom = Ui.column(this); bottom.setPadding(dp(16), 0, dp(16), dp(16));
        clock = label("00:00", 34, Ui.TEXT, true); clock.setTypeface(Typeface.MONOSPACE);
        clock.setShadowLayer(5, 0, 1, Color.BLACK); bottom.addView(clock);
        audio = label("", 12, Ui.TEXT, false); audio.setShadowLayer(5, 0, 1, Color.BLACK);
        audio.setPadding(0, dp(4), 0, 0); bottom.addView(audio);
        hero.addView(bottom, new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM));
        permissionCard = Ui.column(this); padding(permissionCard, landscape ? 12 : 20);
        permissionCard.setGravity(Gravity.CENTER); permissionCard.setBackgroundColor(Ui.SURFACE);
        permissionCard.addView(label(s(R.string.camera_heading), landscape ? 16 : 20, Ui.TEXT, true));
        TextView permissionBody = label(s(R.string.camera_body), 14, Ui.MUTED, false);
        permissionBody.setGravity(Gravity.CENTER); permissionBody.setPadding(0, dp(12), 0, dp(18));
        permissionCard.addView(permissionBody);
        if (landscape) permissionBody.setVisibility(View.GONE);
        cameraButton = Ui.button(this, s(R.string.allow_camera), "camera", true, this::requestCamera);
        permissionCard.addView(cameraButton, lp(-1, -2));
        hero.addView(permissionCard, new FrameLayout.LayoutParams(-1, -1));
        status = label("", 13, Ui.MUTED, false);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        status.setPadding(0, dp(landscape ? 6 : 12), 0, dp(landscape ? 0 : 12)); recorderPage.addView(status);
        LinearLayout stats = Ui.row(this);
        buffer = metric(stats, s(R.string.buffer_label)); saved = metric(stats, s(R.string.saved_label));
        recorderPage.addView(stats);
        if (landscape) stats.setVisibility(View.GONE); else Ui.gap(recorderPage, 8);
    }

    private TextView metric(LinearLayout parent, String name) {
        LinearLayout card = Ui.column(this);
        card.setPadding(dp(12), dp(10), dp(12), dp(10));
        card.setBackground(Ui.shape(this, Ui.SURFACE, Ui.LINE, 18));
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, -2, 1);
        if (parent.getChildCount() > 0) params.leftMargin = dp(10);
        parent.addView(card, params);
        card.addView(label(name, 12, Ui.MUTED, false)); Ui.gap(card, 6);
        TextView value = label("", 18, Ui.TEXT, true); card.addView(value); return value;
    }

    private void buildLibrary() {
        libraryPage.addView(label(s(R.string.footage_header), 28, Ui.TEXT, true));
        TextView explanation = label(s(R.string.footage_subtitle), 14, Ui.MUTED, false);
        explanation.setPadding(0, dp(8), 0, dp(18)); libraryPage.addView(explanation);
        recordingStrip = Ui.button(this, "", "camera", false, () -> selectTab(false));
        libraryPage.addView(recordingStrip, lp(-1, -2)); Ui.gap(libraryPage, 14);
        LinearLayout filters = Ui.row(this);
        int[] labels = {R.string.library_saved, R.string.library_recent, R.string.library_recovery};
        for (int i = 0; i < labels.length; i++) {
            final int selected = i;
            Button chip = Ui.button(this, s(labels[i]), null, false, () -> {
                filter = selected; libraryStamp = ""; renderLibrary();
            });
            chip.setTextSize(13); chip.setPadding(dp(4), dp(10), dp(4), dp(10));
            chip.setTag(i);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, -2, 1);
            if (i > 0) params.leftMargin = dp(6);
            filters.addView(chip, params);
        }
        filters.setTag("filters"); libraryPage.addView(filters); Ui.gap(libraryPage, 18);
        footageList = Ui.column(this); footageList.setId(FOOTAGE_LIST);
        libraryPage.addView(footageList);
    }

    private void buildNavigation() {
        LinearLayout navigation = Ui.row(this);
        navigation.setPadding(dp(20), dp(6), dp(20), dp(6));
        navigation.setBackgroundColor(Ui.SURFACE);
        recordTab = Ui.button(this, s(R.string.record_tab), "camera", false, () -> selectTab(false));
        recordTab.setId(RECORD_TAB);
        libraryTab = Ui.button(this, s(R.string.library_tab), "library", false, () -> selectTab(true));
        libraryTab.setId(LIBRARY_TAB);
        if (landscape) {
            for (Button tab : new Button[]{recordTab, libraryTab}) { tab.setMinHeight(dp(48)); tab.setMinimumHeight(dp(48)); }
        }
        navigation.addView(recordTab, new LinearLayout.LayoutParams(0, -2, 1));
        LinearLayout.LayoutParams second = new LinearLayout.LayoutParams(0, -2, 1); second.leftMargin = dp(10);
        navigation.addView(libraryTab, second); root.addView(navigation);
    }

    private void selectTab(boolean showLibrary) {
        library = showLibrary;
        ((View) recorderPage.getParent()).setVisibility(library ? View.GONE : View.VISIBLE);
        ((View) libraryPage.getParent()).setVisibility(library ? View.VISIBLE : View.GONE);
        actionPanel.setVisibility(library ? View.GONE : View.VISIBLE);
        tintTab(recordTab, !library); tintTab(libraryTab, library);
        if (library) { libraryStamp = ""; renderLibrary(); }
        else main.post(this::attachPreview);
        renderState();
    }

    private void tintTab(Button button, boolean selected) {
        button.setSelected(selected);
        button.setBackground(Ui.touch(this, selected ? Ui.MINT_DARK : Ui.SURFACE, 0, 14));
        button.setTextColor(selected ? Ui.MINT : Ui.MUTED);
        String icon = button == recordTab ? "camera" : "library";
        button.setCompoundDrawablesRelativeWithIntrinsicBounds(new Ui.Glyph(icon, selected ? Ui.MINT : Ui.MUTED, dp(21)), null, null, null);
    }

    private void renderState() {
        if (title == null) return;
        boolean active = service != null && service.isRecording();
        if (active || (service != null && !service.getStatus().equals("Ready"))) starting = false;
        title.setText(s(active ? R.string.recording_header : R.string.record_header));
        subtitle.setText(s(active ? R.string.recording_subtitle : R.string.record_subtitle));
        primary.setText(s(active ? R.string.save_incident : R.string.start_recording));
        primary.setCompoundDrawablesRelativeWithIntrinsicBounds(new Ui.Glyph(active ? "shield" : "camera", Ui.BG, dp(22)), null, null, null);
        primary.setEnabled(service != null && !starting);
        primary.setAlpha(primary.isEnabled() ? 1 : .5f);
        stop.setVisibility(active ? View.VISIBLE : View.GONE); stop.setEnabled(active);
        actionHint.setText(s(active ? R.string.save_help : R.string.start_help));
        live.setText(s(active ? R.string.live : R.string.ready));
        live.setBackground(Ui.shape(this, active ? Ui.RED : Ui.MINT, 0, 12));
        clock.setText(duration(service == null ? 0 : service.getElapsedRecordingMs()));
        boolean mic = active ? service.isMicrophoneEnabled() : preferences.getBoolean("audio", false);
        audio.setText(s(mic ? R.string.audio_on : R.string.audio_off));
        boolean permitted = cameraGranted();
        int desiredHeight = dp(previewHeight());
        if (hero.getLayoutParams().height != desiredHeight) {
            ViewGroup.LayoutParams params = hero.getLayoutParams(); params.height = desiredHeight; hero.setLayoutParams(params);
        }
        permissionCard.setVisibility(permitted ? View.GONE : View.VISIBLE);
        cameraButton.setText(s(cameraPermanentlyDenied() ? R.string.camera_settings : R.string.allow_camera));
        String recorderStatus = service == null ? s(R.string.service_unavailable) : service.getStatus();
        status.setText(!permitted ? s(R.string.camera_body) : recorderStatus);
        String statusKey = recorderStatus.toLowerCase(Locale.ROOT);
        status.setTextColor(statusKey.contains("failed") || statusKey.contains("low") || statusKey.contains("interrupted")
            || statusKey.contains("hot") || statusKey.contains("cannot") || statusKey.contains("unavailable") ? Ui.AMBER : Ui.MUTED);
        RecordingStore store = store();
        long now = service == null ? System.currentTimeMillis() : service.timelineNow();
        long earliest = now;
        if (store != null) for (RecordingStore.Segment segment : store.listSegments())
            if (!segment.uncertain && segment.startMs >= now - RetentionPolicy.ROLLING_MS) earliest = Math.min(earliest, segment.startMs);
        buffer.setText(getString(R.string.buffer_format, duration(Math.min(RetentionPolicy.ROLLING_MS, Math.max(0, now - earliest)))));
        saved.setText(Integer.toString(store == null ? 0 : store.listIncidents().size()));
        recordingStrip.setVisibility(active ? View.VISIBLE : View.GONE);
        recordingStrip.setText(getString(R.string.back_to_recording, duration(service == null ? 0 : service.getElapsedRecordingMs())));
        transformPreview();
        if (library) renderLibrary();
    }

    private void renderLibrary() {
        if (footageList == null) return;
        LinearLayout filters = libraryPage.findViewWithTag("filters");
        for (int i = 0; i < filters.getChildCount(); i++) {
            Button chip = (Button) filters.getChildAt(i); boolean selected = i == filter;
            chip.setSelected(selected); chip.setTextColor(selected ? Ui.MINT : Ui.MUTED);
            chip.setBackground(Ui.touch(this, selected ? Ui.MINT_DARK : Ui.SURFACE, selected ? Ui.MINT_DARK : Ui.LINE, 14));
        }
        RecordingStore store = store();
        if (store == null) {
            if (!libraryStamp.equals("unavailable")) { footageList.removeAllViews(); empty(R.string.storage_unavailable, R.string.retained_footage, "alert"); libraryStamp = "unavailable"; }
            return;
        }
        List<RecordingStore.Incident> incidents = store.listIncidents();
        List<RecordingStore.Segment> segments = store.listSegments();
        StringBuilder stamp = new StringBuilder().append(filter);
        for (RecordingStore.Incident incident : incidents) stamp.append(incident.id).append(tailState(incident, false));
        for (RecordingStore.Segment segment : segments) stamp.append(segment.file.getName()).append(segment.complete).append(segment.uncertain).append(store.isProtected(segment.id));
        if (stamp.toString().equals(libraryStamp)) return;
        libraryStamp = stamp.toString(); footageList.removeAllViews();
        if (filter == 0) {
            Collections.reverse(incidents);
            for (RecordingStore.Incident incident : incidents) {
                List<RecordingStore.Segment> clips = store.segmentsForIncident(incident.id);
                RecordingStore.Segment thumb = null;
                for (RecordingStore.Segment clip : clips) if (clip.complete && !clip.uncertain) { thumb = clip; break; }
                String detail = getResources().getQuantityString(R.plurals.clip_count, clips.size(), clips.size()) + " · " + tailState(incident, false);
                footageRow(footageList, date(incident.endMs - RetentionPolicy.TAIL_MS), detail, "shield", thumb,
                    () -> showIncident(incident), () -> shareIncident(incident));
            }
            if (incidents.isEmpty()) empty(R.string.empty_saved, R.string.empty_saved_body, "shield");
        } else {
            Collections.reverse(segments); int count = 0;
            for (RecordingStore.Segment segment : segments) {
                if (filter == 2 ? !segment.uncertain : segment.uncertain) continue;
                count++;
                String detail = segment.uncertain ? s(R.string.clip_recovery) : !segment.complete ? s(R.string.clip_recording)
                    : duration(Math.max(0, segment.endMs - segment.startMs)) + " · " + s(store.isProtected(segment.id) ? R.string.protected_label : R.string.clip_ready);
                footageRow(footageList, date(segment.startMs), detail, segment.uncertain ? "alert" : "play", segment,
                    () -> play(segment), () -> share(Collections.singletonList(segment)));
            }
            if (count == 0) empty(filter == 1 ? R.string.empty_recent : R.string.empty_recovery,
                filter == 1 ? R.string.empty_recent_body : R.string.empty_recovery_body, filter == 1 ? "camera" : "shield");
        }
    }

    private void empty(int heading, int body, String icon) {
        LinearLayout card = Ui.column(this); padding(card, 24);
        card.setGravity(Gravity.CENTER); card.setBackground(Ui.shape(this, Ui.SURFACE, Ui.LINE, 20));
        ImageView image = new ImageView(this); image.setImageDrawable(new Ui.Glyph(icon, Ui.MINT, dp(34)));
        image.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        card.addView(image, lp(dp(48), dp(48))); Ui.gap(card, 14);
        TextView title = label(s(heading), 20, Ui.TEXT, true); title.setGravity(Gravity.CENTER); card.addView(title);
        TextView description = label(s(body), 14, Ui.MUTED, false); description.setGravity(Gravity.CENTER);
        description.setPadding(0, dp(10), 0, dp(20)); card.addView(description);
        card.addView(Ui.button(this, s(R.string.go_record), "camera", false, () -> selectTab(false)), lp(-1, -2));
        footageList.addView(card, lp(-1, -2));
    }

    private void footageRow(LinearLayout parent, String heading, String detail, String icon,
            RecordingStore.Segment clip, Runnable open, Runnable share) {
        LinearLayout row = Ui.row(this); row.setPadding(dp(12), dp(14), dp(8), dp(14));
        row.setBackground(Ui.touch(this, Ui.SURFACE, Ui.LINE, 18));
        row.setOnClickListener(v -> open.run()); row.setFocusable(true);
        row.setContentDescription((icon.equals("shield") ? s(R.string.incident_title) + ". " : "") + heading + ". " + detail + ". " + s(R.string.open_footage));
        ImageView image = new ImageView(this); image.setScaleType(ImageView.ScaleType.CENTER_CROP);
        image.setBackground(Ui.shape(this, Ui.RAISED, 0, 12)); image.setClipToOutline(true);
        image.setImageDrawable(new Ui.Glyph(icon, Ui.MINT, dp(26)));
        image.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        row.addView(image, lp(dp(58), dp(58)));
        if (clip != null && clip.complete && !clip.uncertain) thumbnail(image, clip);
        LinearLayout words = Ui.column(this); words.setPadding(dp(12), 0, dp(4), 0);
        words.addView(label(heading, 15, Ui.TEXT, true));
        TextView info = label(detail, 12, icon.equals("alert") ? Ui.AMBER : Ui.MUTED, false);
        info.setPadding(0, dp(6), 0, 0); words.addView(info);
        row.addView(words, new LinearLayout.LayoutParams(0, -2, 1));
        ImageButton shareButton = Ui.iconButton(this, "share", s(icon.equals("shield") ? R.string.share_incident : R.string.share_clip) + " · " + heading, share);
        shareButton.setBackground(Ui.touch(this, Ui.SURFACE, 0, 12));
        boolean available = clip == null || clip.complete || clip.uncertain;
        shareButton.setEnabled(available); shareButton.setAlpha(available ? 1 : .3f);
        row.addView(shareButton, lp(dp(48), dp(48)));
        LinearLayout.LayoutParams params = lp(-1, -2); params.bottomMargin = dp(10); parent.addView(row, params);
    }

    private void thumbnail(ImageView target, RecordingStore.Segment segment) {
        String key = segment.file.getAbsolutePath(); target.setTag(key);
        Bitmap cached = thumbnailCache.get(key);
        if (cached != null) { target.setImageBitmap(cached); return; }
        List<ImageView> waiting = thumbnailPending.get(key);
        if (waiting != null) { waiting.add(target); return; }
        waiting = new ArrayList<>(); waiting.add(target); thumbnailPending.put(key, waiting);
        thumbnails.execute(() -> {
            Bitmap frame = null; MediaMetadataRetriever retriever = new MediaMetadataRetriever();
            try {
                retriever.setDataSource(key);
                frame = retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 160, 160);
            } catch (RuntimeException ignored) { }
            finally { try { retriever.release(); } catch (Exception ignored) { } }
            final Bitmap result = frame;
            main.post(() -> {
                List<ImageView> targets = thumbnailPending.remove(key);
                if (isDestroyed()) { if (result != null) result.recycle(); return; }
                if (result != null) {
                    thumbnailCache.put(key, result);
                    if (targets != null) for (ImageView image : targets)
                        if (key.equals(image.getTag())) image.setImageBitmap(result);
                }
            });
        });
    }

    private String tailState(RecordingStore.Incident incident, boolean countdown) {
        RecordingStore store = store(); long coverage = Long.MIN_VALUE;
        if (store != null) for (RecordingStore.Segment clip : store.segmentsForIncident(incident.id))
            if (clip.complete && !clip.uncertain) coverage = Math.max(coverage, clip.endMs);
        if (coverage >= incident.endMs) return s(R.string.protected_label);
        if (service == null || !service.isRecording()) return s(R.string.tail_partial);
        long remaining = incident.endMs - service.timelineNow();
        if (remaining <= 0) return s(R.string.tail_finalizing);
        return countdown ? getString(R.string.tail_pending, (remaining + 999) / 1000) : s(R.string.tail_recording);
    }

    private void showIncident(RecordingStore.Incident incident) {
        if (store() == null) { toast(s(R.string.storage_unavailable)); return; }
        LinearLayout content = Ui.column(this); padding(content, 20);
        Dialog dialog = sheet(s(R.string.incident_title), content);
        content.addView(label(date(incident.endMs - RetentionPolicy.TAIL_MS), 23, Ui.TEXT, true));
        TextView tail = label(tailState(incident, true), 14, Ui.MINT, false);
        tail.setPadding(0, dp(10), 0, dp(16)); content.addView(tail);
        content.addView(Ui.button(this, s(R.string.share_incident), "share", true, () -> shareIncident(incident)), lp(-1, -2));
        TextView explanation = label(s(R.string.clips_footer), 12, Ui.MUTED, false);
        explanation.setPadding(0, dp(16), 0, dp(16)); content.addView(explanation);
        LinearLayout list = Ui.column(this); content.addView(list);
        Runnable update = new Runnable() {
            String stamp = "";
            @Override public void run() {
                if (!dialog.isShowing()) return;
                if (store() == null) { main.postDelayed(this, 1000); return; }
                tail.setText(tailState(incident, true));
                List<RecordingStore.Segment> clips = store().segmentsForIncident(incident.id);
                StringBuilder next = new StringBuilder();
                for (RecordingStore.Segment clip : clips) next.append(clip.file.getName()).append(clip.complete).append(clip.uncertain);
                if (!stamp.equals(next.toString())) {
                    stamp = next.toString(); list.removeAllViews();
                    for (RecordingStore.Segment clip : clips) footageRow(list, date(clip.startMs),
                        s(clip.uncertain ? R.string.clip_recovery : clip.complete ? R.string.clip_ready : R.string.clip_recording),
                        "play", clip, () -> play(clip), () -> share(Collections.singletonList(clip)));
                }
                main.postDelayed(this, 1000);
            }
        };
        update.run();
    }

    private void play(RecordingStore.Segment segment) {
        if (!segment.complete && !segment.uncertain) { toast(s(R.string.wait_clip)); return; }
        LinearLayout content = Ui.column(this); padding(content, 16);
        Dialog player = sheet(date(segment.startMs), content);
        VideoView video = new VideoView(this);
        content.addView(video, lp(-1, dp(getResources().getConfiguration().orientation == 2 ? 220 : 360)));
        Ui.gap(content, 16);
        content.addView(Ui.button(this, s(R.string.share_clip), "share", false, () -> share(Collections.singletonList(segment))), lp(-1, -2));
        MediaController controls = new MediaController(this);
        controls.setAnchorView(video); video.setMediaController(controls);
        player.setOnDismissListener(d -> { video.stopPlayback(); dialogs.remove(player); });
        video.setOnPreparedListener(media -> video.start());
        video.setOnErrorListener((media, what, extra) -> { toast(s(R.string.play_error)); player.dismiss(); return true; });
        video.setVideoURI(RecordingProvider.uriFor(segment.file));
    }

    private void showSettings() {
        LinearLayout content = Ui.column(this); padding(content, 20);
        sheet(s(R.string.settings), content);
        Switch audioSwitch = new Switch(this);
        audioSwitch.setText(s(R.string.record_audio)); audioSwitch.setTextColor(Ui.TEXT);
        audioSwitch.setTextSize(17); audioSwitch.setMinHeight(dp(56));
        audioSwitch.setChecked(preferences.getBoolean("audio", false));
        boolean active = service != null && service.isRecording();
        audioSwitch.setEnabled(!active); content.addView(audioSwitch, lp(-1, -2));
        TextView audioHelp = label(s(active ? R.string.audio_locked : R.string.audio_description), 13, Ui.MUTED, false);
        content.addView(audioHelp); Ui.gap(content, 26);
        audioSwitch.setOnCheckedChangeListener((button, checked) -> { preferences.edit().putBoolean("audio", checked).apply(); renderState(); });
        content.addView(label(s(R.string.storage_heading), 17, Ui.TEXT, true)); Ui.gap(content, 10);
        long bytes = 0;
        if (store() != null) for (RecordingStore.Segment segment : store().listSegments()) bytes += segment.file.length();
        content.addView(label(getString(R.string.storage_format, android.text.format.Formatter.formatShortFileSize(this, bytes),
            android.text.format.Formatter.formatShortFileSize(this, getFilesDir().getUsableSpace())), 14, Ui.MINT, false));
        content.addView(note(R.string.storage_body)); Ui.gap(content, 26);
        content.addView(label(s(R.string.privacy_heading), 17, Ui.TEXT, true));
        content.addView(note(R.string.privacy_body)); Ui.gap(content, 26);
        content.addView(label(s(R.string.about_heading), 17, Ui.TEXT, true));
        content.addView(note(R.string.about_body));
    }

    private TextView note(int value) {
        TextView view = label(s(value), 14, Ui.MUTED, false); view.setPadding(0, dp(10), 0, dp(8)); return view;
    }

    private Dialog sheet(String heading, LinearLayout content) {
        Dialog dialog = new Dialog(this); dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        LinearLayout panel = Ui.column(this); panel.setBackground(Ui.shape(this, Ui.BG, Ui.LINE, 24));
        LinearLayout header = Ui.row(this); header.setPadding(dp(20), dp(12), dp(12), dp(12));
        header.addView(label(heading, 18, Ui.TEXT, true), new LinearLayout.LayoutParams(0, -2, 1));
        header.addView(Ui.iconButton(this, "close", s(R.string.close), dialog::dismiss), lp(dp(48), dp(48)));
        panel.addView(header);
        ScrollView scrolling = scroll(content); panel.addView(scrolling, new LinearLayout.LayoutParams(-1, 0, 1));
        dialog.setContentView(panel); track(dialog); dialog.show();
        Window window = dialog.getWindow();
        if (window != null) {
            window.setBackgroundDrawableResource(android.R.color.transparent);
            window.setLayout(-1, Math.max(dp(200), root.getHeight() - dp(36)));
            window.setGravity(Gravity.BOTTOM);
        }
        return dialog;
    }

    private void track(Dialog dialog) {
        dialogs.add(dialog); dialog.setOnDismissListener(d -> dialogs.remove(dialog));
    }

    private void requestStop() {
        long remaining = 0;
        if (store() != null && service != null) for (RecordingStore.Incident incident : store().listIncidents())
            remaining = Math.max(remaining, incident.endMs - service.timelineNow());
        if (remaining > 0) {
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle(R.string.stop_tail_heading)
                .setMessage(getString(R.string.stop_tail_body, (remaining + 999) / 1000))
                .setNegativeButton(R.string.keep_recording, null)
                .setPositiveButton(R.string.stop_now, (d, which) -> sendAction(RecordingService.ACTION_STOP)).create();
            track(dialog); dialog.show();
        } else sendAction(RecordingService.ACTION_STOP);
    }

    private void shareIncident(RecordingStore.Incident incident) {
        if (store() == null) { toast(s(R.string.storage_unavailable)); return; }
        if (service != null && service.isRecording() && !tailState(incident, false).equals(s(R.string.protected_label))) {
            AlertDialog dialog = new AlertDialog.Builder(this).setTitle(R.string.share_pending_heading)
                .setMessage(R.string.share_pending_body).setNegativeButton(R.string.wait, null)
                .setPositiveButton(R.string.share_available, (d, which) -> { if (store() != null) share(store().segmentsForIncident(incident.id)); }).create();
            track(dialog); dialog.show();
        } else share(store().segmentsForIncident(incident.id));
    }

    private void share(List<RecordingStore.Segment> segments) {
        ArrayList<Uri> uris = new ArrayList<>();
        for (RecordingStore.Segment segment : segments)
            if ((segment.complete || segment.uncertain) && segment.file.isFile() && segment.file.length() > 0)
                uris.add(RecordingProvider.uriFor(segment.file));
        if (uris.isEmpty()) { toast(s(R.string.no_clips)); return; }
        Intent intent = new Intent(uris.size() == 1 ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE).setType("video/mp4");
        if (uris.size() == 1) intent.putExtra(Intent.EXTRA_STREAM, uris.get(0));
        else intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        ClipData data = ClipData.newUri(getContentResolver(), s(R.string.app_title), uris.get(0));
        for (int i = 1; i < uris.size(); i++) data.addItem(new ClipData.Item(uris.get(i)));
        intent.setClipData(data); intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try { startActivity(Intent.createChooser(intent, s(R.string.share_incident))); }
        catch (ActivityNotFoundException error) { toast(s(R.string.no_share_app)); }
    }

    private boolean cameraGranted() { return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED; }
    private boolean cameraPermanentlyDenied() {
        return !cameraGranted() && preferences.getBoolean("cameraAsked", false) && !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA);
    }
    private void requestCamera() {
        if (cameraPermanentlyDenied()) {
            startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
        } else {
            preferences.edit().putBoolean("cameraAsked", true).apply();
            requestPermissions(new String[]{Manifest.permission.CAMERA}, PREVIEW_PERMISSION);
        }
    }
    private void requestStart() {
        if (cameraPermanentlyDenied()) { requestCamera(); return; }
        List<String> missing = new ArrayList<>();
        if (!cameraGranted()) missing.add(Manifest.permission.CAMERA);
        if (preferences.getBoolean("audio", false) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            missing.add(Manifest.permission.RECORD_AUDIO);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            missing.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!missing.isEmpty()) {
            startAfterPermission = true;
            if (missing.contains(Manifest.permission.CAMERA)) preferences.edit().putBoolean("cameraAsked", true).apply();
            requestPermissions(missing.toArray(new String[0]), START_PERMISSION);
        } else startRecording();
    }
    @Override public void onRequestPermissionsResult(int code, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(code, permissions, grants);
        if (code != START_PERMISSION && code != PREVIEW_PERMISSION) return;
        if (!cameraGranted()) { startAfterPermission = false; toast(s(R.string.camera_denied)); renderState(); return; }
        attachPreview();
        if (code == START_PERMISSION && startAfterPermission) {
            startAfterPermission = false;
            if (preferences.getBoolean("audio", false) && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                preferences.edit().putBoolean("audio", false).apply(); toast(s(R.string.audio_denied));
            }
            startRecording();
        }
        renderState();
    }
    private void startRecording() {
        if (!visible || service == null) return;
        Intent intent = new Intent(this, RecordingService.class).setAction(RecordingService.ACTION_START)
            .putExtra("microphone", preferences.getBoolean("audio", false));
        try { starting = true; startForegroundService(intent); renderState(); }
        catch (RuntimeException error) { starting = false; toast(s(R.string.start_failed)); renderState(); }
    }
    private void sendAction(String action) {
        try { startService(new Intent(this, RecordingService.class).setAction(action)); }
        catch (RuntimeException error) { toast(s(R.string.recorder_unavailable)); }
    }

    @Override protected void onStart() {
        super.onStart(); visible = true;
        bound = bindService(new Intent(this, RecordingService.class), connection, BIND_AUTO_CREATE);
        main.removeCallbacks(refresh); refresh.run();
    }
    @Override protected void onStop() {
        visible = false; main.removeCallbacks(refresh);
        if (service != null && preview.isAvailable()) service.detachPreview(preview.getSurfaceTexture(), false);
        if (bound) { unbindService(connection); bound = false; }
        service = null; super.onStop();
    }
    @Override protected void onDestroy() {
        for (Dialog dialog : new ArrayList<>(dialogs)) dialog.dismiss();
        main.removeCallbacksAndMessages(null); thumbnails.shutdownNow();
        super.onDestroy();
    }
    @Override protected void onSaveInstanceState(Bundle state) {
        state.putBoolean("library", library); state.putInt("filter", filter);
        state.putBoolean("startAfterPermission", startAfterPermission); super.onSaveInstanceState(state);
    }
    @Override public void onBackPressed() {
        if (library) selectTab(false); else super.onBackPressed();
    }
    private void attachPreview() {
        if (visible && !library && service != null && preview.isAvailable() && cameraGranted()) {
            previewOwner = service;
            service.setPreview(preview.getSurfaceTexture(), getWindowManager().getDefaultDisplay().getRotation());
            transformPreview();
        }
    }
    private void transformPreview() {
        if (service == null || preview.getWidth() == 0 || preview.getHeight() == 0) return;
        Size size = service.getVideoSize();
        int rotation = (service.getSensorOrientation() - getWindowManager().getDefaultDisplay().getRotation() * 90 + 360) % 360;
        float w = preview.getWidth(), h = preview.getHeight();
        float rw = rotation % 180 == 0 ? size.getWidth() : size.getHeight();
        float rh = rotation % 180 == 0 ? size.getHeight() : size.getWidth();
        float fit = Math.min(w / rw, h / rh);
        Matrix transform = new Matrix();
        transform.setScale(size.getWidth() / w, size.getHeight() / h, w / 2, h / 2);
        transform.postRotate(rotation, w / 2, h / 2);
        transform.postScale(fit, fit, w / 2, h / 2);
        preview.setTransform(transform);
    }
    @Override public void onSurfaceTextureAvailable(SurfaceTexture texture, int width, int height) { attachPreview(); }
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture texture, int width, int height) { transformPreview(); }
    @Override public void onSurfaceTextureUpdated(SurfaceTexture texture) { }
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture texture) {
        RecordingService owner = service == null ? previewOwner : service; previewOwner = null;
        return owner == null || !owner.detachPreview(texture, true);
    }
    private RecordingStore store() { return service == null ? null : service.getStore(); }
    private int previewHeight() {
        int screen = Math.round(getResources().getDisplayMetrics().heightPixels / getResources().getDisplayMetrics().density);
        if (landscape) return Math.max(120, Math.min(210, screen - 266));
        return Math.max(cameraGranted() ? 180 : 230, Math.min(280, screen - 560));
    }
    private String date(long millis) {
        Calendar today = Calendar.getInstance(), day = Calendar.getInstance(); day.setTimeInMillis(millis);
        String time = DateFormat.getTimeInstance(DateFormat.SHORT).format(new Date(millis));
        if (today.get(Calendar.YEAR) == day.get(Calendar.YEAR) && today.get(Calendar.DAY_OF_YEAR) == day.get(Calendar.DAY_OF_YEAR))
            return getString(R.string.today_time, time);
        today.add(Calendar.DAY_OF_YEAR, -1);
        if (today.get(Calendar.YEAR) == day.get(Calendar.YEAR) && today.get(Calendar.DAY_OF_YEAR) == day.get(Calendar.DAY_OF_YEAR))
            return getString(R.string.yesterday_time, time);
        return new SimpleDateFormat("d MMM · HH:mm", Locale.getDefault()).format(new Date(millis));
    }
    private String duration(long millis) {
        long seconds = Math.max(0, millis / 1000);
        return seconds >= 3600 ? String.format(Locale.getDefault(), "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String.format(Locale.getDefault(), "%02d:%02d", seconds / 60, seconds % 60);
    }
    private int dp(int value) { return Ui.dp(this, value); }
    private String s(int value) { return getString(value); }
    private TextView label(String value, int size, int color, boolean bold) { return Ui.text(this, value, size, color, bold); }
    private LinearLayout.LayoutParams lp(int w, int h) { return new LinearLayout.LayoutParams(w, h); }
    private void padding(View view, int amount) { view.setPadding(dp(amount), dp(amount), dp(amount), dp(amount)); }
    private ScrollView scroll(View child) { ScrollView view = new ScrollView(this); view.setFillViewport(true); view.setClipToPadding(false); view.addView(child); return view; }
    private void toast(String message) { Toast.makeText(this, message, Toast.LENGTH_SHORT).show(); }
}
