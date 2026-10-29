import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  testWidgets('Inter weights load from bundled assets without network', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final name in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      expect(manifest.listAssets(), contains('assets/fonts/Inter-$name.ttf'));
    }
    for (final weight in [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
    ]) {
      GoogleFonts.inter(fontWeight: weight);
    }
    await GoogleFonts.pendingFonts();
  });
}
