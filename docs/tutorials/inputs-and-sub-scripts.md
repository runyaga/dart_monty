# Nested execution

A host handler cannot re-enter the shared bridge that suspended it. Use
`HostContext.subExecute` when the handler owns the source, or register the host
function from `buildRunScriptFunction` when the application resolves source by
path.

[HostContext.subExecute](https://github.com/runyaga/dart_monty/blob/main/lib/src/host/context.dart)
defines sub-execution, and
[buildRunScriptFunction](https://github.com/runyaga/dart_monty/blob/main/lib/src/extensions/run_script.dart)
defines loader and input-name requirements.
