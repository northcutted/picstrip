#!/usr/bin/env python3
"""Use the reviewed platform pin locally; Actions supplies IOS_RELEASE_ROOT."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def platform_root(sync=False):
    pin = json.loads((ROOT / '.github/ios-release-platform.json').read_text())
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', pin['repository']) or not re.fullmatch(r'[a-f0-9]{40}', pin['revision']):
        raise ValueError('Expected a GitHub repository and full platform commit')
    # Set only by the pinned bootstrap action, or explicitly for platform development.
    if os.environ.get('IOS_RELEASE_ROOT') and not sync:
        result = Path(os.environ['IOS_RELEASE_ROOT']).resolve()
    else:
        cache = ROOT / 'build/ios-release-platform'
        result = cache / pin['revision']
        if sync and not result.exists():
            cache.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='fetch-', dir=cache) as temp:
                subprocess.run(['git', 'init', '-q', temp], check=True)
                subprocess.run(['git', '-C', temp, 'fetch', '--quiet', '--depth=1',
                                f"https://github.com/{pin['repository']}.git", pin['revision']], check=True)
                subprocess.run(['git', '-C', temp, 'checkout', '--quiet', '--detach', 'FETCH_HEAD'], check=True)
                Path(temp).rename(result)
        if not result.is_dir():
            raise ValueError('Platform is not cached. Run make platform-sync once; subsequent commands work offline.')
        head = subprocess.check_output(['git', '-C', str(result), 'rev-parse', 'HEAD'], text=True).strip()
        dirty = subprocess.check_output(['git', '-C', str(result), 'status', '--porcelain', '--untracked-files=all'], text=True)
        if head != pin['revision'] or dirty.strip():
            raise ValueError('Cached platform differs from the reviewed pin; inspect it before resyncing')
    if not (result / 'bin/ios-release').is_file():
        raise ValueError('Platform does not provide the supported command interface')
    return result


def main():
    args = sys.argv[1:]
    sync = args == ['sync']
    platform = platform_root(sync or (args[:1] == ['setup'] and not os.environ.get('IOS_RELEASE_ROOT')))
    if sync:
        print(f'Pinned platform ready: {platform}')
        return 0
    env = {**os.environ, 'IOS_APP_ROOT': str(ROOT), 'IOS_RELEASE_CONFIG': str(ROOT / '.github/ios-release.json')}
    env.setdefault('IOS_RELEASE_REVISION', json.loads((ROOT / '.github/ios-release-platform.json').read_text())['revision'])
    env.setdefault('SOURCE_SHA', subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip())
    return subprocess.call([sys.executable, str(platform / 'bin/ios-release'), *args], cwd=ROOT, env=env)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
