#!/usr/bin/env python3
import argparse
import tempfile
import subprocess
import os

ap = argparse.ArgumentParser('script to update passing Zig tests')
ap.add_argument('compiler', type=str, help='Path to Zig compiler')
ap.add_argument('test', type=str, help='Path to file to test')

args = ap.parse_args()

basedir = os.path.abspath(os.path.dirname(__file__))

def update_test(tmpdir, path):
    with open(path, 'rb') as f:
        test = f.readlines()

    new_test = []
    test_path = os.path.join(tmpdir, 'test.zig')
    total = 0
    for line in test:
        if b'if (builtin.zig_backend == .stage2_spirv64) return error.SkipZigTest;' in line:
            total += 1

    current = 0
    for i, line in enumerate(test):
        if line.startswith(b'test'):
            # Cheekily strip out the text from the quotes
            name = line[len('test "') : -len('" {\n')].decode('utf-8')
        elif b'if (builtin.zig_backend == .stage2_spirv64) return error.SkipZigTest;' in line:
            current += 1

            test_without_check = test[:]
            del test_without_check[i]

            with open(test_path, 'wb') as f:
                f.writelines(test_without_check)

            result = subprocess.run([
                args.compiler,
                'test',
                test_path,
                '--test-runner',
                os.path.join(basedir, 'src', 'test_runner.zig'),
                '-fno-compiler-rt',
                '-target',
                'spirv64-opencl',
                '-mcpu',
                'generic+Int64+Int16+Int8+Float64',
                '-fno-llvm',
                '--test-cmd',
                os.path.join(basedir, 'zig-out', 'bin', 'zig-spirv-executor'),
                '--test-cmd-bin',
            ], capture_output=True)
            if result.returncode == 0:
                print(f'[{current}/{total}] PASS {name}')
                continue # Skip adding the line
            else:
                stderr = result.stderr.decode('utf-8')
                if 'panic: reached unreachable code' in stderr:
                    error = 'unreachable'
                elif 'panic: index out of bounds' in stderr:
                    error = 'index out of bounds'
                elif 'panic: ' in stderr:
                    error = 'panic'
                else:
                    tags = []
                    for ln in stderr.split('\n'):
                        if 'TODO (SPIR-V): implement AIR tag' in ln:
                            tags.append(ln.split(' ')[-1])
                    if len(tags) == 0:
                        error = 'unknown'
                    else:
                        error = 'missing air tags ' + ', '.join(tags)

                print(f'[{current}/{total}] FAIL {name} ({error})')

        new_test.append(line)

    with open(path, 'wb') as f:
        f.writelines(new_test)

with tempfile.TemporaryDirectory() as tmpdir:
    if os.path.isfile(args.test):
        update_test(tmpdir, args.test)
    else:
        for subdir, dirs, files in os.walk(args.test):
            for path in files:
                path = os.path.join(subdir, path)
                print(f'updating {path}')
                update_test(tmpdir, path)
                print('')
