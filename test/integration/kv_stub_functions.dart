import 'package:dart_monty/dart_monty.dart';

/// String KV handlers shared by the network matrices and offline regression.
List<HostFunction> kvStubFunctions(
  Map<String, String> kv, {
  required String storedResult,
}) => [
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_set',
      description: 'Set',
      params: [
        HostParam(name: 'k', type: HostParamType.string),
        HostParam(name: 'v', type: HostParamType.string),
      ],
    ),
    handler: (args, _) async {
      kv[(args['k']! as MontyString).value] = (args['v']! as MontyString).value;

      return MontyString(storedResult);
    },
  ),
  HostFunction(
    schema: const HostFunctionSchema(
      name: 'kv_get',
      description: 'Get',
      params: [HostParam(name: 'k', type: HostParamType.string)],
    ),
    handler: (args, _) async =>
        MontyValue.fromDart(kv[(args['k']! as MontyString).value]),
  ),
];
