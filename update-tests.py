#!/usr/bin/env python3
import argparse
import tempfile
import subprocess
import os

ap = argparse.ArgumentParser('script to update passing Zig tests')
ap.add_argument('compiler', type=str, help='Path to Zig compiler')
ap.add_argument('test', type=str, help='Path to file to test')
ap.add_argument('--todo', default=False, action='store_true', help='Print the number of tests that still need to be done')

args = ap.parse_args()

basedir = os.path.abspath(os.path.dirname(__file__))
todo = {}

def update_test(tmpdir, path):
    with open(path, 'rb') as f:
        test = f.readlines()

    new_test = []
    test_path = os.path.join(tmpdir, 'test.zig')
    total = 0
    for line in test:
        if b'if (builtin.zig_backend == .stage2_spirv64) return error.SkipZigTest;' in line:
            total += 1

    if args.todo:
        todo[path] = total
        return

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
                'generic+Int64+Int16+Int8+Float64+Float16',
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
                elif 'Segmentation fault' in stderr:
                    error = 'segfault'
                elif '... FAIL (' in stderr:
                    error = 'test failure'
                elif 'has no member named \'fd_t\'' in stderr:
                    error = 'uses expectEqualSlices'
                elif 'Floating point width of ' in stderr:
                    error = 'uses f128/f80 float'
                elif 'BuildProgramFailure' in stderr:
                    error = 'backend compilation error'
                elif 'error: validation failed' in stderr:
                    error = 'validation failure'
                elif 'cannot call function pointers' in stderr:
                    error = 'uses function pointers'
                else:
                    tags = []
                    todos = []
                    for ln in stderr.split('\n'):
                        if 'TODO (SPIR-V): implement AIR tag' in ln:
                            tags.append(ln.split(' ')[-1])
                        elif 'TODO (SPIR-V): ' in ln:
                            todos.append(ln.split('TODO (SPIR-V): ')[1])
                    if len(tags) != 0:
                        error = 'missing air tags ' + ', '.join(tags)
                    elif len(todos) != 0:
                        error = 'todo ' + ', '.join(todos)
                    else:
                        error = 'unknown'

                print(f'[{current}/{total}] FAIL {name} ({error})')

        new_test.append(line)

    with open(path, 'wb') as f:
        f.writelines(new_test)

    subprocess.run([args.compiler, 'fmt', path], capture_output=True)

with tempfile.TemporaryDirectory() as tmpdir:
    if os.path.isfile(args.test):
        update_test(tmpdir, args.test)
    else:
        for subdir, dirs, files in os.walk(args.test):
            for path in files:
                path = os.path.join(subdir, path)
                if not args.todo:
                    print(f'updating {path}')

                update_test(tmpdir, path)

                if not args.todo:
                    print('')

if args.todo:
    x = sorted(todo.items(), key=lambda x: x[1])
    for k, v in x:
        if v > 0:
            print(v, k)
