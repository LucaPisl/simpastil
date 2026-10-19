import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Server certificate fingerprints.
///
/// The fingerprint is the SHA-256 of the DER `SubjectPublicKeyInfo` of the
/// server's leaf certificate, written as 32 uppercase hex byte pairs joined by
/// colons (95 characters). It is exactly what `scripts/init-deploy.sh` prints
/// and what the "Certificate fingerprint" command in DEPLOYMENT.md computes, so
/// an administrator can compare the two by eye. It changes only when the key
/// changes, not when the certificate is renewed with the same key.

final RegExp _fingerprintPattern = RegExp(r'^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$');

/// True for a canonical fingerprint: 32 uppercase hex pairs, colon separated.
bool isWellFormedFingerprint(String value) =>
    _fingerprintPattern.hasMatch(value);

/// Formats a SHA-256 [digest] as uppercase hex pairs joined by colons.
String formatFingerprint(List<int> digest) {
  const hex = '0123456789ABCDEF';
  final out = StringBuffer();
  for (var i = 0; i < digest.length; i++) {
    if (i > 0) out.write(':');
    out
      ..write(hex[digest[i] >> 4])
      ..write(hex[digest[i] & 0x0f]);
  }
  return out.toString();
}

/// The fingerprint of the key in the DER-encoded X.509 [certificate].
///
/// Throws a [FormatException] when the bytes are not a well-formed certificate.
String spkiFingerprintOfCertificate(Uint8List certificate) => formatFingerprint(
  sha256.convert(subjectPublicKeyInfoOf(certificate)).bytes,
);

/// Extracts the complete DER `SubjectPublicKeyInfo` (tag, length and content)
/// from a DER X.509 certificate.
///
/// A hand-written walk over the fixed prefix of `TBSCertificate`:
///
///     Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
///     TBSCertificate ::= SEQUENCE {
///       [0] version OPTIONAL, serialNumber, signature, issuer, validity,
///       subject, subjectPublicKeyInfo, ... }
///
/// Every length is bounds-checked, indefinite and non-minimal lengths are
/// refused (DER forbids them) and the certificate must end exactly where its
/// outer SEQUENCE ends.
Uint8List subjectPublicKeyInfoOf(Uint8List certificate) {
  final cert = _readTlv(certificate, 0, certificate.length);
  if (cert.tag != _sequence || cert.end != certificate.length) {
    throw const FormatException('Not a DER certificate');
  }
  final tbs = _readTlv(certificate, cert.contentStart, cert.end);
  if (tbs.tag != _sequence) {
    throw const FormatException('Malformed TBSCertificate');
  }
  var offset = tbs.contentStart;
  var field = _readTlv(certificate, offset, tbs.end);
  if (field.tag == _contextZero) {
    offset = field.end;
    field = _readTlv(certificate, offset, tbs.end);
  }
  // serialNumber INTEGER
  if (field.tag != _integer) {
    throw const FormatException('Malformed serialNumber');
  }
  // signature, issuer, validity, subject: four SEQUENCEs.
  for (var i = 0; i < 4; i++) {
    offset = field.end;
    field = _readTlv(certificate, offset, tbs.end);
    if (field.tag != _sequence) {
      throw const FormatException('Malformed TBSCertificate');
    }
  }
  offset = field.end;
  final spki = _readTlv(certificate, offset, tbs.end);
  if (spki.tag != _sequence) {
    throw const FormatException('Malformed SubjectPublicKeyInfo');
  }
  // algorithm SEQUENCE followed by subjectPublicKey BIT STRING, nothing else.
  final algorithm = _readTlv(certificate, spki.contentStart, spki.end);
  final key = _readTlv(certificate, algorithm.end, spki.end);
  if (algorithm.tag != _sequence ||
      key.tag != _bitString ||
      key.end != spki.end) {
    throw const FormatException('Malformed SubjectPublicKeyInfo');
  }
  return Uint8List.sublistView(certificate, spki.headerStart, spki.end);
}

const int _integer = 0x02;
const int _bitString = 0x03;
const int _sequence = 0x30;
const int _contextZero = 0xa0;

class _Tlv {
  const _Tlv(this.tag, this.headerStart, this.contentStart, this.end);
  final int tag;
  final int headerStart;
  final int contentStart;
  final int end;
}

_Tlv _readTlv(Uint8List bytes, int offset, int limit) {
  if (offset < 0 || offset + 2 > limit || limit > bytes.length) {
    throw const FormatException('Truncated DER');
  }
  final tag = bytes[offset];
  if (tag & 0x1f == 0x1f) {
    throw const FormatException('High tag numbers are not used here');
  }
  final first = bytes[offset + 1];
  int length;
  int contentStart;
  if (first < 0x80) {
    length = first;
    contentStart = offset + 2;
  } else {
    final count = first & 0x7f;
    if (count == 0 || count > 4 || offset + 2 + count > limit) {
      throw const FormatException('Unsupported DER length');
    }
    if (bytes[offset + 2] == 0) {
      throw const FormatException('Non-minimal DER length');
    }
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | bytes[offset + 2 + i];
    }
    if (length < 0x80) throw const FormatException('Non-minimal DER length');
    contentStart = offset + 2 + count;
  }
  final end = contentStart + length;
  if (end > limit) {
    throw const FormatException('DER length overruns its parent');
  }
  return _Tlv(tag, offset, contentStart, end);
}
