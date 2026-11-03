"""Integration checks for preview encoding; no editor harness required."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(all(shutil.which(x) for x in ('ldc2', 'ffmpeg', 'ffprobe', 'sdl2-config')),
                     'Requires ldc2, FFmpeg and SDL2 development tools')
class VideoCaptureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.tmp.name) / 'capture-test'
        flags = subprocess.check_output(['sdl2-config', '--libs'], text=True).split()
        command = ['ldc2', '-d-version=DerelictSDL2_Static', '-Isrc',
                   'tests/video_capture_driver.d', 'src/com/videocapture.d',
                   'src/derelict/sdl2/internal/sdl_types.d', f'-of={cls.binary}']
        start = time.monotonic()
        subprocess.run(command + ['-L' + flag for flag in flags], cwd=ROOT, check=True,
                       capture_output=True)
        print(f'Capture test build: {time.monotonic() - start:.2f}s')

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_missing_ffmpeg(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(self.binary), 'missing'], cwd=directory,
                                    env={**os.environ, 'PATH': directory},
                                    capture_output=True, text=True, check=True)
            self.assertIn('Install FFmpeg', result.stdout)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_encoder_failure_does_not_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'ffmpeg'
            fake.write_text('#!/bin/sh\nif [ "$1" = "-version" ]; then exit 0; fi\nexit 1\n')
            fake.chmod(0o755)
            subprocess.run([str(self.binary), 'encoder-failure'], cwd=directory,
                           env={**os.environ, 'PATH': directory, 'SDL_VIDEODRIVER': 'dummy',
                                'SDL_AUDIODRIVER': 'dummy'}, check=True, capture_output=True, timeout=10)

    def test_repeated_recordings_have_video_and_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([str(self.binary)], cwd=directory, check=True,
                           env={**os.environ, 'SDL_VIDEODRIVER': 'dummy', 'SDL_AUDIODRIVER': 'dummy'},
                           capture_output=True, timeout=30)
            files = list(Path(directory).glob('preview_*.mp4'))
            self.assertEqual(len(files), 2)
            for movie in files:
                data = json.loads(subprocess.check_output([
                    'ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(movie)]))
                streams = {s['codec_type']: s for s in data['streams']}
                self.assertEqual(streams['video']['codec_name'], 'h264')
                self.assertEqual((streams['video']['width'], streams['video']['height']), (162, 92))
                self.assertEqual(streams['audio']['codec_name'], 'aac')
                self.assertAlmostEqual(float(streams['video']['duration']),
                                       float(streams['audio']['duration']), delta=0.05)
                audio = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(movie),
                                                 '-f', 's16le', '-ac', '1', 'pipe:1'])
                import array
                samples = array.array('h', audio)
                self.assertLess(max(abs(x) for x in samples[:4000]), 100)
                self.assertGreater(max(abs(x) for x in samples[12000:30000]), 5000)
