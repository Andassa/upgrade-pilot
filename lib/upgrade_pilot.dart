/// upgrade-pilot: simulate a Flutter upgrade in a sandbox and produce a
/// verified plan.
///
/// The command-line entry point is `runCli`; `Services` wires the
/// implementations of the ports (file system, processes, network).
library;

export 'src/cli/cli.dart' show runCli;
export 'src/cli/services.dart' show Services;
export 'src/domain/exit_codes.dart' show ExitCodes;
export 'src/domain/plan.dart';
export 'src/infra/allowlisted_http.dart' show AllowlistedHttp;
export 'src/infra/local_file_system.dart' show LocalFileSystem;
export 'src/infra/local_host.dart' show LocalHost;
export 'src/infra/local_process_runner.dart' show LocalProcessRunner;
export 'src/infra/stdio_console.dart' show StdioConsole;
export 'src/version.dart' show packageVersion;
