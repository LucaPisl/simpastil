import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/errors/app_error.dart';
import 'package:simpastil/core/errors/app_error_l10n.dart';
import 'package:simpastil/l10n/app_localizations.dart';

void main() {
  test('the logout warning is localized with correct plurals', () async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    final ro = await AppLocalizations.delegate.load(const Locale('ro'));
    expect(en.settings_logOutUnsynced(1), contains('1 unsynced change'));
    expect(en.settings_logOutUnsynced(3), contains('3 unsynced changes'));
    expect(ro.settings_logOutUnsynced(1), contains('o modificare'));
    expect(ro.settings_logOutUnsynced(3), contains('3 modificări'));
    expect(ro.settings_logOutUnsynced(20), contains('20 de modificări'));
    expect(ro.settings_logOutUnsynced(3), isNot(contains('unsynced')));
  });

  test('Romanian pin and sync strings use comma-below diacritics', () async {
    final ro = await AppLocalizations.delegate.load(const Locale('ro'));
    final all = [
      ro.pin_trustTitle,
      ro.pin_trustBody('exemplu.ro'),
      ro.pin_changedTitle,
      ro.pin_confirmTrustBody,
      ro.pin_confirmNormalBody,
      ro.auth_resetUnavailableBody,
    ].join(' ');
    // Cedilla forms (ş ţ Ş Ţ) are wrong for Romanian.
    expect(all, isNot(matches(RegExp('[şţŞŢ]'))));
  });

  test('errors shown to people follow the app language, not English', () async {
    final ro = await AppLocalizations.delegate.load(const Locale('ro'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    const totp = ServerCodeError(400, 'TOTP_INVALID_CODE', 'Invalid code');
    expect(localizedAppErrorMessage(en, totp), totp.userMessage);
    expect(
      localizedAppErrorMessage(ro, totp),
      'Cod de verificare nevalid. Încearcă din nou.',
    );
    expect(
      localizedAppErrorMessage(ro, const RateLimitError(120)),
      contains('2 minute'),
    );
    expect(
      localizedAppErrorMessage(ro, const RateLimitError(60 * 60 * 10)),
      contains('600 de minute'),
    );
    expect(
      localizedAppErrorMessage(en, const RateLimitError(45)),
      contains('1 minute'),
    );
    // An unknown server message is never shown verbatim.
    expect(
      localizedAppErrorMessage(
        ro,
        const ServerCodeError(500, 'X', 'English only'),
      ),
      isNot(contains('English only')),
    );
    for (final error in <AppError>[
      const NetworkError('x'),
      const UnauthorizedError(),
      const ConflictError(),
      const NotFoundError(),
      const ServerError(500),
      const UnknownError(),
    ]) {
      expect(localizedAppErrorMessage(ro, error), isNot(error.userMessage));
    }
  });
}
