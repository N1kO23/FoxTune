import 'package:integration_test/integration_test_driver.dart';

/// Host side of the dashboard benchmark: writes the frame timings the test
/// reports to build/integration_response_data.json.
Future<void> main() => integrationDriver();
