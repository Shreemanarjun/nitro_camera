/// Declarative, constraint-driven camera configuration + format negotiation.
///
/// Mirrors vision-camera's session-configuration + constraint model:
///  * [CameraConfiguration] — immutable desired session state (+ `copyWith`, diff).
///  * [CameraConstraint] / [FormatResolver] — prioritised format negotiation.
library;

export 'camera_configuration.dart';
export 'constraints.dart';
export 'format_resolver.dart';
