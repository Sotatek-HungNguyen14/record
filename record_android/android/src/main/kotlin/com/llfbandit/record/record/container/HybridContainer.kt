package com.llfbandit.record.record.container

import android.media.MediaCodec
import android.media.MediaFormat
import java.nio.ByteBuffer

/**
 * Hybrid container that supports both file writing AND streaming simultaneously.
 * This allows real-time audio processing (e.g., transcription) while saving to file.
 */
class HybridContainer(
  private val fileContainer: IContainerWriter,
  private val streamContainer: IContainerWriter
) : IContainerWriter {
  
  private var isStarted = false
  
  override fun start() {
    if (isStarted) {
      throw IllegalStateException("Hybrid container already started")
    }
    
    // Start both containers
    fileContainer.start()
    streamContainer.start()
    
    isStarted = true
  }

  override fun stop() {
    if (!isStarted) {
      return
    }
    
    // Stop both containers
    try {
      fileContainer.stop()
    } catch (e: Exception) {
      // Log but continue to stop stream container
      e.printStackTrace()
    }
    
    try {
      streamContainer.stop()
    } catch (e: Exception) {
      e.printStackTrace()
    }
    
    isStarted = false
  }

  override fun release() {
    // Release both containers
    try {
      fileContainer.release()
    } catch (e: Exception) {
      e.printStackTrace()
    }
    
    try {
      streamContainer.release()
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  override fun isStream(): Boolean {
    // Return true to enable streaming callback
    return true
  }

  override fun addTrack(mediaFormat: MediaFormat): Int {
    // Add track to both containers
    val fileTrack = fileContainer.addTrack(mediaFormat)
    val streamTrack = streamContainer.addTrack(mediaFormat)
    
    // Both should return the same track index
    if (fileTrack != streamTrack) {
      throw IllegalStateException("Track index mismatch between file and stream containers")
    }
    
    return fileTrack
  }

  override fun writeSampleData(
    trackIndex: Int,
    byteBuffer: ByteBuffer,
    bufferInfo: MediaCodec.BufferInfo
  ) {
    // Write to file container
    // Clone buffer position for second write
    val position = byteBuffer.position()
    fileContainer.writeSampleData(trackIndex, byteBuffer, bufferInfo)
    
    // Reset position for stream container (writeSampleData may have modified it)
    byteBuffer.position(position)
  }

  override fun writeStream(
    trackIndex: Int,
    byteBuffer: ByteBuffer,
    bufferInfo: MediaCodec.BufferInfo
  ): ByteArray {
    // First write to file (reuses writeSampleData logic)
    val position = byteBuffer.position()
    writeSampleData(trackIndex, byteBuffer, bufferInfo)
    
    // Reset position for stream
    byteBuffer.position(position)
    
    // Then stream the data
    return streamContainer.writeStream(trackIndex, byteBuffer, bufferInfo)
  }

  override fun ignoreCodecSpecificData(): Boolean {
    // Use the file container's setting (typically more restrictive)
    return fileContainer.ignoreCodecSpecificData()
  }
}

