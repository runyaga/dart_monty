/// Where the published demo pages find dart_monty_core's browser worker.
///
/// The site serves core's `dart_monty_core_worker.js` and
/// `dart_monty_core_worker.wasm` next to the pages (pages.yaml and
/// `tool/check_demo_pages.sh` copy core's `lib/assets/` to the site root),
/// so every demo names that location instead of relying on core's search
/// of the package asset paths.
library;

import 'package:dart_monty/dart_monty.dart';

/// The asset base of core's worker on the published site: the page's own
/// directory.
const String demoWorkerLocation = '.';

/// Starts a pool of browser workers on [demoWorkerLocation]; the caller
/// closes it. A checkout waits at most 30 seconds for a free worker.
Future<Monty> startDemoPool({int? maxProcesses}) => Monty.start(
      maxProcesses: maxProcesses,
      checkoutTimeout: const Duration(seconds: 30),
      workerLocation: demoWorkerLocation,
    );
