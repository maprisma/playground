import 'package:test/test.dart';
import 'package:maprisma_playground_core/maprisma_playground_core.dart';
import 'test_environment.dart';

void main() {
  test('first and later move prompts, strengths and thinking', () {
    final pos = start();
    final move = parse(pos, 'e4')!;
    final first = chessPrompt(pos, [], 'w');
    expect(first, contains('You play White, I play Black.'));
    expect(first, contains(startFen));
    expect(first, contains('You make the first move.'));
    final later = chessPrompt(pos, [move], 'b');
    expect(later, contains('Moves so far: 1. e4'));
    expect(later, contains('My last move: e4'));
    expect(later, contains('Nf6'));
    expect(chessPrompt(pos, [], 'w', strength: 'nonsense'), contains('good club player'));
    expect(chessPrompt(pos, [], 'w', strength: 'max', level: 'quick'), contains('as strongly as you can'));
    expect(chessPrompt(pos, [], 'w', strength: 'beginner', level: 'max'), contains('about 240 seconds'));
    expect(seconds('unknown'), 90);
  });
  test('retry is bounded and comment drops only a move-only line', () {
    final text = retryPrompt('P', 'hello\n' * 200);
    expect(text, startsWith('P\n\n'));
    expect(text.length, lessThan(400));
    expect(commentOf('**Nf6**\nDeveloping.', 'Nf6'), 'Developing.');
    expect(commentOf('I play Nf6 to develop.', 'Nf6'), 'I play Nf6 to develop.');
    expect(commentOf('x' * 5000, '').length, 601);
  });
  test('chess asks with stdin and parses Claude JSON', () async {
    final e = TestEnvironment();
    addTearDown(e.dispose);
    e.script('claude', r'''
import sys,json
assert 'private prompt' not in sys.argv
assert sys.stdin.read()=='private prompt'
print(json.dumps({'type':'result','result':'e5\nThe classical answer: I claim the centre.'}))
''');
    final pos = apply(start(), parse(start(), 'e4')!);
    final reply = await askChess(e.runner, 'claude', 'private prompt', pos);
    expect(reply.move, parse(pos, 'e5'));
    expect(reply.comment, 'The classical answer: I claim the centre.');
    expect(reply.error, isEmpty);
    e.script('pi', "print('I would rather not play.')");
    final no = await askChess(e.runner, 'pi', 'p', pos);
    expect(no.move, isNull);
    expect(no.comment, 'I would rather not play.');
  });
}
