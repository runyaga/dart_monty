import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// GitHub repository for pre-built binary downloads.
const _repo = 'runyaga/dart_monty';

/// Reads the native library version from `NATIVE_LIB_VERSION`.
///
/// Single source of truth for the version used in GitHub Release download
/// URLs (`native-lib-v<version>`). The file lives at the repo root in
/// `native/NATIVE_LIB_VERSION` and is copied into the FFI package root
/// before publishing. Both contributor and consumer paths read from it.
String _readNativeLibVersion(Uri packageRoot) {
  // Check package root first (consumer path: file copied at publish time).
  final pkgFile = File.fromUri(packageRoot.resolve('NATIVE_LIB_VERSION'));
  if (pkgFile.existsSync()) return pkgFile.readAsStringSync().trim();

  // Fall back to monorepo path (contributor path).
  final nativeFile = File.fromUri(
    packageRoot.resolve('native/NATIVE_LIB_VERSION'),
  );
  if (nativeFile.existsSync()) return nativeFile.readAsStringSync().trim();

  throw StateError(
    'NATIVE_LIB_VERSION not found. '
    'Expected at package root or native/ directory.',
  );
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final os = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;

    final libName = switch (os) {
      OS.macOS => 'libdart_monty_native.dylib',
      OS.linux => 'libdart_monty_native.so',
      OS.windows => 'dart_monty_native.dll',
      _ => null,
    };

    // Graceful fallback for iOS/Android — no native assets for now.
    if (libName == null) return;

    // Include arch in the output path to avoid collisions when Flutter
    // invokes the hook for multiple architectures (e.g. macOS universal).
    final outFile = File.fromUri(
      input.outputDirectoryShared.resolve('$arch/$libName'),
    );
    outFile.parent.createSync(recursive: true);

    final nativeDir = input.packageRoot.resolve('native/');
    final cargoToml = File.fromUri(nativeDir.resolve('Cargo.toml'));

    if (cargoToml.existsSync()) {
      // Contributor path: always run cargo (handles incremental builds).
      final triple = _rustTriple(os, arch);
      final targetArgs = triple != null ? ['--target', triple] : <String>[];
      final result = await Process.run('cargo', [
        'build',
        '--release',
        ...targetArgs,
      ], workingDirectory: Directory.fromUri(nativeDir).path);
      if (result.exitCode != 0) {
        throw StateError(
          'cargo build failed.\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
        );
      }

      for (final sub in _cargoPaths(os, arch, libName)) {
        final f = File.fromUri(nativeDir.resolve(sub));
        if (f.existsSync() && f.lengthSync() > 0) {
          f.copySync(outFile.path);
          _addAsset(output, input.packageName, outFile.uri);
          return;
        }
      }

      throw StateError(
        'cargo build succeeded but $libName not found in target directories.',
      );
    } else {
      // Consumer path: download pre-built binary from GitHub Releases.
      final version = _readNativeLibVersion(input.packageRoot);
      if (await _download(os, arch, libName, outFile, version)) {
        _addAsset(output, input.packageName, outFile.uri);
        return;
      }

      throw StateError(
        'Cannot obtain dart_monty native library.\n'
        'Consumers: check your network connection.\n'
        'Contributors: clone the full monorepo with native/ directory.',
      );
    }
  });
}

void _addAsset(BuildOutputBuilder output, String packageName, Uri file) {
  output.assets.code.add(
    CodeAsset(
      package: packageName,
      name: 'dart_monty_ffi.dart',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ),
  );
}

List<String> _cargoPaths(OS os, Architecture? arch, String libName) {
  final triple = _rustTriple(os, arch);
  return [
    if (triple != null) 'target/$triple/release/$libName',
    'target/release/$libName',
  ];
}

Future<bool> _download(
  OS os,
  Architecture? arch,
  String libName,
  File outFile,
  String version,
) async {
  final archStr = arch?.toString() ?? 'x64';
  final filename = switch (os) {
    OS.macOS => 'libdart_monty_native-macos-$archStr.dylib',
    OS.linux => 'libdart_monty_native-linux-$archStr.so',
    OS.windows => 'dart_monty_native-windows-$archStr.dll',
    _ => null,
  };
  if (filename == null) return false;

  final url = Uri.parse(
    'https://github.com/$_repo/releases/download/native-lib-v$version/$filename',
  );

  final tmpFile = File('${outFile.path}.tmp');

  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return false;
      }

      final contentLength = response.contentLength;
      await response.pipe(tmpFile.openWrite());

      if (contentLength > 0 && tmpFile.lengthSync() != contentLength) {
        throw StateError('Content-Length mismatch');
      }

      tmpFile.renameSync(outFile.path);
    } finally {
      client.close(force: true);
    }

    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', outFile.path]);
    }
    return true;
  } on Object {
    if (tmpFile.existsSync()) {
      try {
        tmpFile.deleteSync();
      } on Object {
        // Ignore cleanup failures.
      }
    }
    return false;
  }
}

String? _rustTriple(OS os, Architecture? arch) {
  final a = arch?.toString() ?? 'arm64';
  return switch ((os, a)) {
    (OS.macOS, 'arm64') => 'aarch64-apple-darwin',
    (OS.macOS, 'x64') => 'x86_64-apple-darwin',
    (OS.linux, 'arm64') => 'aarch64-unknown-linux-gnu',
    (OS.linux, 'x64') => 'x86_64-unknown-linux-gnu',
    (OS.windows, 'arm64') => 'aarch64-pc-windows-msvc',
    (OS.windows, 'x64') => 'x86_64-pc-windows-msvc',
    _ => null,
  };
}
