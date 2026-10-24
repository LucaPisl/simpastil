import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/medication/medication_photo_processor.dart';
import '../../../l10n/app_localizations.dart';
import 'medication_photo_card.dart';

/// Hands over the bytes of a picture the person chose, or null when they
/// backed out. A provider so tests can pick without a platform channel.
final medicationPhotoPickerProvider =
    Provider<Future<Uint8List?> Function(ImageSource source)>(
      (ref) => (source) async {
        final file = await ImagePicker().pickImage(
          source: source,
          // Bounds the memory the decode needs; the stored copy is shrunk and
          // cleaned again by [processMedicationPhoto].
          maxWidth: 2400,
          maxHeight: 2400,
        );
        return file?.readAsBytes();
      },
    );

/// Whether this device can take a picture with its camera.
bool get _hasCamera =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// What the edit form holds about the photo: the stored one, or a change the
/// person has made and not saved yet.
class MedicationPhotoDraft {
  const MedicationPhotoDraft({this.staged, this.removed = false});
  final ProcessedMedicationPhoto? staged;
  final bool removed;
  bool get changed => staged != null || removed;
}

/// Add, replace and remove the medicine's photo inside the edit form. It only
/// reports the change through [onChanged]; the form stores it with the save.
class MedicationPhotoField extends ConsumerStatefulWidget {
  const MedicationPhotoField({
    super.key,
    required this.name,
    required this.stored,
    required this.draft,
    required this.onChanged,
    this.enabled = true,
  });

  final String name;

  /// The picture saved with the medicine now, if any.
  final Uint8List? stored;
  final MedicationPhotoDraft draft;
  final ValueChanged<MedicationPhotoDraft> onChanged;
  final bool enabled;

  @override
  ConsumerState<MedicationPhotoField> createState() =>
      _MedicationPhotoFieldState();
}

class _MedicationPhotoFieldState extends ConsumerState<MedicationPhotoField> {
  bool _working = false;
  String? _error;

  Uint8List? get _shown {
    if (widget.draft.removed) return null;
    return widget.draft.staged?.bytes ?? widget.stored;
  }

  Future<ImageSource?> _chooseSource() {
    if (!_hasCamera) return Future.value(ImageSource.gallery);
    final l = AppLocalizations.of(context);
    return showModalBottomSheet<ImageSource>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('photo-source-camera'),
            minTileHeight: 56,
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l.photo_fromCamera),
            onTap: () => Navigator.of(sheet).pop(ImageSource.camera),
          ),
          ListTile(
            key: const ValueKey('photo-source-gallery'),
            minTileHeight: 56,
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l.photo_fromGallery),
            onTap: () => Navigator.of(sheet).pop(ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _pick() async {
    if (_working) return;
    final l = AppLocalizations.of(context);
    final source = await _chooseSource();
    if (source == null || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    String? failure;
    ProcessedMedicationPhoto? processed;
    try {
      final bytes = await ref.read(medicationPhotoPickerProvider)(source);
      if (bytes != null) processed = await processMedicationPhoto(bytes);
    } on MedicationPhotoException catch (error) {
      failure = error.failure == MedicationPhotoFailure.tooLarge
          ? l.photo_tooLarge
          : l.photo_unreadable;
    } on Object {
      failure = l.photo_pickFailed;
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _error = failure;
    });
    if (processed != null) {
      widget.onChanged(MedicationPhotoDraft(staged: processed));
    }
  }

  void _remove() {
    setState(() => _error = null);
    // Dropping a photo chosen in this form goes back to the stored one.
    widget.onChanged(
      widget.draft.staged != null && widget.stored == null
          ? const MedicationPhotoDraft()
          : const MedicationPhotoDraft(removed: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final shown = _shown;
    final canAct = widget.enabled && !_working;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (shown != null) ...[
          MedicationPhotoFrame(
            key: const ValueKey('photo-preview'),
            bytes: shown,
            semanticLabel: l.photo_a11y(widget.name),
            maxHeight: 200,
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('photo-pick'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: canAct ? _pick : null,
              icon: _working
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_a_photo_outlined, size: 20),
              label: Text(shown == null ? l.photo_add : l.photo_replace),
            ),
            if (shown != null)
              TextButton.icon(
                key: const ValueKey('photo-remove'),
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: canAct ? _remove : null,
                icon: const Icon(Icons.delete_outline, size: 20),
                label: Text(l.photo_remove),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: text.bodyMedium?.copyWith(color: cs.error),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          l.photo_hint,
          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
