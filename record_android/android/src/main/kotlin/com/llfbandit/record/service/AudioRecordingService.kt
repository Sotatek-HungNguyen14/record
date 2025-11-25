package com.llfbandit.record.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.VISIBILITY_PUBLIC
import com.llfbandit.record.R
import com.llfbandit.record.methodcall.RecorderWrapper
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class AudioRecordingService : Service() {
  companion object {
    private const val TAG = "AudioRecordingService"
    private const val CHANNEL_ID = "AudioRecordingChannel"
    private const val NOTIFICATION_ID = 1
    const val DEFAULT_TITLE = "Audio Capture"
    
    // Static reference to active recorders for cleanup on app termination
    @Volatile
    private var activeRecorders = mutableSetOf<RecorderWrapper>()
    private val recordersLock = Any()
    
    fun registerRecorder(recorder: RecorderWrapper) {
      synchronized(recordersLock) {
        activeRecorders.add(recorder)
        Log.d(TAG, "Registered recorder, total active: ${activeRecorders.size}")
      }
    }
    
    fun unregisterRecorder(recorder: RecorderWrapper) {
      synchronized(recordersLock) {
        activeRecorders.remove(recorder)
        Log.d(TAG, "Unregistered recorder, total active: ${activeRecorders.size}")
      }
    }
    
    fun getActiveRecorders(): List<RecorderWrapper> {
      synchronized(recordersLock) {
        return activeRecorders.toList()
      }
    }
    
    fun startService(context: Context) {
      try {
        val serviceIntent = Intent(context, AudioRecordingService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          context.startForegroundService(serviceIntent)
        } else {
          context.startService(serviceIntent)
        }
        Log.d(TAG, "Service start requested")
      } catch (e: Exception) {
        Log.e(TAG, "Failed to start service: ${e.message}", e)
      }
    }
    
    fun stopService(context: Context) {
      try {
        context.stopService(Intent(context, AudioRecordingService::class.java))
        Log.d(TAG, "Service stop requested")
      } catch (e: Exception) {
        Log.e(TAG, "Failed to stop service: ${e.message}", e)
      }
    }
  }

  private val binder: IBinder = LocalBinder()
  private lateinit var notificationManager: NotificationManager
  private val mainHandler = Handler(Looper.getMainLooper())

  inner class LocalBinder : Binder() {
//        fun getService(): AudioRecordingService = this@AudioRecordingService
  }

  override fun onBind(intent: Intent): IBinder {
    return binder
  }

  override fun onCreate() {
    super.onCreate()
    notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    createNotificationChannel()
    Log.d(TAG, "Service onCreate")
  }

  override fun onDestroy() {
    Log.d(TAG, "Service onDestroy - checking for orphaned recordings")
    
    // Fallback: cleanup any remaining recordings if service is destroyed
    val recorders = getActiveRecorders()
    if (recorders.isNotEmpty()) {
      Log.w(TAG, "Service destroyed with ${recorders.size} active recording(s) - forcing cleanup")
      for (recorder in recorders) {
        try {
          recorder.forceStop()
        } catch (e: Exception) {
          Log.e(TAG, "Error forcing stop on recorder: ${e.message}", e)
        }
      }
    }
    
    super.onDestroy()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    
    Log.d(TAG, "Service onDestroy completed")
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    if (intent?.action == null) {
      val notification = createNotification(
        intent?.getStringExtra("title"),
        intent?.getStringExtra("content")
      )
      startForeground(NOTIFICATION_ID, notification)

      notificationManager.notify(NOTIFICATION_ID, notification)
    }

    return START_NOT_STICKY
  }
  
  override fun onTaskRemoved(rootIntent: Intent?) {
    super.onTaskRemoved(rootIntent)
    Log.d(TAG, "⚠️ App task removed - attempting to save recordings before termination")
    
    val startTime = System.currentTimeMillis()
    val recorders = getActiveRecorders()
    
    if (recorders.isEmpty()) {
      Log.d(TAG, "No active recordings to save")
      cleanup()
      return
    }
    
    Log.d(TAG, "Found ${recorders.size} active recording(s) - stopping them gracefully")
    
    try {
      // Use CountDownLatch to wait for all recordings to stop
      val latch = CountDownLatch(recorders.size)
      var successCount = 0
      
      for (recorder in recorders) {
        mainHandler.post {
          try {
            recorder.stopOnTaskRemoved(
              onSuccess = {
                successCount++
                Log.d(TAG, "✅ Recording stopped successfully ($successCount/${recorders.size})")
                latch.countDown()
              },
              onError = { error ->
                Log.e(TAG, "❌ Failed to stop recording: $error")
                latch.countDown()
              }
            )
          } catch (e: Exception) {
            Log.e(TAG, "Exception stopping recorder: ${e.message}", e)
            latch.countDown()
          }
        }
      }
      
      // Wait max 3 seconds for all recordings to stop
      val completed = latch.await(3, TimeUnit.SECONDS)
      val duration = System.currentTimeMillis() - startTime
      
      if (completed) {
        Log.d(TAG, "✅ All recordings processed in ${duration}ms ($successCount succeeded)")
      } else {
        Log.w(TAG, "⚠️ Timeout after ${duration}ms - some recordings may not be fully saved")
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error in onTaskRemoved: ${e.message}", e)
    } finally {
      cleanup()
    }
  }
  
  private fun cleanup() {
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
        stopForeground(STOP_FOREGROUND_REMOVE)
      } else {
        @Suppress("DEPRECATION")
        stopForeground(true)
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error stopping foreground in cleanup: ${e.message}", e)
    }
    stopSelf()
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val channel = NotificationChannel(
        CHANNEL_ID,
        DEFAULT_TITLE,
        NotificationManager.IMPORTANCE_LOW
      )
      notificationManager.createNotificationChannel(channel)
    }
  }

  private fun createNotification(title: String?, content: String?): Notification {
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(title ?: DEFAULT_TITLE)
      .setContentText(content)
      .setSmallIcon(R.drawable.ic_mic)
      .setSilent(true)
      .setOngoing(true)
      .setVisibility(VISIBILITY_PUBLIC)
      .build()
  }
}