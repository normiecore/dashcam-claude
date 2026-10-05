package com.daz.dashcam;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;
import java.nio.file.Files;
import java.util.Random;

public final class RecordingStoreTest {
    private static int checks;
    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }
    private static File directory() throws Exception { return Files.createTempDirectory("dashcam-core-").toFile(); }
    private static void media(File file) throws Exception {
        try (FileOutputStream out = new FileOutputStream(file)) { out.write(new byte[] {1, 2, 3, 4}); }
    }
    private static RecordingStore.Segment segment(RecordingStore store, long start) throws Exception {
        RecordingStore.Segment segment = store.beginSegment(start);
        media(segment.file);
        store.completeSegment(segment.id, start + 10_000, true);
        return segment;
    }
    public static void main(String[] args) throws Exception {
        boundaries(); incidentAndTail(); overlapping(); recovery(); failures(); failureLatch(); metadataValidation(); randomPolicy(); soak();
        System.out.println("PASS: " + checks + " Android retention/storage assertions");
    }
    private static void boundaries() throws Exception {
        check(!RetentionPolicy.canDelete(-1, 1, true, false, false, 1_000_000), "Negative segment metadata never authorizes deletion");
        check(!RetentionPolicy.canDelete(0, 1, true, false, false, Long.MIN_VALUE), "Negative clock cannot overflow expiry arithmetic");
        RecordingStore store = new RecordingStore(directory());
        RecordingStore.Segment oldest = segment(store, 1_000_000);
        check(store.prune(1_310_000) == 0, "Keep exact five-minute boundary");
        check(oldest.file.exists(), "Boundary media exists");
        check(store.prune(1_310_001) == 1, "Expire older-than-five-minute media");
        check(!oldest.file.exists(), "Expired unpinned media removed");
    }
    private static void incidentAndTail() throws Exception {
        File dir = directory();
        RecordingStore store = new RecordingStore(dir);
        RecordingStore.Segment before = segment(store, 700_000);
        RecordingStore.Segment outside = segment(store, 660_000);
        RecordingStore.Incident incident = store.saveIncident(1_000_000);
        RecordingStore.Segment tail = segment(store, 1_020_000);
        RecordingStore.Segment after = segment(store, 1_040_000);
        check(incident.startMs == 700_000 && incident.endMs == 1_030_000, "Incident has 300s prior and 30s tail");
        check(store.isProtected(before.id), "Past footage pinned");
        check(store.isProtected(tail.id), "Future tail pinned");
        check(!store.isProtected(after.id), "Post-tail footage unpinned");
        check(store.prune(2_000_000) == 2, "Only unpinned media expires");
        check(before.file.exists() && tail.file.exists(), "Protected media remains");
        check(!outside.file.exists() && !after.file.exists(), "Unprotected expired media removed");
        store = new RecordingStore(dir);
        check(store.isProtected(before.id) && store.isProtected(tail.id), "Pins survive reopening");
        check(store.segmentsForIncident(incident.id).size() == 2, "Incident lists protected segments");
    }
    private static void overlapping() throws Exception {
        RecordingStore store = new RecordingStore(directory());
        RecordingStore.Segment shared = segment(store, 990_000);
        RecordingStore.Incident first = store.saveIncident(1_000_000);
        RecordingStore.Incident second = store.saveIncident(1_020_000);
        check(store.segmentsForIncident(first.id).size() == 1, "First overlapping incident owns segment");
        check(store.segmentsForIncident(second.id).size() == 1, "Second overlapping incident owns same segment");
        check(store.prune(3_000_000) == 0 && shared.file.exists(), "Overlapping incidents preserve shared footage");
    }
    private static void recovery() throws Exception {
        File dir = directory();
        RecordingStore store = new RecordingStore(dir);
        RecordingStore.Segment interrupted = store.beginSegment(100_000);
        media(interrupted.file);
        File orphan = new File(dir, "unknown-recording.mp4");
        media(orphan);
        store = new RecordingStore(dir);
        check(store.listSegments().size() == 2, "Interrupted and orphan media recovered");
        for (RecordingStore.Segment s : store.listSegments()) check(s.uncertain, "Recovery marks uncertain media");
        check(store.prune(Long.MAX_VALUE / 2) == 0, "Never prune uncertain media");
        check(interrupted.file.exists() && orphan.exists(), "Recovery originals retained");
        RecordingStore secondOpen = new RecordingStore(dir);
        check(secondOpen.prune(Long.MAX_VALUE / 2) == 0, "Uncertainty remains durable");
    }
    private static void failures() throws Exception {
        File dir = directory();
        RecordingStore store = new RecordingStore(dir);
        RecordingStore.Segment failed = store.beginSegment(100_000);
        media(failed.file);
        store.completeSegment(failed.id, 110_000, false);
        check(store.prune(9_000_000) == 0 && failed.file.exists(), "Recorder error retains uncertain bytes");
        check(!store.hasEnoughSpace(Long.MAX_VALUE), "Impossible space requirement stops recording");
        check(!store.hasEnoughSpace(-1), "Invalid space requirement rejected");
        File manifest = new File(dir, "manifest.properties");
        try (FileOutputStream out = new FileOutputStream(manifest)) { out.write("version=1\nsegments=garbage\nincidents=0\n".getBytes("UTF-8")); }
        boolean refused = false;
        try { new RecordingStore(dir); } catch (java.io.IOException expected) { refused = true; }
        check(refused && failed.file.exists(), "Corrupt manifest fails closed and preserves media");

        File other = directory();
        store = new RecordingStore(other);
        RecordingStore.Segment old = segment(store, 1_000);
        File pending = new File(other, "manifest.pending");
        check(pending.mkdir(), "Inject metadata write failure");
        refused = false;
        try { store.prune(9_000_000); } catch (java.io.IOException expected) { refused = true; }
        check(refused && old.file.exists(), "Metadata failure prevents deletion");
    }
    private static void failureLatch() throws Exception {
        File dir = directory();
        AtomicBoolean fail = new AtomicBoolean(false);
        RecordingStore store = new RecordingStore(dir, directory -> {
            if (fail.get()) throw new java.io.IOException("Injected directory fsync failure");
            try (java.nio.channels.FileChannel channel = java.nio.channels.FileChannel.open(
                    directory.toPath(), java.nio.file.StandardOpenOption.READ)) { channel.force(true); }
        });
        RecordingStore.Segment footage = segment(store, 1_000_000);
        fail.set(true);
        boolean refused = false;
        try { store.saveIncident(1_010_000); } catch (java.io.IOException expected) { refused = true; }
        check(refused && !store.isWritable(), "Directory fsync failure latches store unwritable");
        check(store.isProtected(footage.id), "Failed protection save retains conservative in-memory protection");
        fail.set(false);
        refused = false;
        try { store.prune(9_000_000); } catch (java.io.IOException expected) { refused = true; }
        check(refused && footage.file.exists(), "Recovered disk access never clears write-failure latch");
        refused = false;
        try { store.beginSegment(9_000_000); } catch (java.io.IOException expected) { refused = true; }
        check(refused, "Recording cannot restart through a failed store");
        RecordingStore reopened = new RecordingStore(dir);
        check(reopened.isWritable() && reopened.isProtected(footage.id), "Restart safely reloads actually written incident");
    }
    private static void metadataValidation() throws Exception {
        File dir = directory();
        RecordingStore store = new RecordingStore(dir);
        boolean refused = false;
        try { store.beginSegment(-1); } catch (java.io.IOException expected) { refused = true; }
        check(refused && store.listSegments().isEmpty(), "Negative recording timestamps rejected before mutation");
        refused = false;
        try { store.saveIncident(Long.MAX_VALUE); } catch (java.io.IOException expected) { refused = true; }
        check(refused && store.listIncidents().isEmpty(), "Overflowing incident tail rejected before mutation");
        for (boolean complete : new boolean[] {false, true}) {
            for (boolean uncertain : new boolean[] {false, true}) {
                File caseDir = directory();
                RecordingStore caseStore = new RecordingStore(caseDir);
                RecordingStore.Segment recorded = segment(caseStore, 1_000_000);
                File manifest = new File(caseDir, "manifest.properties");
                Properties p = new Properties();
                try (FileInputStream input = new FileInputStream(manifest)) { p.load(input); }
                p.setProperty("segment.0.complete", Boolean.toString(complete));
                p.setProperty("segment.0.uncertain", Boolean.toString(uncertain));
                try (FileOutputStream output = new FileOutputStream(manifest)) { p.store(output, "fixture"); }
                caseStore = new RecordingStore(caseDir);
                int removed = caseStore.prune(9_000_000);
                check(removed == (complete && !uncertain ? 1 : 0), "All completeness/uncertainty combinations stay conservative");
                if (!complete || uncertain) check(recorded.file.exists(), "Uncertain or incomplete bytes survive");
            }
        }
        RecordingStore.Segment recorded = segment(store, 1_000_000);
        File manifest = new File(dir, "manifest.properties");
        Properties p = new Properties();
        try (FileInputStream input = new FileInputStream(manifest)) { p.load(input); }
        p.setProperty("segment.0.start", "-1");
        try (FileOutputStream output = new FileOutputStream(manifest)) { p.store(output, "fixture"); }
        refused = false;
        try { new RecordingStore(dir); } catch (java.io.IOException expected) { refused = true; }
        check(refused && recorded.file.exists(), "Negative persisted timestamps fail closed");
        p.setProperty("segment.0.start", "1000000");
        p.setProperty("segment.0.complete", "garbage");
        try (FileOutputStream output = new FileOutputStream(manifest)) { p.store(output, "fixture"); }
        refused = false;
        try { new RecordingStore(dir); } catch (java.io.IOException expected) { refused = true; }
        check(refused && recorded.file.exists(), "Corrupt completeness metadata fails closed");
    }
    private static void randomPolicy() {
        Random random = new Random(29);
        for (int i = 0; i < 100_000; i++) {
            long start = random.nextInt(2_000_000), end = start + random.nextInt(20_000);
            long now = random.nextInt(3_000_000);
            boolean complete = random.nextBoolean(), uncertain = random.nextBoolean(), pinned = random.nextBoolean();
            boolean result = RetentionPolicy.canDelete(start, end, complete, uncertain, pinned, now);
            check(!result || (complete && !uncertain && !pinned && now - end > 300_000), "Deletion safety property");
            long windowStart = random.nextInt(2_000_000), windowEnd = windowStart + 330_000;
            check(RetentionPolicy.overlaps(start, end, windowStart, windowEnd)
                    == !(end < windowStart || start > windowEnd), "Interval overlap property");
        }
    }
    private static void soak() throws Exception {
        RecordingStore store = new RecordingStore(directory());
        long epoch = 1_000_000;
        RecordingStore.Incident incident = null;
        for (int n = 0; n < 600; n++) {
            long start = epoch + n * 10_000L;
            segment(store, start);
            if (n == 40) incident = store.saveIncident(start + 10_000);
            store.prune(start + 10_000);
            check(store.listSegments().size() <= 66, "Rolling window stays bounded apart from protected incident");
        }
        check(incident != null && store.segmentsForIncident(incident.id).size() >= 33, "Incident persists after simulated 100-minute drive");
    }
}
