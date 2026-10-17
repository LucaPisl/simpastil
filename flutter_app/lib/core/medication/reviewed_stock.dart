import 'dart:convert';
import 'package:drift/drift.dart';
import '../db/database.dart';
import '../workspace/workspace_access_repository.dart';
import '../workspace/workspace_context.dart';
import 'medication_amount.dart';

/// Signed exact physical quantity. Zero, negative and unknown stock are distinct.
class StockQuantity {
  StockQuantity(BigInt numerator, BigInt denominator, String unit)
    : numerator = numerator ~/ numerator.gcd(denominator),
      denominator = denominator ~/ numerator.gcd(denominator),
      unit = unit.trim() {
    if (denominator <= BigInt.zero ||
        this.unit.isEmpty ||
        this.unit.length > 80) {
      throw const FormatException('Invalid reviewed stock quantity');
    }
  }
  factory StockQuantity.parse(String quantity, String unit) {
    final input = quantity.trim();
    final negative = input.startsWith('-');
    final text = negative ? input.substring(1) : input;
    if (RegExp(r'^0+(?:[.,]0+)?$').hasMatch(text)) {
      return StockQuantity(BigInt.zero, BigInt.one, unit);
    }
    final amount = MedicationAmount.known(text, unit);
    return StockQuantity(
      negative ? -amount.numerator! : amount.numerator!,
      amount.denominator!,
      unit,
    );
  }
  factory StockQuantity.fromAmount(MedicationAmount amount) {
    if (amount.isUnknown) {
      throw const FormatException('Unknown physical amount');
    }
    return StockQuantity(amount.numerator!, amount.denominator!, amount.unit!);
  }
  final BigInt numerator;
  final BigInt denominator;
  final String unit;
  StockQuantity operator -() => StockQuantity(-numerator, denominator, unit);
  StockQuantity operator +(StockQuantity other) {
    if (unit != other.unit) {
      throw const FormatException('Unreviewed unit relationship');
    }
    return StockQuantity(
      numerator * other.denominator + other.numerator * denominator,
      denominator * other.denominator,
      unit,
    );
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'numerator': numerator.toString(),
    'denominator': denominator.toString(),
    'unit': unit,
  };
  factory StockQuantity.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported stock quantity');
    }
    return StockQuantity(
      BigInt.parse(json['numerator'] as String),
      BigInt.parse(json['denominator'] as String),
      json['unit'] as String,
    );
  }
}

enum CareStockOutcome {
  notTracked,
  applied,
  needsReview,

  /// The change was recorded but the stock count was left as it was: undoing
  /// a dose taken before the ledger was active, whose stock the server's
  /// opening count already included.
  unchanged,
}

