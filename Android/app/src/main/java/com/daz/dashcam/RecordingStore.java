package com.daz.dashcam;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;

/** Durable index. The recorder and UI share one instance; all operations are serialized. */
public final class RecordingStore {
    /** Android supplies an Os.open/fsync adapter; desktop tests use Java NIO. */
    public interface DirectorySync { void sync(File directory) throws IOException; }
    public static final class Segment {
        public final String id;
        public final File file;
        public final long startMs, endMs;
        public final boolean complete, uncertain;
        private Segment(String id, File file, long start, long end, boolean complete, boolean uncertain) {
            this.id = id; this.file = file; this.startMs = start; this.endMs = end;
            this.complete = complete; this.uncertain = uncertain;
        }
    }
    public static final class Incident {
        public final String id;
        public final long startMs, endMs;
        private Incident(String id, long start, long end) {
            this.id = id; this.startMs = start; this.endMs = end;
        }
    }
    private final File root, manifest;
    private final DirectorySync directorySync;
    private boolean writeFailed;
    private final Map<String, Segment> segments = new LinkedHashMap<>();
    private final Map<String, Incident> incidents = new LinkedHashMap<>();

    public RecordingStore(File directory) throws IOException {
        this(directory, path -> {
            try (FileChannel channel = FileChannel.open(path.toPath(), StandardOpenOption.READ)) {
                channel.force(true);
            }
        });
    }

    public RecordingStore(File directory, DirectorySync sync) throws IOException {
        if (sync == null) throw new IllegalArgumentException("Directory sync is required");
        directorySync = sync;
        root = directory.getCanonicalFile();
        if (!root.isDirectory() && !root.mkdirs()) throw new IOException("Cannot create recording directory");
        manifest = new File(root, "manifest.properties");
        if (manifest.exists()) load(); // Malformed metadata fails closed: never clear or prune it.
        recover();
        persist();
    }

    public synchronized Segment beginSegment(long nowMs) throws IOException {
        requireWritable();
        if (nowMs < 0) throw new IOException("Invalid recording timestamp");
        String id = UUID.randomUUID().toString();
        Segment segment = new Segment(id, new File(root, id + ".mp4"), nowMs, nowMs, false, false);
        segments.put(id, segment);
        persist(); // Register intent before the recorder opens the file.
        return segment;
    }

    public synchronized void completeSegment(String id, long endMs, boolean successful) throws IOException {
        requireWritable();
        Segment old = segments.get(id);
        if (old == null) throw new IOException("Unknown recording segment");
        boolean valid = successful && endMs >= old.startMs && old.file.isFile() && old.file.length() > 0;
        segments.put(id, new Segment(id, old.file, old.startMs, Math.max(old.startMs, endMs), valid, !valid));
        persist();
    }

    public synchronized Incident saveIncident(long nowMs) throws IOException {
        requireWritable();
        if (nowMs < 0 || nowMs > Long.MAX_VALUE - RetentionPolicy.TAIL_MS)
            throw new IOException("Invalid incident timestamp");
        Incident incident = new Incident(UUID.randomUUID().toString(), nowMs - RetentionPolicy.ROLLING_MS,
                nowMs + RetentionPolicy.TAIL_MS);
        incidents.put(incident.id, incident);
        persist(); // Protection is durable before reporting success to the user.
        return incident;
    }

    public synchronized boolean isWritable() { return !writeFailed; }

    public synchronized List<Segment> listSegments() { return new ArrayList<>(segments.values()); }
    public synchronized List<Incident> listIncidents() { return new ArrayList<>(incidents.values()); }

    public synchronized List<Segment> segmentsForIncident(String id) {
        Incident incident = incidents.get(id);
        List<Segment> result = new ArrayList<>();
        if (incident == null) return result;
        for (Segment segment : segments.values()) if (belongs(segment, incident)) result.add(segment);
        return result;
    }

    public synchronized boolean hasEnoughSpace(long minimumBytes) {
        return minimumBytes >= 0 && root.getUsableSpace() >= minimumBytes;
    }

    public synchronized boolean isProtected(String segmentId) {
        Segment segment = segments.get(segmentId);
        if (segment == null) return false;
        for (Incident incident : incidents.values()) if (belongs(segment, incident)) return true;
        return false;
    }

    /** Deletes only completed, validated, expired and unprotected files. Never frees pinned footage. */
    public synchronized int prune(long nowMs) throws IOException {
        persist(); // If metadata cannot be saved, no footage is deleted.
        int removed = 0;
        for (Segment segment : new ArrayList<>(segments.values())) {
            if (!RetentionPolicy.canDelete(segment.startMs, segment.endMs, segment.complete,
                    segment.uncertain, isProtected(segment.id), nowMs)) continue;
            if (segment.file.exists() && !segment.file.delete()) throw new IOException("Cannot remove expired segment");
            segments.remove(segment.id);
            removed++;
        }
        if (removed > 0) persist();
        return removed;
    }

    private boolean belongs(Segment segment, Incident incident) {
        long end = segment.complete ? segment.endMs : Long.MAX_VALUE;
        return RetentionPolicy.overlaps(segment.startMs, end, incident.startMs, incident.endMs);
    }

