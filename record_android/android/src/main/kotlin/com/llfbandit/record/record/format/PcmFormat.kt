package com.llfbandit.record.record.format

import android.media.MediaFormat
import com.llfbandit.record.record.RecordConfig
import com.llfbandit.record.record.container.HybridContainer
import com.llfbandit.record.record.container.IContainerWriter
import com.llfbandit.record.record.container.RawContainer

class PcmFormat : Format() {
  override val mimeTypeAudio: String = MediaFormat.MIMETYPE_AUDIO_RAW
  override val passthrough: Boolean = true

  override fun getMediaFormat(config: RecordConfig): MediaFormat {
    val bitsPerSample = 16
    val frameSize = config.numChannels * bitsPerSample / 8

    val format = MediaFormat().apply {
      setString(MediaFormat.KEY_MIME, mimeTypeAudio)
      setInteger(MediaFormat.KEY_SAMPLE_RATE, config.sampleRate)
      setInteger(MediaFormat.KEY_CHANNEL_COUNT, config.numChannels)
      setInteger(KEY_X_FRAME_SIZE_IN_BYTES, frameSize)
    }

    return format
  }


  override fun getContainer(config: RecordConfig): IContainerWriter {
    val path = config.path
    
    // Hybrid mode: both file and stream
    if (config.hybridMode && path != null) {
      val fileContainer = RawContainer(path)
      val streamContainer = RawContainer(null)
      
      return HybridContainer(fileContainer, streamContainer)
    }
    
    // File only or stream only
    return RawContainer(path)
  }
}