package com.ableh.dokumentasibarangpecah

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channel = "dokumentasi_barang_pecah/media_store"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            if (call.method != "saveImage") { result.notImplemented(); return@setMethodCallHandler }
            val bytes = call.argument<ByteArray>("bytes")
            val name = call.argument<String>("displayName") ?: "foto.jpg"
            val relative = call.argument<String>("relativePath") ?: "Pictures/Dokumentasi Barang Pecah"
            if (bytes == null) { result.error("NO_BYTES", "Data foto kosong", null); return@setMethodCallHandler }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, name)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, relative)
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("MediaStore insert gagal")
                    try {
                        contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                            ?: throw IllegalStateException("Output MediaStore tidak tersedia")
                        val done = ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }
                        contentResolver.update(uri, done, null, null)
                    } catch (e: Exception) {
                        contentResolver.delete(uri, null, null)
                        throw e
                    }
                } else {
                    val pictures = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                    val folder = File(pictures, "Dokumentasi Barang Pecah")
                    if (!folder.exists() && !folder.mkdirs()) throw IllegalStateException("Folder Galeri gagal dibuat")
                    val file = File(folder, name)
                    FileOutputStream(file).use { it.write(bytes) }
                    MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), arrayOf("image/jpeg"), null)
                }
                result.success(true)
            } catch (e: Exception) {
                result.error("SAVE_FAILED", e.message, null)
            }
        }
    }
}
