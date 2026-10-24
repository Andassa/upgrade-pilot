import 'package:args/args.dart';
import 'package:args/command_runner.dart';

const shells = ['bash', 'zsh', 'fish'];

List<String> _flags(ArgParser parser) => [
      for (final option in parser.options.values)
        if (!option.hide) ...[
          '--${option.name}',
          if (option.isFlag && option.negatable == true) '--no-${option.name}',
        ],
    ];

Map<String, List<String>> _commandFlags(CommandRunner<int> runner) => {
      for (final MapEntry(key: name, value: command) in runner.commands.entries)
        if (!command.hidden && name != 'help')
          name: [
            ..._flags(command.argParser),
            ...command.subcommands.keys,
          ],
    };

/// Completion script for [shell], generated from the command definitions
/// so that it never drifts from the real options.
String completionScript(String shell, CommandRunner<int> runner) {
  final commands = _commandFlags(runner);
  final global = _flags(runner.argParser);
  final names = commands.keys.join(' ');
  switch (shell) {
    case 'bash':
      final cases = commands.entries
          .map((e) => '    ${e.key}) opts="${e.value.join(' ')}" ;;')
          .join('\n');
      return '''
# upgrade-pilot bash completion
_upgrade_pilot() {
  local cur cmd opts
  cur="\${COMP_WORDS[COMP_CWORD]}"
  cmd="\${COMP_WORDS[1]}"
  if [ "\$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( \$(compgen -W "$names ${global.join(' ')}" -- "\$cur") )
    return
  fi
  case "\$cmd" in
$cases
    *) opts="" ;;
  esac
  COMPREPLY=( \$(compgen -W "\$opts ${global.join(' ')}" -- "\$cur") )
}
complete -F _upgrade_pilot upgrade-pilot
''';
    case 'zsh':
      final cases = commands.entries
          .map((e) => "    ${e.key}) compadd -- ${e.value.join(' ')} ;;")
          .join('\n');
      return '''
#compdef upgrade-pilot
# upgrade-pilot zsh completion
_upgrade_pilot() {
  if (( CURRENT == 2 )); then
    compadd -- $names ${global.join(' ')}
    return
  fi
  case "\${words[2]}" in
$cases
  esac
  compadd -- ${global.join(' ')}
}
compdef _upgrade_pilot upgrade-pilot
''';
    default:
      final buffer = StringBuffer('# upgrade-pilot fish completion\n')
        ..writeln(
          'complete -c upgrade-pilot -f -n "__fish_use_subcommand" -a "$names"',
        );
      for (final flag in global) {
        buffer.writeln('complete -c upgrade-pilot -l ${flag.substring(2)}');
      }
      for (final MapEntry(key: name, value: flags) in commands.entries) {
        for (final flag in flags) {
          if (flag.startsWith('--')) {
            buffer.writeln(
              'complete -c upgrade-pilot -n "__fish_seen_subcommand_from '
              '$name" -l ${flag.substring(2)}',
            );
          } else {
            buffer.writeln(
              'complete -c upgrade-pilot -n "__fish_seen_subcommand_from '
              '$name" -a $flag',
            );
          }
        }
      }
      return buffer.toString();
  }
}
