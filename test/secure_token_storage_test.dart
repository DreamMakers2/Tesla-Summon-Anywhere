import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:summon_anywhere_tesla/core/storage/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = SecureStorage(FlutterSecureStorage());

  test(
    'existing token keys remain readable without credential migration',
    () async {
      final expiry = DateTime.now().add(const Duration(hours: 1));
      FlutterSecureStorage.setMockInitialValues({
        'tesla_access_token': 'ACCESS_FIXTURE',
        'tesla_refresh_token': 'REFRESH_FIXTURE',
        'tesla_token_expiry': expiry.toIso8601String(),
        'tesla_client_secret': 'OLD_SECRET_FIXTURE',
      });
      expect(await storage.getAccessToken(), 'ACCESS_FIXTURE');
      expect(await storage.getRefreshToken(), 'REFRESH_FIXTURE');
      expect(await storage.getTokenExpiry(), expiry);
      await storage.saveTokens(
        accessToken: 'NEW_ACCESS_FIXTURE',
        refreshToken: 'NEW_REFRESH_FIXTURE',
        expiry: expiry,
      );
      expect(await storage.getAccessToken(), 'NEW_ACCESS_FIXTURE');
      expect(await storage.getRefreshToken(), 'NEW_REFRESH_FIXTURE');
      expect(
        await const FlutterSecureStorage().read(key: 'tesla_client_secret'),
        'OLD_SECRET_FIXTURE',
      );
    },
  );
}
