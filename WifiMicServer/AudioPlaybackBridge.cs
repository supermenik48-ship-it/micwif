using System;
using System.Buffers.Binary;
using System.Linq;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace WifiMicServer;

public sealed class AudioPlaybackBridge : IDisposable
{
    private readonly object _lock = new();
    private WasapiOut? _wasapiOut;
    private BufferedWaveProvider? _waveProvider;
    private readonly WaveFormat _format = new(48000, 16, 1);

    private uint _expectedSeq;
    private bool _hasFirstPacket;

    public float Volume { get; set; } = 1.0f;
    public float GainDb { get; set; } = 0.0f;
    public bool NoiseGateEnabled { get; set; } = false;
    public float NoiseGateThresholdDb { get; set; } = -60.0f;

    public MMDeviceCollection GetOutputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
    }

    public MMDevice? FindVbCable()
    {
        var devices = GetOutputDevices();
        return devices.FirstOrDefault(d => d.FriendlyName.StartsWith("CABLE Input", StringComparison.OrdinalIgnoreCase))
            ?? devices.FirstOrDefault(d => d.FriendlyName.Contains("CABLE", StringComparison.OrdinalIgnoreCase));
    }

    public void Start(MMDevice device)
    {
        lock (_lock)
        {
            Stop();

            _waveProvider = new BufferedWaveProvider(_format)
            {
                DiscardOnBufferOverflow = true,
                ReadFully = true,
                BufferDuration = TimeSpan.FromMilliseconds(500)
            };

            // WASAPI in shared mode, event sync, 20ms latency
            _wasapiOut = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 20);
            _wasapiOut.Init(_waveProvider);
            _wasapiOut.Play();

            _hasFirstPacket = false;
            _expectedSeq = 0;
        }
    }

    public void ResetState()
    {
        lock (_lock)
        {
            _hasFirstPacket = false;
            _expectedSeq = 0;
            _waveProvider?.ClearBuffer();
            if (_wasapiOut != null && _wasapiOut.PlaybackState != PlaybackState.Playing)
            {
                try { _wasapiOut.Play(); } catch { }
            }
        }
    }

    public void EnqueueAudio(uint seqNum, ReadOnlyMemory<byte> pcmData)
    {
        lock (_lock)
        {
            if (_waveProvider == null) return;

            // Ensure Wasapi is playing
            if (_wasapiOut != null && _wasapiOut.PlaybackState != PlaybackState.Playing)
            {
                try { _wasapiOut.Play(); } catch { }
            }

            // 1. Jitter & sequence gap handling
            if (!_hasFirstPacket)
            {
                _hasFirstPacket = true;
                _expectedSeq = seqNum + 1;
            }
            else
            {
                uint diff = seqNum - _expectedSeq;
                if (diff > 0 && diff < 0x80000000)
                {
                    int missing = (int)diff;
                    if (missing >= 1 && missing <= 3)
                    {
                        // Insert 960 bytes of zeros per missing packet (10ms @ 48kHz 16-bit mono)
                        byte[] silence = new byte[missing * 960];
                        _waveProvider.AddSamples(silence, 0, silence.Length);
                    }
                    // For large gaps (> 3), continue without insertion
                }
                _expectedSeq = seqNum + 1;
            }

            // 2. Buffer latency check: prevent massive latency buildup (e.g. after long network freeze)
            if (_waveProvider.BufferedDuration.TotalMilliseconds > 300)
            {
                _waveProvider.ClearBuffer();
            }

            ReadOnlySpan<byte> span = pcmData.Span;
            if (span.Length == 0) return;

            // 3. Noise gate
            if (NoiseGateEnabled)
            {
                float thresholdLinear = 32767f * MathF.Pow(10f, NoiseGateThresholdDb / 20f);
                int peak = 0;
                for (int i = 0; i < span.Length - 1; i += 2)
                {
                    short sample = BinaryPrimitives.ReadInt16LittleEndian(span.Slice(i, 2));
                    int abs = Math.Abs((int)sample);
                    if (abs > peak) peak = abs;
                }

                if (peak < thresholdLinear)
                {
                    // Silence below threshold
                    byte[] zeros = new byte[span.Length];
                    _waveProvider.AddSamples(zeros, 0, zeros.Length);
                    return;
                }
            }

            // 4. Volume and dB Gain
            float gainLinear = MathF.Pow(10f, GainDb / 20f);
            float totalMultiplier = Volume * gainLinear;

            if (Math.Abs(totalMultiplier - 1.0f) > 0.001f)
            {
                byte[] processed = new byte[span.Length];
                for (int i = 0; i < span.Length - 1; i += 2)
                {
                    short sample = BinaryPrimitives.ReadInt16LittleEndian(span.Slice(i, 2));
                    float val = sample * totalMultiplier;
                    val = Math.Clamp(val, -32768f, 32767f);
                    BinaryPrimitives.WriteInt16LittleEndian(processed.AsSpan(i, 2), (short)val);
                }
                _waveProvider.AddSamples(processed, 0, processed.Length);
            }
            else
            {
                _waveProvider.AddSamples(pcmData.ToArray(), 0, pcmData.Length);
            }
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            if (_wasapiOut != null)
            {
                try
                {
                    _wasapiOut.Stop();
                    _wasapiOut.Dispose();
                }
                catch { }
                _wasapiOut = null;
            }
            _waveProvider = null;
            _hasFirstPacket = false;
            _expectedSeq = 0;
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
