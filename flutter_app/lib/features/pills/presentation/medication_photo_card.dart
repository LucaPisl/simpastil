import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../medication_photo_repository.dart';

/// The picture of a medicine: rounded, never cropped, and as wide as the
/// column allows up to [maxWidth]. Shows nothing while the medicine has none.
///
/// The picture is a recognition aid, not information the page depends on, so a
/// photo that cannot be read leaves the space empty instead of an error.
class MedicationPhotoCard extends ConsumerWidget {
  const MedicationPhotoCard({
    super.key,
    required this.pillId,
    required this.name,
    this.maxWidth = 420,
    this.maxHeight = 260,
    this.fill = false,
    this.gapAbove = 0,
  });

  final String pillId;
  final String name;
  final double maxWidth;
  final double maxHeight;

  /// Fills the width it is given at 4:3 and opens full screen on a tap (the
  /// medication page), instead of hugging the picture up to [maxWidth] and
  /// [maxHeight].
  final bool fill;

  /// Space kept above the picture, and only when there is one.
  final double gapAbove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(medicationPhotoProvider(pillId)).asData?.value;
    if (photo == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final label = l.photo_a11y(name);
    final frame = MedicationPhotoFrame(
      bytes: photo.bytes,
      semanticLabel: label,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      aspectRatio: fill ? 4 / 3 : null,
      onTap: fill
          ? () => showMedicationPhotoViewer(
              context,
              bytes: photo.bytes,
              label: label,
            )
          : null,
      tapLabel: fill ? l.rvm_photoOpen(name) : null,
    );
    return gapAbove == 0
        ? frame
        : Padding(
            padding: EdgeInsets.only(top: gapAbove),
            child: frame,
          );
  }
}

/// Opens [bytes] full screen on a dark ground, pinch to zoom, with a Close
/// button that is always on screen.
Future<void> showMedicationPhotoViewer(
  BuildContext context, {
  required Uint8List bytes,
  required String label,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _PhotoViewer(bytes: bytes, label: label),
  ),
);

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.bytes, required this.label});

  final Uint8List bytes;
  final String label;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      key: const ValueKey('medication-photo-viewer'),
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                semanticLabel: label,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
          PositionedDirectional(
            top: 8,
            end: 8,
            child: SafeArea(
              child: IconButton.filled(
                key: const ValueKey('medication-photo-close'),
                tooltip: l.rvm_photoClose,
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// [child] with the medication's photo to its right when there is one, and
/// [child] alone otherwise, so a page without a photo keeps its full width.
class MedicationPhotoBeside extends ConsumerWidget {
  const MedicationPhotoBeside({
    super.key,
    required this.pillId,
    required this.name,
    required this.child,
    this.photoWidth = 280,
    this.stacked = false,
    this.childIsEmpty = false,
  });

  final String pillId;
  final String name;
  final Widget child;
  final double photoWidth;

  /// There is nothing to show beside the photo: the photo then sits alone, at
  /// the start, instead of leaving an empty column next to it.
  final bool childIsEmpty;

  /// Puts the photo under [child] at the full width, up to 480, for a pane
  /// too narrow for two columns.
  final bool stacked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(medicationPhotoProvider(pillId)).asData?.value;
    if (photo == null) return child;
    if (childIsEmpty) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: MedicationPhotoCard(
          pillId: pillId,
          name: name,
          maxWidth: photoWidth > 0 ? photoWidth : 480,
          fill: true,
        ),
      );
    }
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          child,
          MedicationPhotoCard(
            pillId: pillId,
            name: name,
            maxWidth: 480,
            fill: true,
            gapAbove: 16,
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: child),
        const SizedBox(width: 28),
        SizedBox(
          width: photoWidth,
          child: MedicationPhotoCard(
            pillId: pillId,
            name: name,
            maxWidth: photoWidth,
            fill: true,
          ),
        ),
      ],
    );
  }
}

/// The bytes of a photo inside the card's frame.
class MedicationPhotoFrame extends StatelessWidget {
  const MedicationPhotoFrame({
    super.key,
    required this.bytes,
    required this.semanticLabel,
    this.maxWidth = 420,
    this.maxHeight = 260,
    this.aspectRatio,
    this.onTap,
    this.tapLabel,
  });

  final Uint8List bytes;
  final String semanticLabel;
  final double maxWidth;
  final double maxHeight;

  /// A fixed shape (width over height) filled edge to edge; the picture is
  /// still never cropped. Null hugs the picture.
  final double? aspectRatio;

  /// Opens the picture larger. [tapLabel] names that for a screen reader.
  final VoidCallback? onTap;
  final String? tapLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fixed = aspectRatio != null;
    Widget picture = Image.memory(
      bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: onTap == null ? semanticLabel : null,
      excludeFromSemantics: onTap != null,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    if (fixed) picture = Center(child: picture);
    Widget framed = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: .5)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: onTap == null
            ? picture
            : Stack(
                fit: fixed ? StackFit.expand : StackFit.loose,
                children: [
                  picture,
                  Positioned.fill(
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        key: const ValueKey('medication-photo-open'),
                        onTap: onTap,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
    if (fixed) framed = AspectRatio(aspectRatio: aspectRatio!, child: framed);
    if (onTap != null) {
      framed = Semantics(
        button: true,
        label: tapLabel ?? semanticLabel,
        excludeSemantics: true,
        onTap: onTap,
        child: framed,
      );
    }
    if (fixed) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: framed,
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: framed,
      ),
    );
  }
}
