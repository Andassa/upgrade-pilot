import 'dart:io';

import 'package:upgrade_pilot/upgrade_pilot.dart';

Future<void> main(List<String> arguments) async {
  final host = LocalHost();
  final code = await runCli(
    arguments,
    Services(
      fs: LocalFileSystem(),
      runner: LocalProcessRunner(environment: host.environment),
      http: AllowlistedHttp(userAgent: 'upgrade-pilot/$packageVersion'),
      host: host,
      clock: DateTime.now,
      console: StdioConsole(),
    ),
  );
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
