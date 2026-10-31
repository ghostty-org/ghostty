#!/usr/bin/env python3
"""Build matching native and Linux runtime artifacts, serially, without remote tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(args, **kwargs):
    subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def sign_adhoc(paths):
    """Re-sign copied Mach-O files after load-command edits.

    install_name_tool and lipo invalidate the linker's ad-hoc signature, and
    Apple silicon refuses to execute a Mach-O whose pages no longer match it.
    The installing script runs these artifacts before the app bundle is signed,
    so they must carry a usable signature here.
    """
    for path in paths:
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(path)])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--linux', default='x86_64,aarch64')
    parser.add_argument('--macos', default='native', choices=['native', 'all'])
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Content-derived revision also distinguishes uncommitted development builds.
    digest = hashlib.sha256()
    snapshot_digest = hashlib.sha256()
    for base in ['session-runtime/src', 'include/ghostty/vt', 'src/terminal']:
        for path in sorted((ROOT / base).rglob('*')):
            if path.is_file():
                digest.update(str(path.relative_to(ROOT)).encode())
                contents = path.read_bytes()
                digest.update(contents)
                if base != 'session-runtime/src':
                    snapshot_digest.update(str(path.relative_to(ROOT)).encode())
                    snapshot_digest.update(contents)
    for path in [ROOT/'session-runtime/Cargo.lock', ROOT/'session-runtime/build.rs']:
        digest.update(path.read_bytes())
    revision = digest.hexdigest()[:20]
    zig = Path(subprocess.check_output(['mise', 'exec', 'zig@0.16.0', '--', 'which', 'zig'], text=True).strip())
    rustc = subprocess.check_output(['rustup', 'which', 'rustc'], text=True).strip()
    native = 'aarch64' if platform.machine() == 'arm64' else 'x86_64'
    targets = [(f'macos-{native}', None, None)]
    if args.macos == 'all':
        other = 'x86_64' if native == 'aarch64' else 'aarch64'
        targets.append((f'macos-{other}', f'{other}-apple-darwin', f'{other}-macos.13.0'))
    for arch in filter(None, args.linux.split(',')):
        if arch not in {'x86_64', 'aarch64'}: raise ValueError('invalid Linux architecture')
        targets.append((f'linux-{arch}', f'{arch}-unknown-linux-gnu', f'{arch}-linux-gnu.2.28'))
    for name, rust_target, zig_target in targets:
        destination = output/name
        destination.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='omg-runtime-build-') as tmp:
            tmp = Path(tmp)
            prefix = tmp/'vt'
            command = [str(zig), 'build', '-Demit-lib-vt', '-Demit-macos-app=false',
                       '-Doptimize=ReleaseFast', '-Dversion-string=1.3.2-dev', '--prefix', str(prefix)]
            if zig_target: command.append('-Dtarget=' + zig_target)
            run(command)
            env = os.environ.copy()
            env['RUSTC'] = rustc
            env['OMG_VT_LIB_DIR'] = str(prefix/'lib')
            cargo = ['cargo', 'build', '--manifest-path', 'session-runtime/Cargo.toml', '--release']
            if rust_target:
                run(['rustup', 'target', 'add', rust_target])
                cc = tmp/'cc'
                ar = tmp/'ar'
                if name.startswith('macos-'):
                    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
                    apple_arch = 'arm64' if name.endswith('aarch64') else 'x86_64'
                    cc.write_text(f'#!/bin/sh\nexec /usr/bin/clang -arch {apple_arch} -isysroot "{sdk}" -mmacosx-version-min=13.0 "$@"\n')
                else:
                    cc.write_text(f'#!/bin/sh\nexec "{zig}" cc -target {zig_target} "$@"\n')
                ar.write_text(f'#!/bin/sh\nexec "{zig}" ar "$@"\n')
                cc.chmod(0o700)
                ar.chmod(0o700)
                env['OMG_RUNTIME_CC'] = str(cc)
                env['OMG_RUNTIME_AR'] = str(ar)
                env['CARGO_TARGET_' + rust_target.upper().replace('-', '_') + '_LINKER'] = str(cc)
                cargo += ['--target', rust_target]
            run(cargo, env=env)
            binary = ROOT/'session-runtime/target'
            if rust_target: binary /= rust_target
            binary /= 'release/omgd'
            shutil.copy2(binary, destination/'omgd')
            if name.startswith('linux-'):
                library = next(p for p in (prefix/'lib').glob('libghostty-vt.so.*') if not p.is_symlink())
                shutil.copy2(library, destination/'libghostty-vt.so.0')
            else:
                library = next(p for p in (prefix/'lib').glob('libghostty-vt.*.dylib') if not p.is_symlink())
                shutil.copy2(library, destination/library.name)
                run(['/usr/bin/install_name_tool', '-id', '@rpath/' + library.name, str(destination/library.name)])
                dependencies = subprocess.check_output(['/usr/bin/otool', '-L', str(destination/'omgd')], text=True)
                for line in dependencies.splitlines()[1:]:
                    dependency = line.strip().split(' (')[0]
                    if 'libghostty-vt' in dependency:
                        run(['/usr/bin/install_name_tool', '-change', dependency, '@rpath/' + library.name, str(destination/'omgd')])
                sign_adhoc([destination/library.name, destination/'omgd'])
            files = [{'name': p.name, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                     for p in sorted(destination.iterdir()) if p.name != 'manifest.json' and p.is_file()]
            (destination/'manifest.json').write_text(json.dumps({'revision': revision, 'platform': name, 'files': files}, indent=2)+'\n')
        print(f'built {name} {revision}', flush=True)
    for path in (output/f'macos-{native}').iterdir():
        if path.name != 'manifest.json': shutil.copy2(path, output/path.name)
    if args.macos == 'all':
        for path in (output/f'macos-{native}').iterdir():
            if path.name == 'manifest.json': continue
            run(['/usr/bin/lipo', '-create', str(output/'macos-aarch64'/path.name),
                 str(output/'macos-x86_64'/path.name), '-output', str(output/path.name)])
            sign_adhoc([output/path.name])
    shutil.copy2(ROOT/'dist/macos/session-runtime-askpass.sh', output/'askpass')
    (output/'askpass').chmod(0o755)
    (output/'revision').write_text(revision+'\n')
    (output/'snapshot-revision').write_text(snapshot_digest.hexdigest()[:20]+'\n')
    print(f'runtime artifacts: {output}', flush=True)


if __name__ == '__main__': main()
