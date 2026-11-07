import io
import unittest
import wave
from types import SimpleNamespace
from unittest.mock import Mock, patch

import numpy as np

from trident.speech import Speech


class SpeechRecordingTests(unittest.TestCase):
    def setUp(self):
        self.speech = Speech.__new__(Speech)
        self.speech.rate = 16_000
        self.speech.model = Mock()

    @staticmethod
    def wav(rate, seconds):
        stream = io.BytesIO()
        with wave.open(stream, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(np.zeros(int(rate * seconds), np.int16).tobytes())
        return stream.getvalue()

    def test_empty_and_accidentally_short_recordings_skip_the_model(self):
        for rate in (16_000, 44_100, 48_000):
            for seconds in (0, 0.02, 0.09):
                with self.subTest(rate=rate, seconds=seconds):
                    self.assertEqual(self.speech.transcribe_wav(self.wav(rate, seconds)), "")
        self.speech.model.generate.assert_not_called()

    def test_normal_recording_still_reaches_recognition_at_the_model_rate(self):
        self.speech.model.generate.return_value = [SimpleNamespace(text=" find the bottle ")]
        with patch("parakeet_mlx.audio.get_logmel", return_value=object()) as features:
            self.assertEqual(self.speech.transcribe_wav(self.wav(48_000, 0.5)), "find the bottle")
        self.assertEqual(features.call_args.args[0].shape, (8_000,))
        self.speech.model.generate.assert_called_once_with(features.return_value)


if __name__ == "__main__":
    unittest.main()
