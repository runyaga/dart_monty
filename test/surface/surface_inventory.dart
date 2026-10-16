/// Source inventory including typedefs, extensions and conditional exports.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

/// Reads the actual public declarations, following export combinators.
final class SurfaceInventory {
  /// Uses the implementation's resolved packages, including overrides.
  SurfaceInventory() {
    final config = File('.dart_tool/package_config.json').absolute;
    final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    for (final package in json['packages'] as List<dynamic>) {
      final entry = package as Map<String, dynamic>;
      _packages[entry['name'] as String] = config.uri
          .resolve(
            '${(entry['rootUri'] as String).replaceFirst(RegExp(r'/$'), "")}/',
          )
          .resolve(entry['packageUri'] as String? ?? 'lib/');
    }
  }

  final _packages = <String, Uri>{};

  /// Resolves public package imports or relative source files.
  Uri resolve(Uri base, String path) {
    final uri = Uri.parse(path);
    if (uri.scheme != 'package') return base.resolveUri(uri);

    return _packages[uri.pathSegments.firstOrNull!]!.resolve(
      uri.pathSegments.skip(1).join('/'),
    );
  }

  /// Exported names for a selected platform, with their declarations.
  Map<String, CompilationUnitMember> exported(Uri uri, {required bool web}) {
    final unit = parseString(
      content: File.fromUri(uri).readAsStringSync(),
    ).unit;
    final result = <String, CompilationUnitMember>{};
    for (final declaration in unit.declarations) {
      for (final name in _names(declaration)) {
        if (!name.startsWith('_')) result[name] = declaration;
      }
    }
    for (final part in unit.directives.whereType<PartDirective>()) {
      result.addAll(exported(resolve(uri, part.uri.stringValue!), web: web));
    }
    for (final directive in unit.directives.whereType<ExportDirective>()) {
      var target = directive.uri.stringValue!;
      for (final condition in directive.configurations) {
        final enabled = switch (condition.name.toSource()) {
          'dart.library.io' || 'dart.library.ffi' => !web,
          'dart.library.js_interop' || 'dart.library.html' => web,
          _ => false,
        };
        if (enabled) {
          target = condition.uri.stringValue!;
          break;
        }
      }
      final names = exported(resolve(uri, target), web: web);
      for (final combinator in directive.combinators) {
        switch (combinator) {
          case ShowCombinator(:final shownNames):
            final shown = shownNames.map((name) => name.name).toSet();
            names.removeWhere((name, _) => !shown.contains(name));
          case HideCombinator(:final hiddenNames):
            for (final name in hiddenNames) {
              names.remove(name.name);
            }
        }
      }
      result.addAll(names);
    }

    return result;
  }
}

List<String> _names(CompilationUnitMember declaration) => switch (declaration) {
  ClassDeclaration(:final namePart) || EnumDeclaration(:final namePart) => [
    namePart.toSource().split('<').firstOrNull!,
  ],
  ExtensionDeclaration(:final name) => [if (name != null) name.lexeme],
  GenericTypeAlias(:final name) || FunctionDeclaration(:final name) => [
    name.lexeme,
  ],
  TopLevelVariableDeclaration(:final variables) => [
    for (final variable in variables.variables) variable.name.lexeme,
  ],
  _ => throw StateError('Unsupported public declaration: $declaration'),
};

/// Exact declarations and signatures, including extension members and defaults.
Map<String, String> memberSignatures(
  Map<String, CompilationUnitMember> declarations,
) {
  final result = <String, String>{};
  for (final MapEntry(:key, :value) in declarations.entries) {
    final members = switch (value) {
      ClassDeclaration(body: ClassBody(:final members)) ||
      ExtensionDeclaration(body: ClassBody(:final members)) ||
      EnumDeclaration(body: EnumBody(:final members)) => members,
      _ => <ClassMember>[],
    };
    for (final member in members) {
      final names = switch (member) {
        ConstructorDeclaration(:final name) => [name?.lexeme ?? 'new'],
        MethodDeclaration(:final name) => [name.lexeme],
        FieldDeclaration(:final fields) => [
          for (final field in fields.variables) field.name.lexeme,
        ],
        _ => throw StateError('Unsupported member: $member'),
      };
      final body = switch (member) {
        ConstructorDeclaration(body: final functionBody) ||
        MethodDeclaration(body: final functionBody) => functionBody,
        _ => null,
      };
      final end = body?.offset ?? member.end;
      final signature = _tokens(member, end);
      for (final name in names.where(
        (candidate) => !candidate.startsWith('_'),
      )) {
        result['$key.$name'] = signature;
      }
    }
    if (value is EnumDeclaration) {
      for (final constant in value.body.constants) {
        result['$key.${constant.name.lexeme}'] = constant.toSource();
      }
    }
  }

  return result;
}

String _tokens(AstNode node, int end) {
  final parts = <String>[];
  var token = node is AnnotatedNode
      ? node.firstTokenAfterCommentAndMetadata
      : node.beginToken;
  while (token.offset < end && !token.isEof) {
    parts.add(token.lexeme);
    final next = token.next;
    if (next == null) break;
    token = next;
  }

  return parts.join(' ');
}

/// Declaration headers preserve typedef signatures and inheritance clauses.
Map<String, String> declarationSignatures(
  Map<String, CompilationUnitMember> declarations,
) => {
  for (final MapEntry(:key, :value) in declarations.entries)
    key: _tokens(value, switch (value) {
      ClassDeclaration(body: ClassBody(:final offset)) ||
      ExtensionDeclaration(body: ClassBody(:final offset)) ||
      EnumDeclaration(body: EnumBody(:final offset)) => offset,
      FunctionDeclaration(:final functionExpression) =>
        functionExpression.body.offset,
      _ => value.end,
    }),
};
