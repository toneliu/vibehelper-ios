import 'package:flutter/material.dart';

const _markdownExts = {'md', 'markdown'};

const _codeHighlightExts = {
  'py', 'dart', 'js', 'ts', 'tsx', 'jsx', 'json', 'jsonl', 'yaml', 'yml',
  'toml', 'ini', 'sh', 'swift', 'kt', 'java', 'c', 'h', 'cpp', 'rs', 'go',
  'sql', 'html', 'htm', 'xml', 'md', 'markdown',
};

const _maxHighlightChars = 80 * 1024;

bool isMarkdownExt(String ext) => _markdownExts.contains(ext.toLowerCase());

bool isCodeHighlightExt(String ext) =>
    _codeHighlightExts.contains(ext.toLowerCase());

const _baseColor = Color(0xFFE5E7EB);
const _commentColor = Color(0xFF6B7280);
const _stringColor = Color(0xFF34D399);
const _keywordColor = Color(0xFFC084FC);
const _decoratorColor = Color(0xFFFBBF24);
const _numberColor = Color(0xFFF59E0B);
const _keyOrTypeColor = Color(0xFF38BDF8);

const _literalWords = {
  'true', 'false', 'null', 'nil', 'undefined', 'True', 'False', 'None',
  'NaN', 'Infinity', 'self', 'this', 'super',
};

const _pyKeywords = {
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
  'case', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
  'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda',
  'match', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while',
  'with', 'yield',
};

const _cStyleKeywords = {
  'abstract', 'as', 'async', 'await', 'bool', 'break', 'case', 'catch',
  'class', 'const', 'continue', 'default', 'defer', 'do', 'double', 'dynamic',
  'else', 'enum', 'export', 'extends', 'extension', 'external', 'factory',
  'final', 'finally', 'float', 'for', 'from', 'fun', 'func', 'function',
  'get', 'go', 'guard', 'if', 'implements', 'import', 'in', 'init', 'int',
  'interface', 'internal', 'is', 'late', 'let', 'match', 'mixin', 'mut',
  'new', 'null', 'object', 'operator', 'override', 'package', 'private',
  'protected', 'pub', 'public', 'required', 'return', 'sealed', 'set',
  'show', 'static', 'struct', 'super', 'switch', 'this', 'throw', 'throws',
  'trait', 'try', 'type', 'typedef', 'typeof', 'use', 'val', 'var', 'void',
  'when', 'where', 'while', 'with', 'yield',
};

const _shKeywords = {
  'case', 'do', 'done', 'elif', 'else', 'esac', 'export', 'fi', 'for',
  'function', 'if', 'in', 'local', 'readonly', 'return', 'select', 'set',
  'then', 'trap', 'unset', 'until', 'while',
};

const _sqlKeywords = {
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET',
  'DELETE', 'CREATE', 'TABLE', 'ALTER', 'DROP', 'INDEX', 'JOIN', 'LEFT',
  'RIGHT', 'INNER', 'ON', 'AS', 'AND', 'OR', 'NOT', 'NULL', 'IS', 'IN',
  'ORDER', 'BY', 'GROUP', 'HAVING', 'LIMIT', 'OFFSET', 'DISTINCT', 'UNION',
  'select', 'from', 'where', 'insert', 'into', 'values', 'update', 'set',
  'delete', 'create', 'table', 'alter', 'drop', 'index', 'join', 'left',
  'right', 'inner', 'on', 'as', 'and', 'or', 'not', 'null', 'is', 'in',
  'order', 'by', 'group', 'having', 'limit', 'offset', 'distinct', 'union',
};

Set<String> _keywordsFor(String ext) {
  switch (ext.toLowerCase()) {
    case 'py':
      return _pyKeywords;
    case 'sh':
      return _shKeywords;
    case 'sql':
      return _sqlKeywords;
    case 'json':
    case 'jsonl':
    case 'yaml':
    case 'yml':
    case 'toml':
    case 'ini':
    case 'html':
    case 'htm':
    case 'xml':
    case 'md':
    case 'markdown':
      return const {};
    default:
      return _cStyleKeywords;
  }
}

