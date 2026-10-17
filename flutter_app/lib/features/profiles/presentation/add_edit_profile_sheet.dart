import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/database.dart';
import '../../../core/errors/app_error.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/motion/app_motion.dart';
import '../../../shared/motion/pressable.dart';
import '../../../shared/widgets/confirm_delete_dialog.dart';
import '../../pills/presentation/medication_form_kit.dart';
import '../profile_provider.dart';

// ── Emoji set ────────────────────────────────────────────────────────────────

const _kEmojis = [
  '👤',
  '👨',
  '👩',
  '👦',
  '👧',
  '🧑',
  '👴',
  '👵',
  '🧒',
  '👶',
  '🏥',
  '💊',
  '🩺',
  '🩹',
  '🧬',
  '❤️',
  '🫀',
  '🧠',
  '👁️',
  '🦷',
];

// ── Public API ────────────────────────────────────────────────────────────────

/// Opens the add/edit profile sheet.
///
/// Pass [profile] to open in edit mode; omit for create mode.
Future<void> showAddEditProfileSheet({
  required BuildContext context,
  Profile? profile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _AddEditProfileSheet(profile: profile),
  );
}

// ── Sheet ─────────────────────────────────────────────────────────────────────

class _AddEditProfileSheet extends ConsumerStatefulWidget {
  const _AddEditProfileSheet({this.profile});

  final Profile? profile;

  @override
  ConsumerState<_AddEditProfileSheet> createState() =>
      _AddEditProfileSheetState();
}

class _AddEditProfileSheetState extends ConsumerState<_AddEditProfileSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late String _selectedEmoji;
  bool _isSaving = false;
  bool _isDeleting = false;
  final Object _sectionIdentity = Object();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile?.name ?? '');
    _selectedEmoji = widget.profile?.avatarEmoji ?? _kEmojis.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _isEditMode => widget.profile != null;

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);

    final repo = ref.read(profileRepositoryProvider);
    final name = _nameController.text.trim();

    final result = _isEditMode
        ? await repo.update(widget.profile!.id, name, _selectedEmoji)
        : await repo.create(name, _selectedEmoji);

    if (!mounted || !identical(repo, ref.read(profileRepositoryProvider))) {
      return;
    }
    setState(() => _isSaving = false);

    switch (result) {
      case Ok():
        Navigator.of(context).pop();
      case Err(:final error):
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorMessage(error, l))));
    }
  }

  Future<void> _deleteProfile() async {
    final l = AppLocalizations.of(context);
    final profile = widget.profile!;
    final repo = ref.read(profileRepositoryProvider);
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: l.profiles_deleteTitle(profile.name),
      message: l.profiles_deleteMessage(profile.name),
    );
    if (!confirmed || !mounted) return;

    setState(() => _isDeleting = true);
    try {
      final result = await repo.delete(profile.id);
      if (!mounted || !identical(repo, ref.read(profileRepositoryProvider))) {
        return;
      }
      if (result is Err) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.profiles_failedToDelete)));
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(l.profiles_deleted)));
    } catch (_) {
      if (!mounted || !identical(repo, ref.read(profileRepositoryProvider))) {
        return;
      }
      final l2 = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l2.profiles_failedToDelete)));
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);

    // Read primary profile ID when in edit mode.
    final primaryId = _isEditMode
        ? ref.watch(primaryProfileIdProvider).valueOrNull
        : null;
    final isAlreadyPrimary = _isEditMode && primaryId == widget.profile!.id;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scrollController) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            // ── Handle ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _isEditMode
                            ? l.profiles_editTitle
                            : l.profiles_newTitle,
                        style: text.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      _PersonPreview(
                        name: _nameController,
                        emoji: _selectedEmoji,
                      ),
                      const SizedBox(height: 16),
                      FormSection(
                        index: 0,
                        identity: _sectionIdentity,
                        icon: Icons.person_outline_rounded,
                        title: l.mf_sectionWho,
                        hint: l.mf_personHint,
                        children: [
                          TextFormField(
                            controller: _nameController,
                            autofocus: true,
                            maxLength: 100,
                            textCapitalization: TextCapitalization.words,
                            decoration: InputDecoration(
                              labelText: l.profiles_nameLabel,
                              counterText: '',
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? l.mf_nameNeeded
                                : null,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                          ),
                        ],
                      ),
                      FormSection(
                        index: 1,
                        identity: _sectionIdentity,
                        icon: Icons.mood_rounded,
                        title: l.mf_personFace,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final emoji in _kEmojis)
                                _EmojiChoice(
                                  emoji: emoji,
                                  selected: emoji == _selectedEmoji,
                                  label: emoji == _selectedEmoji
                                      ? l.profiles_avatarSelected(emoji)
                                      : l.profiles_avatarUnselected(emoji),
                                  onTap: () =>
                                      setState(() => _selectedEmoji = emoji),
                                ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // ── Save button ──────────────────────────────────────
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: (_isSaving || _isDeleting) ? null : _submit,
                        child: _isSaving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l.shared_save),
                      ),

                      // ── Edit-mode extras ─────────────────────────────────
                      if (_isEditMode) ...[
                        const SizedBox(height: 12),

                        // Set as primary button
                        FilledButton.tonal(
                          onPressed: isAlreadyPrimary
                              ? null
                              : () => ref
                                    .read(primaryProfileIdProvider.notifier)
                                    .setPrimary(widget.profile!.id),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isAlreadyPrimary) ...[
                                Icon(
                                  Icons.check,
                                  size: 18,
                                  color: cs.onSecondaryContainer,
                                ),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                isAlreadyPrimary
                                    ? l.profiles_primaryProfile
                                    : l.profiles_setAsPrimary,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Delete profile button
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: cs.error,
                            side: BorderSide(color: cs.error),
                          ),
                          onPressed: (_isSaving || _isDeleting)
                              ? null
                              : _deleteProfile,
                          child: _isDeleting
                              ? SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: cs.error,
                                  ),
                                )
                              : Text(l.profiles_deleteProfile),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _errorMessage(AppError error, AppLocalizations l) => switch (error) {
    NetworkError() => l.error_noConnection,
    UnauthorizedError() => l.error_sessionExpired,
    NotFoundError() => l.error_profileNotFound,
    ServerError(:final statusCode) => l.error_serverError(statusCode),
    _ => l.shared_somethingWentWrong,
  };
}

/// A calm card that shows the person as they will appear: their face and
/// name, following each keystroke. Decorative; the field carries the value.
class _PersonPreview extends StatelessWidget {
  const _PersonPreview({required this.name, required this.emoji});
  final TextEditingController name;
  final String emoji;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final l = AppLocalizations.of(context);
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primaryContainer, cs.surfaceContainerLow],
          ),
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: AppMotion.duration(context),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: Tween(begin: .8, end: 1.0).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Container(
                key: ValueKey(emoji),
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.surface,
                  shape: BoxShape.circle,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: ListenableBuilder(
                listenable: name,
                builder: (context, _) {
                  final value = name.text.trim();
                  return Text(
                    value.isEmpty ? l.mf_previewPlaceholder : value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleLarge?.copyWith(
                      color: value.isEmpty ? cs.onSurfaceVariant : cs.onSurface,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmojiChoice extends StatelessWidget {
  const _EmojiChoice({
    required this.emoji,
    required this.selected,
    required this.label,
    required this.onTap,
  });
  final String emoji;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        radius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: AppMotion.duration(context),
          curve: AppMotion.curve,
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer : cs.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}