    private void recover() throws IOException {
        for (Segment old : new ArrayList<>(segments.values())) {
            if (!old.file.exists()) { segments.remove(old.id); continue; }
            if (!old.complete) segments.put(old.id, new Segment(old.id, old.file, old.startMs, old.endMs, false, true));
        }
        File[] files = root.listFiles();
        if (files == null) throw new IOException("Cannot inspect recordings");
        for (File file : files) {
            if (!file.isFile() || !file.getName().endsWith(".mp4")) continue;
            String id = file.getName().substring(0, file.getName().length() - 4);
            if (!segments.containsKey(id)) {
                // An unknown recording may contain incident footage. Keep it until reviewed.
                segments.put(id, new Segment(id, file, file.lastModified(), file.lastModified(), false, true));
            }
        }
    }

    private void load() throws IOException {
        Properties properties = new Properties();
        try {
            try (FileInputStream input = new FileInputStream(manifest)) { properties.load(input); }
            if (!"1".equals(properties.getProperty("version"))) throw new IllegalArgumentException("Unknown manifest version");
            int segmentCount = count(properties, "segments");
            int incidentCount = count(properties, "incidents");
            for (int i = 0; i < segmentCount; i++) {
                String prefix = "segment." + i + ".";
                String id = properties.getProperty(prefix + "id");
                if (id == null || id.isEmpty() || id.contains("/") || id.contains("\\") || id.contains(".."))
                    throw new IllegalArgumentException("Unsafe segment ID");
                long start = number(properties, prefix + "start"), end = number(properties, prefix + "end");
                if (start < 0 || end < start || segments.containsKey(id)) throw new IllegalArgumentException("Invalid segment");
                segments.put(id, new Segment(id, new File(root, id + ".mp4"), start, end,
                        bool(properties, prefix + "complete"), bool(properties, prefix + "uncertain")));
            }
            for (int i = 0; i < incidentCount; i++) {
                String prefix = "incident." + i + ".";
                String id = properties.getProperty(prefix + "id");
                long start = number(properties, prefix + "start"), end = number(properties, prefix + "end");
                if (id == null || id.isEmpty() || end < start || incidents.containsKey(id))
                    throw new IllegalArgumentException("Invalid incident");
                incidents.put(id, new Incident(id, start, end));
            }
        } catch (IllegalArgumentException exception) { throw new IOException("Recording manifest damaged; footage retained", exception); }
    }

    private static int count(Properties p, String key) {
        int n = Integer.parseInt(p.getProperty(key));
        if (n < 0 || n > 100_000) throw new IllegalArgumentException("Invalid manifest count");
        return n;
    }
    private static long number(Properties p, String key) { return Long.parseLong(p.getProperty(key)); }
    private static boolean bool(Properties p, String key) {
        String value = p.getProperty(key);
        if (!"true".equals(value) && !"false".equals(value)) throw new IllegalArgumentException("Invalid boolean");
        return Boolean.parseBoolean(value);
    }

    private void requireWritable() throws IOException {
        if (writeFailed) throw new IOException("Recording metadata write failed; restart required, footage retained");
    }

    private void persist() throws IOException {
        requireWritable();
        try {
            writeManifest();
        } catch (IOException exception) {
            writeFailed = true;
            throw exception;
        } catch (RuntimeException exception) {
            writeFailed = true;
            throw new IOException("Recording metadata write failed; footage retained", exception);
        }
    }

    private void writeManifest() throws IOException {
        Properties properties = new Properties();
        properties.setProperty("version", "1");
        properties.setProperty("segments", Integer.toString(segments.size()));
        properties.setProperty("incidents", Integer.toString(incidents.size()));
        int i = 0;
        for (Segment s : segments.values()) {
            String p = "segment." + i++ + ".";
            properties.setProperty(p + "id", s.id);
            properties.setProperty(p + "start", Long.toString(s.startMs));
            properties.setProperty(p + "end", Long.toString(s.endMs));
            properties.setProperty(p + "complete", Boolean.toString(s.complete));
            properties.setProperty(p + "uncertain", Boolean.toString(s.uncertain));
        }
        i = 0;
        for (Incident incident : incidents.values()) {
            String p = "incident." + i++ + ".";
            properties.setProperty(p + "id", incident.id);
            properties.setProperty(p + "start", Long.toString(incident.startMs));
            properties.setProperty(p + "end", Long.toString(incident.endMs));
        }
        File pending = new File(root, "manifest.pending");
        try (FileOutputStream output = new FileOutputStream(pending)) {
            properties.store(output, "Dashcam recording index");
            output.getFD().sync();
        }
        try {
            Files.move(pending.toPath(), manifest.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            // Persist the directory entry too; rename alone is not durable across power loss.
            directorySync.sync(root);
        } catch (AtomicMoveNotSupportedException unsupported) {
            // Stay conservative: without atomic replacement, keep the previous manifest and all media.
            throw new IOException("Recording storage requires atomic manifest replacement", unsupported);
        }
    }
}
