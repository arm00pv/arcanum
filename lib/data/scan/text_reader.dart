import 'dart:math' as math;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'package:arcanum/domain/scan/card_scan.dart';

/// Reads the text off a photograph and says where on it each line sat.
///
/// An interface rather than the recogniser itself so the screen that uses it
/// can be tested, and so a second engine could be dropped in without the rest
/// of the feature noticing.
abstract interface class CardTextReader {
  /// Every line of text in the picture at [path].
  Future<List<ScannedLine>> read(String path);

  /// Releases the recogniser. Called when the screen goes away.
  Future<void> close();
}

/// The on-device reader: ML Kit's Latin-script text recognition.
///
/// On-device is the whole point. A card photograph is a picture of something
/// the collector owns, in their house, and sending it to a service to be read
/// would be a strange price to pay for not typing eleven characters.
///
/// The model is bundled with the app rather than downloaded from Play Services,
/// so scanning works the first time it is opened, offline, on a phone that has
/// never signed in to anything.
class MlKitTextReader implements CardTextReader {
  TextRecognizer? _recogniser;

  @override
  Future<List<ScannedLine>> read(String path) async {
    final recogniser = _recogniser ??= TextRecognizer(
      script: TextRecognitionScript.latin,
    );
    final image = InputImage.fromFilePath(path);
    final recognised = await recogniser.processImage(image);

    // ML Kit reports each line's box in pixels. Turning those into fractions of
    // the picture is what lets the parser tell a card's name from its rarity,
    // so the height has to be right - and when the platform does not say, the
    // lowest line in the picture is the best estimate available.
    final lines = <TextLine>[
      for (final TextBlock block in recognised.blocks) ...block.lines,
    ];
    if (lines.isEmpty) return const <ScannedLine>[];

    var height = image.metadata?.size.height.toDouble() ?? 0;
    if (height <= 0) {
      for (final TextLine line in lines) {
        height = math.max(height, line.boundingBox.bottom);
      }
    }
    if (height <= 0) return const <ScannedLine>[];

    return <ScannedLine>[
      for (final TextLine line in lines)
        ScannedLine(
          line.text,
          top: (line.boundingBox.top / height).clamp(0.0, 1.0),
          height: line.boundingBox.height / height,
          confidence: line.confidence,
        ),
    ];
  }

  @override
  Future<void> close() async {
    await _recogniser?.close();
    _recogniser = null;
  }
}
