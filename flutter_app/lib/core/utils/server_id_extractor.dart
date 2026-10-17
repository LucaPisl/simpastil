/// Extracts the server-assigned ID from an API response body.
///
/// Handles two response shapes:
///   - Direct: `{'id': 'abc'}` → returns `'abc'`
///   - Nested: `{'data': {'id': 'abc'}}` → returns `'abc'`
///
/// Returns null when [data] is null or contains no extractable id.
String? extractServerId(Map<String, dynamic>? data) {
  if (data == null) return null;
  final direct = data['id'];
  if (direct is String) return direct;
  final nested = data['data'];
  if (nested is Map<String, dynamic>) {
    final nestedId = nested['id'];
    if (nestedId is String) return nestedId;
  }
  return null;
}
