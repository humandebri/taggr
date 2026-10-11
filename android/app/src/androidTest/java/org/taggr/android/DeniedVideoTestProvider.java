package org.taggr.android;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Test-APK-only Binder fixture. Uses platform Java because the independent test APK process
 * does not inherit the target APK's Kotlin runtime.
 */
public final class DeniedVideoTestProvider extends ContentProvider {
    private final AtomicInteger attempts = new AtomicInteger();

    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "video/mp4"; }

    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) {
        attempts.incrementAndGet();
        throw new SecurityException("Fixture video permission is no longer available");
    }

    @Override public Bundle call(String method, String arg, Bundle extras) {
        if (!"attempts".equals(method)) return super.call(method, arg, extras);
        Bundle result = new Bundle();
        result.putInt("count", attempts.get());
        return result;
    }

    @Override public Cursor query(Uri uri, String[] projection, String selection,
                                  String[] selectionArgs, String sortOrder) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { return null; }
    @Override public int update(Uri uri, ContentValues values, String selection,
                                String[] selectionArgs) { return 0; }
    @Override public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }
}
