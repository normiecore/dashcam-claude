package com.daz.dashcam;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;

/** Android's explicit directory fsync keeps manifest replacement durable. */
public final class AndroidStorage {
    private AndroidStorage() { }
    public static RecordingStore open(File directory) throws IOException {
        return new RecordingStore(directory, root -> {
            FileDescriptor descriptor = null;
            try {
                if (!root.isDirectory()) throw new IOException("Recording directory unavailable");
                descriptor = Os.open(root.getAbsolutePath(), OsConstants.O_RDONLY, 0);
                Os.fsync(descriptor);
            } catch (ErrnoException error) {
                throw new IOException("Cannot sync recording directory", error);
            } finally {
                if (descriptor != null) {
                    try { Os.close(descriptor); }
                    catch (ErrnoException error) { throw new IOException("Cannot close recording directory", error); }
                }
            }
        });
    }
}
