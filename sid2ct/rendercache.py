"""Reuse deterministic SID renders by content, renderer and playback settings."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def render(command, *, cwd=None, timeout=600, cache_dir=None):
    """Render a SID command, copying cached WAV and returning renderer metadata."""
    binary, source, output, *settings = map(str, command)
    digest = hashlib.sha256()
    for value in (Path(source).read_bytes(), Path(binary).read_bytes(),
                  json.dumps(settings, separators=(',', ':')).encode()):
        digest.update(len(value).to_bytes(8, 'big'))
        digest.update(value)
    root = Path(cache_dir) if cache_dir is not None else Path.home()/'.cache/sid2ct/renders'
    root.mkdir(parents=True, exist_ok=True)
    key = digest.hexdigest()
    wav, metadata = root/(key+'.wav'), root/(key+'.json')
    try:
        info = json.loads(metadata.read_text())
        shutil.copyfile(wav, output)
        return info['stdout']
    except (OSError, ValueError, KeyError):
        pass
    # Publish metadata last; concurrent identical jobs have independent temp files.
    with tempfile.TemporaryDirectory(prefix=key+'.', dir=root) as temporary:
        temporary = Path(temporary)
        rendered = temporary/'render.wav'
        result = subprocess.run([binary, source, str(rendered), *settings], cwd=cwd,
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise ValueError('Audio rendering failed: '+result.stdout+result.stderr)
        if not rendered.is_file():
            raise ValueError('Renderer did not produce a WAV.')
        info = temporary/'metadata.json'
        info.write_text(json.dumps(dict(stdout=result.stdout.strip())))
        shutil.copyfile(rendered, output)
        os.replace(rendered, wav)
        os.replace(info, metadata)
    return result.stdout.strip()
