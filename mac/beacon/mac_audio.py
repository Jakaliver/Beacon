"""Optional local audio mirror; phone messages and audio status remain unchanged."""
import asyncio
import hashlib
import json
import logging
import os
from pathlib import Path
import sys
import tempfile

log = logging.getLogger('beacon.mac_audio')


class MacAudio:
    def __init__(self):
        self.process = None
        self.enabled = sys.platform == 'darwin' and os.environ.get('BEACON_MAC_AUDIO', '1') != '0'

    async def start(self):
        if not self.enabled:
            return
        try:
            root = Path(__file__).resolve().parents[2]
            sources = [root / 'mac/audio/main.swift', root / 'ios/Beacon/Beacon/GuidanceSounds.swift']
            digest = hashlib.sha256(b''.join(p.read_bytes() for p in sources)).hexdigest()[:16]
            directory = Path(tempfile.gettempdir()) / f'beacon-audio-{os.getuid()}'
            directory.mkdir(mode=0o700, exist_ok=True)
            binary = directory / digest
            if not binary.exists():
                temporary = directory / f'{digest}-{os.getpid()}.tmp'
                compiler = await asyncio.create_subprocess_exec(
                    'swiftc', '-parse-as-library', '-O', *(str(p) for p in sources), '-o', str(temporary),
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
                _, errors = await compiler.communicate()
                if compiler.returncode:
                    raise RuntimeError(errors.decode())
                temporary.replace(binary)
            self.process = await asyncio.create_subprocess_exec(str(binary), stdin=asyncio.subprocess.PIPE)
            log.warning('Laptop audio mirror started')
        except Exception:
            log.exception('Laptop audio unavailable; phone audio continues normally')

    def publish(self, messages):
        process = self.process
        if process is None or process.returncode is not None or process.stdin.is_closing():
            return
        # Never let local playback stall the phone's control stream.
        if process.stdin.transport.get_write_buffer_size() > 64_000:
            return
        try:
            for message in messages:
                if message.get('type') in {'say', 'cue', 'guidance'}:
                    process.stdin.write((json.dumps(message) + '\n').encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    async def close(self):
        if self.process is None:
            return
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), 3)
        except asyncio.TimeoutError:
            self.process.kill()
            await self.process.wait()
        self.process = None
