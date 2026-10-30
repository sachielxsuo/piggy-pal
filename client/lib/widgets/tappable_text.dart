import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 可点的英文单词文本：点中英文词时回调单词本身，以及它在屏幕上的位置。
///
/// 位置用于把词典卡片贴在单词上方（popover），所以要在点击时用 TextPainter
/// 重新量一遍这个词的位置——不重新排版就只知道手指落在哪，卡片会盖住单词。
class TappableText extends StatefulWidget {
  final String text;
  final TextStyle style;

  /// 点中英文词的回调；为空时退化成普通文本。
  ///
  /// [globalRect] 是该词在屏幕坐标系里的矩形，拿不到时为 [Rect.zero]。
  final void Function(String word, Rect globalRect)? onWordTap;

  const TappableText({
    super.key,
    required this.text,
    required this.style,
    this.onWordTap,
  });

  @override
  State<TappableText> createState() => _TappableTextState();
}

class _TappableTextState extends State<TappableText> {
  // 英文词 / 其它字符：英文词可能带撇号（don't）
  static final RegExp _tokenRE =
      RegExp(r"[A-Za-z]+(?:['’][A-Za-z]+)?|[^A-Za-z]+");

  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  List<InlineSpan> _buildSpans(double maxWidth) {
    _disposeRecognizers();
    final spans = <InlineSpan>[];
    for (final m in _tokenRE.allMatches(widget.text)) {
      final token = m.group(0)!;
      final isWord = RegExp(r'^[A-Za-z]').hasMatch(token);
      if (!isWord || widget.onWordTap == null) {
        spans.add(TextSpan(text: token));
        continue;
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onWordTap!(
              token,
              _wordRect(m.start, m.end, maxWidth),
            );
      _recognizers.add(recognizer);
      spans.add(TextSpan(text: token, recognizer: recognizer));
    }
    return spans;
  }

  /// 量出 [start, end) 这段文字在屏幕上的矩形。
  ///
  /// 用和正文同样的样式、同样的可用宽度重排一次，再叠加文本自身的全局偏移；
  /// 这样多行换行、emoji / 中文混排都能落到正确的位置。
  Rect _wordRect(int start, int end, double maxWidth) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.attached) return Rect.zero;

    final painter = TextPainter(
      text: TextSpan(
        text: widget.text,
        // Text 会把外层 DefaultTextStyle 合并进来，量的时候也要合并，否则字宽对不上
        style: DefaultTextStyle.of(context).style.merge(widget.style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: maxWidth);

    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    var local = boxes.isEmpty ? Offset.zero & painter.size : boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      local = local.expandToInclude(box.toRect());
    }
    painter.dispose();

    return local.shift(renderBox.localToGlobal(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return Text.rich(
          TextSpan(style: widget.style, children: _buildSpans(maxWidth)),
        );
      },
    );
  }
}
