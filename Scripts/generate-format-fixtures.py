#!/usr/bin/env python3
"""Generate small, original test videos with actual distinct containers/codecs/tracks."""
import pathlib
import subprocess
import sys

ffmpeg = sys.argv[1]
root = pathlib.Path(__file__).resolve().parent.parent / 'Tests/JellyMacTests/Fixtures'
root.mkdir(parents=True, exist_ok=True)
subtitles = root / 'captions.srt'
subtitles.write_text('1\n00:00:00,000 --> 00:00:04,000\nJellyMac subtitle test\n\n2\n00:00:04,000 --> 00:00:08,000\nSecond subtitle cue\n')
inputs = ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
          '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
          '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000']

def generate(name, options, tracks=False):
    command = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', *inputs]
    if tracks:
        command += ['-i', str(subtitles), '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s',
                    '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=fra',
                    '-metadata:s:s:0', 'language=eng']
    else:
        command += ['-map', '0:v', '-map', '1:a']
    command += ['-t', '8', *options, str(root / name)]
    subprocess.run(command, check=True)
    print(name, flush=True)

generate('h264-aac.mp4', ['-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart'])
generate('multitrack-h264.mkv', ['-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-c:s', 'srt'], tracks=True)
generate('mpeg4-mp3.avi', ['-c:v', 'mpeg4', '-q:v', '5', '-c:a', 'libmp3lame'])
generate('h264-pcm.mov', ['-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'pcm_s16le', '-movflags', '+faststart'])
generate('vp9-opus.webm', ['-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-cpu-used', '8', '-b:v', '300k', '-c:a', 'libopus'])
generate('hevc-ac3.mkv', ['-c:v', 'libx265', '-preset', 'ultrafast', '-x265-params', 'log-level=error:pools=2', '-c:a', 'ac3'])
(root / 'h264-aac.en.srt').write_text(subtitles.read_text())