/// Explicit review enables a physical balance; it never relabels legacy stock.
class ReviewedStockRepository {
  ReviewedStockRepository({
    required this.database,
    required this.access,
    required this.context,
  });
  final AppDatabase database;
  final WorkspaceAccessRepository access;
  final WorkspaceContext context;
  Future<ReviewedStockBalance?> load(String pillId) =>
      access.withGrant(context, () async {
        final pill = await database.pillsDao.getById(pillId);
        if (pill == null || pill.isDeleted) {
          throw const WorkspaceAccessFailure(
            WorkspaceAccessFailureCode.wrongPerson,
          );
        }
        await access.requireCurrent(context, profileId: pill.profileId);
        return (database.select(database.reviewedStockBalances)..where(
              (s) =>
                  s.workspaceId.equals(context.workspaceId) &
                  s.pillId.equals(pillId),
            ))
            .getSingleOrNull();
      });
  Future<ReviewedStockBalance> review(
    String pillId,
    StockQuantity quantity, {
    required int expectedRevision,
  }) => access.withGrant(context, () async {
    if (!context.isLocal) {
      throw const WorkspaceAccessFailure(
        WorkspaceAccessFailureCode.unavailable,
      );
    }
    final old = await load(pillId);
    if ((old?.revision ?? 0) != expectedRevision) {
      throw StateError('Stock review changed');
    }
    await database
        .into(database.reviewedStockBalances)
        .insertOnConflictUpdate(
          ReviewedStockBalancesCompanion.insert(
            workspaceId: context.workspaceId,
            pillId: pillId,
            authorId: context.authorId,
            quantityJson: jsonEncode(quantity.toJson()),
            reviewRevision: (old?.reviewRevision ?? 0) + 1,
            revision: expectedRevision + 1,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    return (await load(pillId))!;
  });
}

/// Runs only inside the caller's captured care transaction.
Future<({CareStockOutcome outcome, String? effectJson})>
commitReviewedStockEffect({
  required AppDatabase db,
  required WorkspaceContext context,
  required Pill pill,
  required String action,
  required String fromState,
  required String toState,
  required MedicationAmount amount,
  CareEventDetail? headDetails,
}) async {
  final row =
      await (db.select(db.reviewedStockBalances)..where(
            (s) =>
                s.workspaceId.equals(context.workspaceId) &
                s.pillId.equals(pill.id),
          ))
          .getSingleOrNull();
  if (row == null) {
    return (
      outcome: pill.currentStock == null
          ? CareStockOutcome.notTracked
          : CareStockOutcome.needsReview,
      effectJson: null,
    );
  }
  StockQuantity before;
  StockQuantity delta;
  StockQuantity consumptionBefore;
  StockQuantity consumptionAfter;
  try {
    before = StockQuantity.fromJson(
      jsonDecode(row.quantityJson) as Map<String, dynamic>,
    );
    delta = StockQuantity(BigInt.zero, BigInt.one, before.unit);
    consumptionBefore = StockQuantity(BigInt.zero, BigInt.one, before.unit);
    consumptionAfter = consumptionBefore;
    if (action == 'undo' || fromState == 'taken') {
      if (headDetails?.stockOutcome != CareStockOutcome.applied.name ||
          headDetails?.stockEffectJson == null) {
        return (outcome: CareStockOutcome.needsReview, effectJson: null);
      }
      final previous =
          jsonDecode(headDetails!.stockEffectJson!) as Map<String, dynamic>;
      if (previous['reviewRevision'] != row.reviewRevision) {
        return (outcome: CareStockOutcome.needsReview, effectJson: null);
      }
      consumptionBefore = StockQuantity.fromJson(
        Map<String, dynamic>.from(previous['consumptionAfter'] as Map),
      );
      if (action == 'undo') {
        delta = -StockQuantity.fromJson(
          Map<String, dynamic>.from(previous['delta'] as Map),
        );
        consumptionAfter = StockQuantity.fromJson(
          Map<String, dynamic>.from(previous['consumptionBefore'] as Map),
        );
      } else {
        // Corrections remove the currently attributable consumption, which can
        // differ from the most recent correction's net balance delta.
        delta = consumptionBefore;
      }
      if (delta.unit != before.unit) {
        return (outcome: CareStockOutcome.needsReview, effectJson: null);
      }
    }
    if (action != 'undo' && toState == 'taken') {
      if (amount.isUnknown || amount.unit != before.unit) {
        return (outcome: CareStockOutcome.needsReview, effectJson: null);
      }
      delta = delta + -StockQuantity.fromAmount(amount);
      consumptionAfter = StockQuantity.fromAmount(amount);
    }
  } on Object {
    // An unproven quantity relationship does not invent a stock change or block care.
    return (outcome: CareStockOutcome.needsReview, effectJson: null);
  }
  final after = before + delta;
  if (delta.numerator != BigInt.zero) {
    await (db.update(db.reviewedStockBalances)..where(
          (s) =>
              s.workspaceId.equals(context.workspaceId) &
              s.pillId.equals(pill.id),
        ))
        .write(
          ReviewedStockBalancesCompanion(
            quantityJson: Value(jsonEncode(after.toJson())),
            revision: Value(row.revision + 1),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }
  return (
    outcome: CareStockOutcome.applied,
    effectJson: jsonEncode({
      'version': 1,
      'reviewRevision': row.reviewRevision,
      'delta': delta.toJson(),
      'consumptionBefore': consumptionBefore.toJson(),
      'consumptionAfter': consumptionAfter.toJson(),
      'before': before.toJson(),
      'after': after.toJson(),
    }),
  );
}