final RegExp _hashCommentTokenRe = RegExp(
  r'(?<comment>#[^\n]*|/\*[\s\S]*?\*/|<!--[\s\S]*?-->)'
  r'|(?<key>"(?:\\.|[^"\\\n])*"(?=\s*:)|(?<=^|\n)[ \t-]*[A-Za-z_][A-Za-z0-9_.-]*(?=\s*:))'
  r'|(?<str>[rRbBfFuU]?"""[\s\S]*?"""|[rRbBfFuU]?\x27\x27\x27[\s\S]*?\x27\x27\x27|[rRbBfFuU]?"(?:\\.|[^"\\\n])*"|[rRbBfFuU]?\x27(?:\\.|[^\x27\\\n])*\x27|`(?:\\.|[^`\\])*`)'
  r'|(?<deco>@[A-Za-z_][A-Za-z0-9_.]*)'
  r'|(?<num>\b(?:0[xXbBoO][0-9a-fA-F_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b)'
  r'|(?<word>\b[A-Za-z_][A-Za-z0-9_]*\b)',
);

final RegExp _slashCommentTokenRe = RegExp(
  r'(?<comment>//[^\n]*|/\*[\s\S]*?\*/|<!--[\s\S]*?-->|--[ \t][^\n]*)'
  r'|(?<key>"(?:\\.|[^"\\\n])*"(?=\s*:))'
  r'|(?<str>"(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27|`(?:\\.|[^`\\])*`)'
  r'|(?<deco>@[A-Za-z_][A-Za-z0-9_.]*|<\/?[A-Za-z][A-Za-z0-9:._-]*>)'
  r'|(?<num>\b(?:0[xXbBoO][0-9a-fA-F_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?)\b)'
  r'|(?<word>\b[A-Za-z_][A-Za-z0-9_]*\b)',
);

bool _usesHashComment(String ext) {
  switch (ext.toLowerCase()) {
    case 'py':
    case 'sh':
    case 'yaml':
    case 'yml':
    case 'toml':
    case 'ini':
    case 'md':
    case 'markdown':
      return true;
    default:
      return false;
  }
}

bool _isCapitalizedType(String word) {
  if (word.length < 2) return false;
  final first = word.codeUnitAt(0);
  if (first < 65 || first > 90) return false;
  for (int i = 1; i < word.length; i++) {
    final c = word.codeUnitAt(i);
    if (c >= 97 && c <= 122) return true;
  }
  return false;
}

TextSpan buildHighlightedCodeSpan(
  String source,
  String ext, {
  double fontSize = 12.5,
}) {
  final baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: fontSize,
    height: 1.5,
    color: _baseColor,
  );
  if (source.isEmpty) {
    return TextSpan(style: baseStyle, text: '');
  }

  final limit =
      source.length > _maxHighlightChars ? _maxHighlightChars : source.length;
  final head = limit == source.length ? source : source.substring(0, limit);
  final tail = limit == source.length ? '' : source.substring(limit);

  final keywords = _keywordsFor(ext);
  final re = _usesHashComment(ext) ? _hashCommentTokenRe : _slashCommentTokenRe;
  final spans = <InlineSpan>[];
  int lastEnd = 0;

  for (final m in re.allMatches(head)) {
    if (m.start > lastEnd) {
      spans.add(TextSpan(text: head.substring(lastEnd, m.start)));
    }
    final tok = m.group(0)!;
    TextStyle? style;

    if (m.namedGroup('comment') != null) {
      style = baseStyle.copyWith(
        color: _commentColor,
        fontStyle: FontStyle.italic,
      );
    } else if (m.namedGroup('str') != null) {
      style = baseStyle.copyWith(color: _stringColor);
    } else if (m.namedGroup('key') != null) {
      style = baseStyle.copyWith(
        color: _keyOrTypeColor,
        fontWeight: FontWeight.w500,
      );
    } else if (m.namedGroup('deco') != null) {
      style = baseStyle.copyWith(color: _decoratorColor);
    } else if (m.namedGroup('num') != null) {
      style = baseStyle.copyWith(color: _numberColor);
    } else if (m.namedGroup('word') != null) {
      if (keywords.contains(tok)) {
        style = baseStyle.copyWith(
          color: _keywordColor,
          fontWeight: FontWeight.w600,
        );
      } else if (_literalWords.contains(tok)) {
        style = baseStyle.copyWith(color: _numberColor);
      } else if (_isCapitalizedType(tok)) {
        style = baseStyle.copyWith(color: _keyOrTypeColor);
      }
    }

    spans.add(TextSpan(text: tok, style: style));
    lastEnd = m.end;
  }

  if (lastEnd < head.length) {
    spans.add(TextSpan(text: head.substring(lastEnd)));
  }
  if (tail.isNotEmpty) {
    spans.add(TextSpan(text: tail));
  }

  return TextSpan(style: baseStyle, children: spans);
}
