import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/errors/app_error.dart';

void main() {
  group('Result', () {
    test('Ok and Err carry their payload and switch exhaustively', () {
      const Result<int> ok = Ok(7);
      const Result<int> err = Err(ConflictError());
      String label(Result<int> r) => switch (r) {
        Ok(:final value) => 'ok:$value',
        Err(:final error) => 'err:${error.runtimeType}',
      };
      expect(label(ok), 'ok:7');
      expect(label(err), 'err:ConflictError');
    });

    test('equality follows the payload', () {
      expect(const Ok<int>(1), equals(const Ok<int>(1)));
      expect(const Ok<int>(1).hashCode, const Ok<int>(1).hashCode);
      expect(const Ok<int>(1), isNot(equals(const Ok<int>(2))));
      expect(
        const Err<int>(NetworkError('x')),
        equals(const Err<int>(NetworkError('x'))),
      );
      expect(
        const Err<int>(NetworkError('x')),
        isNot(equals(const Err<int>(NetworkError('y')))),
      );
    });
  });

  group('AppError equality', () {
    // One test per family: errors with a field compare by it (and by type);
    // field-less errors are interchangeable.
    test('errors that carry a field compare by that field and type', () {
      expect(const NetworkError('x'), equals(const NetworkError('x')));
      expect(
        const NetworkError('x').hashCode,
        const NetworkError('x').hashCode,
      );
      expect(const NetworkError('x'), isNot(equals(const NetworkError('y'))));
      expect(const NetworkError('x'), isNot(equals(const ServerError(500))));
      expect(const ServerError(500), equals(const ServerError(500)));
      expect(const ServerError(500), isNot(equals(const ServerError(503))));
      expect(const UnknownError('a'), isNot(equals(const UnknownError('b'))));
      expect(const UnknownError(), equals(const UnknownError()));
      expect(const NetworkError('timeout').toString(), contains('timeout'));
    });

    test('RateLimitError compares by retryAfter, including absent', () {
      expect(const RateLimitError(60), equals(const RateLimitError(60)));
      expect(
        const RateLimitError(60),
        isNot(equals(const RateLimitError(120))),
      );
      expect(const RateLimitError(60), isNot(equals(const RateLimitError())));
    });

    test('field-less errors are equal to each other', () {
      expect(const UnauthorizedError(), equals(const UnauthorizedError()));
      expect(const ConflictError(), equals(const ConflictError()));
      expect(const NotFoundError(), equals(const NotFoundError()));
      expect(const ConflictError(), isNot(equals(const NotFoundError())));
    });
  });

  group('AppError.userMessage', () {
    test('NetworkError', () {
      const e = NetworkError('timeout');
      expect(
        e.userMessage,
        'No internet connection. Check your network and try again.',
      );
    });
    test('UnauthorizedError', () {
      expect(
        const UnauthorizedError().userMessage,
        'Your session has expired. Please log in again.',
      );
    });
    test('ConflictError', () {
      expect(const ConflictError().userMessage, 'That item already exists.');
    });
    test('RateLimitError without retryAfter', () {
      expect(
        const RateLimitError().userMessage,
        'Too many requests. Please wait a moment.',
      );
    });
    test('RateLimitError with retryAfter shows minutes', () {
      expect(
        const RateLimitError(120).userMessage,
        'Too many requests. Try again in 2 minutes.',
      );
    });
    test('RateLimitError with retryAfter 45s rounds up to 1 minute', () {
      expect(
        const RateLimitError(45).userMessage,
        'Too many requests. Try again in 1 minute.',
      );
    });
    test('RateLimitError with retryAfter 0 falls back to generic', () {
      expect(
        const RateLimitError(0).userMessage,
        'Too many requests. Please wait a moment.',
      );
    });
    test('NotFoundError', () {
      expect(const NotFoundError().userMessage, 'The item could not be found.');
    });
    test('ServerError', () {
      expect(
        const ServerError(500).userMessage,
        'Something went wrong on our end. Please try again later.',
      );
    });
    test('UnknownError', () {
      expect(const UnknownError().userMessage, 'An unexpected error occurred.');
    });
  });
}
