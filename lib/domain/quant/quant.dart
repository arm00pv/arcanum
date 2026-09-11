/// On-device quantitative price analytics for Arcanum.
///
/// Pure Dart: no Flutter, no network, no persistence, no machine learning.
/// Every figure this library reports is a closed form statistic that can be
/// checked by hand, and every figure it cannot compute is `null` rather than a
/// guess.
///
/// Typical use:
///
/// ```dart
/// import 'package:arcanum/domain/quant/quant.dart';
///
/// final analytics = analyzeSeries(points, windowDays: 365);
/// if (analytics.thinData) {
///   // show the price only
/// } else {
///   print(analytics.headline);   // e.g. "Rising"
///   print(analytics.summary);    // plain-English explanation
///   for (final row in analytics.readings) {
///     print('${row.label}: ${row.value} (${row.interpretation})');
///   }
/// }
/// ```
library;

export 'analytics.dart';
export 'models.dart';
