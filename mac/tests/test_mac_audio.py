import json
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from beacon.mac_audio import MacAudio
from beacon import server


class MacAudioTests(unittest.TestCase):
    def player(self):
        audio = MacAudio()
        stream = Mock()
        stream.is_closing.return_value = False
        stream.transport.get_write_buffer_size.return_value = 0
        audio.process = SimpleNamespace(returncode=None, stdin=stream)
        return audio, stream

    def test_copies_audio_events_without_modifying_them(self):
        audio, stream = self.player()
        messages = [{'type': 'say', 'text': 'Found the bottle.'},
                    {'type': 'guidance', 'mode': 'probe'}, {'type': 'cue', 'name': 'stop'}]
        before = json.dumps(messages)
        audio.publish(messages + [{'type': 'other'}])
        self.assertEqual([json.loads(call.args[0]) for call in stream.write.call_args_list], messages)
        self.assertEqual(json.dumps(messages), before)

    def test_dead_or_slow_local_player_does_not_block_phone_messages(self):
        audio, stream = self.player()
        stream.transport.get_write_buffer_size.return_value = 100_000
        audio.publish([{'type': 'say', 'text': 'hello'}])
        stream.write.assert_not_called()
        audio.process.returncode = 1
        audio.publish([{'type': 'say', 'text': 'hello'}])
        stream.write.assert_not_called()

    def test_broken_pipe_is_isolated_from_phone_output(self):
        audio, stream = self.player()
        stream.write.side_effect = BrokenPipeError
        audio.publish([{'type': 'say', 'text': 'hello'}])


class MirrorRoutingTests(unittest.IsolatedAsyncioTestCase):
    async def test_phone_receives_identical_events_with_local_mirror(self):
        from unittest.mock import AsyncMock
        guidance = {'type': 'guidance', 'mode': 'idle', 'stop_reason': None, 'target': None}
        engine = SimpleNamespace(step=lambda: guidance, drain=lambda: [{'type': 'say', 'text': 'Ready.'}])
        mirror, broadcast = Mock(), AsyncMock()
        with patch.object(server, 'engine', engine), patch.object(server, 'mac_audio', mirror), \
                patch.object(server, 'broadcast', broadcast):
            await server.publish_guidance()
        self.assertEqual(mirror.publish.call_args.args[0], broadcast.call_args.args[1])
        self.assertEqual(broadcast.call_args.args[1], [{'type': 'say', 'text': 'Ready.'}, guidance])
