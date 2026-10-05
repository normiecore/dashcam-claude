package com.daz.dashcam;

import android.content.*;
import android.database.*;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.*;
import java.util.List;

/** Read-only, per-URI grants for private footage. Never exposes the manifest or arbitrary paths. */
public final class RecordingProvider extends ContentProvider {
    public static final String AUTHORITY = "com.daz.dashcam.recordings";
    public static Uri uriFor(File file) {
        return new Uri.Builder().scheme("content").authority(AUTHORITY).appendPath("file").appendPath(file.getName()).build();
    }
    @Override public boolean onCreate() { return true; }
    private File resolve(Uri uri) throws FileNotFoundException {
        List<String> path = uri.getPathSegments();
        if (!AUTHORITY.equals(uri.getAuthority()) || path.size() != 2 || !"file".equals(path.get(0))) throw new FileNotFoundException("Invalid footage URI");
        String name = path.get(1);
        if (!name.endsWith(".mp4") || name.contains("/") || name.contains("\\") || name.contains("..")) throw new FileNotFoundException("Invalid footage name");
        try {
            File root = new File(getContext().getFilesDir(), "recordings").getCanonicalFile();
            File file = new File(root, name).getCanonicalFile();
            if (!root.equals(file.getParentFile()) || !file.isFile()) throw new FileNotFoundException("Footage unavailable");
            return file;
        } catch (IOException error) { throw new FileNotFoundException("Footage unavailable"); }
    }
    @Override public String getType(Uri uri) { return "video/mp4"; }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read access only");
        return ParcelFileDescriptor.open(resolve(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        try {
            File file = resolve(uri);
            String[] columns = projection == null ? new String[] {OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE} : projection;
            MatrixCursor cursor = new MatrixCursor(columns, 1);
            Object[] row = new Object[columns.length];
            for (int i = 0; i < columns.length; i++) {
                if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) row[i] = file.getName();
                else if (OpenableColumns.SIZE.equals(columns[i])) row[i] = file.length();
            }
            cursor.addRow(row);
            return cursor;
        } catch (FileNotFoundException error) { return null; }
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException("Read-only footage"); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("Read-only footage"); }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { throw new UnsupportedOperationException("Read-only footage"); }
}
