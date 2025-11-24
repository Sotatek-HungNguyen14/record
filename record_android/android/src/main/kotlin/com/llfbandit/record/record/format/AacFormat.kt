package com.llfbandit.record.record.format

import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import com.llfbandit.record.record.AudioEncoder
import com.llfbandit.record.record.RecordConfig
import com.llfbandit.record.record.container.AdtsContainer
import com.llfbandit.record.record.container.HybridContainer
import com.llfbandit.record.record.container.IContainerWriter
import com.llfbandit.record.record.container.MuxerContainer

class AacFormat : Format() {
  override val mimeTypeAudio: String = MediaFormat.MIMETYPE_AUDIO_AAC
  override val passthrough: Boolean = false

  private var sampleRate: Int = 44100
  private var numChannels: Int = 2
  private var aacProfile: Int = MediaCodecInfo.CodecProfileLevel.AACObjectLC

  override fun getMediaFormat(config: RecordConfig): MediaFormat {
    val format = MediaFormat().apply {
      setString(MediaFormat.KEY_MIME, mimeTypeAudio)
      setInteger(MediaFormat.KEY_SAMPLE_RATE, config.sampleRate)
      setInteger(MediaFormat.KEY_CHANNEL_COUNT, config.numChannels)
      setInteger(MediaFormat.KEY_BIT_RATE, config.bitRate)

      // Specifics
      @Suppress("CascadeIf")
      if (config.encoder == AudioEncoder.AacLc) {
        setInteger(
          MediaFormat.KEY_AAC_PROFILE,
          MediaCodecInfo.CodecProfileLevel.AACObjectLC
        )
      } else if (config.encoder == AudioEncoder.AacEld) {
        setInteger(
          MediaFormat.KEY_AAC_PROFILE,
          MediaCodecInfo.CodecProfileLevel.AACObjectELD
        )
      } else if (config.encoder == AudioEncoder.AacHe) {
        setInteger(
          MediaFormat.KEY_AAC_PROFILE,
          MediaCodecInfo.CodecProfileLevel.AACObjectHE
        )
      }
    }

    sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    numChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    aacProfile = format.getInteger(MediaFormat.KEY_AAC_PROFILE)

    return format
  }

  override fun adjustSampleRate(format: MediaFormat, sampleRate: Int) {
    super.adjustSampleRate(format, sampleRate)
    this.sampleRate = sampleRate
  }

  override fun adjustNumChannels(format: MediaFormat, numChannels: Int) {
    super.adjustNumChannels(format, numChannels)
    this.numChannels = numChannels
  }

  override fun getContainer(config: RecordConfig): IContainerWriter {
    val path = config.path
    
    // Hybrid mode: both file and stream
    if (config.hybridMode && path != null) {
      if (aacProfile != MediaCodecInfo.CodecProfileLevel.AACObjectLC) {
        throw IllegalArgumentException("Hybrid mode is only supported for AAC-LC profile.")
      }
      
      // File: AAC-LC encoded to M4A
      val fileContainer = MuxerContainer(path, true, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      
      // Stream: Raw AAC frames in ADTS format for compatibility
      // Note: This is AAC encoded data, unlike iOS which streams PCM
      // If you need PCM stream, consider using PCM encoder in hybrid mode
      val streamContainer = AdtsContainer(sampleRate, numChannels, aacProfile)
      
      return HybridContainer(fileContainer, streamContainer)
    }
    
    // Stream only
    if (path == null) {
      if (aacProfile != MediaCodecInfo.CodecProfileLevel.AACObjectLC) {
        throw IllegalArgumentException("Stream is not supported.")
      }

      return AdtsContainer(sampleRate, numChannels, aacProfile)
    }

    // File only
    return MuxerContainer(path, true, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
  }
}