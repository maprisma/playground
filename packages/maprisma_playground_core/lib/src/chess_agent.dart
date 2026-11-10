import 'i18n.dart';
import 'chess_rules.dart' as rules;
import 'agent_run.dart';
import 'runner.dart';
import 'agents.dart';

String sideName(String side) => side == 'w' ? tr("White") : tr("Black");
String chessPrompt(
  rules.Position start,
  List<rules.Move> moves,
  String agentSide, {
  String level = 'normal',
  String strength = 'club',
}) {
  var pos = start;
  for (final move in moves) {
    pos = rules.apply(pos, move);
  }
  final legal = rules.legalMoves(pos).map((m) => rules.san(pos, m)).toList()..sort();
  var last = start;
  for (final move in moves.take((moves.length - 1).clamp(0, moves.length))) {
    last = rules.apply(last, move);
  }
  return [
    'We are playing a game of chess. You play ${sideName(agentSide)}, I play ${sideName(agentSide == 'w' ? 'b' : 'w')}.',
    'Current position (FEN): ${rules.fen(pos)}',
    if (moves.isNotEmpty) ...[
      'Moves so far: ${rules.gameSan(start, moves)}',
      'My last move: ${rules.san(last, moves.last)}',
    ] else
      'You make the first move.',
    'Your legal moves: ${legal.join(', ')}',
    'Play ${strengthPrompts[strength] ?? strengthPrompts['club']}; you have about ${seconds(level) * 2 ~/ 3} seconds to think.',
    'Answer with your move in standard algebraic notation (SAN) alone on the first line.',
    'Then say in at most two short sentences what the idea of your move is.',
    'Do not use any tools and do not ask questions.',
  ].join('\n');
}

String commentOf(String answer, String written) {
  final lines = answer.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (lines.isNotEmpty &&
      written.isNotEmpty &&
      lines.first
          .replaceAll(RegExp(r'^[*`. ]+|[*`. ]+$'), '')
          .replaceAll(' ', '')
          .endsWith(written.replaceAll(' ', '')) &&
      lines.first.length <= written.length + 12) {
    lines.removeAt(0);
  }
  final text = lines.join(' ');
  return text.length > 600 ? '${text.substring(0, 600)}…' : text;
}

String retryPrompt(String first, String writtenAnswer) {
  var said = writtenAnswer.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ');
  if (said.length > 200) said = said.substring(0, 200);
  return '$first\n\nYour previous answer did not contain one of your legal moves${said.isEmpty ? '' : ' (it began: “$said”)'}. Answer again: one legal move from the list, in SAN, alone on the first line.';
}

class ChessReply {
  const ChessReply(this.move, this.written, this.comment, {this.error = ''});
  final rules.Move? move;
  final String written, comment, error;
  Map<String, Object?> toJson() => {
    if (move != null) 'move': move!.uci(),
    'written': written,
    'comment': comment,
    'error': error,
  };
}

Future<ChessReply> askChess(
  ProcessRunner runner,
  String command,
  String text,
  rules.Position pos, {
  String level = 'normal',
  CancelToken? cancel,
}) async {
  if (!canAsk(command)) {
    return ChessReply(null, '', '', error: tr("This agent cannot be asked for a move."));
  }
  final answer = await askAgent(runner, command, text, level: level, cancel: cancel, maxBytes: 64 * 1024);
  if (answer.text.isEmpty) return ChessReply(null, '', '', error: answer.error);
  final (move, written) = rules.findMove(pos, answer.text);
  return ChessReply(move, written, commentOf(answer.text, written));
}
